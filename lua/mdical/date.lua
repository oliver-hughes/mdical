--- Date arithmetic for markers. Pure lua 5.1, no `os.time`, no `vim`.
---
--- Deliberately avoids `os.time`/`os.date` for anything but "what is today":
--- `os.time` normalises overflow (Jan 32 -> Feb 1), which is org's behaviour and
--- exactly the thing the grammar overrides, and `os.date("%a")` is locale
--- dependent. Everything here is integer arithmetic on a day count instead, so
--- there is no DST, no timezone and no locale in the picture.
---
--- A `date` throughout is `{ year = 2026, month = 8, day = 1 }`.

local M = {}

M.DAYNAMES = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

--- Days since 1970-01-01. Hinnant's days_from_civil.
--- @return integer
function M.to_days(d)
  local y, m = d.year, d.month
  y = m <= 2 and y - 1 or y
  local era = math.floor((y >= 0 and y or y - 399) / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d.day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Inverse of `to_days`. Hinnant's civil_from_days.
--- @return table date
function M.from_days(z)
  z = z + 719468
  local era = math.floor((z >= 0 and z or z - 146096) / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  return { year = (m <= 2 and y + 1 or y), month = m, day = d }
end

--- 0 = Sunday, matching the index into `M.DAYNAMES` (offset by one).
function M.dow(d)
  return (M.to_days(d) + 4) % 7
end

--- Three-letter day name for a date. Locale-independent by construction.
function M.dayname(d)
  return M.DAYNAMES[M.dow(d) + 1]
end

local function is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function M.days_in_month(y, m)
  if m == 2 and is_leap(y) then
    return 29
  end
  return MONTH_DAYS[m]
end

--- Is this a real calendar date? 2026-02-30 is not.
function M.valid(d)
  if not d or not d.year or not d.month or not d.day then
    return false
  end
  if d.month < 1 or d.month > 12 or d.day < 1 then
    return false
  end
  return d.day <= M.days_in_month(d.year, d.month)
end

function M.eq(a, b)
  return a and b and a.year == b.year and a.month == b.month and a.day == b.day
end

--- a < b
function M.lt(a, b)
  return M.to_days(a) < M.to_days(b)
end

function M.add_days(d, n)
  return M.from_days(M.to_days(d) + n)
end

--- Add `n` months, **clamping** the day to the length of the target month.
--- The deliberate override of org, which overflows: 2026-01-31 +1m is
--- 2026-02-28 here and 2026-03-03 in org.
function M.add_months(d, n)
  local m0 = (d.year * 12) + (d.month - 1) + n
  local year = math.floor(m0 / 12)
  local month = m0 % 12 + 1
  local day = math.min(d.day, M.days_in_month(year, month))
  return { year = year, month = month, day = day }
end

--- Add one interval of a repeater or warning cookie unit.
--- `h` is a no-op on the date: hourly repeaters are accepted for org
--- compatibility only and have no use case here (the parser warns).
function M.add(d, n, unit)
  if unit == "d" then
    return M.add_days(d, n)
  elseif unit == "w" then
    return M.add_days(d, n * 7)
  elseif unit == "m" then
    return M.add_months(d, n)
  elseif unit == "y" then
    return M.add_months(d, n * 12)
  elseif unit == "h" then
    return { year = d.year, month = d.month, day = d.day }
  end
  error("unknown unit: " .. tostring(unit))
end

--- Today, as a date. The only thing in this module that reads the clock.
function M.today()
  local t = os.date("*t")
  return { year = t.year, month = t.month, day = t.day }
end

--- The next occurrence of a repeating marker, honouring all three org
--- flavours. `opts.today` and `opts.closed` are injected so this is testable.
---
---   +Nu   add one interval, once - may still be in the past
---   ++Nu  add repeatedly until strictly after today
---   .+Nu  completion date + N units; nil if there is no completion date
---
--- @return table|nil date, string|nil err
function M.next(d, rep, opts)
  opts = opts or {}
  if not rep then
    return nil, "no repeater"
  end
  if rep.kind == ".+" then
    if not opts.closed then
      return nil, "`.+` needs a CLOSED: date"
    end
    return M.add(opts.closed, rep.n, rep.unit)
  end
  if rep.kind == "+" then
    return M.add(d, rep.n, rep.unit)
  end
  -- "++": catch up to the present.
  --
  -- Each step is `k` intervals from the **anchor**, not one interval from the
  -- previous result. It matters for the clamped cases: iterating makes the clamp
  -- sticky, so a 29 Feb birthday would be stuck on the 28th for ever after its
  -- first non-leap year. From the anchor it comes back to the 29th in 2028.
  local today = opts.today or M.today()
  for k = 1, 4000 do
    local candidate = M.add(d, rep.n * k, rep.unit)
    if M.lt(today, candidate) then
      return candidate
    end
  end
  return nil, "`++` failed to catch up"
end

--- Occurrences of a repeating marker from its anchor date onwards.
--- Used by the build's expansion path; `.+` is not expressible as a series
--- and returns just the anchor.
--- @param opts table { count = 12, until_date = date }
function M.expand(d, rep, opts)
  opts = opts or {}
  local out = { d }
  if not rep or rep.kind == ".+" then
    return out
  end
  local count = opts.count or 12
  local k = 1
  while #out < count do
    -- from the anchor, for the same reason as `M.next`
    local cur = M.add(d, rep.n * k, rep.unit)
    if opts.until_date and M.lt(opts.until_date, cur) then
      break
    end
    out[#out + 1] = cur
    k = k + 1
  end
  return out
end

--- "2026-08-01"
function M.iso(d)
  return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

--- "2026-08-01" -> date, or nil.
function M.parse_iso(s)
  local y, m, dd = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  local d = { year = tonumber(y), month = tonumber(m), day = tonumber(dd) }
  if not M.valid(d) then
    return nil
  end
  return d
end

return M
