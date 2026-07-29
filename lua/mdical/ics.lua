--- Markers to iCalendar. Pure lua 5.1, no `vim`, no clock.
---
--- Every rule here is grounded in the M0 spike's recorded wire evidence rather
--- than in a reading of RFC 5545, and the test ids in the comments refer to it.
--- Four of them are load-bearing enough to state up front:
---
--- **TEXT is escaped.** B7/B9 caught radicale storing `buy milk` and silently
--- dropping the rest of `buy milk, bread and eggs` - server-side, before the
--- phone ever saw it. Real note text has commas in it constantly, so this is the
--- highest-probability data-loss bug in the whole pipeline.
---
--- **No `DTSTAMP: now()`.** Output has to be byte-stable or every nightly run is
--- a meaningless commit and real changes vanish in the diff. `DTSTAMP` is derived
--- from the item instead, and A11a showed byte-identical rewrites are silent
--- anyway.
---
--- **No `SEQUENCE`.** A11b, B9a and B9b all showed the phone notices changes
--- without it. The M0 fixtures carry `SEQUENCE:0` because the spike wrote it;
--- omitting it is deliberate.
---
--- **`DTEND` is exclusive on all-day items.** B4/B5 - a one-day event ends the
--- following day, and a three-day range ends on the fourth.

local date = require("mdical.date")
local uid = require("mdical.uid")

local M = {}

M.PRODID = "-//mdical//EN"
M.TZID = "Europe/London"
M.EOL = "\r\n" -- RFC 5545 3.1; the spike's fixtures used LF and radicale took either

--- Undated tasks have no date to derive a `DTSTAMP` from. A fixed sentinel keeps
--- them byte-stable, and nothing reads it - A13 rendered an undated VTODO fine.
M.UNDATED_DTSTAMP = "19700101T000000Z"

M.defaults = {
  --- How far ahead repeaters are expanded. Tasks get a shorter horizon than
  --- events on purpose: twelve months of "pay rent" is twelve reminders, where
  --- twelve months of a birthday is a calendar that looks right.
  horizon = { task_months = 3, event_months = 12, grace_days = 7, max_occurrences = 60 },
}

--- Verbatim from the spike's a2b fixture, which is the version radicale and iOS
--- were actually observed to accept.
local VTIMEZONE = {
  "BEGIN:VTIMEZONE",
  "TZID:Europe/London",
  "BEGIN:DAYLIGHT",
  "TZOFFSETFROM:+0000",
  "TZOFFSETTO:+0100",
  "TZNAME:BST",
  "DTSTART:19700329T010000",
  "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU",
  "END:DAYLIGHT",
  "BEGIN:STANDARD",
  "TZOFFSETFROM:+0100",
  "TZOFFSETTO:+0000",
  "TZNAME:GMT",
  "DTSTART:19701025T020000",
  "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU",
  "END:STANDARD",
  "END:VTIMEZONE",
}

----------------------------------------------------------------- text plumbing

--- Escape a TEXT property value. Backslash first, or the others get doubled.
function M.escape(text)
  return (tostring(text or "")
    :gsub("\\", "\\\\")
    :gsub(";", "\\;")
    :gsub(",", "\\,")
    :gsub("\r\n", "\\n")
    :gsub("\n", "\\n"))
end

