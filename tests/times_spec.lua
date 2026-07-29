local times = require("mdical.nvim.times")
local grammar = require("mdical.grammar")

describe("nvim.times presets", function()
  it("offers none, five times, and free text", function()
    eq(#times.presets, 7, "seven entries")
    eq(times.presets[1].none, true, "none first")
    eq(times.presets[#times.presets].custom, true, "free text last")
  end)

  it("shows the friendly name and what it means", function()
    eq(times.format({ label = "9am", value = "09:00" }), "9am       09:00", "preset")
    eq(times.format({ label = "none", none = true }), "none", "none")
  end)

  it("only offers times the grammar accepts", function()
    for _, p in ipairs(times.presets) do
      if p.value then
        truthy(grammar.parse_body("2026-09-01 " .. p.value, true), p.value .. " parses")
      end
    end
  end)
end)

describe("nvim.times.normalise", function()
  it("takes a bare hour", function()
    eq(times.normalise("9"), "09:00", "9")
    eq(times.normalise("09"), "09:00", "09")
    eq(times.normalise("17"), "17:00", "17")
    eq(times.normalise("0"), "00:00", "midnight as 0")
  end)

  it("takes hours and minutes, however they are separated", function()
    eq(times.normalise("9:30"), "09:30", "9:30")
    eq(times.normalise("09:30"), "09:30", "09:30")
    eq(times.normalise("9.30"), "09:30", "9.30")
    eq(times.normalise("930"), "09:30", "930")
    eq(times.normalise("0930"), "09:30", "0930")
    eq(times.normalise("1745"), "17:45", "1745")
  end)

  it("takes am and pm", function()
    eq(times.normalise("9am"), "09:00", "9am")
    eq(times.normalise("9pm"), "21:00", "9pm")
    eq(times.normalise("9:30pm"), "21:30", "9:30pm")
    eq(times.normalise("12pm"), "12:00", "noon stays noon")
    eq(times.normalise("12am"), "00:00", "midnight becomes zero")
    eq(times.normalise("11PM"), "23:00", "upper case")
    eq(times.normalise("7 am"), "07:00", "with a space")
  end)

  it("takes the words", function()
    eq(times.normalise("midday"), "12:00", "midday")
    eq(times.normalise("noon"), "12:00", "noon")
    eq(times.normalise("midnight"), "00:00", "midnight")
  end)

  it("takes ranges", function()
    eq(times.normalise("9-17"), "09:00-17:00", "bare hours")
    eq(times.normalise("9am-5pm"), "09:00-17:00", "am and pm")
    eq(times.normalise("15:00-16:00"), "15:00-16:00", "already canonical")
    eq(times.normalise("930 - 1015"), "09:30-10:15", "spaces round the dash")
    eq(times.normalise("midday-1pm"), "12:00-13:00", "a word on one side")
  end)

  it("rejects what is not a time", function()
    for _, bad in ipairs({ "", "  ", "tomorrow", "25", "24:00", "9:60", "9am-", "-5pm", "9:", "nine" }) do
      nilly(times.normalise(bad), ("%q is not a time"):format(bad))
    end
  end)

  it("only ever produces something the grammar accepts", function()
    for _, input in ipairs({ "9", "930", "9am", "9pm", "midday", "midnight", "9am-5pm", "1745", "12am" }) do
      local out = times.normalise(input)
      truthy(grammar.parse_body("2026-09-01 " .. out, true), ("%s -> %s parses"):format(input, out))
    end
  end)
end)
