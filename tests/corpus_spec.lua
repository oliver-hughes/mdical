--- Drives tests/corpus.lua - the grammar spec's worked examples - through the
--- parser and checks every stated expectation.

local parse = require("mdical.parse")
local date = require("mdical.date")
local fmt = require("mdical.fmt")
local grammar = require("mdical.grammar")

local corpus = assert(loadfile(TEST_ROOT .. "/tests/corpus.lua"))()

local function iso(ts)
  return ts and ts.date and date.iso(ts.date) or nil
end

local function codes_of(p)
  local out = {}
  for _, d in ipairs(p.diagnostics) do
    out[#out + 1] = d.code
  end
  table.sort(out)
  return out
end

local function sorted(list)
  local out = {}
  for _, v in ipairs(list or {}) do
    out[#out + 1] = v
  end
  table.sort(out)
  return out
end

local function cookie(ts)
  if not ts or not ts.repeater then
    return nil
  end
  return ("%s%d%s"):format(ts.repeater.kind, ts.repeater.n, ts.repeater.unit)
end

local function warning(ts)
  if not ts or not ts.warn then
    return nil
  end
  return ("-%d%s"):format(ts.warn.n, ts.warn.unit)
end

local function check(case)
  local p = parse.line(case.line)
  local primary = p.due or p.at

  eq(p.kind, case.kind or nil, "kind")
  if case.summary ~= nil then
    eq(p.summary, case.summary, "summary")
  end
  eq(p.emit, case.emit or false, "emit")
  eq(p.done, case.done or false, "done")
  eq(p.priority, case.priority, "priority")
  eq(p.undated, case.undated or false, "undated")
  eq(iso(p.due), case.due, "due")
  eq(iso(p.at), case.at, "at")
  eq(iso(p.at_end), case.at_end, "at_end")
  eq(iso(p.scheduled), case.scheduled, "scheduled")
  eq(iso(p.closed), case.closed, "closed")
  eq(p.rrule, case.rrule, "rrule")
  eq(cookie(primary), case.repeater, "repeater")
  eq(warning(primary), case.warn, "warning")
  eq(primary and primary.time and fmt.time(primary.time) or nil, case.time, "time")
  eq(primary and primary.time_end and fmt.time(primary.time_end) or nil, case.time_end, "time_end")

  local except = {}
  for _, ts in ipairs(p.except) do
    except[#except + 1] = date.iso(ts.date)
  end
  eq(except, case.except or {}, "except")
  eq(codes_of(p), sorted(case.codes), "diagnostic codes")
end

for group, cases in pairs(corpus) do
  describe("corpus: " .. group, function()
    for _, case in ipairs(cases) do
      it(case.line, function()
        check(case)
      end)
    end
  end)
end

describe("corpus: day names", function()
  -- The spec claims every day name in it is correct, checked against `date`.
  -- This is that claim, tested - and it is also a check on this module's own
  -- day-of-week arithmetic, since a bug there would flag a correct note.
  it("every day name in the spec's examples is right", function()
    for group, cases in pairs(corpus) do
      for _, case in ipairs(cases) do
        if not (group == "lint" and case.codes and case.codes[1] == "dayname-mismatch") then
          for body in case.line:gmatch("[<%[]([^<>%[%]]+)[>%]]") do
            local ts = grammar.parse_body(body, true)
            if ts and ts.dayname then
              eq(ts.dayname, date.dayname(ts.date), case.line .. " -> " .. body)
            end
          end
        end
      end
    end
  end)
end)

describe("corpus: the three spellings", function()
  -- The point of the whole keyword discussion: three ways to write it, one
  -- result. If these ever diverge the grammar's central claim is broken.
  it("bare, day-named and DEADLINE: are identical", function()
    local a = parse.line("- [ ] put the bins out <2026-09-01>")
    local b = parse.line("- [ ] put the bins out <2026-09-01 Tue>")
    local c = parse.line("- [ ] put the bins out DEADLINE: <2026-09-01 Tue>")
    for _, p in ipairs({ b, c }) do
      eq(p.kind, a.kind, "kind")
      eq(p.summary, a.summary, "summary")
      eq(date.iso(p.due.date), date.iso(a.due.date), "due")
      eq(p.priority, a.priority, "priority")
      eq(p.emit, a.emit, "emit")
    end
  end)
end)
