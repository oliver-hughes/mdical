local parse = require("mdical.parse")
local date = require("mdical.date")

local function diag(p, code)
  for _, d in ipairs(p.diagnostics) do
    if d.code == code then
      return d
    end
  end
  return nil
end

local function lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

describe("parse.line: summary extraction", function()
  it("treats paragraph, bullet and heading identically", function()
    local want = "rach's birthday"
    for _, line in ipairs({
      "<2026-07-30 Thu ++1y> rach's birthday",
      "- rach's birthday <2026-07-30 Thu ++1y>",
      "## rach's birthday <2026-07-30 Thu ++1y>",
      "* <2026-07-30 Thu ++1y> rach's birthday",
    }) do
      local p = parse.line(line)
      eq(p.summary, want, line)
      eq(p.kind, "event", line)
    end
  end)

  it("strips an ordered list marker too", function()
    eq(parse.line("1. call the bank <2026-09-01 Tue>").summary, "call the bank", "numbered list")
  end)

  it("keeps indentation out of the summary", function()
    local p = parse.line("    - [ ] a nested task <2026-09-01 Tue>")
    eq(p.summary, "a nested task", "summary")
    eq(p.kind, "task", "still a task")
  end)

  it("collapses the gap a stripped marker leaves behind", function()
    eq(parse.line("- [ ] pay <2026-09-01 Tue> the rent").summary, "pay the rent", "mid-line marker")
  end)

  it("keeps an inactive timestamp's text", function()
    local p = parse.line("[2026-01-31 Sat] the date the last return was filed")
    eq(p.summary, "the date the last return was filed", "summary")
    eq(p.kind, nil, "inert")
  end)
end)

