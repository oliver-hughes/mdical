--- The editor layer: config, `:Mdical`, and wiring the linter up.
---
--- Everything under `mdical.nvim` may use the nvim api. Everything above it -
--- `mdical.parse`, `mdical.date`, `mdical.fmt`, `mdical.grammar`,
--- `mdical.scope` - may not, because the nightly build requires those modules
--- under bare luajit with no nvim anywhere.

local M = {}

M.config = {
  --- Which notes the linter reads. Same keys, same meaning, as the build's.
  scope = {
    include_tags = {}, -- empty = every note
    exclude_tags = { "meta" }, -- always wins
  },
  lint = {
    enabled = true,
    debounce = 200, -- ms after a change before re-linting
    --- Codes to stop showing, e.g. { "done-without-closed" }. Editor-only:
    --- the build has no equivalent, so this can never silence a line's refusal
    --- to publish.
    disable = {},
  },
}

local function deep_extend(base, opts)
  return vim.tbl_deep_extend("force", base, opts or {})
end

local ACTIONS = {
  insert = function()
    require("mdical.nvim.insert").insert({})
  end,
  task = function()
    require("mdical.nvim.insert").insert({ ensure_task = true })
  end,
  fix = function()
    require("mdical.nvim.insert").fix()
  end,
  lint = function()
    require("mdical.nvim.lint").buffer(0, M.config)
  end,
}

M.subcommands = { "insert", "task", "fix", "lint" }

function M.command(args)
  local name = args.fargs[1] or "insert"
  local action = ACTIONS[name]
  if not action then
    vim.notify(("mdical: unknown command `%s` (try %s)"):format(name, table.concat(M.subcommands, ", ")),
      vim.log.levels.ERROR)
    return
  end
  action()
end

function M.setup(opts)
  M.config = deep_extend(M.config, opts)
  if M.config.lint.enabled then
    require("mdical.nvim.lint").attach(M.config)
  end
  return M.config
end

return M
