--- Reading the vault. Lua 5.1, no `vim` - this runs under bare luajit on the
--- server as well as inside the editor.
---
--- Uses `find` rather than a directory-listing library, because the alternative
--- is a C dependency in the container for something a subprocess does fine. The
--- result is sorted, which matters: a build whose output order depends on
--- filesystem order is a build whose git diffs are noise.

local parse = require("mdical.parse")
local scope = require("mdical.scope")

local M = {}

--- Every markdown file under `root`, sorted, `.git` excluded.
--- @return string[] paths
function M.notes(root)
  local cmd = ("find %s -type f -name '*.md' -not -path '*/.git/*' 2>/dev/null | sort"):format(("%q"):format(root))
  local pipe = assert(io.popen(cmd, "r"), "could not list " .. root)
  local out = {}
  for line in pipe:lines() do
    out[#out + 1] = line
  end
  pipe:close()
  return out
end

--- @return string[]|nil lines
function M.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    out[#out + 1] = line
  end
  -- the trailing newline produces one empty line too many
  if out[#out] == "" then
    out[#out] = nil
  end
  return out
end

--- Parse the whole vault.
---
--- @param root string
--- @param cfg table|nil { scope = { include_tags, exclude_tags } }
--- @return table {
---   markers = { { parsed, path, lnum }, ... }  emitting lines only
---   diagnostics = { { severity, code, msg, path, lnum }, ... }
---   notes_scanned, notes_skipped, lines, checkboxes }
function M.vault(root, cfg)
  cfg = cfg or {}
  local out = {
    markers = {},
    diagnostics = {},
    notes_scanned = 0,
    notes_skipped = 0,
    lines = 0,
    checkboxes = 0,
  }

  for _, path in ipairs(M.notes(root)) do
    local lines = M.read(path)
    if lines then
      local rel = path:sub(#root + 2)
      if not scope.included(scope.tags(lines), cfg.scope) then
        out.notes_skipped = out.notes_skipped + 1
      else
        out.notes_scanned = out.notes_scanned + 1
        for lnum, p in ipairs(parse.document(lines)) do
          if p then
            out.lines = out.lines + 1
            if p.text:match("^%s*[-*+]%s+%[[ xX]%]") then
              out.checkboxes = out.checkboxes + 1
            end
            if p.emit then
              out.markers[#out.markers + 1] = { parsed = p, path = rel, lnum = lnum }
            end
            for _, d in ipairs(p.diagnostics) do
              out.diagnostics[#out.diagnostics + 1] = {
                severity = d.severity,
                code = d.code,
                msg = d.msg,
                path = rel,
                lnum = lnum,
              }
            end
          end
        end
      end
    end
  end

  return out
end

return M
