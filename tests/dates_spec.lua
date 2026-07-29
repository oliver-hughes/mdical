-- The picker's entries are pure: only `mdical.date`, no nvim api, so they test
-- like anything else here.
local dates = require("mdical.nvim.dates")
local date = require("mdical.date")

local WED = date.parse_iso("2026-07-29") -- a Wednesday

local function by_label(entries)
  local out = {}
  for _, x in ipairs(entries) do
    out[x.label] = date.iso(x.date)
  end
  return out
end

local function labels(entries)
  local out = {}
  for i, x in ipairs(entries) do
    out[i] = x.label
  end
  return out
end

describe("nvim.dates", function()
  local e = by_label(dates.entries(WED))

  it("offers the full set, in order", function()
    eq(labels(dates.entries(WED)), {
      "today", "tomorrow",
      "thu", "fri", "sat", "sun", "mon", "tue",
      "1w", "2w", "3w",
      "1m", "2m", "3m",
      "end of month",
      "1y",
    }, "sixteen entries, before free text is appended")
  end)

  it("resolves the relative ones", function()
    eq(e.today, "2026-07-29", "today")
    eq(e.tomorrow, "2026-07-30", "tomorrow")
    eq(e["1w"], "2026-08-05", "1w")
    eq(e["2w"], "2026-08-12", "2w")
    eq(e["3w"], "2026-08-19", "3w")
    eq(e["1m"], "2026-08-29", "1m")
    eq(e["2m"], "2026-09-29", "2m")
    eq(e["3m"], "2026-10-29", "3m")
    eq(e["1y"], "2027-07-29", "1y")
  end)

  it("names the next six days, starting tomorrow", function()
    eq(e.thu, "2026-07-30", "thu")
    eq(e.fri, "2026-07-31", "fri")
    eq(e.sat, "2026-08-01", "sat")
    eq(e.sun, "2026-08-02", "sun")
    eq(e.mon, "2026-08-03", "mon")
    eq(e.tue, "2026-08-04", "tue")
    eq(e.wed, nil, "not today's own day name - `1w` is that date")
    eq(e.thu, e.tomorrow, "the first of them is tomorrow, deliberately")
  end)

  it("rolls the six days over a month and a year boundary", function()
    local d = by_label(dates.entries(date.parse_iso("2026-12-30"))) -- a Wednesday
    eq(d.thu, "2026-12-31", "new year's eve")
    eq(d.fri, "2027-01-01", "and over into january")
    eq(d["end of month"], "2026-12-31", "december")
  end)

  it("always names six days, whatever day it is", function()
    for _, iso in ipairs({ "2026-07-26", "2026-07-27", "2026-07-31", "2026-08-01" }) do
      local names = {}
      for _, x in ipairs(dates.entries(date.parse_iso(iso))) do
        if #x.label == 3 and x.label:match("^%l+$") then
          names[#names + 1] = x.label
        end
      end
      eq(#names, 6, "six day names from " .. iso)
    end
  end)

  it("finds the end of the month", function()
    eq(e["end of month"], "2026-07-31", "july")
    eq(by_label(dates.entries(date.parse_iso("2026-02-03")))["end of month"], "2026-02-28", "february")
    eq(by_label(dates.entries(date.parse_iso("2024-02-03")))["end of month"], "2024-02-29", "a leap february")
  end)

  it("clamps a monthly step rather than overflowing", function()
    eq(by_label(dates.entries(date.parse_iso("2026-01-31")))["1m"], "2026-02-28", "31 jan + 1m")
  end)

  it("shows what each entry resolves to", function()
    eq(dates.format({ label = "1w", date = date.parse_iso("2026-08-05") }), "1w            2026-08-05 Wed",
      "label, date and day name")
    eq(dates.format({ label = "date…", custom = true }), "date…", "the free-text entry")
  end)
end)