describe("parse.line: promotion", function()
  it("promotes only on active brackets", function()
    eq(parse.line("- [ ] buy a new kettle").kind, nil, "bare checkbox")
    eq(parse.line("- [ ] buy a kettle [2026-09-01 Tue]").kind, nil, "inactive")
    eq(parse.line("- [ ] buy a kettle <2026-09-01 Tue>").kind, "task", "active")
    eq(parse.line("buy a kettle <2026-09-01 Tue>").kind, "event", "no checkbox")
  end)

  it("takes a bare timestamp on a task line as the deadline", function()
    local p = parse.line("- [ ] put the bins out <2026-09-01>")
    eq(date.iso(p.due.date), "2026-09-01", "due")
    eq(p.at, nil, "not an event")
  end)

  it("never promotes on SCHEDULED: alone", function()
    local p = parse.line("- [ ] think about the loft SCHEDULED: <2026-09-07 Mon>")
    eq(p.kind, nil, "notes only")
    truthy(p.scheduled, "but it is parsed")
  end)

  it("prefers the explicit DEADLINE: when both are written", function()
    local p = parse.line("- [ ] confusing <2026-09-01 Tue> DEADLINE: <2026-09-08 Tue>")
    eq(date.iso(p.due.date), "2026-09-08", "the keyword wins")
    truthy(diag(p, "two-due-dates"), "and it is an error")
  end)

  it("reads a range as one event", function()
    local p = parse.line("<2026-08-10 Mon>--<2026-08-12 Wed> conference in manchester")
    eq(date.iso(p.at.date), "2026-08-10", "start")
    eq(date.iso(p.at_end.date), "2026-08-12", "end")
    eq(#p.diagnostics, 0, "not two events")
  end)

  it("will not emit a completed task", function()
    local p = parse.line("- [x] pay the window cleaner <2026-07-20 Mon> CLOSED: [2026-07-21 Tue]")
    eq(p.kind, "task", "still a task")
    eq(p.done, true, "done")
    eq(p.emit, false, "absent from the payload")
  end)
end)

describe("parse.line: diagnostics", function()
  it("offers a fixit for org's priority cookie", function()
    local p = parse.line("- [ ] [#A] old habit <2026-09-01 Tue>")
    local d = diag(p, "org-priority")
    truthy(d, "reported")
    eq(d.fixit.text, "!!!", "A means !!!")
    eq(p.text:sub(d.fixit.s, d.fixit.e), "[#A]", "over the right span")
    eq(parse.line("- [ ] [#C] low <2026-09-01 Tue>").diagnostics[1].fixit.text, "!", "C means !")
  end)

  it("offers a fixit for a wrong day name", function()
    local p = parse.line("- [ ] wrong day name <2026-09-01 Fri>")
    local d = diag(p, "dayname-mismatch")
    truthy(d, "reported")
    eq(d.fixit.text, "<2026-09-01 Tue>", "corrected timestamp")
    eq(p.text:sub(d.fixit.s, d.fixit.e), "<2026-09-01 Fri>", "over the right span")
    eq(p.emit, true, "a warning does not stop it exporting")
  end)

  it("reports a keyword with nothing after it", function()
    truthy(diag(parse.line("- [ ] a task DEADLINE:"), "keyword-without-timestamp"), "DEADLINE:")
    truthy(diag(parse.line("- [ ] a task DEADLINE: tomorrow"), "keyword-without-timestamp"), "prose")
    truthy(diag(parse.line("<2026-08-12 Wed> planning EXCEPT:"), "keyword-without-timestamp"), "EXCEPT:")
    truthy(diag(parse.line("- [ ] a task <2026-09-01 Tue> RRULE:"), "keyword-without-value"), "RRULE:")
  end)

  it("reports a planning keyword on a line with no checkbox", function()
    local p = parse.line("- meeting DEADLINE: <2026-09-01 Tue>")
    truthy(diag(p, "keyword-on-non-task"), "reported")
    eq(p.kind, nil, "and not promoted either way")
  end)

  it("reports a range on a task", function()
    truthy(diag(parse.line("- [ ] a task <2026-09-01 Tue>--<2026-09-03 Thu>"), "range-on-task"), "reported")
  end)

  it("nudges towards an explicit DEADLINE: next to SCHEDULED:", function()
    local p = parse.line("- [ ] a task <2026-09-10 Thu> SCHEDULED: <2026-09-01 Tue>")
    local d = diag(p, "implicit-deadline")
    truthy(d, "reported")
    eq(d.severity, parse.INFO, "only a hint - it is legal")
    eq(p.emit, true, "and it still exports")
  end)

  it("mentions a repeater on an inactive timestamp", function()
    truthy(diag(parse.line("[2026-09-01 Tue +1w] a date I am not exporting"), "cookie-on-inactive"), "reported")
  end)

  it("mentions a completed task with no CLOSED: date", function()
    truthy(diag(parse.line("- [x] a task <2026-09-01 Tue>"), "done-without-closed"), "reported")
    -- ...but not on the 1035 completed checkboxes that were never markers
    eq(#parse.line("- [x] cancel the gym").diagnostics, 0, "quiet on a bare checkbox")
  end)

  it("validates the RRULE passthrough against known parts", function()
    eq(#parse.line("- [ ] retro <2026-08-19 Wed> RRULE: FREQ=MONTHLY;BYDAY=3WE").diagnostics, 0, "a good rule")
    truthy(diag(parse.line("- [ ] retro <2026-08-19 Wed> RRULE: FREQ=MUNTHLY"), "bad-rrule"), "bad FREQ value")
    truthy(diag(parse.line("- [ ] retro <2026-08-19 Wed> RRULE: FRQ=MONTHLY"), "bad-rrule"), "bad part name")
    truthy(diag(parse.line("- [ ] retro <2026-08-19 Wed> RRULE: nonsense"), "bad-rrule"), "not a rule at all")
  end)

  it("puts every diagnostic inside the line", function()
    local line = "- [ ] [#A] confusing <2026-09-01 Fri> DEADLINE: <2026-09-08 Tue>"
    local p = parse.line(line)
    truthy(#p.diagnostics >= 3, "several problems")
    for _, d in ipairs(p.diagnostics) do
      truthy(d.col >= 1 and d.col <= #line, d.code .. " col in range")
      truthy(d.end_col >= d.col and d.end_col <= #line, d.code .. " end_col in range")
      truthy(d.msg ~= nil and d.msg ~= "", d.code .. " has a message")
    end
  end)
end)

describe("parse.document", function()
  local note = lines([[
---
tags:
  - meta
---

# a note

- [ ] a real task <2026-09-01 Tue>

```lua
-- [ ] a task in a code fence <2026-09-02 Wed>
```

~~~
- [ ] and in a tilde fence <2026-09-03 Thu>
~~~

- [ ] another real one <2026-09-04 Fri>
]])

  it("skips frontmatter", function()
    for n = 1, 4 do
      eq(note[n] and select(1, parse.document(note)[n]), false, "line " .. n .. " skipped")
    end
  end)

  it("parses the lines that are content", function()
    local doc = parse.document(note)
    truthy(doc[8] and doc[8].kind == "task", "the real task")
    truthy(doc[18] and doc[18].kind == "task", "the other real task")
  end)

  it("skips fenced code, both fence styles", function()
    local doc = parse.document(note)
    eq(doc[11], false, "inside a backtick fence")
    eq(doc[15], false, "inside a tilde fence")
  end)

  it("counts markers only once", function()
    local doc = parse.document(note)
    local n = 0
    for _, p in pairs(doc) do
      if p and p.emit then
        n = n + 1
      end
    end
    eq(n, 2, "two emitting lines in the note")
  end)
end)
