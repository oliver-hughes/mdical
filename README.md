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
    { "<leader>cd", "<Cmd>Mdical insert<CR>", desc = "date on this line" },
    { "<leader>ct", "<Cmd>Mdical task<CR>",   desc = "task with a deadline" },
    { "<leader>cf", "<Cmd>Mdical fix<CR>",    desc = "fix this line" },
  },
}
```

## Commands

| | |
|--|--|
| `:Mdical insert` | pick a date, put it on the current line. Respects the line as it stands: a bullet becomes an event, a `- [ ]` gets a deadline |
| `:Mdical task` | the same, and adds `- [ ] ` if the line isn't a task yet |
| `:Mdical fix` | apply the fixits the current line's diagnostics offer |
| `:Mdical lint` | re-lint the buffer now |

`insert` and `task` **re-date a marker in place** when the line already carries
one, inheriting its time and cookies - so `<leader>cd` on
`- [ ] pay rent <2026-08-01 Sat +1m>` changes the date and keeps the `+1m`,
rather than appending a second timestamp and creating an error.

The picker offers twelve relative dates plus free text. Free text goes through
the timestamp grammar itself, so `2026-08-01 14:00 +1m` typed by hand works.

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
  },
}
```

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
