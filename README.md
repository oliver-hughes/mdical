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

**Status: early, but end to end.** The parser, the linter, the inserter, the
calendar build, the completion ratchet and the container that runs them are all
written and tested. What has not happened yet is any of it running against a real
radicale and a real phone, so everything downstream of the vdir is grounded in
recorded wire evidence rather than in a working system.
[`server/README.md`](server/README.md) is the runbook for standing that up.

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

### Typing beats picking

Every stage takes a list of presets **and** whatever you typed into the prompt,
and resolves them in this order:

1. typed text that is itself a valid answer wins
2. otherwise the highlighted preset
3. otherwise it says what was wrong with what you typed

So `08:00` at the time stage, `+2d` at the repeat stage and `2026-12-25` at the
date stage all just work, without hunting for a "type it yourself" entry. Words
like `today`, `sat` and `eom` are *not* valid answers, so filtering down to a
preset and confirming behaves exactly as you'd expect.

Typed text has to win outright rather than only when nothing matched, because
fuzzy matching is too loose to arbitrate: `+2d` matches the preset `+1y -21d` on
a subsequence, so "did anything match?" would silently throw away what you typed.

Where telescope is present it is driven directly, because that is the only way to
read the prompt text back - `vim.ui.select` discards it. That also means the keys
and the look are your own telescope config's, fuzzy sorter and confirm keys
included, so `<C-y>` works if you have bound it there. Without telescope it falls
back to `vim.ui.select` plus a `type it…` entry: the same behaviour, one more
keystroke.

### The date stage

Sixteen entries: today, tomorrow, the next six days by name, 1w/2w/3w, 1m/2m/3m,
end of month, 1y - each showing the date and day name it resolves to. Anything
you type goes through the timestamp grammar itself, so `2026-08-01 14:00 +1m`
works and lands the whole marker in one go.

### The time stage

`none` and five presets (7am, 9am, midday, 5pm, 9pm). What you type is
forgiving: `9`, `930`, `9.30`, `9am`, `midday`, `1745` and `9am-5pm` all become
something the grammar accepts. Anything that doesn't is refused before it can be
written into a note.

### The repeat stage

All three of org's repeater flavours with what they actually mean, and warnings
both on their own and alongside a repeater. It doubles as the syntax reminder for
the `+1m` / `++1m` / `.+1m` distinction:

```
+1m        every month - clamps, so the 31st becomes the 28th in february
++1m       every month, catching up
.+1m       a month after you tick it
-21d       warn three weeks early
+1y -21d   yearly, warned three weeks early
```


## The calendar build

```sh
bin/mdical-build --vault ~/vaults/brain --dry-run
bin/mdical-build --vault ~/vaults/brain --vdir /opt/cal/vdir --healthcheck https://...
```

