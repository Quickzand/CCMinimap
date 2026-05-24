-- Heading helpers copied from CCMinimap's navigation-table logic.
--
-- The Simulated navigation table does not directly return world yaw. Its
-- needle points toward spawn and getRelativeAngle() reports that needle's
-- angle relative to ship-forward. World heading therefore requires current
-- GPS position:
--
--   ship heading = bearing-to-spawn - relative-angle + headingOffset

local M = {}

local NAV_TYPES = { "navigation_table", "ship_navigation_table", "compass" }
local NAV_METHODS = { "getRelativeAngle", "getYaw", "getRotationYaw", "getRotation" }

function M.discover(configured, configuredMethod)
  if configured and configured ~= "" then
    local p = peripheral.wrap(configured)
    if p then
      local m = configuredMethod
      if m and type(p[m]) == "function" then return { name = configured, peripheral = p, method = m } end
      for _, mm in ipairs(NAV_METHODS) do
        if type(p[mm]) == "function" then return { name = configured, peripheral = p, method = mm } end
      end
    end
  end
  for _, t in ipairs(NAV_TYPES) do
    local p = peripheral.find(t)
    if p then
      for _, m in ipairs(NAV_METHODS) do
        if type(p[m]) == "function" then
          return { name = peripheral.getName and peripheral.getName(p) or t, peripheral = p, method = m }
        end
      end
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p then
      for _, m in ipairs(NAV_METHODS) do
        if type(p[m]) == "function" then return { name = name, peripheral = p, method = m } end
      end
    end
  end
  return nil
end

function M.relativeAngle(source)
  if not source or not source.peripheral or not source.method then return nil end
  local ok, result = pcall(source.peripheral[source.method], source.peripheral)
  if not ok or result == nil then return nil end
  if type(result) == "number" then return result end
  if type(result) == "table" then return result.yaw or result.heading or result[1] end
  return nil
end

function M.fromPositionAndRelative(pos, rel, offset)
  if not pos or type(pos.x) ~= "number" or type(pos.z) ~= "number" or type(rel) ~= "number" then
    return nil
  end
  local bearingToSpawn = math.deg(math.atan2(-pos.x, pos.z))
  return (bearingToSpawn - rel + (tonumber(offset) or 0)) % 360
end

function M.read(source, pos, offset)
  return M.fromPositionAndRelative(pos, M.relativeAngle(source), offset)
end

return M

