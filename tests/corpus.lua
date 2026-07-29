--- The worked examples from the marker grammar spec, as data.
---
--- Transcribed by hand rather than scraped: a scraper coupled to the note's
--- table formatting is a worse dependency than a stale copy. See the spec's
--- "worked examples" section - every line below appears there verbatim, in
--- order, and the day names are the note's own.
---
--- Expectations are strict. `codes` absent means **no diagnostics at all**, so a
--- change that starts emitting spurious lint fails the suite rather than being
--- absorbed.
---
---   kind      "task" | "event" | false (inert)
---   due/at    ISO date string, or "empty" for `<>`
---   codes     the exact set of diagnostic codes, unordered

return {
  ------------------------------------------------------------------- tasks
  tasks = {
    { line = "- [ ] put the bins out <2026-09-01>",
      kind = "task", summary = "put the bins out", due = "2026-09-01", emit = true },
    { line = "- [ ] put the bins out <2026-09-01 Tue>",
      kind = "task", summary = "put the bins out", due = "2026-09-01", emit = true },
    { line = "- [ ] put the bins out DEADLINE: <2026-09-01 Tue>",
      kind = "task", summary = "put the bins out", due = "2026-09-01", emit = true },
    { line = "- [ ] submit expenses <2026-09-01 Tue 17:00>",
      kind = "task", summary = "submit expenses", due = "2026-09-01", time = "17:00", emit = true },
    { line = "- [ ] !!! renew the passport <2026-10-15 Thu>",
      kind = "task", summary = "renew the passport", due = "2026-10-15", priority = 1, emit = true },
    { line = "- [ ] !! set up a direct debit for rent <2027-01-01 Fri>",
      kind = "task", summary = "set up a direct debit for rent", due = "2027-01-01", priority = 5, emit = true },
    { line = "- [ ] ! tidy the garage <2026-09-30 Wed>",
      kind = "task", summary = "tidy the garage", due = "2026-09-30", priority = 9, emit = true },
    { line = "- [ ] chase the plumber about the boiler <>",
      kind = "task", summary = "chase the plumber about the boiler", undated = true, emit = true },
    { line = "- [ ] !! book the MOT <>",
      kind = "task", summary = "book the MOT", undated = true, priority = 5, emit = true },
    { line = "- [ ] draft the Q3 report SCHEDULED: <2026-08-03 Mon> DEADLINE: <2026-08-10 Mon>",
      kind = "task", summary = "draft the Q3 report", due = "2026-08-10", scheduled = "2026-08-03", emit = true },
    { line = "- [ ] think about the loft SCHEDULED: <2026-09-07 Mon>",
      kind = false, summary = "think about the loft", scheduled = "2026-09-07", emit = false },
    { line = "- [x] renew the tv licence CLOSED: [2026-07-14 Tue 10:32]",
      kind = false, summary = "renew the tv licence", closed = "2026-07-14", done = true, emit = false },
    { line = "- [x] pay the window cleaner <2026-07-20 Mon> CLOSED: [2026-07-21 Tue]",
      kind = "task", summary = "pay the window cleaner", due = "2026-07-20", closed = "2026-07-21",
      done = true, emit = false },
  },

  --------------------------------------------------- recurrence and warnings
  recurrence = {
    { line = "- [ ] pay rent <2026-08-01 Sat +1m>",
      kind = "task", summary = "pay rent", due = "2026-08-01", repeater = "+1m", emit = true },
    { line = "- [ ] take the recycling out <2026-08-03 Mon +1w>",
      kind = "task", summary = "take the recycling out", due = "2026-08-03", repeater = "+1w", emit = true },
    { line = "- [ ] change the smoke alarm battery <2026-10-01 Thu ++1y>",
      kind = "task", summary = "change the smoke alarm battery", due = "2026-10-01", repeater = "++1y",
      emit = true },
    { line = "- [ ] deep clean the oven <2026-08-01 Sat +6m>",
      kind = "task", summary = "deep clean the oven", due = "2026-08-01", repeater = "+6m", emit = true },
    { line = "- [ ] water the plants <2026-07-30 Thu .+3d>",
      kind = "task", summary = "water the plants", due = "2026-07-30", repeater = ".+3d", emit = true },
    { line = "- [ ] team retro <2026-08-19 Wed> RRULE: FREQ=MONTHLY;BYDAY=3WE",
      kind = "task", summary = "team retro", due = "2026-08-19", rrule = "FREQ=MONTHLY;BYDAY=3WE", emit = true },
    { line = "- [ ] !!! submit tax return <2027-01-31 Sun -21d>",
      kind = "task", summary = "submit tax return", due = "2027-01-31", priority = 1, warn = "-21d", emit = true },
    { line = "- [ ] renew car insurance <2026-08-14 Fri +1y -21d>",
      kind = "task", summary = "renew car insurance", due = "2026-08-14", repeater = "+1y", warn = "-21d",
      emit = true },
  },

  ------------------------------------------------------------------ events
  events = {
    { line = "<2026-08-05 Wed 15:00-16:00> standup",
      kind = "event", summary = "standup", at = "2026-08-05", time = "15:00", time_end = "16:00", emit = true },
    { line = "<2026-08-05 Wed> team offsite",
      kind = "event", summary = "team offsite", at = "2026-08-05", emit = true },
    { line = "<2026-08-10 Mon>--<2026-08-12 Wed> conference in manchester",
      kind = "event", summary = "conference in manchester", at = "2026-08-10", at_end = "2026-08-12", emit = true },
    { line = "<2026-09-16 Wed 16:42> big birthday party",
      kind = "event", summary = "big birthday party", at = "2026-09-16", time = "16:42", emit = true },
    { line = "<2026-07-30 Thu ++1y> rach's birthday",
      kind = "event", summary = "rach's birthday", at = "2026-07-30", repeater = "++1y", emit = true },
    { line = "<2026-12-25 Fri ++1y> christmas",
      kind = "event", summary = "christmas", at = "2026-12-25", repeater = "++1y", emit = true },
    { line = "<2026-08-12 Wed 10:00-10:15 +1w> planning EXCEPT: [2026-08-19 Wed]",
      kind = "event", summary = "planning", at = "2026-08-12", time = "10:00", time_end = "10:15",
      repeater = "+1w", except = { "2026-08-19" }, emit = true },
    { line = "<2026-08-14 Fri +1y -21d> car insurance renewal",
      kind = "event", summary = "car insurance renewal", at = "2026-08-14", repeater = "+1y", warn = "-21d",
      emit = true },
    { line = "- <2026-08-20 Thu 09:00-09:30> gp appointment",
      kind = "event", summary = "gp appointment", at = "2026-08-20", time = "09:00", time_end = "09:30",
      emit = true },
    { line = "## <2026-09-05 Sat> rach's parents visiting",
      kind = "event", summary = "rach's parents visiting", at = "2026-09-05", emit = true },
  },

  --------------------------------------------------------- silent by design
  silent = {
    { line = "- [ ] buy a new kettle", kind = false, summary = "buy a new kettle", emit = false },
    { line = "- [ ] read the thing james sent over", kind = false,
      summary = "read the thing james sent over", emit = false },
    { line = "- [x] cancel the gym", kind = false, summary = "cancel the gym", done = true, emit = false },
    { line = "[2026-01-31 Sat] the date the last return was filed", kind = false,
      summary = "the date the last return was filed", emit = false },
    { line = "[2026-07-14 Tue 10:32] when the passport application went in", kind = false,
      summary = "when the passport application went in", emit = false },
    -- `<>` off a checkbox is inert, and says so once
    { line = "the query had `WHERE ms <> 0` in it, which took a while to spot", kind = false,
      codes = { "empty-ts-on-non-task" }, emit = false },
    { line = "we talked about september but nothing is booked yet", kind = false,
      summary = "we talked about september but nothing is booked yet", emit = false },
  },

  -------------------------------------------------------------------- lint
  lint = {
    { line = "- [ ] confusing <2026-09-01 Tue> DEADLINE: <2026-09-08 Tue>",
      kind = "task", summary = "confusing", due = "2026-09-08", codes = { "two-due-dates" }, emit = false },
    { line = "- [ ] <2026-09-01 Tue>",
      kind = "task", summary = "", due = "2026-09-01", codes = { "empty-summary" }, emit = false },
    { line = "- [ ] [#A] old habit <2026-09-01 Tue>",
      kind = "task", summary = "old habit", due = "2026-09-01", codes = { "org-priority" }, emit = false },
    { line = "- [ ] wrong day name <2026-09-01 Fri>",
      kind = "task", summary = "wrong day name", due = "2026-09-01", codes = { "dayname-mismatch" }, emit = true },
    { line = "- [ ] hourly repeat <2026-09-01 Tue 09:00 +2h>",
      kind = "task", summary = "hourly repeat", due = "2026-09-01", time = "09:00", repeater = "+2h",
      codes = { "hourly-repeat" }, emit = true },
    { line = "- [ ] typo'd rule <2026-08-19 Wed> RRULE: FREQ=MUNTHLY;BYDAY=3WE",
      kind = "task", summary = "typo'd rule", due = "2026-08-19", rrule = "FREQ=MUNTHLY;BYDAY=3WE",
      codes = { "bad-rrule" }, emit = false },
    { line = "<2026-09-01 Tue> <2026-09-05 Sat> two events on one line",
      kind = "event", summary = "two events on one line", at = "2026-09-01",
      codes = { "two-events" }, emit = false },
  },

  ------------------------------------------- the rows that catch emitters out
  traps = {
    { line = "- [ ] buy milk, bread and eggs <2026-09-01 Tue>",
      kind = "task", summary = "buy milk, bread and eggs", due = "2026-09-01", emit = true },
    { line = "- [ ] escape these; and this \\ too <2026-09-01 Tue>",
      kind = "task", summary = "escape these; and this \\ too", due = "2026-09-01", emit = true },
    { line = "- [ ] pay the invoice <2026-01-31 Sat +1m>",
      kind = "task", summary = "pay the invoice", due = "2026-01-31", repeater = "+1m", emit = true },
    { line = "- [ ] leap-day thing <2024-02-29 Thu ++1y>",
      kind = "task", summary = "leap-day thing", due = "2024-02-29", repeater = "++1y", emit = true },
  },

  ------------------------------------- not in the spec; brackets that aren't
  brackets = {
    -- CommonMark-safe shortcut reference, and it must survive into the summary
    { line = "- [ ] !! [draft] review the thing <2026-09-01 Tue>",
      kind = "task", summary = "[draft] review the thing", due = "2026-09-01", priority = 5, emit = true },
    -- wikilinks are everywhere in the vault and are not timestamps
    { line = "- [ ] chase [[20260723-azie-1600]] with james <2026-09-01 Tue>",
      kind = "task", summary = "chase [[20260723-azie-1600]] with james", due = "2026-09-01", emit = true },
    { line = "- [ ] read [[2026-W30|w/c 20 Jul 2026]] again <2026-09-01 Tue>",
      kind = "task", summary = "read [[2026-W30|w/c 20 Jul 2026]] again", due = "2026-09-01", emit = true },
    -- a markdown link, likewise
    { line = "<2026-09-01 Tue> read [the docs](https://example.com/a-b)",
      kind = "event", summary = "read [the docs](https://example.com/a-b)", at = "2026-09-01", emit = true },
    -- an unterminated bracket is text
    { line = "- [ ] the < in that expression <2026-09-01 Tue>",
      kind = "task", summary = "the < in that expression", due = "2026-09-01", emit = true },
    -- a real date that isn't a date
    { line = "- [ ] impossible <2026-02-30 Mon>",
      kind = false, summary = "impossible", codes = { "bad-timestamp" }, emit = false },
    -- junk inside otherwise valid brackets is reported, not silently dropped
    { line = "- [ ] typo in the cookie <2026-09-01 Tue +1z>",
      kind = false, summary = "typo in the cookie", codes = { "bad-timestamp" }, emit = false },
    -- documented sharp edge: `<>` after a checkbox promotes, even in prose
    { line = "- [ ] fix the WHERE ms <> 0 thing",
      kind = "task", summary = "fix the WHERE ms 0 thing", undated = true, emit = true },
  },
}
