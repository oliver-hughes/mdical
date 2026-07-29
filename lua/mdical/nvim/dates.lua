--- The date stage's entries. Pure - only `mdical.date` - so it tests like
--- anything else here.
---
--- Sixteen precomputed relative dates plus free text. No date *parsing* beyond
--- the free-text case, which reuses the timestamp grammar itself, so
--- `2026-08-01 14:00 +1m` typed by hand just works.
---
--- Every label carries its resolved date and day name, which is most of the
--- point: hand-typing ISO dates and day names is the fastest way to end up
--- hating a format for the wrong reasons.

local date = require("mdical.date")

local M = {}

local function end_of_month(d)
  return { year = d.year, month = d.month, day = date.days_in_month(d.year, d.month) }
end

--- @param today table|nil date, injected by the tests
--- @return table[] entries  { label = "1w", date = <date> }
function M.entries(today)
  today = today or date.today()
  local e = {}
  local function add(label, d)
    e[#e + 1] = { label = label, date = d }
  end

  add("today", today)
  add("tomorrow", date.add_days(today, 1))
  -- the next six days by name, so "sat" is one keystroke away and it is obvious
  -- which saturday it means. Deliberately overlaps `tomorrow`.
  for i = 1, 6 do
    local d = date.add_days(today, i)
    add(date.dayname(d):lower(), d)
  end
  add("1w", date.add(today, 1, "w"))
  add("2w", date.add(today, 2, "w"))
  add("3w", date.add(today, 3, "w"))
  add("1m", date.add(today, 1, "m"))
  add("2m", date.add(today, 2, "m"))
  add("3m", date.add(today, 3, "m"))
  add("end of month", end_of_month(today))
  add("1y", date.add(today, 1, "y"))
  return e
end

--- How an entry reads in the picker: the shorthand, then what it resolves to.
function M.format(entry)
  if not entry.date then
    return entry.label
  end
  return ("%-13s %s %s"):format(entry.label, date.iso(entry.date), date.dayname(entry.date))
end

return M
