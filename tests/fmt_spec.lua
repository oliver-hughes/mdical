local fmt = require("mdical.fmt")
local grammar = require("mdical.grammar")
local date = require("mdical.date")

describe("fmt.timestamp", function()
  it("round-trips every canonical form", function()
    -- The cheap way to catch span and ordering bugs: anything the grammar
    -- accepts in canonical shape must come back out identically.
    local canonical = {
      "<2026-09-01 Tue>",
      "<2026-09-01 Tue 17:00>",
      "<2026-08-05 Wed 15:00-16:00>",
      "<2026-08-01 Sat +1m>",
      "<2026-10-01 Thu ++1y>",
      "<2026-07-30 Thu .+3d>",
      "<2027-01-31 Sun -21d>",
      "<2026-08-14 Fri +1y -21d>",
      "<2026-08-12 Wed 10:00-10:15 +1w>",
      "[2026-07-14 Tue 10:32]",
      "[2026-01-31 Sat]",
      "<>",
    }
    for _, want in ipairs(canonical) do
      local active = want:sub(1, 1) == "<"
      local ts = assert(grammar.parse_body(want:sub(2, -2), active), want)
      eq(fmt.timestamp(ts), want, want)
    end
  end)

  it("writes the day name even when the input omitted it", function()
    local ts = assert(grammar.parse_body("2026-09-01", true))
    eq(fmt.timestamp(ts), "<2026-09-01 Tue>", "day name filled in")
  end)

  it("emits repeater before warning whatever the input order", function()
    local ts = assert(grammar.parse_body("2026-08-14 Fri -21d +1y", true))
    eq(fmt.timestamp(ts), "<2026-08-14 Fri +1y -21d>", "canonical cookie order")
  end)

  it("can override the day name, which is how the fixit works", function()
    local ts = assert(grammar.parse_body("2026-09-01 Fri", true))
    eq(fmt.timestamp(ts, { dayname = "Tue" }), "<2026-09-01 Tue>", "corrected")
  end)

  it("builds a new timestamp, keeping the cookies of the old one", function()
    local old = assert(grammar.parse_body("2026-08-01 Sat 09:00 +1m -3d", true))
    eq(fmt.new_timestamp(date.parse_iso("2026-12-25"), old), "<2026-12-25 Fri 09:00 +1m -3d>", "inherited")
    eq(fmt.new_timestamp(date.parse_iso("2026-12-25")), "<2026-12-25 Fri>", "fresh")
  end)
end)
