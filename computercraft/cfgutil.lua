-- cfgutil.lua: shared JSON-config utilities for CCMinimap and Spruce.
--
-- Both products write back their on-disk config every boot (after merging
-- new default keys from the server) and want the result to be stable and
-- human-readable. Lua tables don't preserve insertion order, so we sort
-- keys alphabetically before serializing.
--
-- Usage:
--   local Cfg = dofile("cfgutil.lua")
--   local added = Cfg.deepMergeMissing(defaults, current)
--   writeFile("foo.cfg", Cfg.jsonPretty(current) .. "\n")

local M = {}

-- Pretty-print a value as JSON with two-space indent. Object keys are
-- sorted alphabetically so the on-disk config diff is stable across boots.
function M.jsonPretty(value, indent)
  indent = indent or 0
  if type(value) ~= "table" then return textutils.serialiseJSON(value) end
  local n, isArray = 0, true
  for k, _ in pairs(value) do
    n = n + 1
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then isArray = false end
  end
  if n == 0 then return "{}" end
  local pad      = string.rep("  ", indent)
  local innerPad = string.rep("  ", indent + 1)
  if isArray and n == #value then
    local parts = {}
    for i = 1, n do parts[i] = innerPad .. M.jsonPretty(value[i], indent + 1) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end
  local keys = {}
  for k, _ in pairs(value) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = innerPad .. textutils.serialiseJSON(k) .. ": " .. M.jsonPretty(value[k], indent + 1)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

-- Fill keys missing from `current` with values from `defaults`. Recurses
-- into nested tables so e.g. adding a new `channels.back` entry to defaults
-- appends it to an existing `channels` table without overwriting siblings.
-- Returns dotted paths that were added so the bootloader can log them.
function M.deepMergeMissing(defaults, current)
  local added = {}
  for k, v in pairs(defaults) do
    if current[k] == nil then
      current[k] = v
      added[#added + 1] = tostring(k)
    elseif type(v) == "table" and type(current[k]) == "table" then
      local sub = M.deepMergeMissing(v, current[k])
      for _, s in ipairs(sub) do added[#added + 1] = tostring(k) .. "." .. s end
    end
  end
  return added
end

return M
