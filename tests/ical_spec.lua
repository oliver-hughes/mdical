local ical = require("mdical.ical")
local ics = require("mdical.ics")

local FIXTURE = TEST_ROOT .. "/tests/fixtures/ingest/a1-completed-by-ios.ics"

local function fixture()
  local f = assert(io.open(FIXTURE, "rb"), "missing " .. FIXTURE)
  local text = f:read("*a")
  f:close()
  return text
end

describe("ical.unfold", function()
  it("rejoins a folded line, dropping the one leading space", function()
    eq(ical.unfold("SUMMARY:buy milk\r\n  and bread\r\n"), { "SUMMARY:buy milk and bread" },
      "the second space is content")
  end)

  it("takes a tab continuation too", function()
    eq(ical.unfold("SUMMARY:one\r\n\ttwo\r\n"), { "SUMMARY:onetwo" }, "htab folds")
  end)

  it("reads lf as happily as crlf", function()
    -- radicale stored the phone's writes with lf, so a crlf-only reader would
    -- see one enormous line
    eq(ical.unfold("A:1\nB:2\n"), { "A:1", "B:2" }, "lf")
    eq(ical.unfold("A:1\r\nB:2\r\n"), { "A:1", "B:2" }, "crlf")
  end)

  it("does not invent a trailing empty line", function()
    eq(ical.unfold("A:1\r\n"), { "A:1" }, "one line")
    eq(ical.unfold("A:1"), { "A:1" }, "no terminator at all")
    eq(ical.unfold(""), {}, "nothing")
  end)

  it("survives a fold as the very first line", function()
    eq(ical.unfold(" orphan\r\nA:1\r\n"), { " orphan", "A:1" }, "nothing to join it to")
  end)
end)

describe("ical.read", function()
  it("recovers properties by name", function()
    local c = ical.read(fixture())
    eq(#c, 1, "one VCALENDAR")
    local todo = ical.find(c, "VTODO")[1]
    eq(ical.get(todo, "UID"), "m0-a1-due-date", "uid")
    eq(ical.get(todo, "SUMMARY"), "A1 due date only", "summary")
    eq(ical.get(todo, "STATUS"), "COMPLETED", "status")
    eq(ical.get(todo, "COMPLETED"), "20260728T195946Z", "completed")
  end)

  it("keeps parameters off the value", function()
    local todo = ical.find(ical.read(fixture()), "VTODO")[1]
    local value, params = ical.get(todo, "DUE")
    eq(value, "20260801", "value")
    eq(params.VALUE, "DATE", "the parameter iOS added")
  end)

  it("takes a colon inside a quoted parameter", function()
    local c = ical.read('BEGIN:VEVENT\r\nATTENDEE;CN="Smith:Jr":mailto:a@b\r\nEND:VEVENT\r\n')
    local value, params = ical.get(c[1], "ATTENDEE")
    eq(value, "mailto:a@b", "the value starts after the unquoted colon")
    eq(params.CN, "Smith:Jr", "quotes stripped")
  end)

  it("nests, so an alarm's summary cannot shadow the task's", function()
    local text = table.concat({
      "BEGIN:VCALENDAR", "BEGIN:VTODO", "SUMMARY:the task", "UID:x",
      "BEGIN:VALARM", "ACTION:DISPLAY", "SUMMARY:the alarm", "END:VALARM",
      "END:VTODO", "END:VCALENDAR", "",
    }, "\r\n")
    local todo = ical.find(ical.read(text), "VTODO")[1]
    eq(ical.get(todo, "SUMMARY"), "the task", "the task's own")
    eq(#todo.children, 1, "the alarm is a child")
    eq(ical.get(todo.children[1], "SUMMARY"), "the alarm", "and keeps its own")
  end)

  it("finds a component at any depth", function()
    local text = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:a\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:b\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
    eq(#ical.find(ical.read(text), "VTODO"), 2, "both")
  end)

  it("returns nothing rather than erroring on rubbish", function()
    eq(ical.read("not calendar data at all"), {}, "no components")
    nilly(ical.get(nil, "UID"), "no component")
  end)
end)

describe("ical.unescape", function()
  it("undoes what ics.escape did", function()
    for _, raw in ipairs({
      "buy milk, bread and eggs",
      "a; semicolon",
      [[a \ backslash]],
      "comma, semi; and \\ together",
    }) do
      eq(ical.unescape(ics.escape(raw)), raw, "round trip: " .. raw)
    end
  end)

  it("turns an escaped newline back into one", function()
    eq(ical.unescape("one\\ntwo"), "one\ntwo", "lowercase n")
    eq(ical.unescape("one\\Ntwo"), "one\ntwo", "uppercase, which is also legal")
  end)
end)

describe("ical.datetime", function()
  it("reads a date", function()
    local d, t, form = ical.datetime("20260801", { VALUE = "DATE" })
    eq(d, { year = 2026, month = 8, day = 1 }, "date")
    nilly(t, "no time")
    eq(form, "date", "form")
  end)

  it("reads utc", function()
    local d, t, form = ical.datetime("20260728T195946Z")
    eq(d, { year = 2026, month = 7, day = 28 }, "date")
    eq(t, { hour = 19, min = 59, sec = 46 }, "time")
    eq(form, "utc", "the Z")
  end)

  it("distinguishes floating from zoned", function()
    eq(select(3, ical.datetime("20260801T100000")), "floating", "no zone")
    eq(select(3, ical.datetime("20260801T100000", { TZID = "Europe/London" })), "Europe/London", "zoned")
  end)

  it("refuses what is not a date", function()
    eq(select(3, ical.datetime("")), "invalid", "empty")
    eq(select(3, ical.datetime("20260231")), "invalid", "31 February")
    eq(select(3, ical.datetime("tomorrow")), "invalid", "words")
  end)
end)

describe("ical.local_stamp", function()
  it("moves a utc stamp into local wall time", function()
    -- the real a1 completion: 19:59:46Z, ticked at 20:59 on a July evening
    local d, t = ical.local_stamp("20260728T195946Z", nil, 3600)
    eq(d, { year = 2026, month = 7, day = 28 }, "same day")
    eq({ hour = t.hour, min = t.min }, { hour = 20, min = 59 }, "an hour on, as BST")
  end)

  it("rolls the date when the offset crosses midnight", function()
    local d, t = ical.local_stamp("20260728T233000Z", nil, 3600)
    eq(d, { year = 2026, month = 7, day = 29 }, "the next day")
    eq(t.hour, 0, "half past midnight")
  end)

  it("leaves a floating or all-day value where it is", function()
    local d, t = ical.local_stamp("20260801", { VALUE = "DATE" }, 3600)
    eq(d, { year = 2026, month = 8, day = 1 }, "not shifted")
    nilly(t, "still no time")
  end)
end)
