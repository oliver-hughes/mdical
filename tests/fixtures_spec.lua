--- The emitter, checked against recorded wire evidence.
---
--- Each fixture in `tests/fixtures/m0/` was PUT to radicale during the spike and
--- then looked at on a real iPhone, so its property forms are known to work.
--- These cases assert that a marker producing the same *meaning* produces the
--- same *properties* - which is a stronger claim than "it looks like valid
--- iCalendar", and it is the only kind of claim that can be made without a phone
--- in the room.
---
--- Deliberate differences are listed per case rather than glossed over.

local ics = require("mdical.ics")
local parse = require("mdical.parse")
local date = require("mdical.date")

local TODAY = date.parse_iso("2026-07-29")

--- Unfold an ics file into a list of properties.
local function properties(text)
  local out = {}
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, 1) == " " then
      out[#out] = out[#out] .. line:sub(2)
    elseif line ~= "" then
      out[#out + 1] = line
    end
  end
  return out
end

local function read_fixture(name)
  local path = TEST_ROOT .. "/tests/fixtures/m0/" .. name
  local f = assert(io.open(path, "rb"), "missing fixture: " .. path)
  local text = f:read("*a")
  f:close()
  return properties(text)
end

local function emitted(line, opts)
  opts = opts or {}
  opts.today = opts.today or TODAY
  local items = ics.items(parse.line(line), opts)
  truthy(#items > 0, "nothing emitted for: " .. line)
  return properties(items[1].text)
end

local function pick(props, names)
  local want, out = {}, {}
  for _, n in ipairs(names) do
    want[n] = true
  end
  for _, p in ipairs(props) do
    local name = p:match("^([%u%-]+)[;:]")
    if name and want[name] then
      out[#out + 1] = p
    end
  end
  return out
end

--- Assert the named properties come out exactly as the fixture has them.
local function matches(fixture, line, names, opts)
  eq(pick(emitted(line, opts), names), pick(read_fixture(fixture), names), fixture)
end

describe("m0 fixtures: tasks", function()
  it("a1 - a date-only due date", function()
    matches("tasks/a1-due-date.ics", "- [ ] A1 due date only <2026-08-01 Sat>", { "DUE", "STATUS" })
  end)

  it("a2b - a due time with a timezone, and the VTIMEZONE with it", function()
    matches("tasks/a2b-due-tzid.ics", "- [ ] A2b due 1400 TZID <2026-08-01 Sat 14:00>",
      { "DUE", "STATUS", "TZID", "TZOFFSETFROM", "TZOFFSETTO", "TZNAME" })
  end)

  it("a5a/b/c - the three priorities", function()
    matches("tasks/a5a-priority-1.ics", "- [ ] !!! A5a priority 1 <2026-08-03 Mon>", { "DUE", "PRIORITY" })
    matches("tasks/a5b-priority-5.ics", "- [ ] !! A5b priority 5 <2026-08-03 Mon>", { "DUE", "PRIORITY" })
    matches("tasks/a5c-priority-9.ics", "- [ ] ! A5c priority 9 <2026-08-03 Mon>", { "DUE", "PRIORITY" })
  end)

  it("a12 - an overdue task still emits", function()
    matches("tasks/a12-overdue.ics", "- [ ] A12 overdue <2026-07-20 Mon>", { "DUE", "STATUS" })
  end)

  it("a13 - an undated task has no DUE at all", function()
    local props = emitted("- [ ] A13 no due date at all <>")
    eq(pick(props, { "DUE" }), {}, "no DUE")
    eq(pick(props, { "STATUS" }), pick(read_fixture("tasks/a13-no-due.ics"), { "STATUS" }), "STATUS")
  end)

  it("a4a - a passthrough rule, plus the DTSTART the spike did not write", function()
    -- The fixture has DUE and RRULE and no DTSTART. A9 later showed Apple's own
    -- phone-authored repeating reminder writes DTSTART == DUE, because RFC 5545
    -- anchors a recurrence on DTSTART, so we emit one.
    local line = "- [ ] A4a repeats monthly on the 1st <2026-08-01 Sat> RRULE: FREQ=MONTHLY;BYMONTHDAY=1"
    matches("tasks/a4a-rrule-monthly.ics", line, { "DUE", "RRULE", "STATUS" })
    eq(pick(emitted(line), { "DTSTART" }), { "DTSTART;VALUE=DATE:20260801" }, "DTSTART == DUE, per A9")
    eq(pick(read_fixture("tasks/a4a-rrule-monthly.ics"), { "DTSTART" }), {}, "which the spike lacked")
  end)

  it("a6b - and the alarm the spike proved we must NOT copy", function()
    -- A6b put a relative alarm on a VTODO and iOS displayed the alarm time as
    -- the task's own time. A `-Nd` warning on a task is editor-only because of it.
    truthy(#pick(read_fixture("tasks/a6b-valarm-relative.ics"), { "TRIGGER" }) > 0, "the fixture has one")
    eq(pick(emitted("- [ ] A6b warned <2026-08-01 Sat -21d>"), { "TRIGGER", "BEGIN" })[1], "BEGIN:VCALENDAR",
      "we emit no VALARM at all")
  end)
end)

describe("m0 fixtures: events", function()
  it("b1 - a timed event with a timezone", function()
    matches("events/b1-tzid.ics", "<2026-08-05 Wed 15:00-16:00> B1 1500-1600 TZID",
      { "DTSTART", "DTEND", "TZID", "TZOFFSETFROM", "TZOFFSETTO", "TZNAME" })
  end)

  it("b4 - one all-day event, ending the next day", function()
    matches("events/b4-allday-one.ics", "<2026-08-07 Fri> B4 all day Aug 7 only", { "DTSTART", "DTEND" })
  end)

  it("b5 - three all-day events, ending on the fourth", function()
    matches("events/b5-allday-three.ics", "<2026-08-10 Mon>--<2026-08-12 Wed> B5 all day Aug 10-12",
      { "DTSTART", "DTEND" })
  end)

  it("b7 - a rule with an exception", function()
    -- The rule is a passthrough here, so it is delegated rather than expanded -
    -- which is also what keeps EXDATE meaningful.
    matches("events/b7-exdate.ics",
      "<2026-08-12 Wed 10:00-10:15> B7 weekly, skip Aug 19 RRULE: FREQ=WEEKLY;BYDAY=WE;COUNT=6 EXCEPT: [2026-08-19 Wed]",
      { "DTSTART", "DTEND", "RRULE", "EXDATE" })
  end)

  it("b8 - an alarm before an event", function()
    -- The fixture's -PT15M has no marker: the grammar's units stop at hours, and
    -- `m` means months. So the structure is what is compared, and the trigger is
    -- checked in its own right.
    local props = emitted("<2026-08-06 Thu 14:00-15:00 -1d> B8 alarm 15m before")
    eq(pick(props, { "ACTION" }), pick(read_fixture("events/b8-valarm.ics"), { "ACTION" }), "ACTION:DISPLAY")
    eq(pick(props, { "TRIGGER" }), { "TRIGGER:-P1D" }, "a duration RFC 5545 allows")
  end)

  it("b9 - and no SEQUENCE, which every one of these fixtures carries", function()
    -- A11b, B9a and B9b showed the phone notices changes without it, so the
    -- fixtures' SEQUENCE:0 is one thing deliberately not copied.
    truthy(#pick(read_fixture("events/b9-sequence.ics"), { "SEQUENCE" }) > 0, "the fixture has one")
    eq(pick(emitted("<2026-08-07 Fri> B9 seq"), { "SEQUENCE" }), {}, "we emit none")
  end)
end)

describe("m0 fixtures: the envelope", function()
  it("wraps each item the way every fixture does", function()
    local props = emitted("- [ ] put the bins out <2026-08-01 Sat>")
    eq(props[1], "BEGIN:VCALENDAR", "opens")
    eq(props[2], "VERSION:2.0", "version")
    eq(props[#props], "END:VCALENDAR", "closes")
    truthy(props[3]:match("^PRODID:") ~= nil, "prodid")
  end)

  it("puts VTIMEZONE before the component, as the spike did", function()
    local props = emitted("- [ ] submit expenses <2026-08-01 Sat 14:00>")
    local tz, todo
    for i, p in ipairs(props) do
      if p == "BEGIN:VTIMEZONE" then
        tz = i
      elseif p == "BEGIN:VTODO" then
        todo = i
      end
    end
    truthy(tz and todo and tz < todo, "timezone first")
  end)
end)
