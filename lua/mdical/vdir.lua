--- Writing a vdir: a directory of `.ics` files, one item per file, named by UID.
--- Lua 5.1, no `vim`.
---
--- The build never speaks CalDAV. vdirsyncer owns the wire; this owns files. That
--- is the whole reason lua was a safe choice despite there being no usable lua
--- CalDAV library.
---
--- Two rules from the vdir format, both load-bearing:
---
--- **Write to `.tmp` and rename.** vdirsyncer may be reading the directory while
--- the build writes it, and a half-written `.ics` is a corrupt resource rather
--- than a missing one.
---
--- **Only delete what we recognise.** A task created on the phone has a UID this
--- build has never seen. Deleting unknown resources is what a strict "markdown is
--- the only source" rebuild would do, and it would silently eat anything captured
--- on the phone.

local uid = require("mdical.uid")

local M = {}

local function quote(s)
  return ("%q"):format(s)
end

function M.ensure(dir)
  os.execute(("mkdir -p %s"):format(quote(dir)))
  return dir
end

--- UID -> path, for the resources already in `dir`.
function M.existing(dir)
  local pipe = io.popen(("ls -1 %s 2>/dev/null"):format(quote(dir)), "r")
  local out = {}
  if not pipe then
    return out
  end
  for name in pipe:lines() do
    local id = name:match("^(.+)%.ics$")
    if id then
      out[id] = dir .. "/" .. name
    end
  end
  pipe:close()
  return out
end

function M.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- Write `text` to `path` atomically.
--- @return boolean ok, string|nil err
function M.write_file(path, text)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  f:write(text)
  f:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rename_err
  end
  return true
end

--- vdirsyncer propagates a plain extensionless `color` file, so per-collection
--- colour needs no PROPPATCH.
function M.colour(dir, value)
  if not value then
    return
  end
  local path = dir .. "/color"
  if M.read(path) == value then
    return -- byte-stable: do not rewrite what is already right
  end
  M.write_file(path, value)
end

--- Reconcile `dir` against the items it should hold.
---
--- @param dir string
--- @param items table[] from ics.items - each { uid, text }
--- @param opts table|nil {
---   previous = { uid = true, ... }   what the last run emitted
---   dry_run  = boolean
---   colour   = "#rrggbb" }
--- @return table { written, unchanged, removed, kept_unknown, uids = { uid = true } }
function M.sync(dir, items, opts)
  opts = opts or {}
  local stats = { written = 0, unchanged = 0, removed = 0, kept_unknown = 0, uids = {}, errors = {} }

  if not opts.dry_run then
    M.ensure(dir)
    M.colour(dir, opts.colour)
  end

  local existing = M.existing(dir)
  local wanted = {}

  for _, item in ipairs(items) do
    wanted[item.uid] = true
    stats.uids[item.uid] = true
    local path = dir .. "/" .. item.uid .. ".ics"
    if existing[item.uid] and M.read(path) == item.text then
      -- byte-identical, so leave it alone entirely: A11a showed a byte-identical
      -- rewrite is silent to the phone, and not touching it keeps mtimes stable
      stats.unchanged = stats.unchanged + 1
    else
      if opts.dry_run then
        stats.written = stats.written + 1
      else
        local ok, err = M.write_file(path, item.text)
        if ok then
          stats.written = stats.written + 1
        else
          stats.errors[#stats.errors + 1] = ("write %s: %s"):format(path, tostring(err))
        end
      end
    end
  end

  for id, path in pairs(existing) do
    if not wanted[id] then
      -- Two guards, deliberately overlapping: the UID must look like ours, and
      -- the previous run must have recorded emitting it. Anything else is the
      -- phone's and is left where it is.
      local ours = uid.is_ours(id) and (opts.previous == nil or opts.previous[id])
      if ours then
        stats.removed = stats.removed + 1
        if not opts.dry_run then
          os.remove(path)
        end
      else
        stats.kept_unknown = stats.kept_unknown + 1
      end
    end
  end

  return stats
end

return M
