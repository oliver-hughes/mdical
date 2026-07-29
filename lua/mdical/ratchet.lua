--- Completions, coming back. Pure lua 5.1, no `vim`, no io.
---
--- This is steps 3 and 4 of the nightly run - the only part of the whole pipeline
--- that writes to your notes - and it is deliberately a *planner*: it takes
--- markers and iCalendar text and returns the lines it would replace.
--- `bin/mdical-ingest` does the reading and writing. That split is what makes the
--- one dangerous step in the pipeline testable without a vault.
---
--- ## matching a resource back to a line
---
--- UIDs are content hashes, so they cannot be reversed. Instead the same index
--- the build would produce is rebuilt - kind, summary and occurrence date, for
--- every marker - and completions are looked up in it. Two consequences worth
--- knowing: moving a marker between notes does not break the match, and renaming
--- a task does.
---
--- ## what completion does, per flavour
---
--- | marker | on completion |
--- |--------|---------------|
--- | one-off | `- [ ]` becomes `- [x]`, and `CLOSED:` records when |
--- | `+N` | the timestamp advances one interval from the occurrence that was ticked |
--- | `++N` | the timestamp advances past today |
--- | `.+N` | the timestamp becomes the completion date plus N |
--- | `RRULE:` | nothing - iOS expanded it, so iOS owns it |
---
--- A repeater keeps its `- [ ]` and gets **no** `CLOSED:`. That mirrors org,
--- where completing a repeating task logs the repeat and moves the date rather
--- than closing the entry, and it avoids holding the same fact twice: the new
--- anchor already *is* the result of the arithmetic, so a `CLOSED:` beside it
--- could only ever disagree with it.
---
--- Advancing from the ticked occurrence rather than from the anchor matters when
--- an earlier one was missed. Tick September's rent with August's still
--- outstanding and the anchor moves to October; from the anchor it would move to
--- September and the task you just completed would come straight back.

local date = require("mdical.date")
local edit = require("mdical.edit")
local fmt = require("mdical.fmt")
local ical = require("mdical.ical")
local ics = require("mdical.ics")
local uid = require("mdical.uid")

local M = {}

------------------------------------------------------------------- the calendar

--- Has this `VTODO` been completed?
---
--- `STATUS:COMPLETED` is the property that means it, but iOS writes
--- `PERCENT-COMPLETE:100` alongside and some clients write only that, so either
--- counts. Both were present on the wire in M0's a1.
function M.is_complete(todo)
  if (ical.get(todo, "STATUS") or ""):upper() == "COMPLETED" then
    return true
  end
  return tonumber(ical.get(todo, "PERCENT-COMPLETE") or "") == 100
end

--- When it was completed, as local wall time.
---
--- iOS does write `COMPLETED:`, in UTC - M0's a1 recorded
--- `COMPLETED:20260728T195946Z` from a tick at 20:59 BST. The fallbacks are for
--- clients that set only `STATUS`, and losing the exact minute is much better
--- than refusing the completion.
---
--- @return table|nil date, table|nil time, string source
function M.completed_at(todo, opts)
  opts = opts or {}
  for _, name in ipairs({ "COMPLETED", "LAST-MODIFIED", "DTSTAMP" }) do
    local value, params = ical.get(todo, name)
    if value then
      local d, t = ical.local_stamp(value, params, opts.offset)
      if d then
        return d, t, name
      end
    end
  end
  return nil, nil, "none"
end

--- Every completed task in a set of resources.
---
--- @param resources table[] each { path, text } - one `.ics` file
--- @return table[] completions  each { uid, summary, date, time, source, path }
function M.completions(resources, opts)
  local out = {}
  for _, r in ipairs(resources or {}) do
    for _, todo in ipairs(ical.find(ical.read(r.text), "VTODO")) do
      local id = ical.get(todo, "UID")
      if id and M.is_complete(todo) then
        local d, t, source = M.completed_at(todo, opts)
        out[#out + 1] = {
          uid = id,
          summary = ical.unescape(ical.get(todo, "SUMMARY") or ""),
          date = d,
          time = t,
          source = source,
          path = r.path,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.uid < b.uid -- a stable order, so the report reads the same twice
  end)
  return out
