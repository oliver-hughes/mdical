--- The editor layer, exercised headlessly:
---
---     nvim --headless --clean -l tests/nvim_smoke.lua
---
--- Separate from `tests/run.lua` because it needs nvim, and `run.lua` must stay
--- runnable under bare luajit. This covers what unit tests can't reach - the
--- span translation into `vim.diagnostic`, the autocmds, and the picker
--- callbacks - by stubbing `vim.ui.select` / `vim.ui.input`.
local root = debug.getinfo(1, "S").source:match("^@(.*)/tests/nvim_smoke%.lua$") or "."
vim.opt.rtp:prepend(root)
vim.cmd("runtime! plugin/mdical.lua")

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

local seq = 0
local function buffer(name, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  seq = seq + 1
  vim.api.nvim_buf_set_name(buf, (name:gsub("%.md$", seq .. ".md")))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
  return buf
end

print("\n== setup ==")
local cfg = require("mdical").setup({})
check(type(cfg) == "table", "setup() returns the config")
check(vim.fn.exists(":Mdical") == 2, ":Mdical is defined")
check(#vim.api.nvim_get_autocmds({ group = "mdical-lint" }) > 0, "lint autocmds attached")

print("\n== lint ==")
local lint = require("mdical.nvim.lint")
local buf = buffer("/tmp/mdical-smoke.md", {
  "# a note",
  "",
  "- [ ] a fine task <2026-09-01 Tue>",
  "- [ ] wrong day name <2026-09-01 Fri>",
  "- [ ] [#A] old habit <2026-09-01 Tue>",
  "- [ ] buy a kettle",
})
lint.buffer(buf, cfg)
local d = vim.diagnostic.get(buf, { namespace = lint.namespace })
check(#d == 2, "two diagnostics", #d)
local by_line = {}
for _, x in ipairs(d) do
  by_line[x.lnum] = x
end
check(by_line[3] and by_line[3].severity == vim.diagnostic.severity.WARN, "wrong day name is a warning")
check(by_line[4] and by_line[4].severity == vim.diagnostic.severity.ERROR, "[#A] is an error")
check(by_line[4] and by_line[4].code == "org-priority", "code carried through", by_line[4] and by_line[4].code)
check(by_line[4] and by_line[4].user_data.fixit.text == "!!!", "fixit carried through")
local line4 = vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]
check(line4:sub(by_line[3].col + 1, by_line[3].end_col) == "<2026-09-01 Fri>", "span maps onto the text",
  line4:sub(by_line[3].col + 1, by_line[3].end_col))

print("\n== lint: bracket style on keywords ==")
local brackets = buffer("/tmp/mdical-brackets.md", {
  "- [ ] a task DEADLINE: [2026-09-01 Tue]",
  "- [x] done <2026-08-01 Sat> CLOSED: <2026-09-01 Tue>",
})
lint.buffer(brackets, cfg)
local bd = vim.diagnostic.get(brackets, { namespace = lint.namespace })
check(#bd == 2, "both bracket-style problems reported", #bd)
check(bd[1].code == "inactive-keyword-timestamp" and bd[1].user_data.fixit.text == "<2026-09-01 Tue>",
  "DEADLINE: [..] offers an active fixit", bd[1].code)
check(bd[2].code == "active-closed" and bd[2].user_data.fixit.text == "[2026-09-01 Tue]",
  "CLOSED: <..> offers an inactive fixit", bd[2].code)

print("\n== lint: disabling a code ==")
lint.buffer(buf, { scope = cfg.scope, lint = { disable = { "org-priority" } } })
local kept = vim.diagnostic.get(buf, { namespace = lint.namespace })
check(#kept == 1 and kept[1].code == "dayname-mismatch", "a disabled code is not shown", #kept)
lint.buffer(buf, cfg)

print("\n== lint respects scope ==")
local meta = buffer("/tmp/mdical-meta.md", {
  "---",
  "tags:",
  "  - meta",
  "---",
  "",
  "- [ ] [#A] a marker in an excluded note <2026-09-01 Fri>",
})
lint.buffer(meta, cfg)
check(#vim.diagnostic.get(meta, { namespace = lint.namespace }) == 0, "excluded notes are not linted")

print("\n== lint fires on autocmd ==")
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
check(#vim.diagnostic.get(buf, { namespace = lint.namespace }) == 2, "BufReadPost lints")

print("\n== insert ==")
local insert = require("mdical.nvim.insert")
local date = require("mdical.date")
local real_select, real_input, real_notify = vim.ui.select, vim.ui.input, vim.notify
local notified
vim.notify = function(msg)
  notified = msg
end

-- pick a labelled entry
local function pick(label)
  vim.ui.select = function(items, _, on_choice)
    for _, item in ipairs(items) do
      if item.label == label then
        return on_choice(item)
      end
    end
    error("no entry labelled " .. label)
  end
end

local function line_after(text, fn)
  local b = buffer("/tmp/mdical-insert.md", { text })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  fn()
  return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
end

pick("today")
local today = date.iso(date.today()) .. " " .. date.dayname(date.today())
check(line_after("- [ ] put the bins out", function()
  insert.insert({})
end) == ("- [ ] put the bins out <%s>"):format(today), "insert appends a date")

check(line_after("put the bins out", function()
  insert.insert({ ensure_task = true })
end) == ("- [ ] put the bins out <%s>"):format(today), "task adds the checkbox")

check(line_after("- [ ] pay rent <2026-08-01 Sat +1m>", function()
  insert.insert({})
end) == ("- [ ] pay rent <%s +1m>"):format(today), "re-dates in place and keeps the cookie")

notified = nil
check(line_after("## a heading", function()
  insert.insert({ ensure_task = true })
end) == ("## a heading <%s>"):format(today), "heading gets a date only")
check(notified and notified:match("heading"), "and it says why", notified)

-- cancelling changes nothing
vim.ui.select = function(_, _, on_choice)
  on_choice(nil)
end
check(line_after("- [ ] untouched", function()
  insert.insert({})
end) == "- [ ] untouched", "cancelling leaves the line alone")

print("\n== insert: free text ==")
pick("date…")
vim.ui.input = function(_, on_confirm)
  on_confirm("2026-12-25 09:30")
end
check(line_after("- [ ] christmas prep", function()
  insert.insert({})
end) == "- [ ] christmas prep <2026-12-25 Fri 09:30>", "free text with a time")

vim.ui.input = function(_, on_confirm)
  on_confirm("not a date")
end
notified = nil
check(line_after("- [ ] bad input", function()
  insert.insert({})
end) == "- [ ] bad input", "bad free text changes nothing")
check(notified ~= nil, "and reports why", notified)

print("\n== fix ==")
check(line_after("- [ ] [#B] both wrong <2026-09-01 Fri>", function()
  insert.fix()
end) == "- [ ] !! both wrong <2026-09-01 Tue>", "fix applies every fixit on the line")

notified = nil
check(line_after("- [ ] nothing wrong <2026-09-01 Tue>", function()
  insert.fix()
end) == "- [ ] nothing wrong <2026-09-01 Tue>", "fix on a clean line is a no-op")
check(notified and notified:match("nothing to fix"), "and says so", notified)

print("\n== :Mdical ==")
pick("today")
check(line_after("- [ ] via the command", function()
  vim.cmd("Mdical insert")
end) == ("- [ ] via the command <%s>"):format(today), ":Mdical insert")
notified = nil
vim.cmd("Mdical nonsense")
check(notified and notified:match("unknown command"), "unknown subcommand is reported", notified)

vim.ui.select, vim.ui.input, vim.notify = real_select, real_input, real_notify
print(("\n%d ok, %d failed\n"):format(pass, fail))
vim.cmd(fail == 0 and "qa!" or "cq!")
