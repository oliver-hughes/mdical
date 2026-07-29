# what the phone sends back

`a1-completed-by-ios.ics` is verbatim what radicale held after iOS ticked the A1
task in the M0 spike. Recovered from `ai/caldav-m0-spike/m0-git-log.txt`, where
the storage hook committed every accepted write, so this is the real thing rather
than a plausible reconstruction.

Four things in it are the reason the ratchet is written the way it is:

**`COMPLETED:20260728T195946Z` is present.** The plan assumed it would be, and it
is. The `LAST-MODIFIED` and `DTSTAMP` fallbacks in `ratchet.completed_at` are for
other clients, not for this one.

**It is UTC.** The tick happened at 20:59 on a July evening in London, so writing
`CLOSED: [2026-07-28 Tue 19:59]` into a note would be an hour wrong and, near
midnight, a day wrong. That is what `date.utc_to_local` is for.

**`PERCENT-COMPLETE:100` comes alongside `STATUS:COMPLETED`.** Either is accepted
as meaning complete, which costs nothing and covers a client that writes only one.

**iOS rewrote the whole resource, alphabetised, and added
`X-APPLE-SORT-ORDER`.** It also added a `DTSTART` the spike never sent. A reader
that cared about property order or unknown properties would break on this; this
one looks up four properties by name and ignores everything else.
