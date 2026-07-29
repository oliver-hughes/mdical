--- Canonical rendering of a timestamp. Pure lua 5.1, no `vim`.
---
--- Used three ways: the inserter writes markers with it, dayname fixits rewrite
--- a whole timestamp with it, and the round-trip test asserts
--- `fmt(parse(x)) == x` for every canonical form in the corpus - which is the
--- cheap way to catch span bugs.
---
--- The day name is always written, as org's own insertion commands do. Cookie
--- order is repeater then warning, which is what org emits.

local date = require("mdical.date")

local M = {}

function M.time(t)
  return string.format("%02d:%02d", t.hour, t.min)
end

--- @param ts table
--- @param opts table|nil { dayname = "Wed", brackets = "<" | "[" }
function M.timestamp(ts, opts)
  opts = opts or {}
  local active = ts.active
  if opts.brackets then
    active = opts.brackets == "<"
  end
  local open, close = "<", ">"
  if not active then
    open, close = "[", "]"
  end
  if ts.empty or not ts.date then
    return open .. close
  end

  local parts = { date.iso(ts.date), opts.dayname or ts.dayname or date.dayname(ts.date) }
  if ts.time then
    if ts.time_end then
      parts[#parts + 1] = M.time(ts.time) .. "-" .. M.time(ts.time_end)
    else
      parts[#parts + 1] = M.time(ts.time)
    end
  end
  if ts.repeater then
    parts[#parts + 1] = ("%s%d%s"):format(ts.repeater.kind, ts.repeater.n, ts.repeater.unit)
  end
  if ts.warn then
    parts[#parts + 1] = ("-%d%s"):format(ts.warn.n, ts.warn.unit)
  end
  return open .. table.concat(parts, " ") .. close
end

--- A fresh active timestamp, optionally inheriting the cookies of one already
--- on the line. The inserter uses this so re-dating a marker never quietly
--- drops its repeater.
--- @param d table date
--- @param inherit table|nil an existing ts whose time and cookies to keep
function M.new_timestamp(d, inherit)
  local ts = { active = true, date = d }
  if inherit then
    ts.time, ts.time_end = inherit.time, inherit.time_end
    ts.repeater, ts.warn = inherit.repeater, inherit.warn
  end
  return M.timestamp(ts)
end

return M
