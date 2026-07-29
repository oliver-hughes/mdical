--- The telescope path, driven for real.
---
---     nvim --headless -c 'luafile tests/telescope_drive.lua'
---
--- Needs telescope on the runtimepath, so it is not part of CI and skips itself
--- when telescope is absent. Run it under a config that has telescope, e.g.
---
---     NVIM_APPNAME=nvim-24 nvim --headless -c 'sleep 800m' -c 'luafile tests/telescope_drive.lua'
---
--- Worth keeping despite the setup cost: `tests/nvim_smoke.lua` can only exercise
--- the `vim.ui.select` fallback, and every interesting question here - does the
--- prompt text come back, does a fuzzy match override it, does <C-y> confirm - is
--- only answerable against the real picker.

if not pcall(require, "telescope.pickers") then
  print("skipped: no telescope on the runtimepath")
  vim.cmd("qa!")
  return
end

vim.opt.swapfile = false -- scratch buffers below, and a swap prompt hangs headless nvim

local root = debug.getinfo(1, "S").source:match("^@(.*)/tests/telescope_drive%.lua$") or "."
vim.opt.rtp:prepend(root)
vim.cmd("runtime! plugin/mdical.lua")

local insert = require("mdical.nvim.insert")
local date = require("mdical.date")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local pass, fail = 0, 0
local function check(ok, what, extra)
  if ok then
    pass = pass + 1
    print("  ok    " .. what)
  else
    fail = fail + 1
    print("  FAIL  " .. what .. (extra and ("  -> " .. tostring(extra)) or ""))
  end
end

local seen = {}
local function fresh_prompt()
  local found
  vim.wait(4000, function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "prompt" and not seen[b] then
        found = b
        return true
      end
    end
    return false
  end, 20)
  if found then
    seen[found] = true
  end
  return found
end

--- Put `text` in the prompt, then confirm. Returns whatever the sorter had
--- highlighted at the moment of confirming.
local function stage(text)
  local pb = fresh_prompt()
  if not pb then
    check(false, "a telescope prompt appeared")
    return nil
  end
  if text ~= "" then
    action_state.get_current_picker(pb):set_prompt(text)
    vim.wait(400) -- let the sorter settle
  end
  local highlighted = action_state.get_selected_entry()
  actions.select_default(pb)
  vim.wait(300)
  return highlighted and highlighted.ordinal or nil
end

local seq = 0
local function on_line(text, run)
  seq = seq + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "/tmp/mdical-tsdrive" .. seq .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run()
  vim.wait(300)
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
end

local today = date.iso(date.today()) .. " " .. date.dayname(date.today())

print("\n== typed text beats the highlighted entry ==")
local matched = {}
local got = on_line("- [ ] pay rent", function()
  insert.build({})
  matched.date = stage("2026-12-25")
  matched.time = stage("08:00")
  matched.cookie = stage("+2d")
end)
check(matched.date == nil, "a typed date matches no preset", matched.date)
check(matched.time == nil, "a typed time matches no preset", matched.time)
-- fzf matches `+2d` inside `+1y -21d` on a subsequence, which is exactly why
-- "did anything match" cannot decide the answer
check(matched.cookie ~= nil, "a typed cookie CAN fuzzy-match a preset", matched.cookie)
check(got == "- [ ] pay rent <2026-12-25 Fri 08:00 +2d>", "...and what was typed is still used", got)

print("\n== presets still win when what you typed is not an answer ==")
got = on_line("- [ ] presets", function()
  insert.build({})
  stage("today")
  stage("9am")
  stage("+1m")
end)
check(got == ("- [ ] presets <%s 09:00 +1m>"):format(today), "filtering to a preset selects it", got)

got = on_line("- [ ] filtered", function()
  insert.build({})
  stage("eom")
  stage("")
  stage("")
end)
local eom = date.days_in_month(date.today().year, date.today().month)
check(got:find(("-%02d "):format(eom), 1, true) ~= nil, "fuzzy `eom` reaches end of month", got)

print("\n== the simple flow ==")
got = on_line("- [ ] simple flow", function()
  insert.insert({})
  stage("2026-12-25 09:30")
end)
check(got == "- [ ] simple flow <2026-12-25 Fri 09:30>", "a whole marker typed at the date stage", got)

got = on_line("- [ ] cursor", function()
  insert.insert({})
  stage("")
end)
local pos = vim.api.nvim_win_get_cursor(0)
check(got:sub(pos[2] + 1, pos[2] + 1) == ">", "the cursor lands on the closing bracket", got)

print("\n== escaping ==")
got = on_line("- [ ] escaped", function()
  insert.build({})
  local pb = fresh_prompt()
  if pb then
    vim.wait(100)
    actions.close(pb)
    vim.wait(300)
  end
end)
check(got == "- [ ] escaped", "closing the picker writes nothing", got)

print(("\n%d ok, %d failed\n"):format(pass, fail))
io.stdout:flush()
vim.cmd(fail == 0 and "qa!" or "cq!")
