local grammar = require("mdical.grammar")
local date = require("mdical.date")

local function ok(body, active)
  local ts, err = grammar.parse_body(body, active ~= false)
  nilly(err and err.msg, "unexpected error for " .. body)
  truthy(ts, "expected a timestamp for " .. body)
  return ts
end

describe("grammar.parse_body", function()
  it("parses a bare date", function()
    local ts = ok("2026-09-01")
    eq(date.iso(ts.date), "2026-09-01", "date")
    eq(ts.dayname, nil, "no day name")
    eq(ts.active, true, "active")
  end)

  it("parses every part at once", function()
    local ts = ok("2026-08-14 Fri 09:00-17:30 +1y -21d")
    eq(date.iso(ts.date), "2026-08-14", "date")
    eq(ts.dayname, "Fri", "day name")
    eq(ts.time, { hour = 9, min = 0 }, "start time")
    eq(ts.time_end, { hour = 17, min = 30 }, "end time")
    eq(ts.repeater, { kind = "+", n = 1, unit = "y" }, "repeater")
    eq(ts.warn, { n = 21, unit = "d" }, "warning")
  end)

  it("accepts the cookies in either order", function()
    local a = ok("2026-08-14 Fri +1y -21d")
    local b = ok("2026-08-14 Fri -21d +1y")
    eq(b.repeater, a.repeater, "repeater")
    eq(b.warn, a.warn, "warning")
  end)

  it("takes all three repeater flavours", function()
    eq(ok("2026-08-01 +1m").repeater.kind, "+", "+")
    eq(ok("2026-08-01 ++1m").repeater.kind, "++", "++")
    eq(ok("2026-08-01 .+1m").repeater.kind, ".+", ".+")
  end)

  it("ignores the case of a day name", function()
    eq(ok("2026-09-01 tue").dayname, "Tue", "lower case in, canonical out")
  end)

  it("reads `<>` as the empty timestamp", function()
    local ts = ok("")
    eq(ts.empty, true, "empty")
    eq(ts.date, nil, "no date")
  end)

  it("reads `[]` as nothing at all", function()
    local ts, err = grammar.parse_body("", false)
    nilly(ts, "not a timestamp")
    nilly(err, "and not an error either")
  end)

  it("distinguishes not-a-timestamp from a broken one", function()
    for _, body in ipairs({ "draft", "#A", "x", " ", "[a wikilink]", "the docs", "2026", "26-09-01" }) do
      local ts, err = grammar.parse_body(body, false)
      nilly(ts, body .. " is not a timestamp")
      nilly(err, body .. " is not an error")
    end
    for _, body in ipairs({ "2026-02-30", "2026-09-01 Tue +1z", "2026-09-01 25:00", "2026-09-01 Tue Wed",
      "2026-09-01 +1m +2m", "2026-09-01 2026-09-02" }) do
      local ts, err = grammar.parse_body(body, true)
      nilly(ts, body .. " does not parse")
      truthy(err and err.msg, body .. " reports why")
      truthy(err.offset >= 1, body .. " reports where")
    end
  end)

  it("computes the day name a date really falls on", function()
    eq(grammar.true_dayname(ok("2026-09-01 Fri")), "Tue", "the spec's wrong-day-name example")
    nilly(grammar.true_dayname(ok("")), "nothing to check on an empty timestamp")
  end)
end)
