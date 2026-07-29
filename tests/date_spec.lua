local date = require("mdical.date")

local function d(s)
  return assert(date.parse_iso(s), "bad test date: " .. s)
end

describe("date", function()
  it("round-trips through the day count", function()
    for _, s in ipairs({ "1970-01-01", "1999-12-31", "2000-02-29", "2024-02-29", "2026-07-29", "2100-03-01" }) do
      eq(date.iso(date.from_days(date.to_days(d(s)))), s, s)
    end
  end)

  it("knows the day of the week", function()
    eq(date.dayname(d("1970-01-01")), "Thu", "the epoch")
    eq(date.dayname(d("2026-07-29")), "Wed", "today, when this was written")
    eq(date.dayname(d("2026-09-01")), "Tue", "the spec's bins date")
    eq(date.dayname(d("2024-02-29")), "Thu", "a leap day")
    eq(date.dayname(d("2026-01-31")), "Sat", "the spec's invoice date")
  end)

  it("catches the roadmap's original typo", function()
    -- The roadmap's first strawman marker was `<2026-01-31 Fri>`; it is a
    -- Saturday. This is the lint rule's whole justification.
    truthy(date.dayname(d("2026-01-31")) ~= "Fri", "2026-01-31 is not a Friday")
  end)

  it("counts the days in a month", function()
    eq(date.days_in_month(2026, 2), 28, "feb 2026")
    eq(date.days_in_month(2024, 2), 29, "feb 2024")
    eq(date.days_in_month(2000, 2), 29, "feb 2000 - divisible by 400")
    eq(date.days_in_month(1900, 2), 28, "feb 1900 - divisible by 100, not 400")
    eq(date.days_in_month(2026, 9), 30, "sept")
  end)

  it("rejects dates that do not exist", function()
    eq(date.valid({ year = 2026, month = 2, day = 30 }), false, "30 feb")
    eq(date.valid({ year = 2026, month = 13, day = 1 }), false, "month 13")
    eq(date.valid(d("2024-02-29")), true, "29 feb 2024")
  end)

  it("clamps month arithmetic instead of overflowing", function()
    -- The three conformance cases the grammar spec names as a minimum.
    eq(date.iso(date.add(d("2026-01-31"), 1, "m")), "2026-02-28", "2026-01-31 +1m")
    eq(date.iso(date.add(d("2024-02-29"), 1, "y")), "2025-02-28", "2024-02-29 +1y")
    eq(date.iso(date.add(d("2026-08-31"), 6, "m")), "2027-02-28", "2026-08-31 +6m")
    -- org would give 2026-03-03 for the first of those, and RRULE would skip
    -- February altogether.
  end)

  it("adds days, weeks and years", function()
    eq(date.iso(date.add(d("2026-12-25"), 10, "d")), "2027-01-04", "over new year")
    eq(date.iso(date.add(d("2026-08-03"), 1, "w")), "2026-08-10", "+1w")
    eq(date.iso(date.add(d("2026-10-01"), 1, "y")), "2027-10-01", "+1y")
    eq(date.iso(date.add(d("2026-02-28"), 1, "d")), "2026-03-01", "no leap day in 2026")
  end)

  it("treats an hourly repeater as a no-op on the date", function()
    eq(date.iso(date.add(d("2026-09-01"), 2, "h")), "2026-09-01", "+2h")
  end)
end)

describe("date.next", function()
  local today = d("2026-07-29")

  it("`+` adds one interval and may land in the past", function()
    eq(date.iso(date.next(d("2026-01-31"), { kind = "+", n = 1, unit = "m" }, { today = today })), "2026-02-28",
      "+1m from january")
  end)

  it("`++` catches up to the present", function()
    eq(date.iso(date.next(d("2026-01-01"), { kind = "++", n = 1, unit = "m" }, { today = today })), "2026-08-01",
      "++1m")
    eq(date.iso(date.next(d("2026-07-30"), { kind = "++", n = 1, unit = "y" }, { today = today })), "2027-07-30",
      "++1y on a date still ahead of today")
  end)

  it("`++` does not make the leap-day clamp permanent", function()
    -- Iterating from each result would peg this to the 28th for ever; from the
    -- anchor it returns to the 29th in the next leap year.
    eq(date.iso(date.next(d("2024-02-29"), { kind = "++", n = 1, unit = "y" }, { today = d("2027-06-01") })),
      "2028-02-29", "a 29 feb birthday comes back")
  end)

  it("`.+` counts from the completion date", function()
    local rep = { kind = ".+", n = 3, unit = "d" }
    eq(date.iso(date.next(d("2026-07-30"), rep, { closed = d("2026-08-02") })), "2026-08-05", ".+3d")
    local got, err = date.next(d("2026-07-30"), rep, {})
    nilly(got, "no next without a completion")
    truthy(err, "and it says why")
  end)
end)

describe("date.expand", function()
  it("expands a monthly repeater", function()
    local out = date.expand(d("2026-08-01"), { kind = "+", n = 1, unit = "m" }, { count = 3 })
    local iso = {}
    for i, x in ipairs(out) do
      iso[i] = date.iso(x)
    end
    eq(iso, { "2026-08-01", "2026-09-01", "2026-10-01" }, "the spec's rent example")
  end)

  it("stops at until_date", function()
    local out = date.expand(d("2026-08-03"), { kind = "+", n = 1, unit = "w" },
      { count = 99, until_date = d("2026-08-20") })
    eq(#out, 3, "3, 10 and 17 august")
  end)

  it("returns only the anchor for `.+`, which is not a series", function()
    local out = date.expand(d("2026-07-30"), { kind = ".+", n = 3, unit = "d" }, { count = 5 })
    eq(#out, 1, "one occurrence")
  end)
end)
