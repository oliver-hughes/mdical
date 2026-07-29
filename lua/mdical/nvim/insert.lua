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

--- @param on_date fun(d: table)  not called if cancelled
local function ask_date(prompt, on_date)
  local entries = dates.entries()
  entries[#entries + 1] = { label = "date…", custom = true }
  vim.ui.select(entries, { prompt = prompt, format_item = dates.format, kind = "mdical.date" }, function(choice)
    if not choice then
      return
    end
    if not choice.custom then
      return on_date(choice.date, nil)
    end
    vim.ui.input({ prompt = "date [day] [time] [cookies]: " }, function(input)
      if not input or input:match("^%s*$") then
        return
      end
      local ts, err = grammar.parse_body((input:gsub("^%s+", ""):gsub("%s+$", "")), true)
      if not ts or not ts.date then
        vim.notify("mdical: " .. (err and err.msg or "not a date"), vim.log.levels.ERROR)
        return
      end
      -- free text may carry the whole thing, so hand the timestamp back too
      on_date(ts.date, ts)
    end)
  end)
end

local function ask_time(on_time)
  vim.ui.select(times.presets, { prompt = "Time", format_item = times.format, kind = "mdical.time" },
    function(choice)
      if not choice then
        return
      end
      if choice.none then
        return on_time(nil)
      end
      if choice.value then
        return on_time(choice.value)
      end
      vim.ui.input({ prompt = "time (9, 9am, 930, midday, 9am-5pm): " }, function(input)
        if not input or input:match("^%s*$") then
          return on_time(nil)
        end
        local normalised = times.normalise(input)
        if not normalised then
          vim.notify(("mdical: `%s` is not a time"):format(input), vim.log.levels.ERROR)
          return
        end
        on_time(normalised)
      end)
    end)
end

local function ask_cookies(on_cookies)
  vim.ui.select(cookies.presets, { prompt = "Repeat / warn", format_item = cookies.format, kind = "mdical.cookies" },
    function(choice)
      if not choice then
        return
      end
      if not choice.custom then
        return on_cookies(choice.cookies)
      end
      vim.ui.input({ prompt = "cookies ([+|++|.+]N[dwmy] and/or -N[dwmy]): " }, function(input)
        if not input or input:match("^%s*$") then
          return on_cookies(nil)
        end
        on_cookies((input:gsub("^%s+", ""):gsub("%s+$", "")))
      end)
    end)
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
