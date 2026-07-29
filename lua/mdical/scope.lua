--- Which notes are in scope. Pure lua 5.1, no `vim`.
---
--- Orthogonal to promotion: scope decides which *notes* are read, promotion
--- decides which *lines* within them export. No scope setting can make a bare
--- `- [ ]` export.
---
--- Exclusion is evaluated first and wins outright, so a note carrying both an
--- included and an excluded tag is skipped.

local M = {}

M.defaults = {
  include_tags = {}, -- empty = every note
  exclude_tags = { "meta" }, -- always wins
}

--- Line numbers of the frontmatter delimiters, or 0, 0 if there is none.
--- @return integer first, integer last
function M.bounds(lines)
  if not lines[1] or not lines[1]:match("^%-%-%-%s*$") then
    return 0, 0
  end
  for n = 2, #lines do
    if lines[n]:match("^%-%-%-%s*$") or lines[n]:match("^%.%.%.%s*$") then
      return 1, n
    end
  end
  return 0, 0 -- unterminated: treat the note as having no frontmatter
end

--- Frontmatter tags. Handles the YAML list form
---
---     tags:
---       - calendar
---       - meta
---
--- the inline form `tags: [a, b]`, and the bare form `tags: single`.
--- @return string[]
function M.tags(lines)
  local first, last = M.bounds(lines)
  if first == 0 then
    return {}
  end
  local out = {}
  local n = first + 1
  while n < last do
    local rest = lines[n]:match("^tags:%s*(.-)%s*$")
    if rest then
      if rest ~= "" then
        -- inline: [a, b] or a bare scalar
        local inner = rest:match("^%[(.*)%]$") or rest
        for item in inner:gmatch("[^,%s]+") do
          out[#out + 1] = item:gsub("^['\"]", ""):gsub("['\"]$", "")
        end
      else
        -- block list: subsequent `  - tag` lines
        n = n + 1
        while n < last do
          local item = lines[n]:match("^%s*%-%s*(.-)%s*$")
          if not item then
            break
          end
          out[#out + 1] = item:gsub("^['\"]", ""):gsub("['\"]$", "")
          n = n + 1
        end
      end
      return out
    end
    n = n + 1
  end
  return out
end

local function any_of(tags, list)
  local set = {}
  for _, t in ipairs(tags) do
    set[t] = true
  end
  for _, t in ipairs(list or {}) do
    if set[t] then
      return true
    end
  end
  return false
end

--- @param tags string[] the note's frontmatter tags
--- @param cfg table|nil { include_tags, exclude_tags }
function M.included(tags, cfg)
  cfg = cfg or M.defaults
  local exclude = cfg.exclude_tags or M.defaults.exclude_tags
  local include = cfg.include_tags or M.defaults.include_tags
  if any_of(tags, exclude) then
    return false
  end
  if not include or #include == 0 then
    return true
  end
  return any_of(tags, include)
end

return M
