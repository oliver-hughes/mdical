local uid = require("mdical.uid")

describe("uid", function()
  it("is stable for the same content", function()
    eq(uid.item("task", "pay rent", "2026-08-01"), uid.item("task", "pay rent", "2026-08-01"), "same input")
  end)

  it("separates different content", function()
    local seen = {}
    for _, args in ipairs({
      { "task", "pay rent", "2026-08-01" },
      { "task", "pay rent", "2026-09-01" },
      { "task", "pay rent", nil },
      { "event", "pay rent", "2026-08-01" },
      { "task", "pay rent ", "2026-08-01" },
      { "task", "Pay rent", "2026-08-01" },
      { "task", "pay rents", "2026-08-01" },
      { "task", "", "2026-08-01" },
    }) do
      local id = uid.item(args[1], args[2], args[3])
      eq(seen[id], nil, "collision on " .. tostring(args[2]) .. "/" .. tostring(args[3]))
      seen[id] = true
    end
  end)

  it("is recognisably ours, which is what protects phone-created tasks", function()
    truthy(uid.is_ours(uid.item("task", "x", nil)), "ours")
    eq(uid.is_ours("6C7E1B4A-1234-5678-9ABC-DEF012345678"), false, "an iOS-shaped uid is not")
    eq(uid.is_ours(nil), false, "nil is not")
    eq(uid.is_ours(""), false, "empty is not")
  end)

  it("produces a filename-safe id of a fixed length", function()
    for _, summary in ipairs({ "buy milk, bread and eggs", "a/slash", "a\\backslash", "spaces here", "émojis ✨" }) do
      local id = uid.item("task", summary, "2026-08-01")
      truthy(id:match("^mdical%-%x+$") ~= nil, "safe for a filename: " .. id)
      eq(#id, #uid.PREFIX + 16, "fixed width")
    end
  end)

  it("spreads a realistic set of summaries without collisions", function()
    local seen, n = {}, 0
    for i = 1, 500 do
      for _, base in ipairs({ "pay rent", "take the bins out", "standup", "chase the plumber" }) do
        local id = uid.item("task", base .. " " .. i, nil)
        eq(seen[id], nil, "collision at " .. base .. " " .. i)
        seen[id] = true
        n = n + 1
      end
    end
    eq(n, 2000, "two thousand distinct ids")
  end)
end)
