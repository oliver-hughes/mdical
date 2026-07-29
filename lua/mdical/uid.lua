--- Stable identifiers for emitted resources. Pure lua 5.1, no `vim`, and
--- deliberately no bit operations - `bit` happens to exist in LuaJIT on both
--- sides of this project, but a polynomial hash needs nothing and works under
--- PUC Lua too.
---
--- Two properties matter more than the hash quality:
---
--- **Stable across runs.** A UID that changed run to run would churn every item
--- on the phone nightly. So it is derived from content, never from the clock, the
--- file path or the line number.
---
--- **Recognisably ours.** Every UID carries a prefix, which is what lets the
--- build tell a resource it emitted from one the phone created. The state file
--- records what was emitted, but the prefix means an unknown resource is
--- identifiable as not-ours even with no state at all - and *not deleting*
--- phone-created tasks is the rule that keeps captured work from being eaten.

local M = {}

M.PREFIX = "mdical-"

--- Rolling polynomial hash. Both primes and moduli are small enough that
--- `h * prime + byte` stays exact in a double, which is what keeps this
--- identical on every lua that runs it.
local function poly(s, prime, modulus, seed)
  local h = seed % modulus
  for i = 1, #s do
    h = (h * prime + s:byte(i)) % modulus
  end
  return math.floor(h)
end

--- 64-ish bits as 16 hex characters, from two independent passes.
function M.hash(s)
  s = tostring(s or "")
  local a = poly(s, 131, 2147483647, 2166136261)
  local b = poly(s, 8191, 2147483629, 5381)
  return ("%08x%08x"):format(a, b)
end

--- The identity of one emitted item.
---
--- Content, and only content: kind, summary and the occurrence date. Notably
--- **not** the file path, so moving a marker from a daily note into a project
--- note is not a new task - and **not** the priority or the time, so changing
--- either edits the existing resource rather than replacing it.
---
--- Two markers with the same kind, summary and date therefore collapse into one
--- resource, which is the right answer: that is a duplicate, not two things.
---
--- @param kind string "task" | "event"
--- @param summary string
--- @param iso_date string|nil nil for an undated task
function M.item(kind, summary, iso_date)
  return M.PREFIX .. M.hash(table.concat({ kind, summary, iso_date or "undated" }, "\31"))
end

--- Did this build emit this resource? Used before deleting anything.
function M.is_ours(uid)
  return tostring(uid or ""):sub(1, #M.PREFIX) == M.PREFIX
end

return M
