-- `:Mdical` lives here rather than in setup() so the plugin is usable without
-- one. Keymaps deliberately stay in the user's config.

if vim.g.loaded_mdical then
  return
end
vim.g.loaded_mdical = true

vim.api.nvim_create_user_command("Mdical", function(args)
  require("mdical.nvim").command(args)
end, {
  nargs = "?",
  desc = "mdical: insert a marker, fix a line, re-lint",
  complete = function(lead)
    local out = {}
    for _, name in ipairs(require("mdical.nvim").subcommands) do
      if name:find(lead, 1, true) == 1 then
        out[#out + 1] = name
      end
    end
    return out
  end,
})
