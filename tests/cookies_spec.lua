local cookies = require("mdical.nvim.cookies")
local grammar = require("mdical.grammar")

describe("nvim.cookies", function()
  it("starts with none and ends with free text", function()
    eq(cookies.presets[1].label, "none", "none first")
    eq(cookies.presets[#cookies.presets].custom, true, "free text last")
    eq(cookies.presets[1].cookies, nil, "none means none")
  end)

  it("only offers cookies the grammar accepts", function()
    for _, p in ipairs(cookies.presets) do
      if p.cookies then
        local ts = grammar.parse_body("2026-09-01 " .. p.cookies, true)
        truthy(ts, p.cookies .. " parses")
        truthy(ts.repeater or ts.warn, p.cookies .. " is a cookie, not something else")
      end
    end
  end)

  it("covers all three repeater flavours, since that is the point", function()
    local kinds = {}
    for _, p in ipairs(cookies.presets) do
      if p.cookies then
        local ts = grammar.parse_body("2026-09-01 " .. p.cookies, true)
        if ts.repeater then
          kinds[ts.repeater.kind] = true
        end
      end
    end
    eq(kinds, { ["+"] = true, ["++"] = true, [".+"] = true }, "+, ++ and .+ are all offered")
  end)

  it("offers a warning on its own and alongside a repeater", function()
    local alone, both = false, false
    for _, p in ipairs(cookies.presets) do
      if p.cookies then
        local ts = grammar.parse_body("2026-09-01 " .. p.cookies, true)
        if ts.warn and not ts.repeater then
          alone = true
        end
        if ts.warn and ts.repeater then
          both = true
        end
      end
    end
    truthy(alone, "a bare warning")
    truthy(both, "a repeater and a warning together")
  end)

  it("explains every entry, because it doubles as the syntax reminder", function()
    for _, p in ipairs(cookies.presets) do
      truthy(p.hint and p.hint ~= "", p.label .. " has a hint")
      truthy(cookies.format(p):find(p.label, 1, true), p.label .. " shows its own syntax")
    end
  end)
end)
