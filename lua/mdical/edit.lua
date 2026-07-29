--- Working out what to change on a line. Pure lua 5.1, no `vim`.
---
--- Split out from `mdical.nvim.insert` so the interesting half - which span gets
--- replaced, what gets inherited, where a checkbox goes - is testable without an
--- editor. The nvim side does buffer reads, writes and notifications only.

local fmt = require("mdical.fmt")

local M = {}

--- Apply `{ s, e, text }` edits to a string. Spans are 1-based and inclusive;
--- an insertion at `n` is `s = n, e = n - 1`. Applied right to left so earlier
--- spans keep their offsets.
function M.apply(line, edits)
  local sorted = {}
  for i, ed in ipairs(edits) do
    sorted[i] = ed
  end
  table.sort(sorted, function(a, b)
    return a.s > b.s
  end)
  for _, ed in ipairs(sorted) do
    line = line:sub(1, ed.s - 1) .. ed.text .. line:sub(ed.e + 1)
  end
  return line
end

--- The timestamp a new date should replace: the deadline, the event's date, or
--- an existing `<>`. nil when the line carries no marker yet.
function M.target(p)
  return p.due or p.at or p.empty_ts
end

--- Merge a hand-typed timestamp over the one already on the line: what was
--- typed wins, anything not typed is inherited. This is what stops re-dating a
--- repeating task from quietly dropping its `+1m`.
function M.merge(typed, existing)
  if not existing then
    return typed
  end
  return {
    active = true,
    date = typed.date,
    dayname = typed.dayname,
    time = typed.time or existing.time,
    time_end = typed.time_end or existing.time_end,
    repeater = typed.repeater or existing.repeater,
    warn = typed.warn or existing.warn,
  }
end

--- Edits that put `ts_text` on the line, and optionally make it a task.
---
--- Re-dates in place when there is already a timestamp, rather than appending a
--- second one - a helper that produced `two-due-dates` would be worse than
--- typing the marker by hand.
---
--- @param p table a parsed line
--- @param ts_text string e.g. "<2026-08-01 Sat>"
--- @param ensure_task boolean|nil prepend `- [ ] ` / insert `[ ] `
--- @return table edits, string|nil warning
function M.date_edits(p, ts_text, ensure_task)
  local edits = {}
  local existing = M.target(p)
  if existing and existing.span then
    edits[#edits + 1] = { s = existing.span.s, e = existing.span.e, text = ts_text }
  else
    local trimmed = p.text:gsub("%s+$", "")
    edits[#edits + 1] = { s = #trimmed + 1, e = #p.text, text = " " .. ts_text }
  end

  local warning
  if ensure_task and not p.checkbox then
    if p.marker and p.marker.kind == "heading" then
      warning = "a heading can't be a task - inserted the date only"
    elseif p.marker then
      edits[#edits + 1] = { s = p.marker.e + 1, e = p.marker.e, text = "[ ] " }
    else
      edits[#edits + 1] = { s = p.content_col, e = p.content_col - 1, text = "- [ ] " }
    end
  end
  return edits, warning
end

--- Convenience: the whole transform, as a string. Used by the tests.
function M.with_date(p, d, opts)
  opts = opts or {}
  local text = opts.timestamp or fmt.new_timestamp(d, M.target(p))
  local edits, warning = M.date_edits(p, text, opts.ensure_task)
  return M.apply(p.text, edits), warning
end

--- Every fixit the line's diagnostics offer.
function M.fixits(p)
  local edits = {}
  for _, d in ipairs(p.diagnostics) do
    if d.fixit then
      edits[#edits + 1] = d.fixit
    end
  end
  return edits
end

return M
