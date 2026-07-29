--- Line parser. Pure lua 5.1, no `vim`.
---
--- The unit of parse is the **line**, not the marker, because every rule the
--- grammar states - promotion, one event per line, two due dates, empty summary
--- - is a property of a line.
---
--- Diagnostics come out of here rather than a separate linter, so the editor and
--- the build reach the same verdict from the same code. `emit = false` on any
--- error-severity diagnostic is the one rule that keeps them honest.
---
--- The scan collects **byte spans** and the summary is the line with every span
--- removed. That is what makes the grammar's "strip markers in any order"
--- property fall out instead of being something to get right.

local date = require("mdical.date")
local grammar = require("mdical.grammar")
local fmt = require("mdical.fmt")
local scope = require("mdical.scope")

local M = {}

M.ERROR, M.WARN, M.INFO = "error", "warn", "info"

local KEYWORDS = { "DEADLINE:", "SCHEDULED:", "CLOSED:", "EXCEPT:", "RRULE:" }

-- RFC 5545 recur rule parts, for validating the `RRULE:` passthrough. Lint
-- validates against a known-property list rather than parsing the rule.
local RRULE_PARTS = {
  FREQ = true, UNTIL = true, COUNT = true, INTERVAL = true, BYSECOND = true,
  BYMINUTE = true, BYHOUR = true, BYDAY = true, BYMONTHDAY = true,
  BYYEARDAY = true, BYWEEKNO = true, BYMONTH = true, BYSETPOS = true, WKST = true,
}
local RRULE_FREQ = {
  SECONDLY = true, MINUTELY = true, HOURLY = true, DAILY = true,
  WEEKLY = true, MONTHLY = true, YEARLY = true,
}

local PRIORITY_OF_BANGS = { [1] = 9, [2] = 5, [3] = 1 }
local BANGS_OF_LETTER = { A = "!!!", B = "!!", C = "!" }

