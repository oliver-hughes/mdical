local scope = require("mdical.scope")

local function lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

local BLOCK = lines([[
---
id: 20260729-marker-grammar
aliases:
  - marker grammar
tags:
  - notetaking
  - calendar
  - meta
---

# marker grammar
]])

local INLINE = lines([[
---
tags: [cal, work]
---
text
]])

local BARE = lines([[
---
tags: daily
---
text
]])

describe("scope.bounds", function()
  it("finds the frontmatter", function()
    eq({ scope.bounds(BLOCK) }, { 1, 9 }, "block form")
    eq({ scope.bounds(INLINE) }, { 1, 3 }, "inline form")
  end)

  it("reports none when there is none", function()
    eq({ scope.bounds(lines("# just a heading\ntext")) }, { 0, 0 }, "no frontmatter")
    eq({ scope.bounds(lines("---\nunterminated\ntext")) }, { 0, 0 }, "unterminated")
  end)
end)

describe("scope.tags", function()
  it("reads the YAML list form this vault uses", function()
    eq(scope.tags(BLOCK), { "notetaking", "calendar", "meta" }, "block list")
  end)

  it("reads the inline form", function()
    eq(scope.tags(INLINE), { "cal", "work" }, "inline")
  end)

  it("reads a bare scalar", function()
    eq(scope.tags(BARE), { "daily" }, "single tag")
  end)

  it("returns nothing when there are no tags", function()
    eq(scope.tags(lines("---\nid: x\n---\ntext")), {}, "no tags key")
    eq(scope.tags(lines("# no frontmatter")), {}, "no frontmatter")
  end)
end)

describe("scope.included", function()
  it("scans everything by default", function()
    eq(scope.included({}, nil), true, "an untagged daily note")
    eq(scope.included({ "notetaking" }, nil), true, "an irrelevant tag")
  end)

  it("excludes meta by default, which is what keeps the design notes out", function()
    eq(scope.included({ "calendar", "meta" }, nil), false, "the grammar spec itself")
  end)

  it("lets exclusion win over inclusion", function()
    local cfg = { include_tags = { "cal" }, exclude_tags = { "meta" } }
    eq(scope.included({ "cal", "meta" }, cfg), false, "both tags: skipped")
    eq(scope.included({ "cal" }, cfg), true, "included")
    eq(scope.included({ "daily" }, cfg), false, "not in include_tags")
  end)

  it("scans everything when include_tags is empty", function()
    eq(scope.included({ "whatever" }, { include_tags = {}, exclude_tags = {} }), true, "no narrowing")
  end)
end)
