--- Reading just enough iCalendar to find out what the phone did. Pure lua 5.1,
--- no `vim`.
---
--- `mdical.ics` writes; this reads. They are deliberately separate and
--- deliberately asymmetric: writing has to be exactly right, reading only has to
--- recover four properties from a `VTODO` some other client wrote.
---
--- So this is **not** a general iCalendar parser and should not grow into one. It
--- does not validate, does not care about property order, and throws nothing
--- away it does not understand - it just never looks at it. The one thing it does
--- take seriously is unfolding, because a long `SUMMARY` from the phone arrives
--- split across lines and a reader that missed that would silently compare the
--- wrong string.

local date = require("mdical.date")

local M = {}

----------------------------------------------------------------------- lexical

--- Split on CRLF or LF. Not `gmatch`, which cannot distinguish a trailing
--- newline from a trailing empty line.
local function split(text)
  local out, start = {}, 1
  while start <= #text do
    local s, e = text:find("\r?\n", start)
    if not s then
      out[#out + 1] = text:sub(start)
      break
    end
    out[#out + 1] = text:sub(start, s - 1)
    start = e + 1
  end
  return out
end

--- RFC 5545 3.1: a line break followed by a single space or htab is a fold, and
--- that one whitespace character is not part of the value.
--- @return string[] content lines
function M.unfold(text)
  local out = {}
  for _, line in ipairs(split(tostring(text or ""))) do
    local first = line:sub(1, 1)
    if (first == " " or first == "\t") and #out > 0 then
      out[#out] = out[#out] .. line:sub(2)
    else
      out[#out + 1] = line
    end
  end
  return out
end

--- Undo TEXT escaping. Backslash last, mirroring `ics.escape` doing it first.
function M.unescape(value)
  return (tostring(value or "")
    :gsub("\\[nN]", "\n")
    :gsub("\\([,;\\])", "%1"))
end

--- Split a content line into name, params and value.
---
--- The value starts at the first `:` that is not inside a quoted parameter -
--- `ATTENDEE;CN="Smith:Jr":mailto:...` is why that qualification exists, and
--- getting it wrong would cut a `DUE;TZID=Europe/London:...` in the wrong place
--- the moment a zone name contained one.
---
--- @return string|nil name, table params, string value
local function property(line)
  local quoted, colon = false, nil
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == '"' then
      quoted = not quoted
    elseif c == ":" and not quoted then
      colon = i
      break
    end
  end
  if not colon then
    return nil
  end

  local head, value = line:sub(1, colon - 1), line:sub(colon + 1)
  local parts, params = {}, {}
  quoted = false
  local from = 1
  for i = 1, #head + 1 do
    local c = head:sub(i, i)
    if c == '"' then
      quoted = not quoted
    elseif (c == ";" and not quoted) or i > #head then
      parts[#parts + 1] = head:sub(from, i - 1)
      from = i + 1
    end
  end

  local name = table.remove(parts, 1) or ""
  for _, part in ipairs(parts) do
    local key, v = part:match("^([^=]+)=(.*)$")
    if key then
      params[key:upper()] = (v:gsub('^"(.*)"$', "%1"))
    end
  end
  return name:upper(), params, value
end

-------------------------------------------------------------------- components

--- Parse into a component tree.
---
--- Nested rather than flattened, on purpose: a `VALARM` inside a `VTODO` has its
--- own `SUMMARY`, and flattening would let it shadow the task's.
---
--- @return table[] components  each { kind, props = {{name, value, params}}, children }
function M.read(text)
  local roots, stack = {}, {}
  for _, line in ipairs(M.unfold(text)) do
    local name, params, value = property(line)
    if name == "BEGIN" then
      local node = { kind = value:upper(), props = {}, children = {} }
      local parent = stack[#stack]
      if parent then
        parent.children[#parent.children + 1] = node
      else
        roots[#roots + 1] = node
      end
      stack[#stack + 1] = node
    elseif name == "END" then
      table.remove(stack)
    elseif name then
      local node = stack[#stack]
      if node then
        node.props[#node.props + 1] = { name = name, value = value, params = params }
      end
    end
  end
  return roots
end

--- The first value of a property, and its parameters.
--- @return string|nil value, table|nil params
function M.get(component, name)
  for _, p in ipairs(component and component.props or {}) do
    if p.name == name then
      return p.value, p.params
    end
  end
  return nil
end

--- Every component of a kind, at any depth.
function M.find(components, kind, out)
  out = out or {}
  for _, c in ipairs(components or {}) do
    if c.kind == kind then
      out[#out + 1] = c
    end
    M.find(c.children, kind, out)
  end
  return out
end

------------------------------------------------------------------------- times

--- A DATE or DATE-TIME value.
---
--- @return table|nil date, table|nil time, string form  "date" | "utc" | "floating" | a TZID
function M.datetime(value, params)
  value = tostring(value or "")
  local y, m, d = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
  if not y then
    return nil, nil, "invalid"
  end
  local when = { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
  if not date.valid(when) then
    return nil, nil, "invalid"
  end

  local hh, mm, ss, z = value:match("^%d%d%d%d%d%d%d%dT(%d%d)(%d%d)(%d%d)(Z?)$")
  if not hh then
    return when, nil, "date"
  end
  local clock = { hour = tonumber(hh), min = tonumber(mm), sec = tonumber(ss) }
  if z == "Z" then
    return when, clock, "utc"
  end
  return when, clock, (params and params.TZID) or "floating"
end

--- A UTC-or-otherwise stamp as local wall time. Anything not marked `Z` is taken
--- at face value, because resolving an arbitrary `TZID` would mean carrying a
--- timezone database and the only stamps that matter here are the phone's, which
--- are always UTC.
--- @param offset integer|nil seconds from UTC, for the tests
--- @return table|nil date, table|nil time
function M.local_stamp(value, params, offset)
  local when, clock, form = M.datetime(value, params)
  if not when then
    return nil
  end
  if form == "utc" and clock then
    return date.utc_to_local(when, clock, offset)
  end
  return when, clock
end

return M
