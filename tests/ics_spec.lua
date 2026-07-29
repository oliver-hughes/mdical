local ics = require("mdical.ics")
local parse = require("mdical.parse")
local date = require("mdical.date")

local TODAY = date.parse_iso("2026-07-29") -- a Wednesday

--- Every resource one marker emits, as a list of property tables.
local function emit(line, opts)
  opts = opts or {}
  opts.today = opts.today or TODAY
  return ics.items(parse.line(line), opts)
end

--- The first resource, split into lines with folding undone.
local function props(line, opts)
  local items = emit(line, opts)
  if #items == 0 then
    return {}
  end
  local out = {}
  for physical in (items[1].text .. ics.EOL):gmatch("(.-)" .. ics.EOL) do
    if physical:sub(1, 1) == " " then
      out[#out] = out[#out] .. physical:sub(2) -- unfold
    elseif physical ~= "" then
      out[#out + 1] = physical
    end
  end
  return out
end

local function has(line, want, opts)
  for _, p in ipairs(props(line, opts)) do
    if p == want then
      return true
    end
  end
  return false
end

local function find(line, prefix, opts)
  for _, p in ipairs(props(line, opts)) do
    if p:sub(1, #prefix) == prefix then
      return p
    end
  end
  return nil
end

describe("ics.escape", function()
  it("escapes the three characters that silently truncated a summary", function()
    -- B7/B9: radicale stored `buy milk` and dropped the rest, server-side
    eq(ics.escape("buy milk, bread and eggs"), "buy milk\\, bread and eggs", "comma")
    eq(ics.escape("escape these; and this \\ too"), "escape these\\; and this \\\\ too", "semicolon and backslash")
  end)

  it("escapes the backslash before anything else", function()
    eq(ics.escape("a\\,b"), "a\\\\\\,b", "an already-escaped comma is not double-read")
  end)

  it("turns newlines into the literal escape", function()
    eq(ics.escape("first\nsecond"), "first\\nsecond", "lf")
    eq(ics.escape("first\r\nsecond"), "first\\nsecond", "crlf")
  end)

  it("leaves ordinary text alone", function()
    eq(ics.escape("put the bins out"), "put the bins out", "nothing to do")
  end)
end)

describe("ics.fold", function()
  it("leaves a short line alone", function()
    eq(ics.fold("SUMMARY:short"), { "SUMMARY:short" }, "one line")
  end)

  it("folds at 75 octets, with a leading space on the rest", function()
    local line = "SUMMARY:" .. ("x"):rep(200)
    local out = ics.fold(line)
    eq(#out[1], 75, "first line is 75 octets")
    for i = 2, #out do
      eq(out[i]:sub(1, 1), " ", "continuation " .. i .. " starts with a space")
      truthy(#out[i] <= 75, "continuation " .. i .. " is at most 75 octets")
    end
    local rejoined = out[1]
    for i = 2, #out do
      rejoined = rejoined .. out[i]:sub(2)
    end
    eq(rejoined, line, "unfolds back to the original")
  end)

  it("never splits a utf-8 sequence", function()
    -- an em dash is three bytes; landing the fold inside it corrupts the property.
    -- Ending *on* its last byte is fine - what must not happen is a chunk that is
    -- not valid utf-8 on its own.
    local function valid_utf8(s)
      local i = 1
      while i <= #s do
        local b, n = s:byte(i), nil
        if b < 0x80 then
          n = 1
        elseif b >= 0xC0 and b < 0xE0 then
          n = 2
        elseif b >= 0xE0 and b < 0xF0 then
          n = 3
        elseif b >= 0xF0 and b < 0xF8 then
          n = 4
        else
          return false -- a continuation byte where a sequence should start
        end
        if i + n - 1 > #s then
          return false -- a sequence cut short
        end
        for j = i + 1, i + n - 1 do
          local c = s:byte(j)
          if not (c >= 0x80 and c < 0xC0) then
            return false
          end
        end
        i = i + n
      end
      return true
    end

    -- offsets chosen so a naive 75-byte cut lands inside a codepoint
    for _, pad in ipairs({ 64, 65, 66, 67 }) do
      local line = "SUMMARY:" .. ("a"):rep(pad) .. ("—"):rep(20)
      local out = ics.fold(line)
      for i, physical in ipairs(out) do
        local body = i == 1 and physical or physical:sub(2)
        truthy(valid_utf8(body), ("pad %d, line %d is valid utf-8 on its own"):format(pad, i))
      end
      local rejoined = out[1]
      for i = 2, #out do
        rejoined = rejoined .. out[i]:sub(2)
      end
      eq(rejoined, line, ("pad %d unfolds exactly"):format(pad))
    end
  end)
end)

describe("ics: tasks", function()
  it("emits a date-only DUE", function()
    -- A1: renders as a date, no time
    truthy(has("- [ ] put the bins out <2026-09-01 Tue>", "DUE;VALUE=DATE:20260901"), "DUE")
    truthy(has("- [ ] put the bins out <2026-09-01 Tue>", "SUMMARY:put the bins out"), "SUMMARY")
    truthy(has("- [ ] put the bins out <2026-09-01 Tue>", "STATUS:NEEDS-ACTION"), "STATUS")
    truthy(has("- [ ] put the bins out <2026-09-01 Tue>", "BEGIN:VTODO"), "VTODO")
  end)

  it("emits a timed DUE with a timezone and a VTIMEZONE", function()
    -- A2b
    local line = "- [ ] submit expenses <2026-09-01 Tue 17:00>"
    truthy(has(line, "DUE;TZID=Europe/London:20260901T170000"), "DUE with TZID")
    truthy(has(line, "BEGIN:VTIMEZONE"), "VTIMEZONE attached")
    truthy(has(line, "TZID:Europe/London"), "the zone")
  end)

  it("attaches no VTIMEZONE when there is no time to place", function()
    eq(find("- [ ] put the bins out <2026-09-01 Tue>", "BEGIN:VTIMEZONE"), nil, "date-only needs none")
  end)

  it("emits no DUE at all for an undated task", function()
    -- A13
    local line = "- [ ] chase the plumber <>"
    eq(find(line, "DUE"), nil, "no DUE property")
    truthy(has(line, "BEGIN:VTODO"), "still a VTODO")
    eq(#emit(line), 1, "exactly one resource")
  end)

  it("maps priority onto the glyphs iOS itself shows", function()
    -- A5a/b/c
    truthy(has("- [ ] !!! renew the passport <2026-10-15 Thu>", "PRIORITY:1"), "!!! -> 1")
    truthy(has("- [ ] !! book the MOT <2026-10-15 Thu>", "PRIORITY:5"), "!! -> 5")
    truthy(has("- [ ] ! tidy the garage <2026-10-15 Thu>", "PRIORITY:9"), "! -> 9")
    eq(find("- [ ] no priority <2026-10-15 Thu>", "PRIORITY"), nil, "absent, not defaulted to 5")
  end)

  it("omits DTSTART on a non-recurring task", function()
    -- A3: a differing DTSTART is simply ignored, so emitting one buys nothing
    eq(find("- [ ] put the bins out <2026-09-01 Tue>", "DTSTART"), nil, "no DTSTART")
  end)

  it("emits DTSTART == DUE alongside a passthrough RRULE", function()
    -- A9: what Apple's own phone-authored repeating reminder writes
    local line = "- [ ] team retro <2026-08-19 Wed> RRULE: FREQ=MONTHLY;BYDAY=3WE"
    truthy(has(line, "RRULE:FREQ=MONTHLY;BYDAY=3WE"), "the rule, verbatim")
    truthy(has(line, "DTSTART;VALUE=DATE:20260819"), "DTSTART")
    truthy(has(line, "DUE;VALUE=DATE:20260819"), "equal to DUE")
    eq(#emit(line), 1, "delegated, so not expanded")
  end)

  it("emits nothing for a warning period on a task", function()
    -- A6b: iOS displayed the alarm time AS the due time, which reads as the
    -- deadline having moved. Worse than not emitting it.
    local line = "- [ ] !!! submit tax return <2027-01-31 Sun -21d>"
    eq(find(line, "BEGIN:VALARM"), nil, "no alarm")
    eq(find(line, "TRIGGER"), nil, "no trigger")
    truthy(has(line, "PRIORITY:1"), "the rest still emits")
  end)

  it("emits nothing at all for lines that never promote", function()
    eq(#emit("- [ ] buy a new kettle"), 0, "a bare checkbox")
    eq(#emit("- [x] renew the tv licence CLOSED: [2026-07-14 Tue 10:32]"), 0, "completed")
    eq(#emit("- [ ] think about the loft SCHEDULED: <2026-09-07 Mon>"), 0, "SCHEDULED: only")
    eq(#emit("- [ ] confusing <2026-09-01 Tue> DEADLINE: <2026-09-08 Tue>"), 0, "an error-severity line")
  end)
end)

describe("ics: events", function()
  it("ends an all-day event on the following day", function()
    -- B4: exclusive DTEND, and the off-by-one this prevents
    local line = "<2026-08-05 Wed> team offsite"
    truthy(has(line, "DTSTART;VALUE=DATE:20260805"), "starts on the 5th")
    truthy(has(line, "DTEND;VALUE=DATE:20260806"), "ends on the 6th, exclusively")
  end)

  it("ends a three-day range on the fourth day", function()
    -- B5
    local line = "<2026-08-10 Mon>--<2026-08-12 Wed> conference in manchester"
    truthy(has(line, "DTSTART;VALUE=DATE:20260810"), "start")
    truthy(has(line, "DTEND;VALUE=DATE:20260813"), "three days, not four")
  end)

  it("emits a timed range with a timezone", function()
    -- B1
    local line = "<2026-08-05 Wed 15:00-16:00> standup"
    truthy(has(line, "DTSTART;TZID=Europe/London:20260805T150000"), "start")
    truthy(has(line, "DTEND;TZID=Europe/London:20260805T160000"), "end")
    truthy(has(line, "BEGIN:VTIMEZONE"), "VTIMEZONE")
  end)

  it("gives a timed event with no end one hour", function()
    -- untested against a real phone; a zero-length event may render oddly
    local line = "<2026-09-16 Wed 16:42> big birthday party"
    truthy(has(line, "DTSTART;TZID=Europe/London:20260916T164200"), "start")
    truthy(has(line, "DTEND;TZID=Europe/London:20260916T174200"), "an hour later")
  end)

  it("rolls an hour past midnight onto the next day", function()
    local line = "<2026-09-16 Wed 23:30> late one"
    truthy(has(line, "DTEND;TZID=Europe/London:20260917T003000"), "next day")
  end)

  it("turns a warning period into a real alarm", function()
    -- B8: the same three characters that are editor-only on a task
    local line = "<2026-08-14 Fri -21d> car insurance renewal"
    truthy(has(line, "BEGIN:VALARM"), "an alarm")
    truthy(has(line, "TRIGGER:-P21D"), "21 days before")
    truthy(has(line, "ACTION:DISPLAY"), "action")
  end)

  it("expresses warning units RFC 5545 has, and approximates the ones it does not", function()
    truthy(has("<2026-08-14 Fri -2w> a thing", "TRIGGER:-P2W"), "weeks")
    truthy(has("<2026-08-14 Fri -6h> a thing", "TRIGGER:-PT6H"), "hours")
    -- durations have no months or years, so these become days rather than being dropped
    truthy(has("<2026-08-14 Fri -1m> a thing", "TRIGGER:-P30D"), "a month as 30 days")
    truthy(has("<2026-08-14 Fri -1y> a thing", "TRIGGER:-P365D"), "a year as 365 days")
  end)

  it("turns EXCEPT: into EXDATE", function()
    -- B7
    local line = "<2026-08-12 Wed 10:00-10:15 +1w> planning EXCEPT: [2026-08-19 Wed]"
    truthy(has(line, "EXDATE;TZID=Europe/London:20260819T100000"), "the excluded occurrence")
  end)

  it("treats a heading and a bullet as events like any other line", function()
    truthy(has("## <2026-09-05 Sat> rach's parents visiting", "SUMMARY:rach's parents visiting"), "heading")
    truthy(has("- <2026-08-20 Thu 09:00-09:30> gp appointment", "SUMMARY:gp appointment"), "bullet")
  end)
end)

describe("ics: expansion", function()
  it("expands a monthly task over a short horizon", function()
    local items = emit("- [ ] pay rent <2026-08-01 Sat +1m>")
    truthy(#items >= 2, "several occurrences, not one")
    truthy(#items <= 5, "and not a year of them: " .. #items)
  end)

  it("expands a yearly event over a longer one", function()
    local items = emit("<2026-12-25 Fri ++1y> christmas")
    eq(#items, 1, "one christmas in twelve months")
  end)

  it("gives every occurrence its own identity", function()
    local seen = {}
    for _, item in ipairs(emit("- [ ] pay rent <2026-08-01 Sat +1m>")) do
      eq(seen[item.uid], nil, "no duplicate uid: " .. item.uid)
      seen[item.uid] = true
    end
  end)

  it("clamps the day rather than overflowing the month", function()
    local found = false
    for _, item in ipairs(emit("- [ ] pay the invoice <2026-01-31 Sat +1m>", { today = date.parse_iso("2026-01-30") })) do
      if item.text:find("20260228", 1, true) then
        found = true
      end
      truthy(not item.text:find("20260303", 1, true), "never org's overflow date")
    end
    truthy(found, "28 february is in there")
  end)

  it("does not expand a `.+` cookie, which is not a series", function()
    -- the next date is a function of the completion date, so there is nothing
    -- to expand until the ratchet reads one back
    eq(#emit("- [ ] water the plants <2026-07-30 Thu .+3d>"), 1, "one resource")
    local line = "- [ ] water the plants <2026-07-30 Thu .+3d>"
    eq(find(line, "RRULE"), nil, "and no rule either")
  end)

  it("drops occurrences that are already well past", function()
    local items = emit("- [ ] pay rent <2020-01-01 Wed +1m>")
    eq(#items, 0, "a series that stopped mattering years ago")
  end)

  it("keeps an overdue one-off, which is a different thing entirely", function()
    -- A12 confirmed overdue tasks render
    eq(#emit("- [ ] chase the plumber <2026-01-05 Mon>"), 1, "still emitted")
  end)

  it("respects the horizon it is given", function()
    local wide = emit("- [ ] pay rent <2026-08-01 Sat +1m>",
      { horizon = { task_months = 12, event_months = 12, grace_days = 7, max_occurrences = 60 } })
    truthy(#wide >= 12, "twelve months of rent when asked for it: " .. #wide)
  end)
end)

describe("ics: byte stability", function()
  -- Without this every nightly run is a meaningless commit and real changes
  -- vanish in the diff. It is also what would make a 15-minute cadence possible.
  it("emits identical bytes for identical input", function()
    for _, line in ipairs({
      "- [ ] put the bins out <2026-09-01 Tue>",
      "- [ ] submit expenses <2026-09-01 Tue 17:00>",
      "<2026-08-12 Wed 10:00-10:15 +1w> planning EXCEPT: [2026-08-19 Wed]",
      "- [ ] chase the plumber <>",
    }) do
      local a, b = emit(line)[1], emit(line)[1]
      eq(b.text, a.text, line)
      eq(b.uid, a.uid, line .. " (uid)")
    end
  end)

  it("carries no clock reading anywhere in the output", function()
    local text = emit("- [ ] put the bins out <2026-09-01 Tue>")[1].text
    eq(text:match("DTSTAMP:(%d+T%d+Z)"), "20260901T000000Z", "derived from the item, not from now()")
  end)

  it("gives an undated task a fixed DTSTAMP", function()
    eq(emit("- [ ] chase the plumber <>")[1].text:match("DTSTAMP:(%S+)"), ics.UNDATED_DTSTAMP, "sentinel")
  end)

  it("emits no SEQUENCE", function()
    -- A11b, B9a and B9b: the phone notices changes without it
    eq(find("<2026-08-05 Wed> team offsite", "SEQUENCE"), nil, "none")
  end)

  it("ends every line with CRLF", function()
    local text = emit("- [ ] put the bins out <2026-09-01 Tue>")[1].text
    eq(text:sub(-2), "\r\n", "trailing")
    eq(select(2, text:gsub("\r\n", "")), select(2, text:gsub("\n", "")), "no bare LF anywhere")
  end)
end)

describe("ics: identity", function()
  local uid = require("mdical.uid")

  it("marks every resource as ours", function()
    truthy(uid.is_ours(emit("<2026-08-05 Wed> team offsite")[1].uid), "prefixed")
    eq(uid.is_ours("6C7E1B4A-PHONE-MADE-THIS"), false, "a phone-created resource is not")
  end)

  it("keeps identity when the priority or the time changes", function()
    local a = emit("- [ ] renew the passport <2026-10-15 Thu>")[1].uid
    eq(emit("- [ ] !!! renew the passport <2026-10-15 Thu>")[1].uid, a, "priority is an edit")
    eq(emit("- [ ] renew the passport <2026-10-15 Thu 09:00>")[1].uid, a, "so is a time")
  end)

  it("changes identity when the summary or the date changes", function()
    local a = emit("- [ ] renew the passport <2026-10-15 Thu>")[1].uid
    truthy(emit("- [ ] renew the passport now <2026-10-15 Thu>")[1].uid ~= a, "different summary")
    truthy(emit("- [ ] renew the passport <2026-10-16 Fri>")[1].uid ~= a, "different date")
  end)

  it("separates a task from an event with the same words", function()
    local task = emit("- [ ] standup <2026-08-05 Wed>")[1].uid
    local event = emit("standup <2026-08-05 Wed>")[1].uid
    truthy(task ~= event, "different kinds, different resources")
  end)
end)

describe("ics.rrule_of", function()
  -- the delegation path, kept honest in case that decision is revisited
  it("maps the units", function()
    eq(ics.rrule_of({ kind = "+", n = 1, unit = "d" }), "FREQ=DAILY;INTERVAL=1", "+1d")
    eq(ics.rrule_of({ kind = "+", n = 2, unit = "w" }), "FREQ=WEEKLY;INTERVAL=2", "+2w")
    eq(ics.rrule_of({ kind = "+", n = 6, unit = "m" }), "FREQ=MONTHLY;INTERVAL=6", "+6m")
    eq(ics.rrule_of({ kind = "++", n = 1, unit = "y" }), "FREQ=YEARLY;INTERVAL=1", "++1y")
  end)

  it("shows why delegating loses something the grammar says", function()
    -- `+1m` and `++1m` are different markers and the same rule: FREQ=MONTHLY has
    -- no notion of completion. This is the argument for expanding instead.
    eq(ics.rrule_of({ kind = "+", n = 1, unit = "m" }), ics.rrule_of({ kind = "++", n = 1, unit = "m" }),
      "indistinguishable once delegated")
  end)

  it("has nothing for a completion-relative repeater", function()
    eq(ics.rrule_of({ kind = ".+", n = 3, unit = "d" }), nil, "not expressible at all")
  end)
end)
