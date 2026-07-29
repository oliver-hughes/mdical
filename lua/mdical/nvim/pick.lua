--- One prompt, one list, and what you typed if it matched nothing.
---
--- `vim.ui.select` cannot do the last part: it hands back the chosen item and
--- throws the prompt text away, so typing `08:00` into a list of preset times
--- and pressing enter is indistinguishable from cancelling. Every stage here
--- wants the opposite - the presets are a convenience and typing is the real
--- input - so where telescope is available this drives it directly and reads the
--- prompt line back.
---
--- Fuzzy matching is deliberately restricted to each entry's **label**, not its
--- rendered line. That is what makes "did anything match?" predictable: `08:00`
--- and `2026-12-25` cannot accidentally match `9am` or `today` through their
--- resolved values, so they reliably fall through to the typed-text path.
---
--- Without telescope it falls back to `vim.ui.select` plus an explicit free-text
--- entry, which is the same behaviour with one more keystroke.

local M = {}

--- @return boolean
function M.has_telescope()
  return (pcall(require, "telescope.pickers"))
end

--- Ask, once.
---
--- `on_choice(entry, typed)`:
---   * an entry was highlighted     -> entry, the prompt text
---   * confirmed with nothing shown -> nil, the prompt text
---   * cancelled                    -> nil, nil
---
--- An entry marked `custom = true` is the "let me type it" affordance. Choosing
--- it is resolved here rather than by the caller: with something in the prompt
--- that text is the answer, and with an empty prompt it opens an input. So
--- `on_choice` never sees a custom entry - only a real one, or typed text.
---
--- @param opts table {
---   prompt      = "Time",
---   entries     = table[],           each needs a `label`
---   format      = fun(entry):string, how it is displayed
---   free_prompt = "time: ",          input prompt for a custom entry
---   on_choice   = fun(entry, typed) }
function M.select(opts)
  if M.has_telescope() then
    return M.telescope(opts)
  end
  return M.ui_select(opts)
end

--- Hand an answer to the caller, resolving a custom entry into typed text.
local function deliver(opts, entry, typed)
  if entry and entry.custom then
    if typed and typed ~= "" then
      return opts.on_choice(nil, typed)
    end
    return vim.ui.input({ prompt = opts.free_prompt or (opts.prompt:lower() .. ": ") }, function(input)
      if input == nil then
        return opts.on_choice(nil, nil)
      end
      opts.on_choice(nil, input)
    end)
  end
  opts.on_choice(entry, typed)
end

function M.telescope(opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local themes = require("telescope.themes")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values

  local answered, confirming = false, false
  local function finish(entry, typed)
    if answered then
      return
    end
    answered = true
    -- after the picker has gone, so edits and the cursor land in the real window
    vim.schedule(function()
      deliver(opts, entry, typed)
    end)
  end

  pickers
    .new(themes.get_dropdown({ layout_config = { width = 62, height = math.min(#opts.entries + 5, 22) } }), {
      prompt_title = opts.prompt,
      finder = finders.new_table({
        results = opts.entries,
        entry_maker = function(e)
          return {
            value = e,
            display = opts.format(e),
            -- the label alone: see the note at the top of this file
            ordinal = e.label,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          local typed = action_state.get_current_line() or ""
          local entry = selection and selection.value or nil
          -- closing runs the hook below, which must not read this as a cancel
          confirming = true
          actions.close(prompt_bufnr)
          finish(entry, typed)
        end)
        actions.close:enhance({
          post = function()
            if not confirming then
              finish(nil, nil) -- <Esc> or <C-c>
            end
          end,
        })
        return true
      end,
    })
    :find()
end

--- No telescope: the presets as a list. There is no prompt text to read back, so
--- the custom entry is the only way to type an answer - the same behaviour, one
--- more keystroke.
function M.ui_select(opts)
  vim.ui.select(opts.entries, {
    prompt = opts.prompt,
    format_item = opts.format,
  }, function(choice)
    if not choice then
      return opts.on_choice(nil, nil)
    end
    deliver(opts, choice, "")
  end)
end

return M
