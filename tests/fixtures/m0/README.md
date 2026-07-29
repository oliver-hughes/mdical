# m0 fixtures

Copied verbatim from the calendar spike, where each of these was PUT to radicale
and then looked at on a real iPhone. They are the **ics half of the conformance
corpus** - the markdown half is `tests/corpus.lua`.

`tests/fixtures_spec.lua` asserts that what the emitter produces carries the same
properties, in the same forms, as the ones that were observed to work. Where it
deliberately differs the spec says why:

- **no `SEQUENCE`** - the spike wrote `SEQUENCE:0`; A11b/B9a/B9b showed the phone
  notices changes without it
- **`DTSTART` on a delegated recurring task** - the spike omitted it; A9 showed
  Apple's own phone-authored repeat writes `DTSTART` equal to `DUE`
- **`DTSTAMP`** - the spike wrote a fixed time; we derive it from the item so
  output is byte-stable

Do not edit these. They are evidence, not test data.
