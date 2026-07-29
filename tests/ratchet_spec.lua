local date = require("mdical.date")
local parse = require("mdical.parse")
local ratchet = require("mdical.ratchet")
local uid = require("mdical.uid")

local TODAY = { year = 2026, month = 7, day = 29 } -- a Wednesday

local function marker(line, path, lnum)
  return { parsed = parse.line(line), path = path or "notes.md", lnum = lnum or 1 }
end

--- A resource shaped the way iOS shapes one.
local function resource(id, props)
  local lines = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Apple Inc.//iOS 26.5.2//EN", "BEGIN:VTODO" }
  lines[#lines + 1] = "UID:" .. id
  for _, p in ipairs(props) do
    lines[#lines + 1] = p
  end
  lines[#lines + 1] = "END:VTODO"
  lines[#lines + 1] = "END:VCALENDAR"
  lines[#lines + 1] = ""
  return { path = "/vdir/" .. id .. ".ics", text = table.concat(lines, "\r\n") }
end

--- A completed resource for the marker with this summary and occurrence date.
local function ticked(summary, iso, at)
  return resource(uid.item("task", summary, iso), {
    "SUMMARY:" .. summary,
    "STATUS:COMPLETED",
    "PERCENT-COMPLETE:100",
    "COMPLETED:" .. (at or "20260728T195946Z"),
  })
end

local function fixture()
  local f = assert(io.open(TEST_ROOT .. "/tests/fixtures/ingest/a1-completed-by-ios.ics", "rb"))
  local text = f:read("*a")
  f:close()
  return { path = "a1.ics", text = text }
end

describe("ratchet.is_complete", function()
  local function todo(props)
    local ical = require("mdical.ical")
    return ical.find(ical.read(resource("x", props).text), "VTODO")[1]
  end

  it("recognises the phone's own completed task", function()
    local ical = require("mdical.ical")
    truthy(ratchet.is_complete(ical.find(ical.read(fixture().text), "VTODO")[1]), "the real bytes")
  end)

  it("takes STATUS on its own", function()
    truthy(ratchet.is_complete(todo({ "STATUS:COMPLETED" })), "status")
  end)

  it("takes PERCENT-COMPLETE on its own", function()
    truthy(ratchet.is_complete(todo({ "PERCENT-COMPLETE:100" })), "percent")
  end)

  it("leaves an outstanding task alone", function()
    eq(ratchet.is_complete(todo({ "STATUS:NEEDS-ACTION" })), false, "needs action")
    eq(ratchet.is_complete(todo({ "PERCENT-COMPLETE:50" })), false, "half done is not done")
    eq(ratchet.is_complete(todo({})), false, "nothing said")
  end)
end)

describe("ratchet.completed_at", function()
  local ical = require("mdical.ical")

  it("prefers COMPLETED, converted to local time", function()
    local todo = ical.find(ical.read(fixture().text), "VTODO")[1]
    local d, t, source = ratchet.completed_at(todo, { offset = 3600 })
    eq(source, "COMPLETED", "the right property")
    eq(d, { year = 2026, month = 7, day = 28 }, "date")
    eq({ t.hour, t.min }, { 20, 59 }, "20:59 BST, not 19:59Z")
  end)

  it("falls back for a client that sets only STATUS", function()
    local todo = ical.find(ical.read(resource("x", {
      "STATUS:COMPLETED",
      "LAST-MODIFIED:20260728T195948Z",
    }).text), "VTODO")[1]
    eq(select(3, ratchet.completed_at(todo, { offset = 0 })), "LAST-MODIFIED", "second choice")
  end)

  it("reports none rather than guessing", function()
    local todo = ical.find(ical.read(resource("x", { "STATUS:COMPLETED" }).text), "VTODO")[1]
    eq(select(3, ratchet.completed_at(todo)), "none", "nothing to read")
  end)
end)

describe("ratchet.completions", function()
  it("reads the phone's completion out of the real resource", function()
    local got = ratchet.completions({ fixture() }, { offset = 3600 })
    eq(#got, 1, "one")
    eq(got[1].uid, "m0-a1-due-date", "uid from the content, not the filename")
    eq(got[1].summary, "A1 due date only", "summary")
    eq(got[1].source, "COMPLETED", "source")
  end)

  it("ignores what is not completed", function()
    eq(#ratchet.completions({ resource("x", { "STATUS:NEEDS-ACTION" }) }), 0, "none")
  end)

  it("unescapes the summary, so it can be compared with a marker's", function()
    local got = ratchet.completions({ resource("x", {
      "STATUS:COMPLETED",
      "SUMMARY:buy milk\\, bread and eggs",
    }) })
    eq(got[1].summary, "buy milk, bread and eggs", "as written in the note")
  end)
end)

describe("ratchet.index", function()
  it("maps every occurrence of a repeater", function()
    local m = marker("- [ ] pay rent <2026-08-01 Sat +1m>")
    local index = ratchet.index({ m }, { today = TODAY })
    local dates = {}
    for _, entry in pairs(index) do
      dates[#dates + 1] = date.iso(entry.date)
    end
    table.sort(dates)
    eq(dates, { "2026-08-01", "2026-09-01", "2026-10-01" }, "three months of rent")
  end)

  it("finds an undated task under its undated uid", function()
    local index = ratchet.index({ marker("- [ ] something someday <>") }, { today = TODAY })
    truthy(index[uid.item("task", "something someday", nil)], "indexed")
  end)

  it("holds nothing for a line that does not emit", function()
    local index = ratchet.index({
      marker("- [x] already done <2026-08-01 Sat> CLOSED: [2026-07-28 Tue]"),
      marker("<2026-08-05 Wed> standup"),
      marker("- [ ] a bare checkbox"),
    }, { today = TODAY })
    eq(next(index), nil, "empty: done, an event, and a non-marker")
  end)

  it("counts two lines collapsing onto one resource", function()
    local _, duplicates = ratchet.index({
      marker("- [ ] pay rent <2026-08-01 Sat>", "a.md", 1),
      marker("- [ ] pay rent <2026-08-01 Sat>", "b.md", 1),
    }, { today = TODAY })
    eq(duplicates, 1, "one duplicate")
  end)
end)

describe("ratchet.rewrite", function()
  local completion = { date = { year = 2026, month = 7, day = 28 }, time = { hour = 20, min = 59 } }

  local function rewrite(line, occurrence)
    return ratchet.rewrite(parse.line(line), occurrence, completion, { today = TODAY })
  end

  it("ticks a one-off and records when", function()
    eq(rewrite("- [ ] pay rent <2026-08-01 Sat>"),
      "- [x] pay rent <2026-08-01 Sat> CLOSED: [2026-07-28 Tue 20:59]", "ticked and closed")
  end)

  it("keeps everything else on the line exactly where it was", function()
    local got = rewrite("  - [ ] !! renew the passport DEADLINE: <2026-08-01 Sat 10:00 -3d> #admin")
    eq(got, "  - [x] !! renew the passport DEADLINE: <2026-08-01 Sat 10:00 -3d> #admin"
      .. " CLOSED: [2026-07-28 Tue 20:59]", "indent, priority, keyword, time, warning and tag all intact")
  end)

  it("replaces an existing CLOSED rather than appending a second", function()
    local got = rewrite("- [ ] pay rent <2026-08-01 Sat> CLOSED: [2026-01-01 Thu]")
    eq(got, "- [x] pay rent <2026-08-01 Sat> CLOSED: [2026-07-28 Tue 20:59]", "one CLOSED")
  end)

  it("writes CLOSED without a time when there was none to read", function()
    local got = ratchet.rewrite(parse.line("- [ ] pay rent <2026-08-01 Sat>"), nil,
      { date = { year = 2026, month = 7, day = 28 } }, { today = TODAY })
    eq(got, "- [x] pay rent <2026-08-01 Sat> CLOSED: [2026-07-28 Tue]", "date only")
  end)

  it("advances `+` one interval from the occurrence that was ticked", function()
    -- September ticked with August still outstanding: the anchor must land on
    -- October, not back on the September the phone just completed
    local got, note = rewrite("- [ ] pay rent <2026-08-01 Sat +1m>", { year = 2026, month = 9, day = 1 })
    eq(got, "- [ ] pay rent <2026-10-01 Thu +1m>", "advanced past the ticked one")
    eq(note, "advanced to 2026-10-01", "reported")
    truthy(got:find("- [ ]", 1, true), "and the box stays unticked, as org does it")
  end)

  it("advances `+` even when that leaves it in the past, which is the point of `+`", function()
    local got = rewrite("- [ ] water the plants <2026-07-22 Wed +1w>", { year = 2026, month = 7, day = 22 })
    eq(got, "- [ ] water the plants <2026-07-29 Wed +1w>", "one interval, onto today")
  end)

  it("makes `++` catch up past today instead", function()
    local got = rewrite("- [ ] water the plants <2026-07-22 Wed ++1w>", { year = 2026, month = 7, day = 22 })
    eq(got, "- [ ] water the plants <2026-08-05 Wed ++1w>", "skipped the one that is only today")
  end)

  it("computes `.+` from the completion date", function()
    local got = rewrite("- [ ] water the plants <2026-07-30 Thu .+3d>")
    eq(got, "- [ ] water the plants <2026-07-31 Fri .+3d>", "28 July plus three days")
  end)

  it("refuses `.+` with no completion date rather than guessing", function()
    local got, why = ratchet.rewrite(parse.line("- [ ] plants <2026-07-30 Thu .+3d>"), nil, {}, { today = TODAY })
    nilly(got, "no rewrite")
    truthy(why:find("CLOSED", 1, true), "and says why: " .. tostring(why))
  end)

  it("keeps the time and the warning when it advances", function()
    local got = rewrite("- [ ] standup DEADLINE: <2026-08-01 Sat 09:00 +1w -1d>",
      { year = 2026, month = 8, day = 1 })
    eq(got, "- [ ] standup DEADLINE: <2026-08-08 Sat 09:00 +1w -1d>", "cookies survive")
  end)

  it("leaves an RRULE passthrough alone", function()
    local got, why = rewrite("- [ ] gym <2026-08-01 Sat> RRULE: FREQ=WEEKLY;INTERVAL=1")
    nilly(got, "untouched")
    truthy(why:find("RRULE", 1, true), "and says why: " .. tostring(why))
  end)

  it("ticks an undated task", function()
    eq(rewrite("- [ ] something someday <>"),
      "- [x] something someday <> CLOSED: [2026-07-28 Tue 20:59]", "closed")
  end)
end)

describe("ratchet.plan", function()
  it("turns the phone's tick into one line change", function()
    local markers = {
      marker("- [ ] pay rent <2026-08-01 Sat>", "money.md", 12),
      marker("- [ ] unrelated <2026-09-09 Wed>", "money.md", 13),
    }
    local plan = ratchet.plan(markers, ratchet.completions({ ticked("pay rent", "2026-08-01") }, { offset = 3600 }),
      { today = TODAY })
    eq(#plan.changes, 1, "one change")
    eq(plan.changes[1].path, "money.md", "path")
    eq(plan.changes[1].lnum, 12, "line")
    eq(plan.changes[1].after, "- [x] pay rent <2026-08-01 Sat> CLOSED: [2026-07-28 Tue 20:59]", "the new line")
  end)

  it("leaves a task the phone created entirely alone", function()
    -- the rule that keeps captured work from being eaten. Its uid is not ours,
    -- there is no marker to match, and nothing is written.
    local plan = ratchet.plan({}, ratchet.completions({
      resource("6C7E1B4A-PHONE", { "STATUS:COMPLETED", "SUMMARY:bought on the bus" }),
    }), { today = TODAY })
    eq(#plan.changes, 0, "no changes")
    eq(plan.unknown, 1, "counted as not ours")
    eq(plan.gone, 0, "and not mistaken for a deleted marker")
  end)

  it("distinguishes ours-but-deleted from never-ours", function()
    local plan = ratchet.plan({}, ratchet.completions({ ticked("a marker since deleted", "2026-08-01") }),
      { today = TODAY })
    eq(plan.gone, 1, "ours, and markdown no longer has it")
    eq(plan.unknown, 0, "not unknown")
    eq(#plan.changes, 0, "nothing to write")
  end)

  it("collapses two ticks of one repeater into a single advance", function()
    -- August and September rent both ticked in one night. Two rewrites of one
    -- line would mean the second was computed from a line that no longer exists.
    local markers = { marker("- [ ] pay rent <2026-08-01 Sat +1m>", "money.md", 12) }
    local completions = ratchet.completions({
      ticked("pay rent", "2026-08-01"),
      ticked("pay rent", "2026-09-01"),
    }, { offset = 3600 })
    local plan = ratchet.plan(markers, completions, { today = TODAY })
    eq(#plan.changes, 1, "one change")
    eq(plan.changes[1].after, "- [ ] pay rent <2026-10-01 Thu +1m>", "advanced from the later tick")
  end)

  it("reports what it refused", function()
    local markers = { marker("- [ ] gym <2026-08-01 Sat> RRULE: FREQ=WEEKLY;INTERVAL=1", "health.md", 3) }
    local plan = ratchet.plan(markers, ratchet.completions({ ticked("gym", "2026-08-01") }), { today = TODAY })
    eq(#plan.changes, 0, "nothing written")
    eq(#plan.skipped, 1, "one reported")
    truthy(plan.skipped[1].why:find("RRULE", 1, true), "with a reason")
  end)

  it("counts only the changes that stop a marker promoting", function()
    -- what the build's gate credit is made of: a closed task disappears from the
    -- calendar, an advanced repeater is still there on a later date
    local markers = {
      marker("- [ ] a one-off <2026-08-01 Sat>", "a.md", 1),
      marker("- [ ] a repeater <2026-08-01 Sat +1m>", "a.md", 2),
    }
    local plan = ratchet.plan(markers, ratchet.completions({
      ticked("a one-off", "2026-08-01"), ticked("a repeater", "2026-08-01"),
    }), { today = TODAY })
    eq(#plan.changes, 2, "both changed")
    eq(plan.closed, 1, "but only one stopped promoting")
  end)

  it("changes nothing when the phone has ticked nothing", function()
    local plan = ratchet.plan({ marker("- [ ] pay rent <2026-08-01 Sat>") }, {}, { today = TODAY })
    eq(#plan.changes, 0, "no changes")
    eq(#plan.skipped, 0, "nothing skipped")
  end)

  it("sorts changes by file then line, so a run reads the same twice", function()
    local markers = {
      marker("- [ ] b <2026-08-02 Sun>", "b.md", 5),
      marker("- [ ] a <2026-08-01 Sat>", "a.md", 9),
      marker("- [ ] c <2026-08-03 Mon>", "a.md", 2),
    }
    local plan = ratchet.plan(markers, ratchet.completions({
      ticked("b", "2026-08-02"), ticked("a", "2026-08-01"), ticked("c", "2026-08-03"),
    }), { today = TODAY })
    local seen = {}
    for _, c in ipairs(plan.changes) do
      seen[#seen + 1] = ("%s:%d"):format(c.path, c.lnum)
    end
    eq(seen, { "a.md:2", "a.md:9", "b.md:5" }, "ordered")
  end)
end)

describe("ratchet.splice", function()
  local function change(lnum, before, after)
    return { lnum = lnum, before = before, after = after }
  end

  it("replaces the named line and nothing else", function()
    local got, stale = ratchet.splice("one\ntwo\nthree\n", { change(2, "two", "TWO") })
    eq(got, "one\nTWO\nthree\n", "spliced")
    eq(stale, {}, "nothing stale")
  end)

  it("keeps crlf, because the file's line endings are not ours to normalise", function()
    local got = ratchet.splice("one\r\ntwo\r\n", { change(2, "two", "TWO") })
    eq(got, "one\r\nTWO\r\n", "crlf on both lines, including the one that changed")
  end)

  it("keeps a missing final newline missing", function()
    eq(ratchet.splice("one\ntwo", { change(2, "two", "TWO") }), "one\nTWO", "no newline invented")
  end)

  it("keeps a blank final line", function()
    eq(ratchet.splice("one\n\n", { change(1, "one", "ONE") }), "ONE\n\n", "still there")
  end)

  it("takes several changes in one pass", function()
    eq(ratchet.splice("a\nb\nc\n", { change(1, "a", "A"), change(3, "c", "C") }), "A\nb\nC\n", "both")
  end)

  it("refuses when the line is not what was planned", function()
    -- something else is editing the vault, and guessing would corrupt a note
    local got, stale = ratchet.splice("one\nedited by hand\n", { change(2, "two", "TWO") })
    eq(stale, { 2 }, "reported")
    eq(got, "one\nedited by hand\n", "and the text comes back untouched")
  end)

  it("counts a line the file no longer has as stale", function()
    eq(select(2, ratchet.splice("one\n", { change(9, "nine", "NINE") })), { 9 }, "past the end")
  end)

  it("leaves a file it was given no changes for exactly as it was", function()
    eq(ratchet.splice("one\ntwo\n", {}), "one\ntwo\n", "byte for byte")
  end)

  it("counts lines the way scan.read does", function()
    -- if these ever disagreed the ratchet would write to the wrong line, which is
    -- the worst thing it could possibly do
    local scan = require("mdical.scan")
    local text = "---\ntags:\n  - x\n---\n\n- [ ] a task\nlast\n"
    local path = os.tmpname()
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
    local lines = scan.read(path)
    os.remove(path)
    for lnum, line in ipairs(lines) do
      local got = ratchet.splice(text, { change(lnum, line, "MARK") })
      truthy(got:find("MARK", 1, true) ~= nil, ("line %d agreed"):format(lnum))
      eq(select(2, ratchet.splice(text, { change(lnum, line, "MARK") })), {}, ("line %d not stale"):format(lnum))
    end
  end)
end)

describe("date instants", function()
  it("round-trips through the epoch", function()
    for _, iso in ipairs({ "1970-01-01", "2026-07-28", "2000-02-29", "2100-03-01" }) do
      local d = date.parse_iso(iso)
      local back = date.from_epoch(date.to_epoch(d, { hour = 13, min = 45, sec = 6 }))
      eq(date.iso(back), iso, iso)
      eq(select(2, date.from_epoch(date.to_epoch(d, { hour = 13, min = 45, sec = 6 }))),
        { hour = 13, min = 45, sec = 6 }, "time too")
    end
  end)

  it("agrees with a known epoch second", function()
    eq(date.to_epoch({ year = 1970, month = 1, day = 1 }, { hour = 0, min = 0, sec = 0 }), 0, "the epoch")
    eq(date.to_epoch({ year = 2026, month = 7, day = 28 }, { hour = 19, min = 59, sec = 46 }), 1785268786,
      "the real a1 completion")
  end)

  it("reports the system offset as a number of seconds", function()
    local offset = date.utc_offset(1785268786)
    truthy(type(offset) == "number", "a number")
    eq(offset % 900, 0, "and a whole quarter hour, as every real zone is")
  end)
end)

describe("parse done-repeater", function()
  local function codes(line)
    local out = {}
    for _, d in ipairs(parse.line(line).diagnostics) do
      out[d.code] = d.severity
    end
    return out
  end

  it("warns when a repeating task is ticked by hand", function()
    -- the ratchet advances the date and leaves the box alone; a ticked one has
    -- had its series ended, silently, which is worth saying out loud
    eq(codes("- [x] pay rent <2026-08-01 Sat +1m> CLOSED: [2026-08-01 Sat]")["done-repeater"], parse.WARN,
      "warned")
  end)

  it("says nothing about a ticked one-off", function()
    nilly(codes("- [x] pay rent <2026-08-01 Sat> CLOSED: [2026-08-01 Sat]")["done-repeater"], "no warning")
  end)

  it("says nothing about an outstanding repeater", function()
    nilly(codes("- [ ] pay rent <2026-08-01 Sat +1m>")["done-repeater"], "no warning")
  end)
end)
