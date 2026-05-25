-- lookray.lua: shared player look-ray resolver.
--
-- Turns a player's position + yaw/pitch into a world X/Z target by marching
-- their eye ray against a terrain-height source. Designed for CCMinimap, Spruce,
-- and missile/client code that need the same "block I'm looking at" primitive.

local M = {}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function mcLookVector(yawDeg, pitchDeg)
  local yaw = math.rad(yawDeg)
  local pitch = math.rad(pitchDeg)
  local horizontal = math.cos(pitch)
  return -math.sin(yaw) * horizontal, -math.sin(pitch), math.cos(yaw) * horizontal
end

function M.init(env)
  env = env or {}
  local playerDetector

  local function detector()
    if playerDetector then return playerDetector end
    local configured = env.playerDetectorPeripheral
    if configured and configured ~= "" and peripheral and peripheral.wrap then
      local p = peripheral.wrap(configured)
      if p and type(p.getPlayer) == "function" then
        playerDetector = p
        return playerDetector
      end
    end
    if peripheral and peripheral.find then
      local p = peripheral.find("player_detector")
      if p and type(p.getPlayer) == "function" then playerDetector = p end
    end
    return playerDetector
  end

  local function fromDetector(name)
    if not name or name == "" then return nil end
    local d = detector()
    if not d then return nil end
    local ok, data = pcall(d.getPlayer, name)
    if not ok or type(data) ~= "table" then return nil end
    if type(data.x) ~= "number" or type(data.z) ~= "number" then return nil end
    if type(data.yaw) ~= "number" or type(data.pitch) ~= "number" then return nil end
    return {
      source = "player_detector",
      name = name,
      x = data.x,
      y = data.y or 0,
      z = data.z,
      yaw = data.yaw,
      pitch = data.pitch,
    }
  end

  local function fromBlueMap(name)
    local players = env.players and env.players() or {}
    local target = name
    if not target or target == "" then
      if env.playerName and env.playerName ~= "" then target = env.playerName
      elseif #players == 1 then target = players[1].name end
    end
    if not target or target == "" then return nil, "look: no player configured" end
    for _, p in ipairs(players) do
      if p.name == target and type(p.position) == "table" and type(p.rotation) == "table" then
        if type(p.position.x) == "number" and type(p.position.z) == "number"
           and type(p.rotation.yaw) == "number" and type(p.rotation.pitch) == "number" then
          return {
            source = "bluemap",
            name = p.name,
            x = p.position.x,
            y = p.position.y or 0,
            z = p.position.z,
            yaw = p.rotation.yaw,
            pitch = p.rotation.pitch,
          }
        end
      end
    end
    return nil, "look: missing player yaw/pitch for " .. tostring(target)
  end

  local function lookupPlayer(name)
    local target = (name and name ~= "") and name or env.playerName
    if target and target ~= "" then return fromDetector(target) or fromBlueMap(target) end
    local p, err = fromBlueMap(nil)
    if p and p.name then return fromDetector(p.name) or p end
    return nil, err
  end

  local resolver = {}

  function resolver.resolve(name, maxDistance)
    local p, err = lookupPlayer(name)
    if not p then return nil, err end
    local limit = tonumber(maxDistance) or tonumber(env.maxDistance) or 5000
    local step = tonumber(env.step) or 2
    limit = clamp(limit, 8, 5000)
    step = clamp(step, 0.5, 8)

    local dx, dy, dz = mcLookVector(p.yaw, p.pitch)
    local eyeY = (p.y or 0) + (tonumber(env.eyeHeight) or 1.62)
    local d = step
    while d <= limit do
      local x = p.x + dx * d
      local y = eyeY + dy * d
      local z = p.z + dz * d
      local ground = env.groundY and env.groundY(x, z)
      if y <= (tonumber(ground) or tonumber(env.seaLevel) or 64) + 1 then
        return {
          x = math.floor(x),
          z = math.floor(z),
          player = p.name,
          source = p.source,
          distance = d,
        }
      end
      d = d + step
    end
    return nil, "look: no terrain hit within " .. math.floor(limit) .. "m"
  end

  return resolver
end

return M
