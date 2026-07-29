--- Timestamp grammar: the inside of a pair of brackets.
--- Pure lua 5.1, no `vim`. See the marker grammar spec for the rules.
---
---   datespec := date [ SP dayname ] [ SP timespec ] { SP cookie }
---   cookie   := repeater | warning
---
--- Tokenising on whitespace and classifying each token is what makes plain lua
--- patterns sufficient here - there is no alternation left to express - and it
--- is also what gives errors a column instead of a bare "no match".

local date = require("mdical.date")

local M = {}

M.UNITS = { h = true, d = true, w = true, m = true, y = true }

local DAYNAME_SET = {}
for _, n in ipairs(date.DAYNAMES) do
  DAYNAME_SET[n:lower()] = n
end

--- Split on whitespace, keeping each token's offset within `body`.
local function tokenise(body)
  local out = {}
  local i = 1
  while true do
    local s, e = body:find("%S+", i)
    if not s then
      break
    end
    out[#out + 1] = { text = body:sub(s, e), s = s, e = e }
    i = e + 1
  end
  return out
end

local function classify(tok)
  local t = tok.text
  local y, mo, d = t:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then
    return "date", { year = tonumber(y), month = tonumber(mo), day = tonumber(d) }
  end
  local h1, m1, h2, m2 = t:match("^(%d%d):(%d%d)%-(%d%d):(%d%d)$")
  if h1 then
    return "timerange", { { hour = tonumber(h1), min = tonumber(m1) }, { hour = tonumber(h2), min = tonumber(m2) } }
  end
  h1, m1 = t:match("^(%d%d):(%d%d)$")
  if h1 then
    return "time", { hour = tonumber(h1), min = tonumber(m1) }
  end
  -- repeater: + / ++ / .+ then N then unit
  local kind, n, unit = t:match("^(%.%+)(%d+)(%a)$")
  if not kind then
    kind, n, unit = t:match("^(%+%+?)(%d+)(%a)$")
  end
  if kind and M.UNITS[unit] then
    return "repeater", { kind = kind, n = tonumber(n), unit = unit }
  end
  n, unit = t:match("^%-(%d+)(%a)$")
  if n and M.UNITS[unit] then
    return "warning", { n = tonumber(n), unit = unit }
  end
  if DAYNAME_SET[t:lower()] then
    return "dayname", DAYNAME_SET[t:lower()]
  end
  return nil
end

--- Parse a bracket body into a timestamp.
---
--- Three outcomes, and the difference between the last two matters:
---   * a timestamp                     -> ts, nil
---   * not a timestamp at all          -> nil, nil    (caller leaves it as text:
---                                        `[draft]`, `[[a wikilink]]`, `[x]`)
---   * looks like one but is malformed -> nil, err    (caller reports it)
---
--- `err` is `{ msg = ..., offset = n }`, offset being 1-based within `body`.
---
--- @param body string  the text between the brackets
--- @param active boolean  true for <>, false for []
--- @return table|nil ts, table|nil err
function M.parse_body(body, active)
  if body:match("^%s*$") then
    -- `<>` is the empty timestamp: active, no date. `[]` is nothing.
    if active and body == "" then
      return { active = true, empty = true }, nil
    end
    return nil, nil
  end

  local toks = tokenise(body)
  local kind, value = classify(toks[1])
  if kind ~= "date" then
    return nil, nil -- not a timestamp; the caller keeps the text
  end
  if not date.valid(value) then
    return nil, { msg = ("%s is not a real date"):format(toks[1].text), offset = toks[1].s }
  end

  local ts = { active = active, date = value }
  local seen = {}
  for i = 2, #toks do
    local k, v = classify(toks[i])
    if not k then
      return nil, { msg = ("unrecognised in timestamp: %s"):format(toks[i].text), offset = toks[i].s }
    end
    if k == "date" then
      return nil, { msg = "two dates in one timestamp - use `--` for a range", offset = toks[i].s }
    end
    if seen[k] or (k == "timerange" and seen.time) or (k == "time" and seen.timerange) then
      return nil, { msg = ("repeated %s in timestamp"):format(k), offset = toks[i].s }
    end
    seen[k] = true
    if k == "dayname" then
      ts.dayname = v
    elseif k == "time" then
      ts.time = v
    elseif k == "timerange" then
      ts.time, ts.time_end = v[1], v[2]
    elseif k == "repeater" then
      ts.repeater = v
    elseif k == "warning" then
      ts.warn = v
    end
  end

  local function bad_clock(t)
    return t and (t.hour > 23 or t.min > 59)
  end
  if bad_clock(ts.time) or bad_clock(ts.time_end) then
    return nil, { msg = "not a real time of day", offset = toks[2] and toks[2].s or 1 }
  end

  return ts, nil
end

--- The dayname the date actually falls on, or nil if there is no date.
function M.true_dayname(ts)
  if not ts or not ts.date then
    return nil
  end
  return date.dayname(ts.date)
end

return M
