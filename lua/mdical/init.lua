--- mdical - org-style calendar and task markers in markdown.
---
--- `require("mdical").setup{}` is the editor entry point. The parser is usable
--- on its own and has no nvim dependency:
---
---     local parse = require("mdical.parse")
---     local p = parse.line("- [ ] pay rent <2026-08-01 Sat +1m>")
---     p.kind    --> "task"
---     p.summary --> "pay rent"
---     p.due     --> a timestamp
---
--- See the grammar reference for what the parser accepts.

local M = {}

M.version = "0.1.0"

--- @param opts table|nil see mdical.nvim's M.config
function M.setup(opts)
  return require("mdical.nvim").setup(opts)
end

return M
