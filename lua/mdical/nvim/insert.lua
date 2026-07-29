--- Writing markers: pick a date and put it on the line, or apply a fixit.
--- Buffer io and notifications only - the edit logic is `mdical.edit`.

local parse = require("mdical.parse")
local fmt = require("mdical.fmt")
local grammar = require("mdical.grammar")
local edit = require("mdical.edit")
local dates = require("mdical.nvim.dates")

local M = {}

--- One `nvim_buf_set_lines` per invocation, so the date and any checkbox land
--- in a single undo step.
local function write(bufnr, lnum, edits)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { edit.apply(line, edits) })
end

local function current()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  return bufnr, lnum, parse.line(line)
end

local function put(bufnr, lnum, p, ts_text, ensure_task)
  local edits, warning = edit.date_edits(p, ts_text, ensure_task)
  if warning then
    vim.notify("mdical: " .. warning, vim.log.levels.WARN)
  end
  write(bufnr, lnum, edits)
end

--- Pick a date and write it onto the current line.
--- @param opts table|nil { ensure_task = boolean }
function M.insert(opts)
  opts = opts or {}
  local bufnr, lnum, p = current()

  local entries = dates.entries()
  entries[#entries + 1] = { label = "date…", custom = true }

  vim.ui.select(entries, {
    prompt = opts.ensure_task and "Task deadline" or "Date",
    format_item = dates.format,
  }, function(choice)
    if not choice then
      return
    end
    if not choice.custom then
      put(bufnr, lnum, p, fmt.new_timestamp(choice.date, edit.target(p)), opts.ensure_task)
      return
    end
    -- Free text goes through the timestamp grammar itself, so a time and
    -- cookies typed by hand work with no extra parsing here.
    vim.ui.input({ prompt = "date [day] [time] [cookies]: " }, function(input)
      if not input or input:match("^%s*$") then
        return
      end
      local typed, err = grammar.parse_body((input:gsub("^%s+", ""):gsub("%s+$", "")), true)
      if not typed then
        vim.notify("mdical: " .. (err and err.msg or "not a date"), vim.log.levels.ERROR)
        return
      end
      put(bufnr, lnum, p, fmt.timestamp(edit.merge(typed, edit.target(p))), opts.ensure_task)
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
  write(bufnr, lnum, edits)
  vim.notify(("mdical: applied %d fix%s"):format(#edits, #edits == 1 and "" or "es"), vim.log.levels.INFO)
end

return M