end

------------------------------------------------------------------ the markdown

--- UID -> the marker and occurrence that produced it.
---
--- Mirrors `ics.items` without building any iCalendar, and gates on `emit` for
--- the same reason the build does: a line with an error, or one already ticked,
--- has no resource to be completing.
---
--- @param markers table[] from `scan.vault` - each { parsed, path, lnum }
--- @return table index, integer duplicates
function M.index(markers, opts)
  local out, duplicates = {}, 0
  local function put(id, marker, d)
    if out[id] then
      duplicates = duplicates + 1 -- two lines collapsing to one resource
      return
    end
    out[id] = { marker = marker, date = d }
  end

  for _, marker in ipairs(markers or {}) do
    local p = marker.parsed
    if p.emit and p.kind == "task" then
      if p.undated then
        put(uid.item("task", p.summary, nil), marker, nil)
      else
        for _, d in ipairs(ics.occurrences(p, opts)) do
          put(uid.item("task", p.summary, date.iso(d)), marker, d)
        end
      end
    end
  end
  return out, duplicates
end

--- The rewritten line for one completion.
---
--- @param p table a parsed line
--- @param occurrence table|nil the date whose resource was ticked
--- @param completion table { date, time }
--- @param opts table|nil { today = date }
--- @return string|nil line, string action_or_reason, string|nil kind "closed"|"advanced"
function M.rewrite(p, occurrence, completion, opts)
  opts = opts or {}
  local ts = p.due or p.empty_ts
  if not ts then
    return nil, "no timestamp on the line"
  end
  if p.rrule then
    -- A4 showed iOS expands an `RRULE` itself, and what completing one instance
    -- of a recurring VTODO writes back is the untested RFC-5545 ambiguity the
    -- grammar note flags. Touching it on a guess is worse than leaving it.
    return nil, "RRULE: passthrough - the phone owns this recurrence"
  end
  if not p.checkbox then
    return nil, "not a checkbox line"
  end

  local rep = ts.repeater
  if rep then
    local next_date, err = date.next(occurrence or ts.date, rep, {
      today = opts.today,
      closed = completion.date,
    })
    if not next_date then
      return nil, err or "could not advance the repeater"
    end
    local advanced = {
      active = ts.active,
      date = next_date,
      time = ts.time,
      time_end = ts.time_end,
      repeater = rep,
      warn = ts.warn,
    }
    return edit.apply(p.text, {
      { s = ts.span.s, e = ts.span.e, text = fmt.timestamp(advanced) },
    }), "advanced to " .. date.iso(next_date), "advanced"
  end

  local closed = fmt.timestamp({ active = false, date = completion.date, time = completion.time })
  local edits = { { s = p.checkbox.s, e = p.checkbox.e, text = "[x]" } }
  if p.closed then
    edits[#edits + 1] = { s = p.closed.span.s, e = p.closed.span.e, text = closed }
  else
    local trimmed = p.text:gsub("%s+$", "")
    edits[#edits + 1] = { s = #trimmed + 1, e = #p.text, text = " CLOSED: " .. closed }
  end
  return edit.apply(p.text, edits), "closed " .. closed, "closed"
end

--- What to change in markdown, given the vault's markers and the vdir's
--- completions.
---
--- @param markers table[] from `scan.vault`
--- @param completions table[] from `M.completions`
--- @param opts table|nil { today = date, horizon = {...} }
--- @return table plan {
---   changes = {{ path, lnum, before, after, action, kind, summary }},
---   skipped = {{ uid, summary, why }},
---   unknown = integer,   completed resources this build never emitted
---   gone = integer,      ours, but markdown no longer has them
---   duplicates = integer,
---   closed = integer }   changes that stop a marker promoting - the number the
---                        build's count-drop gate needs to credit
function M.plan(markers, completions, opts)
  opts = opts or {}
  local today = opts.today or date.today()
  local index, duplicates = M.index(markers, opts)
  local plan = { changes = {}, skipped = {}, unknown = 0, gone = 0, duplicates = duplicates, closed = 0 }

  --- One line can receive two completions in a night - tick August's rent and
  --- September's together and both resolve to the same marker. Keep the latest
  --- occurrence, which is the one the repeater should advance from; applying both
  --- would mean two rewrites of the same line, and the second would be computed
  --- from a line that no longer exists.
  local winner = {}
  local order = {}
  for _, c in ipairs(completions) do
    local entry = index[c.uid]
    if not entry then
      if uid.is_ours(c.uid) then
        plan.gone = plan.gone + 1
      else
        plan.unknown = plan.unknown + 1
      end
    else
      local key = entry.marker.path .. "\31" .. entry.marker.lnum
      local held = winner[key]
      if not held then
        order[#order + 1] = key
        winner[key] = { entry = entry, completion = c }
      elseif entry.date and held.entry.date and date.lt(held.entry.date, entry.date) then
        winner[key] = { entry = entry, completion = c }
      end
    end
  end

  for _, key in ipairs(order) do
    local held = winner[key]
    local marker, c = held.entry.marker, held.completion
    local completion = {
      date = c.date or today,
      time = c.date and c.time or nil,
    }
    local after, note, kind = M.rewrite(marker.parsed, held.entry.date, completion, { today = today })
    if after and after ~= marker.parsed.text then
      plan.changes[#plan.changes + 1] = {
        path = marker.path,
        lnum = marker.lnum,
        before = marker.parsed.text,
        after = after,
        action = note,
        kind = kind,
        summary = marker.parsed.summary,
      }
      if kind == "closed" then
        -- an advanced repeater still promotes; a closed task does not
        plan.closed = plan.closed + 1
      end
    elseif not after then
      plan.skipped[#plan.skipped + 1] = { uid = c.uid, summary = c.summary, why = note }
    end
  end

  table.sort(plan.changes, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.lnum < b.lnum
  end)
  return plan
end

--- Replace whole lines in a note's bytes and change nothing else.
---
--- Only the changed lines change. Line endings, indentation, and the presence or
--- absence of a final newline are all preserved, because a rewrite that
--- normalised them would show up as a whole-file diff and bury the one line that
--- actually moved - in the user's own notes, in a commit they did not make.
---
--- Every change carries the line it expects to find. A mismatch means the file
--- moved between planning and writing, and the caller is expected to write
--- nothing rather than guess: `stale` being non-empty is a refusal, not a warning.
---
--- `lnum` counts lines the way `scan.read` does, which is what the plan refers to.
---
--- @param text string the note as it is on disk
--- @param changes table[] each { lnum, before, after }
--- @return string updated, integer[] stale
function M.splice(text, changes)
  local by_lnum = {}
  for _, change in ipairs(changes) do
    by_lnum[change.lnum] = change
  end

  local out, seen, stale = {}, {}, {}
  local lnum, start = 1, 1
  while start <= #text do
    local s, e = text:find("\r?\n", start)
    local content = text:sub(start, (s or #text + 1) - 1)
    local change = by_lnum[lnum]
    if change then
      seen[lnum] = true
      if content == change.before then
        content = change.after
      else
        stale[#stale + 1] = lnum
      end
    end
    out[#out + 1] = content .. (s and text:sub(s, e) or "")
    if not s then
      break
    end
    lnum, start = lnum + 1, e + 1
  end

  -- a line the plan named and the file does not have is stale for the same reason
  for n in pairs(by_lnum) do
    if not seen[n] then
      stale[#stale + 1] = n
    end
  end
  table.sort(stale)
  return table.concat(out), stale
end

return M
