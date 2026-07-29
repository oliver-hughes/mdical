#!/usr/bin/env luajit
--- Test runner. `luajit tests/run.lua` from the repo root.
---
--- No plenary, no nvim: the core is pure 5.1 with no `vim` dependency, so the
--- same suite runs on a laptop, in CI, and on the box that does the nightly
--- build. Running under bare luajit is also what *enforces* the no-`vim` rule -
--- an accidental `vim.trim` in the core errors on the first test.

local root = arg[0]:match("^(.*)[/\\]tests[/\\]run%.lua$") or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
TEST_ROOT = root

local total, failed, group = 0, 0, ""
local failures = {}

local function show(v, depth)
  depth = depth or 0
  if type(v) ~= "table" then
    return type(v) == "string" and ("%q"):format(v) or tostring(v)
  end
  if depth > 3 then
    return "{...}"
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ("%s = %s"):format(tostring(k), show(v[k], depth + 1))
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function deep_eq(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

function describe(name, fn)
  local prev = group
  group = prev == "" and name or (prev .. " / " .. name)
  fn()
  group = prev
end

function it(name, fn)
  total = total + 1
  local label = group .. " :: " .. name
  local ok, err = pcall(fn)
  if not ok then
    failed = failed + 1
    failures[#failures + 1] = { label = label, err = tostring(err) }
    io.write("F")
  else
    io.write(".")
  end
  if total % 60 == 0 then
    io.write("\n")
  end
end

function eq(got, want, what)
  if not deep_eq(got, want) then
    error(("%s\n      want: %s\n      got:  %s"):format(what or "mismatch", show(want), show(got)), 2)
  end
end

function truthy(v, what)
  if not v then
    error(what or "expected a truthy value", 2)
  end
end

function nilly(v, what)
  if v ~= nil then
    error(("%s (got %s)"):format(what or "expected nil", show(v)), 2)
  end
end

local specs = { "date", "grammar", "fmt", "scope", "parse", "edit", "dates", "times", "cookies", "corpus" }
for _, name in ipairs(specs) do
  local chunk = assert(loadfile(root .. "/tests/" .. name .. "_spec.lua"))
  chunk()
end

io.write(("\n\n%d tests, %d failed\n"):format(total, failed))
for _, f in ipairs(failures) do
  io.write(("\nFAIL %s\n      %s\n"):format(f.label, f.err))
end
os.exit(failed == 0 and 0 or 1)
