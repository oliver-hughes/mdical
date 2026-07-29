# mdical

Org-style calendar and task markers in markdown, for Neovim.

```markdown
- [ ] pay rent <2026-08-01 Sat +1m>
- [ ] !!! submit tax return <2027-01-31 Sun -21d>
- [ ] chase the plumber about the boiler <>
<2026-08-05 Wed 15:00-16:00> standup
<2026-08-10 Mon>--<2026-08-12 Wed> conference in manchester
```

Markers are org-mode's timestamp syntax, inline on the line, with `- [ ]`/`- [x]`
standing in for `TODO`/`DONE`. Angle brackets are live and square brackets are
not, so a date can be written into a note without becoming an entry.

**Status: early.** The parser, the linter and the inserter work. The nightly
build that turns these markers into a CalDAV calendar and reads completions back
is the other consumer of the same parser, and is not here yet.

## Install

lazy.nvim:

```lua
{
  "oliver-hughes/mdical",
  ft = "markdown",
  opts = {},
  keys = {
    { "<leader>cd", "<Cmd>Mdical insert<CR>",     desc = "date on this line" },
    { "<leader>ct", "<Cmd>Mdical task<CR>",       desc = "task with a deadline" },
    { "<leader>cD", "<Cmd>Mdical build<CR>",      desc = "date, time and repeat" },
    { "<leader>cT", "<Cmd>Mdical build-task<CR>", desc = "task, timed and repeating" },
    { "<leader>cf", "<Cmd>Mdical fix<CR>",        desc = "fix this line" },
  },
}
```

## Commands

| | |
|--|--|
| `:Mdical insert` | pick a date, put it on the current line. Respects the line as it stands: a bullet becomes an event, a `- [ ]` gets a deadline |
| `:Mdical task` | the same, and adds `- [ ] ` if the line isn't a task yet |
| `:Mdical build` | the long way round: date, then time, then repeater |
| `:Mdical build-task` | the same, and adds `- [ ] ` |
| `:Mdical fix` | apply the fixits the current line's diagnostics offer |
| `:Mdical lint` | re-lint the buffer now |

After any of them the cursor sits **on the closing `>`**, so `i` opens insert
mode inside the brackets to add anything by hand.

`insert` and `task` **re-date a marker in place** when the line already carries
one, inheriting its time and cookies - so `<leader>cd` on
`- [ ] pay rent <2026-08-01 Sat +1m>` changes the date and keeps the `+1m`,
rather than appending a second timestamp and creating an error. `build` is the
opposite: it replaces the timestamp outright, so choosing *none* at the time or
repeat stage means none.

Every prompt is a `vim.ui.select`, so the keys and the look are your own
picker's - fuzzy filtering included, which is the quick way to reach `end of
month`. Confirm keys come from there too; if you want `<C-y>` as well as `<CR>`,
that belongs in your picker's config rather than here.

### The date stage

Sixteen entries: today, tomorrow, the next six days by name, 1w/2w/3w, 1m/2m/3m,
end of month, 1y - each showing the date and day name it resolves to - then
`date…` for free text. Free text goes through the timestamp grammar itself, so
`2026-08-01 14:00 +1m` typed by hand works.

### The time stage

`none`, five presets (7am, 9am, midday, 5pm, 9pm), then `time…`, which is
forgiving: `9`, `930`, `9.30`, `9am`, `midday`, `1745` and `9am-5pm` all become
something the grammar accepts. Anything that doesn't is refused before it can be
written into a note.

### The repeat stage

All three of org's repeater flavours with what they actually mean, warnings on
their own and alongside a repeater, and `cookies…` for the rest. It doubles as
the syntax reminder for the `+1m` / `++1m` / `.+1m` distinction:

```
+1m        every month - clamps, so the 31st becomes the 28th in february
++1m       every month, catching up
.+1m       a month after you tick it
-21d       warn three weeks early
+1y -21d   yearly, warned three weeks early
```

## Config

```lua
require("mdical").setup {
  -- which notes the linter reads. Same keys, same meaning, as the build's.
  scope = {
    include_tags = {},          -- empty = every note
    exclude_tags = { "meta" },  -- evaluated first, always wins
  },
  lint = {
    enabled = true,
    debounce = 200,             -- ms after a change before re-linting
    disable = {},               -- codes to stop showing, e.g. { "done-without-closed" }
  },
}
```

`lint.disable` is editor-only and has no equivalent in the build, so hiding a
code changes what you are shown and never what gets published.

Scope decides which *notes* are read; promotion decides which *lines* within
them are markers. No scope setting can make a bare `- [ ]` into a task - that is
what keeps a vault with 1,800 incidental checkboxes in it quiet.

## Grammar

Timestamps are org's, unchanged:

```
<2026-08-14 Fri 09:00-17:30 +1y -21d>
 |          |   |           |    |
 |          |   |           |    warning period
 |          |   |           repeater
 |          |   time, or a range
 |          day name - optional, and linted against the date
 date
```

| | |
|--|--|
| `<...>` / `[...]` | active - exports / inactive - deliberately doesn't |
| `<>` | an active timestamp with no date: an undated task. Only means anything after a checkbox |
| `- [ ]` + `<date>` | a task due then. `DEADLINE:` is allowed and means the same |
| any other line + `<date>` | an event |
| `- [ ]` with no active brackets | nothing, ever |
| `!` `!!` `!!!` | priority, written where org writes `[#C]`/`[#B]`/`[#A]` - and what iOS Reminders displays |
| `+1m` `++1m` `.+1m` | repeat once / repeat until future / repeat from the completion date |
| `-21d` | warning period. An alarm on an event; editor-only on a task |
| `SCHEDULED:` `CLOSED:` | org's, unchanged. `SCHEDULED:` alone never promotes a line |
| `EXCEPT: [date]` | skip an occurrence |
| `RRULE: FREQ=MONTHLY;BYDAY=3WE` | escape hatch for recurrence a cookie can't express |

Month arithmetic **clamps** rather than overflowing: `<2026-01-31 Sat +1m>` is
due 28 February, where org would say 3 March. `<2024-02-29 Thu ++1y>` returns to
29 February in the next leap year rather than being stuck on the 28th.

## Layout

The core is pure lua 5.1 and **must not touch the nvim api** - the nightly build
requires it under bare luajit on a server with no editor in the picture. CI
enforces that with a grep.

```
lua/mdical/          pure: grammar, parse, date, fmt, edit, scope
lua/mdical/nvim/     editor: the command, the inserter, the picker, the linter
plugin/mdical.lua    :Mdical
tests/               luajit tests/run.lua
```

Diagnostics come out of the parser rather than a separate linter, so the editor
and the build reach the same verdict from the same code. A line with an
error-severity diagnostic sets `emit = false`, which is the build's rule for
refusing to publish it.

## Tests

```sh
luajit tests/run.lua                              # the core
nvim --headless --clean -l tests/nvim_smoke.lua    # the editor layer
```

No plenary and no neovim for the first one: the same suite runs on a laptop, in CI, and on the box
that does the nightly build. `tests/corpus.lua` is the grammar reference's worked
examples transcribed as data, and expectations there are strict - a case with no
`codes` field asserts *no* diagnostics, so newly spurious lint fails the suite
rather than being absorbed.
