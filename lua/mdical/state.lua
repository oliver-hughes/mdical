--- What the last build emitted. Lua 5.1, no `vim`.
---
--- A loadable lua table rather than the JSON the plan named, because the file is
--- only ever read by this code and a lua table needs neither an encoder nor - the
--- awkward half - a decoder. Same contents, one less thing to get wrong.
---
--- It exists for two reasons: the **count-drop gate**, so one bad parse cannot
--- quietly empty the calendar and go unnoticed for a week, and the **record of
--- emitted UIDs**, so the build only ever deletes resources it created.

local M = {}

M.EMPTY = { version = 1, counts = { tasks = 0, events = 0 }, uids = {} }

--- @return table state
function M.read(path)
  local chunk = loadfile(path)
  if not chunk then
    return M.EMPTY
  end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then
    return M.EMPTY
  end
  value.counts = value.counts or { tasks = 0, events = 0 }
  value.uids = value.uids or {}
  return value
end

local function serialise(value, indent)
  indent = indent or "  "
  local out = { "{\n" }
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local v = value[k]
    local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[%q]"):format(tostring(k))
    if type(v) == "table" then
      out[#out + 1] = ("%s%s = %s,\n"):format(indent, key, serialise(v, indent .. "  "))
    elseif type(v) == "string" then
      out[#out + 1] = ("%s%s = %q,\n"):format(indent, key, v)
    else
      out[#out + 1] = ("%s%s = %s,\n"):format(indent, key, tostring(v))
    end
  end
  out[#out + 1] = indent:sub(3) .. "}"
  return table.concat(out)
end

--- Sorted keys throughout, so the file is byte-stable between identical runs.
--- @return boolean ok, string|nil err
function M.write(path, value)
  local f, err = io.open(path .. ".tmp", "wb")
  if not f then
    return false, err
  end
  f:write("-- written by mdical; a loadable lua table\nreturn " .. serialise(value) .. "\n")
  f:close()
  local ok, rename_err = os.rename(path .. ".tmp", path)
  if not ok then
    os.remove(path .. ".tmp")
    return false, rename_err
  end
  return true
end

--- Which counts the gate watches.
---
--- **Markers and notes, not tasks and events.** The item counts move for
--- entirely legitimate reasons and are too noisy to gate on: completing a
--- repeating task advances its anchor, and because the horizon is measured from
--- today while expansion starts at the anchor, a `+1m` task pushed three months
--- out has one occurrence in the window where it used to have three. One ordinary
--- night of completions can drop the item count by a third.
---
--- Markers move only when lines stop promoting, which is what a parser regression
--- or a bad scope tag actually looks like. `notes` catches the scariest case most
--- directly - a vault checkout that did not update, or a `find` that returned
--- nothing.
---
--- The cost of the change is that a horizon misconfiguration would blow the item
--- counts up or down without moving either of these. The build prints both, so it
--- is visible rather than silent.
M.GATE_KEYS = { "markers", "notes" }

--- Would publishing these counts be a suspicious collapse?
---
--- One bad parse otherwise empties the calendar quietly, and nothing else would
--- notice for a week.
---
--- @param previous table counts from the last run
--- @param current table counts from this run
--- @param opts table|nil {
---   allow_drop = 0.2, floor = 5,
---   keys = M.GATE_KEYS,
---   credit = { markers = n }  drops this run has an explanation for }
--- @return boolean ok, string|nil why
function M.gate(previous, current, opts)
  opts = opts or {}
  local allow = opts.allow_drop or 0.2
  local floor = opts.floor or 5
  local credit = opts.credit or {}

  for _, kind in ipairs(opts.keys or M.GATE_KEYS) do
    -- A completion the ratchet applied this run is an accounted-for drop, so it
    -- comes off the baseline rather than counting against it. Without this, a
    -- productive day looks exactly like a broken parser.
    local was = math.max(0, (previous[kind] or 0) - (credit[kind] or 0))
    local now = current[kind] or 0
    -- below the floor there is not enough history for a ratio to mean anything
    if was >= floor and now < was * (1 - allow) then
      return false, ("%s fell from %d to %d, more than the %d%% the gate allows")
        :format(kind, was, now, math.floor(allow * 100))
    end
  end
  return true
end

return M
