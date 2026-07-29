--- Publishes the parser's diagnostics through `vim.diagnostic`.
---
--- There is no lint logic here on purpose. The verdicts come from
--- `mdical.parse`, which is the same code the nightly build uses to decide what
--- it refuses to emit, so the editor and the build can't drift apart. All this
--- module does is translate spans and severities.
---
--- The failure mode of an inline format spread over 500 notes is a marker that
--- silently never fires, which is what this exists to catch.

local parse = require("mdical.parse")
local scope = require("mdical.scope")

local M = {}

local ns = vim.api.nvim_create_namespace("mdical")
local pending = {}

local function severities()
  return {
    [parse.ERROR] = vim.diagnostic.severity.ERROR,
    [parse.WARN] = vim.diagnostic.severity.WARN,
    [parse.INFO] = vim.diagnostic.severity.INFO,
  }
end

--- Lint one buffer now.
--- @param bufnr integer|nil
--- @param cfg table|nil the plugin config
function M.buffer(bufnr, cfg)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not scope.included(scope.tags(lines), cfg and cfg.scope) then
    vim.diagnostic.reset(ns, bufnr)
    return
  end

  local sev = severities()
  local out = {}
  for lnum, p in ipairs(parse.document(lines)) do
    if p then
      for _, d in ipairs(p.diagnostics) do
        out[#out + 1] = {
          lnum = lnum - 1,
          col = d.col - 1,
          end_lnum = lnum - 1,
          end_col = d.end_col, -- 1-based inclusive -> 0-based exclusive
          severity = sev[d.severity],
          message = d.msg,
          code = d.code,
          source = "mdical",
          user_data = { fixit = d.fixit },
        }
      end
    end
  end
  vim.diagnostic.set(ns, bufnr, out)
end

local function debounced(bufnr, cfg)
  pending[bufnr] = (pending[bufnr] or 0) + 1
  local token = pending[bufnr]
  vim.defer_fn(function()
    if pending[bufnr] == token and vim.api.nvim_buf_is_valid(bufnr) then
      M.buffer(bufnr, cfg)
    end
  end, (cfg.lint and cfg.lint.debounce) or 200)
end

function M.attach(cfg)
  local group = vim.api.nvim_create_augroup("mdical-lint", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(args)
      M.buffer(args.buf, cfg)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    pattern = "*.md",
    callback = function(args)
      debounced(args.buf, cfg)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.md",
    callback = function(args)
      pending[args.buf] = nil
    end,
  })

  -- `setup()` usually runs *because* a markdown buffer was just opened, so the
  -- autocmds above have already missed it.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
      M.buffer(buf, cfg)
    end
  end
end

function M.detach()
  pcall(vim.api.nvim_del_augroup_by_name, "mdical-lint")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.diagnostic.reset(ns, buf)
    end
  end
end

M.namespace = ns

return M
