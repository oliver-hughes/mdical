--- The time stage: five presets and a forgiving free-text field. Pure, so the
--- normaliser is unit tested rather than discovered by typing at it.
---
--- The grammar only accepts `HH:MM`, so this exists to stop that being a chore:
--- `9`, `9am`, `930`, `9.30`, `midday` and `9am-5pm` all become something the
--- grammar accepts, and anything that doesn't normalise is rejected before it
--- can be written into a note.

local M = {}

M.presets = {
  { label = "none", none = true },
  { label = "7am", value = "07:00" },
  { label = "9am", value = "09:00" },
  { label = "midday", value = "12:00" },
  { label = "5pm", value = "17:00" },
  { label = "9pm", value = "21:00" },
  { label = "time…", custom = true, hint = "9, 930, 9.30, 9am, midday, 9am-5pm" },
}

function M.format(entry)
  return (("%-9s %s"):format(entry.label, entry.value or entry.hint or ""):gsub("%s+$", ""))
end

local WORDS = { midday = "12:00", noon = "12:00", midnight = "00:00" }

--- One side of a range.
local function one(tok)
  tok = tok:lower():gsub("%s", "")
  if tok == "" then
    return nil
  end
  if WORDS[tok] then
    return WORDS[tok]
  end

  local meridiem
  local body = tok:match("^(.-)am$")
  if body then
    meridiem = "am"
  else
    body = tok:match("^(.-)pm$")
    if body then
      meridiem = "pm"
    end
  end
  tok = body or tok

  local h, m = tok:match("^(%d%d?)[:%.](%d%d)$")
  if not h then
    h, m = tok:match("^(%d%d)(%d%d)$")
  end
  if not h then
    h, m = tok:match("^(%d)(%d%d)$")
  end
  if not h then
    h, m = tok:match("^(%d%d?)$"), "00"
  end
  if not h then
    return nil
  end

  h, m = tonumber(h), tonumber(m)
  if meridiem == "pm" and h < 12 then
    h = h + 12
  elseif meridiem == "am" and h == 12 then
    h = 0
  end
  if h > 23 or m > 59 then
    return nil
  end
  return ("%02d:%02d"):format(h, m)
end

--- Free text -> `HH:MM` or `HH:MM-HH:MM`, or nil if it isn't a time.
function M.normalise(input)
  input = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then
    return nil
  end
  local from, to = input:match("^(.-)%s*%-%s*(.+)$")
  if from then
    local a, b = one(from), one(to)
    if not a or not b then
      return nil
    end
    return a .. "-" .. b
  end
  return one(input)
end

return M