--- Fold a content line at 75 **octets**, continuation lines prefixed with a
--- space. Never splits a utf-8 sequence: the vault has em dashes and curly
--- quotes in it, and half a codepoint is a corrupt property.
--- @return string[] physical lines
function M.fold(line)
  if #line <= 75 then
    return { line }
  end
  local out, i, limit = {}, 1, 75
  while i <= #line do
    local take = math.min(limit, #line - i + 1)
    -- back off a byte at a time while the next byte is a utf-8 continuation
    while take > 1 and i + take <= #line do
      local b = line:byte(i + take)
      if b >= 0x80 and b < 0xC0 then
        take = take - 1
      else
        break
      end
    end
    out[#out + 1] = (i == 1 and "" or " ") .. line:sub(i, i + take - 1)
    i = i + take
    limit = 74 -- the leading space costs one of the 75
  end
  return out
end

local function iso_basic(d)
  return ("%04d%02d%02d"):format(d.year, d.month, d.day)
end

local function clock(t)
  return ("%02d%02d00"):format(t.hour, t.min)
end

--- A date-or-datetime property, with the parameters the two cases need.
local function when(name, d, t)
  if not t then
    return ("%s;VALUE=DATE:%s"):format(name, iso_basic(d))
  end
  return ("%s;TZID=%s:%sT%s"):format(name, M.TZID, iso_basic(d), clock(t))
end

--- RFC 5545 durations have no months or years, so a `-1m` warning becomes days.
--- An alarm lead time is approximate by nature; dropping it would be worse.
local function duration(n, unit)
  if unit == "h" then
    return ("-PT%dH"):format(n)
  elseif unit == "w" then
    return ("-P%dW"):format(n)
  elseif unit == "m" then
    return ("-P%dD"):format(n * 30)
  elseif unit == "y" then
    return ("-P%dD"):format(n * 365)
  end
  return ("-P%dD"):format(n)
end

local UNIT_FREQ = { d = "DAILY", w = "WEEKLY", m = "MONTHLY", y = "YEARLY", h = "HOURLY" }

------------------------------------------------------------------ occurrences

--- Which dates a marker emits.
---
--- Expansion rather than `RRULE` delegation, decided because `+1m` and `++1m`
--- map to the *same* rule - `FREQ=MONTHLY` has no notion of completion - so
--- delegating silently discards a distinction the grammar makes. Clamping is not
--- expressible in `RRULE` either, which skips where we clamp.
---
--- Three things are never expanded: a one-off, a `.+` cookie (whose next date is
--- a function of the completion date, so it is not a series at all), and an
--- `RRULE:` passthrough (expanding an arbitrary rule would mean implementing
--- `RRULE`, so that one is emitted verbatim and iOS expands it - A4 proved it
--- will).
---
--- @param p table a parsed line
--- @param opts table|nil { today = date, horizon = {...} }
--- @return table[] dates
function M.occurrences(p, opts)
  opts = opts or {}
  local horizon = opts.horizon or M.defaults.horizon
  local ts = p.due or p.at
  if not ts or not ts.date then
    return {} -- undated: one resource, handled by the caller
  end
  local rep = ts.repeater
  if not rep or rep.kind == ".+" or p.rrule then
    return { ts.date }
  end

  local today = opts.today or date.today()
  local months = p.kind == "task" and horizon.task_months or horizon.event_months
  local from = date.add_days(today, -(horizon.grace_days or 0))
  local until_date = date.add_months(today, months)

  local out = {}
  for _, d in ipairs(date.expand(ts.date, rep, { count = horizon.max_occurrences, until_date = until_date })) do
    if not date.lt(d, from) then
      out[#out + 1] = d
    end
  end
  return out
end

------------------------------------------------------------------------ items

local function dtstamp(d)
  if not d then
    return M.UNDATED_DTSTAMP
  end
  return iso_basic(d) .. "T000000Z"
end

--- The far end of an event: an explicit range end, a timed end, or the defaults.
local function event_end(p, d)
  local ts = p.at
  if p.at_end and p.at_end.date then
    -- a `--` range. All-day is exclusive, so the day after the last day.
    if not ts.time then
      return date.add_days(p.at_end.date, 1), nil
    end
    return p.at_end.date, ts.time_end or p.at_end.time or ts.time
  end
  if not ts.time then
    return date.add_days(d, 1), nil -- B4: one all-day event ends tomorrow
  end
  if ts.time_end then
    return d, ts.time_end
  end
  -- A timed event with no end. Untested on a real phone; one hour is the safe
  -- guess and a zero-length event may render oddly.
  local hour = ts.time.hour + 1
  if hour > 23 then
    return date.add_days(d, 1), { hour = hour - 24, min = ts.time.min }
  end
  return d, { hour = hour, min = ts.time.min }
end

--- One resource, as a complete VCALENDAR - a vdir holds one item per file.
--- @param p table a parsed line
--- @param d table|nil the occurrence date; nil for an undated task
--- @param opts table|nil { dtstamp = "...", uid = "..." }
--- @return table { uid = , text = , kind = }
function M.item(p, d, opts)
  opts = opts or {}
  local ts = p.due or p.at
  local timed = ts and ts.time ~= nil and d ~= nil
  local id = opts.uid or uid.item(p.kind, p.summary, d and date.iso(d) or nil)
  local stamp = opts.dtstamp or dtstamp(d)

  local body = {}
  local function add(line)
    body[#body + 1] = line
  end

  if p.kind == "task" then
    add("BEGIN:VTODO")
    add("UID:" .. id)
    add("DTSTAMP:" .. stamp)
    add("SUMMARY:" .. M.escape(p.summary))
    if d then
      add(when("DUE", d, ts.time))
    end
    -- A3: given both, Reminders shows DUE and ignores DTSTART, so it is omitted.
    -- The exception is a delegated recurrence, where RFC 5545 anchors the rule on
    -- DTSTART - A9 showed Apple's own phone-authored repeat writes DTSTART == DUE.
    if p.rrule and d then
      add(when("DTSTART", d, ts.time))
      add("RRULE:" .. p.rrule)
    end
    if p.priority then
      add("PRIORITY:" .. p.priority) -- A5a/b/c: 1/5/9 render as !!!/!!/!
    end
    -- A6b: a VALARM on a VTODO made iOS display the *alarm* time as the due
    -- time, so a `-Nd` warning on a task is editor-only and emits nothing.
    add("STATUS:NEEDS-ACTION")
    add("END:VTODO")
  else
    local end_date, end_time = event_end(p, d)
    add("BEGIN:VEVENT")
    add("UID:" .. id)
    add("DTSTAMP:" .. stamp)
    add("SUMMARY:" .. M.escape(p.summary))
    add(when("DTSTART", d, ts.time))
    add(when("DTEND", end_date, end_time))
    if p.rrule then
      add("RRULE:" .. p.rrule)
    end
    for _, ex in ipairs(p.except or {}) do
      if ex.date then
        add(when("EXDATE", ex.date, ts.time and (ex.time or ts.time) or nil))
      end
    end
    if ts.warn then
      -- B8 rendered this as a clean "alert 15 mins before" on an event
      add("BEGIN:VALARM")
      add("ACTION:DISPLAY")
      add("DESCRIPTION:" .. M.escape(p.summary))
      add("TRIGGER:" .. duration(ts.warn.n, ts.warn.unit))
      add("END:VALARM")
    end
    add("END:VEVENT")
  end

  local lines = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:" .. M.PRODID }
  if timed then
    for _, l in ipairs(VTIMEZONE) do
      lines[#lines + 1] = l
    end
  end
  for _, l in ipairs(body) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = "END:VCALENDAR"

  local folded = {}
  for _, l in ipairs(lines) do
    for _, physical in ipairs(M.fold(l)) do
      folded[#folded + 1] = physical
    end
  end

  return { uid = id, kind = p.kind, text = table.concat(folded, M.EOL) .. M.EOL }
end

--- Every resource a parsed line produces.
--- @return table[] items
function M.items(p, opts)
  if not p or not p.emit then
    return {}
  end
  if p.undated then
    return { M.item(p, nil, opts) }
  end
  local out = {}
  for _, d in ipairs(M.occurrences(p, opts)) do
    out[#out + 1] = M.item(p, d, opts)
  end
  return out
end

--- `+1w` -> `FREQ=WEEKLY;INTERVAL=1`. Unused while repeaters are expanded, but
--- it is the whole of the delegation path if that decision is ever revisited,
--- and it is cheap to keep honest.
function M.rrule_of(rep)
  if not rep or rep.kind == ".+" or not UNIT_FREQ[rep.unit] then
    return nil
  end
  return ("FREQ=%s;INTERVAL=%d"):format(UNIT_FREQ[rep.unit], rep.n)
end

return M