--- Strip `spans` from `line`, collapse whitespace runs, trim.
local function strip(line, spans)
  table.sort(spans, function(a, b)
    return a.s < b.s
  end)
  local out, pos = {}, 1
  for _, sp in ipairs(spans) do
    if sp.s > pos then
      out[#out + 1] = line:sub(pos, sp.s - 1)
    end
    pos = math.max(pos, sp.e + 1)
  end
  out[#out + 1] = line:sub(pos)
  return (table.concat(out, " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse one line.
--- @param line string
--- @return table parsed
function M.line(line)
  local p = {
    text = line,
    kind = nil, -- "task" | "event" | nil (inert)
    done = false,
    summary = "",
    priority = nil,
    due = nil, -- task: the deadline, bare or explicit
    undated = false, -- task: `<>`
    at = nil, -- event: when
    at_end = nil, -- event: the far end of a `--` range
    empty_ts = nil, -- the `<>` itself, so the editor can re-date it
    scheduled = nil,
    closed = nil,
    except = {},
    rrule = nil,
    diagnostics = {},
    emit = false,
  }
  local spans = {}
  local timestamps = {} -- every ts parsed, for the day-name and cookie checks

  local function diag(severity, code, msg, s, e, fixit)
    p.diagnostics[#p.diagnostics + 1] = {
      severity = severity,
      code = code,
      msg = msg,
      col = s or 1,
      end_col = e or (s or 1),
      fixit = fixit,
    }
  end

  ---------------------------------------------------------------- line prefix
  local i = select(2, line:find("^%s*")) + 1
  local is_list, is_heading, is_task = false, false, false

  local kind
  local s, e = line:find("^[-*+]%s+", i)
  if s then
    is_list, kind = true, "bullet"
  else
    s, e = line:find("^#+%s+", i)
    if s then
      is_heading, kind = true, "heading"
    else
      s, e = line:find("^%d+[.)]%s+", i)
      if s then
        is_list, kind = true, "ordered"
      end
    end
  end
  if s then
    spans[#spans + 1] = { s = s, e = e }
    -- span covers the trailing space, so `e + 1` is where content starts
    p.marker = { s = s, e = e, kind = kind }
    i = e + 1
  end
  p.content_col = i

  -- A checkbox only counts directly after a list marker.
  if is_list then
    local cs, ce, mark = line:find("^%[([ xX])%]", i)
    if cs then
      spans[#spans + 1] = { s = cs, e = ce }
      p.checkbox = { s = cs, e = ce }
      is_task = true
      p.done = mark:lower() == "x"
      i = ce + 1
      local _, we = line:find("^%s+", i)
      i = (we or ce) + 1
    end
  end

  -- Priority sits where org puts `[#A]`: right after the checkbox.
  if is_task then
    local ps, _, bangs = line:find("^(!+)%s", i)
    if ps then
      if #bangs <= 3 then
        p.priority = PRIORITY_OF_BANGS[#bangs]
        spans[#spans + 1] = { s = ps, e = ps + #bangs - 1 }
        i = ps + #bangs
      else
        diag(M.WARN, "bad-priority", ("%d `!` is not a priority - use !, !! or !!!"):format(#bangs), ps,
          ps + #bangs - 1)
      end
    end
  end

  ------------------------------------------------------------------ main scan
  local bare, empty_bare = {}, nil
  local deadline, range_end = nil, nil

  --- Read a bracket group starting at `pos`.
  --- Returns nil when there is no group there at all, and a group with
  --- `ts == nil and err == nil` when the brackets hold something that is not a
  --- timestamp - `[draft]`, `[[a wikilink]]`, `<div>` - which must be left in
  --- the summary untouched.
  local function read_group(pos)
    local open = line:sub(pos, pos)
    if open ~= "<" and open ~= "[" then
      return nil
    end
    local close = open == "<" and ">" or "]"
    local ce = line:find(close, pos + 1, true)
    if not ce then
      return nil
    end
    local body = line:sub(pos + 1, ce - 1)
    local ts, err = grammar.parse_body(body, open == "<")
    return { s = pos, e = ce, body = body, ts = ts, err = err, active = open == "<" }
  end

  --- Record a group's span and collect its timestamp, or its error.
  local function take(g)
    spans[#spans + 1] = { s = g.s, e = g.e }
    if g.err then
      diag(M.ERROR, "bad-timestamp", g.err.msg, g.s, g.e)
      return nil
    end
    g.ts.span = { s = g.s, e = g.e }
    timestamps[#timestamps + 1] = g.ts
    return g.ts
  end

  --- Skip whitespace from `pos`.
  local function skip_ws(pos)
    local _, we = line:find("^%s+", pos)
    return we and we + 1 or pos
  end

  local pos = i
  while pos <= #line do
    local matched = false

    -- keyword, at a word boundary
    local prev = pos > 1 and line:sub(pos - 1, pos - 1) or " "
    if not prev:match("[%w_]") then
      for _, kw in ipairs(KEYWORDS) do
        local ks, ke = line:find(kw, pos, true)
        if ks == pos then
          local name = kw:sub(1, -2)
          spans[#spans + 1] = { s = ks, e = ke }
          local after = skip_ws(ke + 1)

          if name == "RRULE" then
            local vs, ve = line:find("%S+", after)
            if vs then
              spans[#spans + 1] = { s = vs, e = ve }
              p.rrule = line:sub(vs, ve)
              for part in p.rrule:gmatch("[^;]+") do
                local key, value = part:match("^([%u]+)=(.+)$")
                if not key or not RRULE_PARTS[key] then
                  diag(M.ERROR, "bad-rrule", ("`%s` is not a recurrence rule part"):format(part), vs, ve)
                elseif key == "FREQ" and not RRULE_FREQ[value] then
                  diag(M.ERROR, "bad-rrule", ("`%s` is not a FREQ value"):format(value), vs, ve)
                end
              end
              pos = ve + 1
            else
              diag(M.ERROR, "keyword-without-value", "RRULE: with no rule after it", ks, ke)
              pos = ke + 1
            end
          elseif name == "EXCEPT" then
            -- takes every inactive timestamp that follows, space separated
            local n, at = 0, after
            while true do
              local g = read_group(at)
              if not g or g.active or (not g.ts and not g.err) then
                break
              end
              local ts = take(g)
              if ts then
                p.except[#p.except + 1] = ts
              end
              n = n + 1
              at = skip_ws(g.e + 1)
            end
            if n == 0 then
              diag(M.ERROR, "keyword-without-timestamp", "EXCEPT: with no [timestamp] after it", ks, ke)
            end
            pos = at
          else
            local g = read_group(after)
            if not g or (not g.ts and not g.err) then
              diag(M.ERROR, "keyword-without-timestamp",
                ("%s: with no timestamp after it"):format(name), ks, ke)
              pos = ke + 1
            else
              local ts = take(g)
              if ts then
                if name == "DEADLINE" then
                  deadline = ts
                elseif name == "SCHEDULED" then
                  p.scheduled = ts
                elseif name == "CLOSED" then
                  p.closed = ts
                end
              end
              pos = g.e + 1
            end
          end
          matched = true
          break
        end
      end
    end

    if not matched then
      local g = read_group(pos)
      if g and (g.ts or g.err) then
        local last_e = g.e
        local ts = take(g)
        if ts then
          if ts.active and ts.empty then
            empty_bare = ts
          elseif ts.active then
            bare[#bare + 1] = ts
            -- `<a>--<b>` is a range, not two markers
            if line:sub(g.e + 1, g.e + 2) == "--" then
              local g2 = read_group(g.e + 3)
              if g2 and g2.active and (g2.ts or g2.err) then
                spans[#spans + 1] = { s = g.e + 1, e = g.e + 2 }
                local ts2 = take(g2)
                if ts2 then
                  range_end = ts2
                end
                last_e = g2.e
              end
            end
          end
          -- inactive with no keyword: parsed, span stripped, deliberately inert
        end
        pos = last_e + 1
      elseif g and g.body:match("^#[ABC]$") then
        -- org's priority cookie. Insidious: without this it exports as an
        -- unprioritised task *and* quietly adds a tag named A to the vault.
        local letter = g.body:sub(2, 2)
        spans[#spans + 1] = { s = g.s, e = g.e }
        diag(M.ERROR, "org-priority", ("[#%s] is not read here - write %s"):format(letter, BANGS_OF_LETTER[letter]),
          g.s, g.e, { s = g.s, e = g.e, text = BANGS_OF_LETTER[letter] })
        pos = g.e + 1
      else
        pos = pos + 1
      end
    end
  end

  ------------------------------------------------------------------ promotion
  p.empty_ts = empty_bare
  if is_task then
    if #bare > 1 or (deadline and #bare > 0) then
      local extra = deadline and bare[1] or bare[2]
      diag(M.ERROR, "two-due-dates", "two due dates on one task - keep one", extra.span.s, extra.span.e)
    end
    p.due = deadline or bare[1]
    p.undated = p.due == nil and empty_bare ~= nil
    if p.due or p.undated then
      p.kind = "task"
    end
    if range_end then
      diag(M.ERROR, "range-on-task", "a task has one due date, not a range", range_end.span.s, range_end.span.e)
    end
    if p.scheduled and bare[1] and not deadline then
      diag(M.INFO, "implicit-deadline",
        "bare <...> next to SCHEDULED: - write DEADLINE: so it reads unambiguously", bare[1].span.s, bare[1].span.e)
    end
  else
    if #bare > 1 then
      diag(M.ERROR, "two-events", "two events on one line - use `--` for a span, or split the line",
        bare[2].span.s, bare[2].span.e)
    end
    p.at = bare[1]
    p.at_end = range_end
    if p.at then
      p.kind = "event"
    end
    if empty_bare then
      diag(M.INFO, "empty-ts-on-non-task", "`<>` only means something after a checkbox", empty_bare.span.s,
        empty_bare.span.e)
    end
    if deadline or p.scheduled or p.closed then
      local ts = deadline or p.scheduled or p.closed
      diag(M.WARN, "keyword-on-non-task",
        "planning keywords need a `- [ ]` - add one, or drop the keyword", ts.span.s, ts.span.e)
      p.kind = nil
    end
  end

  --------------------------------------------------------- per-timestamp lint
  for _, ts in ipairs(timestamps) do
    if ts.dayname then
      local truth = grammar.true_dayname(ts)
      if truth and truth ~= ts.dayname then
        diag(M.WARN, "dayname-mismatch", ("%s is a %s, not a %s"):format(date.iso(ts.date), truth, ts.dayname),
          ts.span.s, ts.span.e, { s = ts.span.s, e = ts.span.e, text = fmt.timestamp(ts, { dayname = truth }) })
      end
    end
    if ts.repeater and ts.repeater.unit == "h" then
      diag(M.WARN, "hourly-repeat", "hourly repeaters are accepted for org compatibility and have no use here",
        ts.span.s, ts.span.e)
    end
    if not ts.active and ts.repeater then
      diag(M.INFO, "cookie-on-inactive", "an inactive timestamp never repeats - the cookie does nothing",
        ts.span.s, ts.span.e)
    end
  end

  ---------------------------------------------------------------- summary etc
  p.summary = strip(line, spans)
  if p.kind and p.summary == "" then
    diag(M.ERROR, "empty-summary", "the marker has nothing to name", 1, #line)
  end
  if p.kind == "task" and p.done and not p.closed then
    diag(M.INFO, "done-without-closed", "completed with no CLOSED: - `.+` repeaters need one", 1, #line)
  end

  local has_error = false
  for _, d in ipairs(p.diagnostics) do
    if d.severity == M.ERROR then
      has_error = true
    end
  end
  p.emit = p.kind ~= nil and not p.done and not has_error
  p.heading = is_heading or nil

  return p
end

--- Parse a whole note.
---
--- Frontmatter and fenced code are skipped. Fences are a deliberate addition to
--- the spec, which leaves them unsolved: a marker inside a ``` block is never
--- meant to fire, and doing it here rather than in either consumer keeps the
--- build and the editor agreeing.
---
--- @param lines string[]
--- @return table[] parsed  one entry per line, `false` for skipped lines
function M.document(lines)
  local out = {}
  local fm_last = select(2, scope.bounds(lines)) or 0
  local fence = nil
  for n, line in ipairs(lines) do
    if n <= fm_last then
      out[n] = false
    else
      local f = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
      if fence then
        out[n] = false
        if f and f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then
          fence = nil
        end
      elseif f then
        fence = f
        out[n] = false
      else
        out[n] = M.line(line)
      end
    end
  end
  return out
end

return M
