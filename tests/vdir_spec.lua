local vdir = require("mdical.vdir")
local state = require("mdical.state")

local function tempdir()
  local path = os.tmpname()
  os.remove(path)
  vdir.ensure(path)
  return path
end

local function item(uid, text)
  return { uid = uid, text = text or ("BEGIN:VCALENDAR\r\nUID:" .. uid .. "\r\nEND:VCALENDAR\r\n") }
end

local function names(dir)
  local out = {}
  for id in pairs(vdir.existing(dir)) do
    out[#out + 1] = id
  end
  table.sort(out)
  return out
end

describe("vdir.sync", function()
  it("writes one file per item, named by uid", function()
    local dir = tempdir()
    local stats = vdir.sync(dir, { item("mdical-aaa"), item("mdical-bbb") })
    eq(stats.written, 2, "two written")
    eq(names(dir), { "mdical-aaa", "mdical-bbb" }, "on disk")
    eq(vdir.read(dir .. "/mdical-aaa.ics"), item("mdical-aaa").text, "contents")
  end)

  it("leaves a byte-identical resource completely alone", function()
    -- A11a showed a byte-identical rewrite is silent to the phone, and not
    -- touching the file keeps mtimes - and therefore git - quiet too
    local dir = tempdir()
    vdir.sync(dir, { item("mdical-aaa") })
    local stats = vdir.sync(dir, { item("mdical-aaa") })
    eq(stats.written, 0, "nothing written")
    eq(stats.unchanged, 1, "recognised as unchanged")
  end)

  it("rewrites a resource whose content changed", function()
    local dir = tempdir()
    vdir.sync(dir, { item("mdical-aaa") })
    local stats = vdir.sync(dir, { item("mdical-aaa", "BEGIN:VCALENDAR\r\nSUMMARY:new\r\nEND:VCALENDAR\r\n") })
    eq(stats.written, 1, "written")
    eq(stats.unchanged, 0, "not skipped")
    truthy(vdir.read(dir .. "/mdical-aaa.ics"):find("SUMMARY:new", 1, true) ~= nil, "new content")
  end)

  it("removes a resource it emitted once markdown no longer has it", function()
    local dir = tempdir()
    vdir.sync(dir, { item("mdical-aaa"), item("mdical-bbb") })
    local stats = vdir.sync(dir, { item("mdical-aaa") },
      { previous = { ["mdical-aaa"] = true, ["mdical-bbb"] = true } })
    eq(stats.removed, 1, "one removed")
    eq(names(dir), { "mdical-aaa" }, "only the wanted one is left")
  end)

  it("never deletes a resource it did not emit", function()
    -- The rule that keeps anything captured on the phone from being eaten. A
    -- strict "markdown is the only source" rebuild would delete this.
    local dir = tempdir()
    vdir.sync(dir, { item("mdical-aaa"), item("6C7E1B4A-PHONE") })
    local stats = vdir.sync(dir, {}, { previous = { ["mdical-aaa"] = true } })
    eq(stats.removed, 1, "ours went")
    eq(stats.kept_unknown, 1, "the phone's stayed")
    eq(names(dir), { "6C7E1B4A-PHONE" }, "and it is still on disk")
  end)

  it("will not delete an ours-looking uid the last run did not record", function()
    -- belt and braces: the prefix says it looks like ours, the state file says it
    -- is not, and disagreement resolves towards keeping the file
    local dir = tempdir()
    vdir.sync(dir, { item("mdical-ghost") })
    local stats = vdir.sync(dir, {}, { previous = { ["mdical-other"] = true } })
    eq(stats.removed, 0, "nothing removed")
    eq(stats.kept_unknown, 1, "kept")
  end)

  it("writes nothing at all on a dry run", function()
    local dir = tempdir()
    local stats = vdir.sync(dir, { item("mdical-aaa") }, { dry_run = true })
    eq(stats.written, 1, "reported as it would be written")
    eq(names(dir), {}, "but the directory is empty")
  end)

  it("writes the colour file vdirsyncer propagates, once", function()
    local dir = tempdir()
    vdir.sync(dir, {}, { colour = "#e66100" })
    eq(vdir.read(dir .. "/color"), "#e66100", "written")
    -- rewriting it every run would churn the file for no reason
    local before = vdir.read(dir .. "/color")
    vdir.sync(dir, {}, { colour = "#e66100" })
    eq(vdir.read(dir .. "/color"), before, "left alone when already right")
  end)

  it("leaves no .tmp files behind", function()
    local dir = tempdir()
    vdir.sync(dir, { item("mdical-aaa") })
    for id in pairs(vdir.existing(dir)) do
      truthy(not id:find("%.tmp$"), "no temp file: " .. id)
    end
    eq(vdir.read(dir .. "/mdical-aaa.ics.tmp"), nil, "the temp file was renamed away")
  end)
end)

describe("state", function()
  it("reads back what it wrote", function()
    local path = os.tmpname()
    local value = { version = 1, counts = { tasks = 3, events = 2 }, uids = { ["mdical-aaa"] = true } }
    truthy(state.write(path, value), "written")
    local got = state.read(path)
    eq(got.counts, value.counts, "counts")
    eq(got.uids, value.uids, "uids")
    os.remove(path)
  end)

  it("is byte-stable between identical runs", function()
    local path = os.tmpname()
    local value = { version = 1, counts = { tasks = 3, events = 2 }, uids = { b = true, a = true, c = true } }
    state.write(path, value)
    local first = vdir.read(path)
    state.write(path, value)
    eq(vdir.read(path), first, "identical bytes, so no churn in git")
    os.remove(path)
  end)

  it("treats a missing or broken file as no history", function()
    eq(state.read("/nonexistent/last-build.lua").counts, { tasks = 0, events = 0 }, "missing")
    local path = os.tmpname()
    local f = io.open(path, "wb")
    f:write("this is not lua {{{")
    f:close()
    eq(state.read(path).counts, { tasks = 0, events = 0 }, "unparseable")
    os.remove(path)
  end)
end)

describe("state.gate", function()
  it("passes when the counts hold up", function()
    truthy(state.gate({ markers = 10, notes = 10 }, { markers = 10, notes = 12 }), "steady or growing")
    truthy(state.gate({ markers = 10, notes = 10 }, { markers = 9, notes = 10 }), "a small dip")
  end)

  it("refuses a collapse, which is what one bad parse looks like", function()
    local ok, why = state.gate({ markers = 30, notes = 10 }, { markers = 0, notes = 10 })
    eq(ok, false, "refused")
    truthy(why and why:find("markers", 1, true), "and says which: " .. tostring(why))
  end)

  it("catches the notes going away, which is a checkout that did not update", function()
    eq(select(1, state.gate({ markers = 10, notes = 30 }, { markers = 10, notes = 1 })), false, "notes")
  end)

  it("watches markers rather than items, because completion moves items about", function()
    -- The real case this exists for: ticking a `+1m` task advances its anchor,
    -- and since the horizon runs from today while expansion runs from the anchor,
    -- three occurrences become one. An ordinary night looked like a broken parse.
    eq(state.GATE_KEYS, { "markers", "notes" }, "not tasks and events")
    truthy(state.gate({ markers = 7, notes = 1, tasks = 8 }, { markers = 7, notes = 1, tasks = 5 }),
      "items fell by a third and the gate does not care")
  end)

  it("credits the drop the ratchet already explained", function()
    -- eight one-offs ticked out of forty markers is a 20% fall and entirely
    -- normal; without the credit it reads exactly like a parser regression
    eq(select(1, state.gate({ markers = 40 }, { markers = 32 }, { allow_drop = 0.15 })), false,
      "refused with no explanation")
    truthy(state.gate({ markers = 40 }, { markers = 32 }, { allow_drop = 0.15, credit = { markers = 8 } }),
      "allowed once the closures are accounted for")
  end)

  it("does not let a credit excuse an unrelated collapse", function()
    eq(select(1, state.gate({ markers = 40 }, { markers = 0 }, { credit = { markers = 8 } })), false,
      "32 explained, the other 32 are not")
  end)

  it("does not fire on a vault too small for a ratio to mean anything", function()
    truthy(state.gate({ markers = 2, notes = 0 }, { markers = 0, notes = 0 }), "under the floor")
    truthy(state.gate({ markers = 0, notes = 0 }, { markers = 0, notes = 0 }), "a first run")
  end)

  it("takes a different tolerance", function()
    truthy(state.gate({ markers = 10 }, { markers = 6 }, { allow_drop = 0.5 }), "half allowed")
    eq(select(1, state.gate({ markers = 10 }, { markers = 6 }, { allow_drop = 0.1 })), false, "a tenth is not")
  end)

  it("watches whichever keys it is given", function()
    eq(select(1, state.gate({ tasks = 30 }, { tasks = 0 }, { keys = { "tasks" } })), false, "tasks, when asked")
  end)
end)
