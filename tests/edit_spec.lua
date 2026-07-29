local edit = require("mdical.edit")
local parse = require("mdical.parse")
local date = require("mdical.date")

local D = date.parse_iso("2026-09-01") -- a Tuesday

local function put(line, opts)
  return (edit.with_date(parse.line(line), D, opts))
end

describe("edit.apply", function()
  it("replaces a span", function()
    eq(edit.apply("hello world", { { s = 7, e = 11, text = "there" } }), "hello there", "replace")
  end)

  it("inserts without eating a character", function()
    eq(edit.apply("hello", { { s = 6, e = 5, text = "!" } }), "hello!", "append")
    eq(edit.apply("hello", { { s = 1, e = 0, text = ">" } }), ">hello", "prepend")
  end)

  it("applies several edits without shifting the earlier ones", function()
    local out = edit.apply("- a task", {
      { s = 3, e = 8, text = "a task <2026-09-01 Tue>" },
      { s = 3, e = 2, text = "[ ] " },
    })
    eq(out, "- [ ] a task <2026-09-01 Tue>", "checkbox and date at once")
  end)
end)

describe("edit: inserting a date", function()
  it("appends to a line with no marker", function()
    eq(put("- [ ] put the bins out"), "- [ ] put the bins out <2026-09-01 Tue>", "task line")
    eq(put("team offsite"), "team offsite <2026-09-01 Tue>", "plain line")
  end)

  it("drops trailing whitespace rather than writing into it", function()
    eq(put("- [ ] put the bins out   "), "- [ ] put the bins out <2026-09-01 Tue>", "trailing spaces")
  end)

  it("re-dates in place instead of adding a second timestamp", function()
    eq(put("- [ ] put the bins out <2026-08-01 Sat>"), "- [ ] put the bins out <2026-09-01 Tue>", "bare")
    eq(put("- [ ] put the bins out DEADLINE: <2026-08-01 Sat>"),
      "- [ ] put the bins out DEADLINE: <2026-09-01 Tue>", "explicit keyword kept")
    eq(put("<2026-08-01 Sat> team offsite"), "<2026-09-01 Tue> team offsite", "event, mid-line")
  end)

  it("keeps the repeater and warning when re-dating", function()
    eq(put("- [ ] pay rent <2026-08-01 Sat +1m -3d>"), "- [ ] pay rent <2026-09-01 Tue +1m -3d>", "cookies kept")
    eq(put("<2026-08-05 Wed 15:00-16:00> standup"), "<2026-09-01 Tue 15:00-16:00> standup", "times kept")
  end)

  it("dates an undated task", function()
    eq(put("- [ ] chase the plumber <>"), "- [ ] chase the plumber <2026-09-01 Tue>", "`<>` replaced")
  end)

  it("leaves an inactive timestamp alone", function()
    eq(put("[2026-01-31 Sat] the date the last return was filed"),
      "[2026-01-31 Sat] the date the last return was filed <2026-09-01 Tue>", "not a target")
  end)
end)

describe("edit: ensure_task", function()
  local task = { ensure_task = true }

  it("adds a checkbox to a bullet", function()
    eq(put("- put the bins out", task), "- [ ] put the bins out <2026-09-01 Tue>", "bullet")
    eq(put("* put the bins out", task), "* [ ] put the bins out <2026-09-01 Tue>", "asterisk bullet")
  end)

  it("adds a list marker and a checkbox to a plain line", function()
    eq(put("put the bins out", task), "- [ ] put the bins out <2026-09-01 Tue>", "plain line")
  end)

  it("keeps the indentation of a nested item", function()
    eq(put("    - put the bins out", task), "    - [ ] put the bins out <2026-09-01 Tue>", "indented bullet")
    eq(put("  buy milk", task), "  - [ ] buy milk <2026-09-01 Tue>", "indented plain line")
  end)

  it("leaves an existing checkbox alone", function()
    eq(put("- [x] already done", task), "- [x] already done <2026-09-01 Tue>", "no second checkbox")
  end)

  it("refuses to make a heading a task, and says so", function()
    local out, warning = edit.with_date(parse.line("## a heading"), D, task)
    eq(out, "## a heading <2026-09-01 Tue>", "date only")
    truthy(warning, "warned")
  end)

  it("does not add a checkbox unless asked", function()
    eq(put("- put the bins out"), "- put the bins out <2026-09-01 Tue>", "stays an event")
  end)
end)