Reads the vault, writes a [vdir](https://vdirsyncer.pimutils.org/en/stable/vdir.html)
- a directory of `.ics` files, one item per file, named by UID - into
`cal-tasks/` and `cal-events/`. It never speaks CalDAV: vdirsyncer owns the wire,
this owns files. That is why lua was a safe choice despite there being no usable
lua CalDAV library.

It is step 6 of the nightly run, "rebuild the vdir from markdown".
[`server/`](server/README.md) sequences the rest around it.

### What it will not do to your calendar

**It only deletes resources it emitted.** A task created on the phone has a UID
this build has never seen, and a strict "markdown is the only source" rebuild
would silently eat it. Two overlapping guards stop that: every emitted UID
carries an `mdical-` prefix, and `state/last-build.lua` records what the last run
wrote. A resource has to fail both checks to be removed.

**It refuses to publish a collapse.** If the number of markers, or of notes
scanned, falls by more than 20% against the last run it exits non-zero and changes
nothing, because one bad parse otherwise empties the calendar quietly and nothing
notices for a week. `--allow-drop` changes the tolerance, `--force` overrides it.

The gate counts *markers*, not emitted items, which is the second version of it.
Item counts move for entirely legitimate reasons: completing a `+1m` task advances
its anchor, and because the horizon is measured from today while expansion starts
at the anchor, three occurrences become one. The first ratchet run on a five-item
test vault dropped the count by 37% and was refused. Markers only fall when lines
stop promoting, which is what a broken parser actually looks like - and
`mdical-ingest` leaves behind a credit for the ones it closed, so a productive day
does not read like a regression either.

**Its output is byte-stable.** The same markdown produces the same bytes, so a
re-run writes nothing at all and the nightly commit is empty unless something
really changed. There is no `DTSTAMP: now()` anywhere - it is derived from the
item. Without this every run would be a meaningless commit and real changes would
vanish in the diff.

**TEXT is escaped.** `,` `;` and `\` in a summary, folded at 75 octets. The spike
caught radicale storing `buy milk` and dropping the rest of `buy milk, bread and
eggs` - server-side, before the phone ever saw it - and real note text has commas
in it constantly.

### Recurrence is expanded, not delegated

`+1m` becomes several resources rather than an `RRULE`, because `+1m` and `++1m`
map to the *same* rule - `FREQ=MONTHLY` has no notion of completion - so
delegating silently discards a distinction the grammar makes. Clamping is not
expressible in `RRULE` either, which skips where we clamp.

Tasks expand over three months and events over twelve, on the grounds that twelve
months of "pay rent" is twelve reminders where twelve months of a birthday is a
calendar that looks right. Occurrences more than a week in the past are dropped;
a non-repeating item is always emitted however overdue, since overdue is a real
state.

Three things are never expanded: a one-off, a `.+` cookie - whose next date is a
function of the completion date, so it is not a series - and an `RRULE:`
passthrough, which is emitted verbatim for iOS to expand.

## The completion ratchet

```sh
bin/mdical-ingest --vault ~/vaults/brain --vdir /opt/cal/vdir --dry-run --verbose
```

Steps 3 and 4 of the nightly run, and **the only thing in the whole pipeline that
writes to your notes**. It reads the tasks collection after vdirsyncer has filled
it with whatever the phone did, and writes the completions back.

| marker | ticked on the phone |
|--------|---------------------|
| one-off | `- [ ]` becomes `- [x]`, and `CLOSED:` records when |
| `+N` | the timestamp advances one interval from the occurrence that was ticked |
| `++N` | the timestamp advances past today |
| `.+N` | the timestamp becomes the completion date plus N |
| `RRULE:` | nothing - iOS expanded it, so iOS owns it |

A repeater keeps its `- [ ]` and gets no `CLOSED:`, which mirrors org: completing a
repeating task moves the date rather than closing the entry. The new anchor already
*is* the result of the arithmetic, so a `CLOSED:` beside it could only disagree
with it. Ticking one by hand in the editor therefore ends the series, and the
parser warns about that (`done-repeater`).

Advancing from the ticked occurrence rather than from the anchor matters when an
earlier one was missed. Tick September's rent with August's still outstanding and
the anchor moves to October; from the anchor it would move to September and the
task you just completed would come straight back.

### What it will not do to your notes

**Only the changed lines change.** Line endings, indentation and the presence or
absence of a final newline are preserved exactly. A rewrite that normalised them
would show up as a whole-file diff, in your own notes, in a commit you did not
make, and would bury the one line that actually moved.

**Every write is a temp file plus a rename**, so a note is never half-written.

**It re-checks each line before writing it.** The plan was made from the same bytes
moments earlier, so a mismatch means something else is editing the vault - and the
answer is to write nothing to that file rather than guess.

**A resource it did not emit is never touched.** A task created on the phone has a
UID with no marker behind it. It is counted and left where it is; ingesting those
into an `## Inbox` is a later addition and this rule means waiting costs nothing.

### Matching a resource back to a line

UIDs are content hashes, so they cannot be reversed. Instead the index the build
would produce - kind, summary and occurrence date, per marker - is rebuilt and
completions are looked up in it. Two consequences: moving a marker between notes
does not break the match, and renaming a task does. A renamed task comes back,
because as far as the UID is concerned it is a different task.

`COMPLETED:` is read in UTC and converted to local wall time. M0 recorded
`COMPLETED:20260728T195946Z` from a tick at 20:59 on a July evening, so writing the
UTC value into a note would be an hour wrong and, near midnight, a day wrong.

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
lua/mdical/          pure: grammar, parse, date, fmt, edit, scope, ics, ical, uid, ratchet
lua/mdical/          io:   scan, vdir, state
lua/mdical/nvim/     editor: the command, the inserter, the picker, the linter
plugin/mdical.lua    :Mdical
bin/mdical-build     markdown -> a vdir
bin/mdical-ingest    completions -> markdown
server/              the container: run.sh, the configs, bootstrap.sh
tests/               luajit tests/run.lua
```

`ics` writes iCalendar and `ical` reads it. They are deliberately separate and
deliberately asymmetric: writing has to be exactly right, reading only has to
recover four properties from a `VTODO` some other client wrote.

Diagnostics come out of the parser rather than a separate linter, so the editor
and the build reach the same verdict from the same code. A line with an
error-severity diagnostic sets `emit = false`, which is the build's rule for
refusing to publish it.

## Tests

```sh
luajit tests/run.lua                              # the core
nvim --headless --clean -l tests/nvim_smoke.lua    # the editor layer

# the telescope path, driven for real. Needs telescope on the runtimepath, so it
# skips itself without one and is not part of CI.
nvim --headless some.md -c 'sleep 900m' -c 'luafile tests/telescope_drive.lua'
```

No plenary and no neovim for the first one: the same suite runs on a laptop, in CI, and on the box
that does the nightly build. `tests/corpus.lua` is the grammar reference's worked
examples transcribed as data, and expectations there are strict - a case with no
`codes` field asserts *no* diagnostics, so newly spurious lint fails the suite
rather than being absorbed.
