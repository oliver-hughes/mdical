--- The repeater/warning stage. Pure.
---
--- Doubles as the syntax reference: every one of org's three repeater flavours
--- is here with what it actually means, because `+1m` versus `++1m` versus
--- `.+1m` is exactly the distinction nobody remembers. Whatever is chosen is
--- validated through the grammar before it reaches the note, so the presets and
--- the free-text field share one code path.

local M = {}

M.presets = {
  { label = "none", cookies = nil, hint = "one-off" },

  { label = "+1d", cookies = "+1d", hint = "every day, counted from the date on the line" },
  { label = "+1w", cookies = "+1w", hint = "every week" },
  { label = "+1m", cookies = "+1m", hint = "every month - clamps, so the 31st becomes the 28th in february" },
  { label = "+1y", cookies = "+1y", hint = "every year" },

  { label = "++1w", cookies = "++1w", hint = "every week, catching up to today if you fall behind" },
  { label = "++1m", cookies = "++1m", hint = "every month, catching up" },
  { label = "++1y", cookies = "++1y", hint = "every year, catching up - birthdays" },

  { label = ".+3d", cookies = ".+3d", hint = "3 days after you tick it, not after the date" },
  { label = ".+1w", cookies = ".+1w", hint = "a week after you tick it" },
  { label = ".+1m", cookies = ".+1m", hint = "a month after you tick it" },

  { label = "-1w", cookies = "-1w", hint = "warn a week early - an alarm on an event, editor-only on a task" },
  { label = "-21d", cookies = "-21d", hint = "warn three weeks early" },

  { label = "+1m -1w", cookies = "+1m -1w", hint = "monthly, warned a week early" },
  { label = "+1y -21d", cookies = "+1y -21d", hint = "yearly, warned three weeks early" },

  { label = "cookies…", custom = true, hint = "[+|++|.+]N[dwmy] and/or -N[dwmy]" },
}

function M.format(entry)
  return ("%-10s %s"):format(entry.label, entry.hint or "")
end

--- Is `text` a cookie or two, and nothing else? Validated by parsing it as part
--- of a throwaway timestamp, so the presets and hand-typed text are checked by
--- exactly the code that will later have to read them back out of a note.
--- @return string|nil cookies, string|nil err
function M.valid(text)
  local grammar = require("mdical.grammar")
  local ts, err = grammar.parse_body("2026-01-01 " .. tostring(text or ""), true)
  if not ts then
    return nil, err and err.msg or "not a repeater"
  end
  if not (ts.repeater or ts.warn) or ts.time or ts.dayname then
    return nil, ("`%s` is not a repeater or a warning"):format(text)
  end
  return text
end

return M