describe("edit: hand-typed timestamps", function()
  local grammar = require("mdical.grammar")

  local function typed(line, body)
    local p = parse.line(line)
    local ts = assert(grammar.parse_body(body, true))
    local fmt = require("mdical.fmt")
    return (edit.with_date(p, nil, { timestamp = fmt.timestamp(edit.merge(ts, edit.target(p))) }))
  end

  it("takes a time and cookies as typed", function()
    eq(typed("- [ ] submit expenses", "2026-09-01 17:00"), "- [ ] submit expenses <2026-09-01 Tue 17:00>", "time")
    eq(typed("- [ ] pay rent", "2026-09-01 +1m"), "- [ ] pay rent <2026-09-01 Tue +1m>", "repeater")
  end)

  it("prefers what was typed over what was there", function()
    eq(typed("- [ ] pay rent <2026-08-01 Sat +1m>", "2026-09-01 +2w"), "- [ ] pay rent <2026-09-01 Tue +2w>",
      "typed repeater wins")
  end)

  it("inherits what was not typed", function()
    eq(typed("- [ ] pay rent <2026-08-01 Sat 09:00 +1m>", "2026-09-01"),
      "- [ ] pay rent <2026-09-01 Tue 09:00 +1m>", "time and cookie inherited")
  end)
end)

describe("edit.cursor_col", function()
  -- The cursor lands on the closing `>`, so `i` opens insert mode just inside
  -- it - which is how a time or a repeater gets added by hand afterwards.
  local function lands_on(line, opts)
    local p = parse.line(line)
    local text = (opts and opts.timestamp) or require("mdical.fmt").new_timestamp(D, edit.target(p))
    local edits = edit.date_edits(p, text, opts and opts.ensure_task)
    local out = edit.apply(p.text, edits)
    local col = edit.cursor_col(edits)
    return out:sub(col, col), out, col
  end

  it("lands on the closing bracket when appending", function()
    eq(lands_on("- [ ] buy milk"), ">", "task line")
    eq(lands_on("buy milk"), ">", "plain line")
    eq(lands_on("- [ ] buy milk   "), ">", "trailing whitespace stripped first")
  end)

  it("lands on the closing bracket when re-dating in place", function()
    eq(lands_on("- [ ] pay rent <2026-08-01 Sat +1m>"), ">", "cookies kept, so the text got longer")
    eq(lands_on("<2026-08-01 Sat> team offsite"), ">", "marker mid-line")
    eq(lands_on("- [ ] chase the plumber <>"), ">", "replacing `<>`, which got longer")
  end)

  it("accounts for a checkbox inserted before it", function()
    eq(lands_on("buy milk", { ensure_task = true }), ">", "list marker and checkbox added")
    eq(lands_on("- buy milk", { ensure_task = true }), ">", "checkbox added")
    eq(lands_on("    - buy milk", { ensure_task = true }), ">", "indented")
  end)

  it("points at the last character of the line when the marker is at the end", function()
    local _, out, col = lands_on("- [ ] buy milk")
    eq(col, #out, "so `i` is inside the brackets and `a` is after them")
  end)
end)

describe("edit.fixits", function()
  it("corrects org's priority cookie", function()
    local p = parse.line("- [ ] [#A] old habit <2026-09-01 Tue>")
    eq(edit.apply(p.text, edit.fixits(p)), "- [ ] !!! old habit <2026-09-01 Tue>", "fixed")
  end)

  it("corrects a wrong day name", function()
    local p = parse.line("- [ ] wrong day name <2026-09-01 Fri>")
    eq(edit.apply(p.text, edit.fixits(p)), "- [ ] wrong day name <2026-09-01 Tue>", "fixed")
  end)

  it("fixes several things on one line at once", function()
    local p = parse.line("- [ ] [#B] both wrong <2026-09-01 Fri>")
    eq(edit.apply(p.text, edit.fixits(p)), "- [ ] !! both wrong <2026-09-01 Tue>", "both fixed")
  end)

  it("offers nothing when there is nothing to fix", function()
    eq(#edit.fixits(parse.line("- [ ] fine <2026-09-01 Tue>")), 0, "no fixits")
  end)
end)
