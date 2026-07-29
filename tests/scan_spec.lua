local scan = require("mdical.scan")
local vdir = require("mdical.vdir")

local function vault(files)
  local root = os.tmpname()
  os.remove(root)
  vdir.ensure(root)
  for name, text in pairs(files) do
    local dir = name:match("^(.*)/[^/]+$")
    if dir then
      vdir.ensure(root .. "/" .. dir)
    end
    local f = assert(io.open(root .. "/" .. name, "wb"))
    f:write(text)
    f:close()
  end
  return root
end

local NOTES = [[
---
tags:
  - tasks
---

# markers

- [ ] pay rent <2026-08-01 Sat>
- [ ] a bare checkbox
- [x] and a done one
<2026-08-05 Wed> standup

```lua
- [ ] one in a fence <2026-08-06 Thu>
```
]]

local EXCLUDED = [[
---
tags:
  - meta
---
- [ ] never emitted <2026-08-01 Sat>
]]

local DAILY = [[
---
tags:
  - daily
---
- [ ] typed mid-daily <>
- [ ] and 742 more like this
]]

describe("scan.notes", function()
  it("finds markdown anywhere under the root, sorted", function()
    local root = vault({ ["b.md"] = "x", ["a.md"] = "x", ["daily/c.md"] = "x", ["notes.txt"] = "x" })
    local found = {}
    for _, path in ipairs(scan.notes(root)) do
      found[#found + 1] = path:sub(#root + 2)
    end
    eq(found, { "a.md", "b.md", "daily/c.md" }, "sorted, and only .md")
  end)
end)

describe("scan.read", function()
  it("splits into lines without a phantom trailing one", function()
    local root = vault({ ["a.md"] = "one\ntwo\nthree\n" })
    eq(scan.read(root .. "/a.md"), { "one", "two", "three" }, "three lines")
  end)

  it("copes with crlf and a missing final newline", function()
    local root = vault({ ["a.md"] = "one\r\ntwo", ["b.md"] = "" })
    eq(scan.read(root .. "/a.md"), { "one", "two" }, "crlf stripped")
    eq(scan.read(root .. "/b.md"), {}, "an empty note")
  end)

  it("returns nothing for a file that is not there", function()
    nilly(scan.read("/nonexistent/a.md"), "no lines")
  end)
end)

describe("scan.vault", function()
  local root = vault({ ["notes.md"] = NOTES, ["excluded.md"] = EXCLUDED, ["daily/20260729.md"] = DAILY })
  local result = scan.vault(root, nil)

  it("skips notes the scope excludes", function()
    eq(result.notes_scanned, 2, "two scanned")
    eq(result.notes_skipped, 1, "the meta-tagged one skipped")
    for _, m in ipairs(result.markers) do
      truthy(m.path ~= "excluded.md", "nothing from the excluded note")
    end
  end)

  it("emits only the lines that promote", function()
    local summaries = {}
    for _, m in ipairs(result.markers) do
      summaries[#summaries + 1] = m.parsed.summary
    end
    table.sort(summaries)
    eq(summaries, { "pay rent", "standup", "typed mid-daily" }, "three markers")
  end)

  it("leaves the incidental checkboxes alone, which is the whole point", function()
    truthy(result.checkboxes >= 5, "there are checkbox lines: " .. result.checkboxes)
    eq(#result.markers, 3, "and only three of them are markers")
  end)

  it("ignores markers inside a code fence", function()
    for _, m in ipairs(result.markers) do
      truthy(m.parsed.summary ~= "one in a fence", "the fenced one stayed put")
    end
  end)

  it("reports where every marker came from", function()
    for _, m in ipairs(result.markers) do
      truthy(m.path ~= nil and m.path ~= "", "has a path")
      truthy(m.lnum and m.lnum > 0, "has a line number")
    end
  end)

  it("collects diagnostics with their location", function()
    local root2 = vault({
      ["bad.md"] = "---\ntags:\n  - tasks\n---\n- [ ] [#A] old habit <2026-09-01 Tue>\n",
    })
    local out = scan.vault(root2, nil)
    eq(#out.diagnostics, 1, "one diagnostic")
    eq(out.diagnostics[1].code, "org-priority", "the code")
    eq(out.diagnostics[1].path, "bad.md", "the file")
    eq(out.diagnostics[1].lnum, 5, "the line")
    eq(#out.markers, 0, "and an error-severity line is not emitted")
  end)

  it("narrows to include_tags when asked", function()
    local out = scan.vault(root, { scope = { include_tags = { "tasks" }, exclude_tags = { "meta" } } })
    eq(out.notes_scanned, 1, "only the tasks-tagged note")
    eq(#out.markers, 2, "pay rent and standup")
  end)
end)
