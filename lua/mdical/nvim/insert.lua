--- Writing markers: pick a date and put it on the line, or apply a fixit.
--- Buffer io, prompts and notifications only - the edit logic is `mdical.edit`
--- and the option lists are `dates` / `times` / `cookies`, all of them pure.
---
--- Two flows:
---   insert / task   one prompt, a date. Re-dates in place, keeps the cookies
---   build / build-task   date, then time, then repeater. Replaces outright
---
--- Both assemble a timestamp *body* and hand it to `grammar.parse_body`, so the
--- inserter can only ever write markers the parser accepts.

local parse = require("mdical.parse")
local fmt = require("mdical.fmt")
local grammar = require("mdical.grammar")
local date = require("mdical.date")
local edit = require("mdical.edit")
local pick = require("mdical.nvim.pick")
local dates = require("mdical.nvim.dates")
local times = require("mdical.nvim.times")
local cookies = require("mdical.nvim.cookies")

local M = {}

local function current()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  return bufnr, lnum, parse.line(line)
end

--- One `nvim_buf_set_lines`, so the date and any checkbox are a single undo
--- step, then park the cursor on the closing `>`.
local function write(bufnr, lnum, edits, place_cursor)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { edit.apply(line, edits) })
  if place_cursor and vim.api.nvim_get_current_buf() == bufnr then
    local col = edit.cursor_col(edits)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col - 1 })
  end
end

local function put(bufnr, lnum, p, ts_text, ensure_task)
  local edits, warning = edit.date_edits(p, ts_text, ensure_task)
  if warning then
    vim.notify("mdical: " .. warning, vim.log.levels.WARN)
  end
  write(bufnr, lnum, edits, true)
end

--- Build a timestamp from its parts and validate it through the grammar, so
--- nothing this module writes can fail to parse.
--- @return string|nil text, string|nil err
local function timestamp(d, time_text, cookie_text)
  local body = date.iso(d)
  if time_text then
    body = body .. " " .. time_text
  end
  if cookie_text then
    body = body .. " " .. cookie_text
  end
  local ts, err = grammar.parse_body(body, true)
  if not ts then
    return nil, err and err.msg or ("`%s` is not a timestamp"):format(body)
  end
  return fmt.timestamp(ts)
end

--------------------------------------------------------------------- prompts
--
-- Each stage takes a list of presets *and* whatever was typed, and resolves them
-- in this order:
--
--   1. typed text that is itself a valid answer  -> use it
--   2. otherwise, the highlighted preset         -> use that
--   3. otherwise                                 -> say why it was no good
--
-- Typed text has to win outright rather than only when nothing matched, because
-- fuzzy matching is too loose to be the arbiter: `+2d` matches the preset
-- `+1y -21d` on a subsequence, so "did anything match" would silently discard
-- what was typed. Meanwhile `today`, `sat` and `eom` are not valid answers, so
-- filtering to a preset and confirming still works exactly as expected.

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Shared resolution. `check(typed)` returns a value, or nil plus a reason.
--- @param use fun(value: any)
--- @param from_entry fun(entry: table): any
local function resolve(entry, typed, check, use, from_entry)
  if typed == nil then
    return -- cancelled
  end
  typed = trim(typed)
  if typed ~= "" then
    local value, err = check(typed)
    if value ~= nil then
      return use(value)
    end
    if entry then
      return use(from_entry(entry))
    end
    vim.notify("mdical: " .. (err or ("`%s` is no good here"):format(typed)), vim.log.levels.ERROR)
    return
  end
  if entry then
    return use(from_entry(entry))
  end
end

--- @param on_date fun(d: table, ts: table|nil)  not called if cancelled
local function ask_date(prompt, on_date)
  local entries = dates.entries()
  entries[#entries + 1] = { label = "date…", custom = true }
  pick.select({
    prompt = prompt,
    entries = entries,
    format = dates.format,
    free_prompt = "date [day] [time] [cookies]: ",
    on_choice = function(entry, typed)
      resolve(entry, typed, function(text)
        local ts, err = grammar.parse_body(text, true)
        if not ts or not ts.date then
          return nil, ("`%s` is not a date - %s"):format(text, err and err.msg or "expected YYYY-MM-DD")
        end
        -- typed text may carry a time and cookies as well as the date
        return { date = ts.date, ts = ts }
      end, function(chosen)
        on_date(chosen.date, chosen.ts)
      end, function(e)
        return { date = e.date }
      end)
    end,
  })
end

local function ask_time(on_time)
  pick.select({
    prompt = "Time",
    entries = times.presets,
    format = times.format,
    free_prompt = "time (9, 9am, 930, midday, 9am-5pm): ",
    on_choice = function(entry, typed)
      resolve(entry, typed, function(text)
        local normalised = times.normalise(text)
        if not normalised then
          return nil, ("`%s` is not a time"):format(text)
        end
        return normalised
      end, function(value)
        on_time(value ~= "" and value or nil)
      end, function(e)
        return e.value or "" -- the `none` entry
      end)
    end,
  })
end

local function ask_cookies(on_cookies)
  pick.select({
    prompt = "Repeat / warn",
    entries = cookies.presets,
    format = cookies.format,
    free_prompt = "cookies ([+|++|.+]N[dwmy] and/or -N[dwmy]): ",
    on_choice = function(entry, typed)
      resolve(entry, typed, cookies.valid, function(value)
        on_cookies(value ~= "" and value or nil)
      end, function(e)
        return e.cookies or "" -- the `none` entry
      end)
    end,
  })
end

----------------------------------------------------------------------- flows

--- Pick a date and write it onto the current line, keeping whatever time and
--- cookies are already there.
--- @param opts table|nil { ensure_task = boolean }
function M.insert(opts)
  opts = opts or {}
  local bufnr, lnum, p = current()
  ask_date(opts.ensure_task and "Task deadline" or "Date", function(d, ts)
    local existing = edit.target(p)
    local text
    if ts then
      text = fmt.timestamp(edit.merge(ts, existing))
    else
      text = fmt.new_timestamp(d, existing)
    end
    put(bufnr, lnum, p, text, opts.ensure_task)
  end)
end

--- Date, then time, then repeater. Replaces any existing timestamp outright -
--- choosing "none" at a stage means none, not "keep what was there".
--- @param opts table|nil { ensure_task = boolean }
function M.build(opts)
  opts = opts or {}
  local bufnr, lnum, p = current()
  ask_date(opts.ensure_task and "Task deadline" or "Date", function(d, typed)
    ask_time(function(time_text)
      -- free text at the date stage may already have carried a time
      if not time_text and typed and typed.time then
        time_text = fmt.time(typed.time) .. (typed.time_end and ("-" .. fmt.time(typed.time_end)) or "")
      end
      ask_cookies(function(cookie_text)
        local text, err = timestamp(d, time_text, cookie_text)
        if not text then
          vim.notify("mdical: " .. err, vim.log.levels.ERROR)
          return
        end
        put(bufnr, lnum, p, text, opts.ensure_task)
      end)
    end)
  end)
end

--- Apply every fixit the current line's diagnostics offer.
function M.fix()
  local bufnr, lnum, p = current()
  local edits = edit.fixits(p)
  if #edits == 0 then
    vim.notify("mdical: nothing to fix on this line", vim.log.levels.INFO)
    return
  end
  write(bufnr, lnum, edits, false)
  vim.notify(("mdical: applied %d fix%s"):format(#edits, #edits == 1 and "" or "es"), vim.log.levels.INFO)
end

return M
