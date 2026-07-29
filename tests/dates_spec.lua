-- The picker's entries are pure: only `mdical.date`, no nvim api, so they test
-- like anything else here.
local dates = require("mdical.nvim.dates")
local date = require("mdical.date")

local WED = date.parse_iso("2026-07-29") -- a Wednesday

local function by_label(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[e.label] = date.iso(e.date)
  end
  return out
end

describe("nvim.dates", function()
  local e = by_label(dates.entries(WED))

  it("offers twelve entries", function()
    eq(#dates.entries(WED), 12, "twelve, before free text is appended")
  end)

  it("resolves the obvious ones", function()
    eq(e.today, "2026-07-29", "today")
    eq(e.tomorrow, "2026-07-30", "tomorrow")
    eq(e["+1w"], "2026-08-05", "+1w")
    eq(e["+2w"], "2026-08-12", "+2w")
    eq(e["+1m"], "2026-08-29", "+1m")
    eq(e["+3m"], "2026-10-29", "+3m")
    eq(e["+1y"], "2027-07-29", "+1y")
  end)

  it("takes a weekday to mean the coming one", function()
    eq(e.mon, "2026-08-03", "mon, from a wednesday")
    eq(e.fri, "2026-07-31", "fri, later the same week")
    eq(e.sat, "2026-08-01", "sat")
  end)

  it("never resolves a weekday to today", function()
    -- "today" is already an entry, so `wed` on a Wednesday means next week.
    local w = by_label(dates.entries(date.parse_iso("2026-08-03"))) -- a Monday
    eq(w.mon, "2026-08-10", "mon, from a monday")
  end)

  it("finds the end of the month", function()
    eq(e["end of month"], "2026-07-31", "july")
    eq(by_label(dates.entries(date.parse_iso("2026-02-03")))["end of month"], "2026-02-28", "february")
    eq(by_label(dates.entries(date.parse_iso("2024-02-03")))["end of month"], "2024-02-29", "a leap february")
  end)

  it("clamps a monthly step rather than overflowing", function()
    eq(by_label(dates.entries(date.parse_iso("2026-01-31")))["+1m"], "2026-02-28", "31 jan +1m")
  end)

  it("shows what each entry resolves to", function()
    eq(dates.format({ label = "+1w", date = date.parse_iso("2026-08-05") }), "+1w           2026-08-05 Wed",
      "label, date and day name")
    eq(dates.format({ label = "date…", custom = true }), "date…", "the free-text entry")
  end)
end)
