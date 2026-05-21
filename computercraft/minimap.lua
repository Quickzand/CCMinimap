-- CLI dispatch: `minimap <subcommand> [args]` at the shell delegates to the
-- ship.lua dispatcher and returns. The bare `minimap` invocation (which is
-- what startup.lua runs in the background) falls through to the display
-- program below.
local _cliArgs = { ... }
if #_cliArgs > 0 then
  return shell.run("ship", table.unpack(_cliArgs))
end

-- This file runs as both the ship-side minimap (full autopilot) and the pocket
-- client (thin remote that mirrors state and forwards taps over rednet). The
-- branch point is `IS_POCKET = pocket ~= nil`. The server hosts the file at
-- /minimap.lua (ship) and /minimap-pocket.lua (pocket) -- same content.
local IS_POCKET = pocket ~= nil
local CONFIG_FILE = IS_POCKET and "minimap-pocket.cfg" or "minimap.cfg"
-- __SERVER_URL__ and __PLAYER_NAME__ are substituted by the server (app.py)
-- from the CLIENT_SERVER_URL / CLIENT_PLAYER_NAME env vars at serve time.
-- A literal value here only matters for offline editing.
local SERVER = "__SERVER_URL__"
local PLAYER_NAME = "__PLAYER_NAME__"
local NAV_PERIPHERAL = nil
local NAV_METHOD = nil
local FRAME_INTERVAL = 1.0
local NAV_INTERVAL = 0.1
local SIDECAR_INTERVAL = 2.5

-- Rednet protocols. Ship hosts as SHIP_HOST on SHIP_PROTO so pockets can find
-- it via rednet.lookup. State is broadcast on STATE_PROTOCOL; commands flow
-- back on CMD_PROTOCOL.
local SHIP_PROTO              = "ship-control"
local SHIP_HOST               = "airship"
local STATE_PROTOCOL          = "airship-state"
local CMD_PROTOCOL            = "airship-cmd"
local STATE_BROADCAST_INTERVAL = 0.5
local LOOKUP_RETRY_INTERVAL    = 2.0
local STATE_STALE_AFTER        = 3.0

local SUB_W, SUB_H = 2, 3

-- Rasterized needle config: thin line drawn from the center cell out in the
-- compass-heading direction. Length is in sub-pixels; area is the cell
-- bounding box that gets re-blitted each tick (so old needle positions are
-- restored from cache instead of leaving a trail).
-- Load config (auto-created on first run with defaults).
if not fs.exists(CONFIG_FILE) then
  local f = fs.open(CONFIG_FILE, "w")
  f.write([[{
  "headingOffset": 0,
  "needleLength": 5,
  "channels": {
    "forward": {
      "relay": "redstone_relay_0",
      "side": "front"
    },
    "back": {
      "relay": "redstone_relay_0",
      "side": "back"
    },
    "left": {
      "relay": "redstone_relay_0",
      "side": "left"
    },
    "right": {
      "relay": "redstone_relay_0",
      "side": "right"
    },
    "liftUp": {
      "relay": "redstone_relay_1",
      "side": "right"
    },
    "liftDown": {
      "relay": "redstone_relay_1",
      "side": "left"
    }
  },
  "inputs": {
    "liftLevel": {
      "relay": "redstone_relay_1",
      "side": "front"
    }
  },
  "outputs": {
    "lift": {
      "relay": "redstone_relay_2",
      "side": "back"
    }
  },
  "customControls": [
    {
      "name": "Platform",
      "relay": "redstone_relay_6",
      "side": "back",
      "mode": "toggle",
      "inverted": true,
      "activeLabel": "LOWERING",
      "inactiveLabel": "RAISED",
      "activeColor": "orange"
    }
  ],
  "liftMode": "burner",
  "useAltimeter": true,
  "useVelocitySensor": true,
  "showAltitudeTape": true,
  "showSpeedDial": true,
  "maxAltitude": 320,
  "maxSpeed": 5,
  "velocityFlipped": true,
  "groundSampleChunkRadius": 1,
  "cruiseAltitudeAboveGround": 50,
  "minAltitudeAboveGround": 20,
  "hoverBurnerLevel": 7,
  "minBurnerLevel": 0,
  "landBurnerLevel": 3,
  "liftKp": 0.4,
  "liftKd": 1.2,
  "liftKi": 0.05,
  "liftPulseSeconds": 0.2,
  "landRampSeconds": 2.0,
  "playerName": "",
  "airshipName": "main",
  "controlSecret": "",
  "controlSecretHash": "",
  "authVersion": 1
}
]])
  f.close()
end
local cfg = {}
do
  local f = fs.open(CONFIG_FILE, "r")
  local raw = f and f.readAll() or ""
  if f then f.close() end
  local ok, parsed = pcall(textutils.unserialiseJSON, raw)
  if ok and type(parsed) == "table" then cfg = parsed end
end

local NEEDLE_LENGTH_SUB = tonumber(cfg.needleLength) or 5
-- Multi-user override: cfg.playerName wins over the server-substituted default
-- so two players sharing one BlueMap server can each suppress their own dot.
if type(cfg.playerName) == "string" and cfg.playerName ~= "" then
  PLAYER_NAME = cfg.playerName
end
-- Pairing: AIRSHIP_NAME makes the rednet hostname unique per ship, so a
-- pocket only discovers its own ship.
--
-- Auth: pocket holds plaintext (CONTROL_SECRET) in its cfg; ship holds only
-- the SHA-256 hash (CONTROL_SECRET_HASH). Pocket attaches the plaintext to
-- every command; ship hashes the received value and compares. Empty hash on
-- the ship means "no password set, accept anything" -- the open default
-- before the operator runs `minimap password`. authVersion is reserved for
-- a future challenge-response upgrade (v2) that keeps the same disk shape,
-- so flipping it later won't require re-pairing.
local AIRSHIP_NAME       = tostring(cfg.airshipName or "main")
local CONTROL_SECRET     = tostring(cfg.controlSecret or "")
local CONTROL_SECRET_HASH = tostring(cfg.controlSecretHash or "")
local Sha = dofile("sha256.lua")

-- Ship migration: if a legacy plaintext controlSecret still exists on disk,
-- hash it into controlSecretHash and strip the plaintext. One-shot per ship.
if not IS_POCKET and CONTROL_SECRET ~= "" then
  CONTROL_SECRET_HASH = Sha.hash(CONTROL_SECRET)
  cfg.controlSecretHash = CONTROL_SECRET_HASH
  cfg.controlSecret = nil
  CONTROL_SECRET = ""
  local ok, Cfg = pcall(dofile, "cfgutil.lua")
  if ok and Cfg and Cfg.jsonPretty then
    local body = Cfg.jsonPretty(cfg) .. "\n"
    if fs.exists(CONFIG_FILE) then fs.delete(CONFIG_FILE) end
    local fh = fs.open(CONFIG_FILE, "w")
    fh.write(body); fh.close()
    print("migrated controlSecret -> controlSecretHash")
  end
end

local function authOk(msg)
  if CONTROL_SECRET_HASH == "" then return true end
  local got = (type(msg) == "table" and type(msg.secret) == "string") and msg.secret or ""
  return Sha.hash(got) == CONTROL_SECRET_HASH
end

local function cfgChannel(name, defaults)
  local cs = cfg.channels
  if type(cs) == "table" and type(cs[name]) == "table" then
    local entry = cs[name]
    if type(entry.relay) == "string" and type(entry.side) == "string" then
      return { relay = entry.relay, side = entry.side }
    end
  end
  return defaults
end
local function cfgInput(name)
  local cs = cfg.inputs
  if type(cs) == "table" and type(cs[name]) == "table" then
    local entry = cs[name]
    if type(entry.relay) == "string" and type(entry.side) == "string" then
      return { relay = entry.relay, side = entry.side }
    end
  end
  return nil
end
local function cfgOutput(name)
  local cs = cfg.outputs
  if type(cs) == "table" and type(cs[name]) == "table" then
    local entry = cs[name]
    if type(entry.relay) == "string" and type(entry.side) == "string" then
      return { relay = entry.relay, side = entry.side }
    end
  end
  return nil
end
local CHANNELS = {
  forward  = cfgChannel("forward",  { relay = "redstone_relay_0", side = "back"  }),
  back     = cfgChannel("back",     { relay = "redstone_relay_0", side = "top"   }),
  left     = cfgChannel("left",     { relay = "redstone_relay_0", side = "left"  }),
  right    = cfgChannel("right",    { relay = "redstone_relay_0", side = "right" }),
  liftUp   = cfgChannel("liftUp",   { relay = "redstone_relay_1", side = "right" }),
  liftDown = cfgChannel("liftDown", { relay = "redstone_relay_1", side = "left"  }),
}

-- User-defined redstone toggles surfaced as tappable rows on the Controls
-- screen. Each entry registers a channel into CHANNELS under its `name` so
-- setControl(name, on) works. `inverted` means active = LOW (e.g. a platform
-- that lowers when redstone power is removed). `mode` is reserved for a
-- future "pulse" type; only "toggle" is implemented today.
local DEFAULT_CUSTOM_CONTROLS = {
  { name = "Platform", relay = "redstone_relay_6", side = "back",
    mode = "toggle", inverted = true,
    activeLabel = "LOWERING", inactiveLabel = "RAISED", activeColor = "orange" },
}
local CUSTOM_CONTROLS = {}
do
  -- Absent key -> defaults. Explicit empty array -> respect it (user wants no controls).
  local src = (type(cfg.customControls) == "table") and cfg.customControls or DEFAULT_CUSTOM_CONTROLS
  for _, e in ipairs(src) do
    if type(e) == "table" and type(e.name) == "string"
       and type(e.relay) == "string" and type(e.side) == "string" then
      CHANNELS[e.name] = { relay = e.relay, side = e.side }
      CUSTOM_CONTROLS[#CUSTOM_CONTROLS + 1] = {
        name          = e.name,
        mode          = (e.mode == "pulse") and "pulse" or "toggle",
        inverted      = (e.inverted == true),
        activeLabel   = tostring(e.activeLabel or "ON"),
        inactiveLabel = tostring(e.inactiveLabel or "OFF"),
        activeColor   = tostring(e.activeColor or "orange"),
      }
    end
  end
end
local INPUTS = {
  liftLevel = cfgInput("liftLevel"),
}
local OUTPUTS = {
  lift = cfgOutput("lift"),
}
local LIFT_MODE = (cfg.liftMode == "direct") and "direct" or "burner"
local USE_ALTIMETER = (cfg.useAltimeter ~= false)
local USE_VELOCITY_SENSOR = (cfg.useVelocitySensor ~= false)

local relayCache = {}
local function wrapRelay(name)
  if not name then return nil end
  if relayCache[name] then return relayCache[name] end
  local ok, r = pcall(peripheral.wrap, name)
  if ok and r then relayCache[name] = r end
  return relayCache[name]
end

-- Lift driver: pulse-based burner mode (default) is what the original CCMinimap
-- rig uses (liftUp/liftDown pulse channels + liftLevel analog feedback). The
-- module is shared with Spruce, which uses a direct-output variant for cheap
-- drones. minimap.lua talks to it through commandLevel/currentLevel/idle.
-- Pocket has no relays so it skips the load entirely.
local Lift
local Altitude
local Cfg  -- only used on the ship for Settings -> cfg writeback
if not IS_POCKET then
  Lift = dofile("lift.lua")
  Altitude = dofile("altitude.lua")
  Cfg = dofile("cfgutil.lua")
  Lift.init({
    mode = LIFT_MODE,
    channels = CHANNELS,
    inputs = INPUTS,
    outputs = OUTPUTS,
    pulseSeconds = tonumber(cfg.liftPulseSeconds) or 0.2,
  })
end

local altSensor = peripheral.find("altitude_sensor")
local velSensor = peripheral.find("velocity_sensor")

-- Modem for ship<->pocket rednet. Must be a WIRELESS (or ender) modem -- a
-- wired modem with `isWireless()=false` would happily open but never reach the
-- pocket. The ship often has both kinds attached (wired for the relay
-- network, wireless for control), so filter explicitly.
local modemName
do
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m and type(m.isWireless) == "function" and m.isWireless() then
        if not rednet.isOpen(name) then pcall(rednet.open, name) end
        modemName = name
        break
      end
    end
  end
end
local SHIP_HOSTNAME = SHIP_HOST .. "-" .. AIRSHIP_NAME
if modemName and not IS_POCKET then
  pcall(rednet.host, SHIP_PROTO, SHIP_HOSTNAME)
end

local SHOW_ALT_TAPE   = (cfg.showAltitudeTape ~= false)
local SHOW_SPEED_DIAL = (cfg.showSpeedDial ~= false)
local MAX_ALT   = tonumber(cfg.maxAltitude) or 320
local MAX_SPEED = tonumber(cfg.maxSpeed) or 5
local GROUND_CHUNK_RADIUS = math.floor(tonumber(cfg.groundSampleChunkRadius) or 1)
local VELOCITY_FLIPPED = (cfg.velocityFlipped ~= false)
local CRUISE_ALT_AGL    = tonumber(cfg.cruiseAltitudeAboveGround) or 50
local MIN_ALT_AGL       = tonumber(cfg.minAltitudeAboveGround) or 20
-- AGL held when following a player target. Defaults to MIN_ALT_AGL so the
-- ship hovers low enough to see the player; tunable on the settings screen.
local FOLLOW_ALT_AGL    = tonumber(cfg.followAltitudeAboveGround) or MIN_ALT_AGL
local HOVER_BURNER      = tonumber(cfg.hoverBurnerLevel) or 7
-- Floor on the PID-commanded burner level. The pure [0,15] clamp lets the
-- controller drop the burner to 0 when asking for descent, which on heavier
-- builds means free-fall rather than a controlled glide. Setting this to a
-- small positive value (e.g. 3-5) keeps a baseline lift so descent is gentle.
local MIN_BURNER        = tonumber(cfg.minBurnerLevel) or 0
local LAND_BURNER       = tonumber(cfg.landBurnerLevel) or 3
local LIFT_KP           = tonumber(cfg.liftKp) or 0.4
local LIFT_KD           = tonumber(cfg.liftKd) or 1.2
local LIFT_KI           = tonumber(cfg.liftKi) or 0.05
local LIFT_I_MAX        = 8       -- |integrator| cap to bound anti-windup error
local CLIMB_STUCK_S     = 3       -- seconds saturated-at-15 before surfacing CLIMB MAX
local LAND_RAMP_S       = tonumber(cfg.landRampSeconds) or 2.0
local CLIMB_DONE_MARGIN = 5    -- blocks below cruise that count as "arrived at cruise"
local RECOVER_MARGIN    = 10   -- exit STOP_AND_RISE this many blocks above MIN_ALT_AGL
local LANDED_ALT_MARGIN = 2    -- |alt - groundY| < this and |vy| small = landed
local LANDED_VY_THRESH  = 0.1
local NEEDLE_AREA_W = 2 * math.ceil(NEEDLE_LENGTH_SUB / SUB_W) + 1
local NEEDLE_AREA_H = 2 * math.ceil(NEEDLE_LENGTH_SUB / SUB_H) + 1

local SETTINGS = {
  { name = "Cruise AGL", cfgKey = "cruiseAltitudeAboveGround", get = function() return CRUISE_ALT_AGL end, set = function(v) CRUISE_ALT_AGL = v end, step = 5,  min = 10,  max = 200 },
  { name = "Min AGL",    cfgKey = "minAltitudeAboveGround",    get = function() return MIN_ALT_AGL end,    set = function(v) MIN_ALT_AGL = v end,    step = 5,  min = 5,   max = 100 },
  { name = "Follow AGL", cfgKey = "followAltitudeAboveGround", get = function() return FOLLOW_ALT_AGL end, set = function(v) FOLLOW_ALT_AGL = v end, step = 5,  min = 5,   max = 200 },
  { name = "Hover Brn",  cfgKey = "hoverBurnerLevel",          get = function() return HOVER_BURNER end,   set = function(v) HOVER_BURNER = v end,   step = 1,  min = 0,   max = 15  },
  { name = "Max Speed",  cfgKey = "maxSpeed",                  get = function() return MAX_SPEED end,      set = function(v) MAX_SPEED = v end,      step = 1,  min = 1,   max = 20  },
  { name = "Max Alt",    cfgKey = "maxAltitude",               get = function() return MAX_ALT end,        set = function(v) MAX_ALT = v end,        step = 10, min = 64,  max = 320 },
}

-- Last-persisted snapshot for the Cancel button. Captured at boot from the
-- cfg-loaded values; refreshed on every successful Save.
local SETTINGS_SAVED = {}
local function captureSettingsSaved()
  for i, s in ipairs(SETTINGS) do SETTINGS_SAVED[i] = s.get() end
end
captureSettingsSaved()

local function settingsDirty()
  for i, s in ipairs(SETTINGS) do
    if s.get() ~= SETTINGS_SAVED[i] then return true end
  end
  return false
end

-- Ship-side: write current SETTINGS values back to the cfg file via cfgutil.
-- Pocket never reaches this path (setting_save is forwarded to the ship).
local function saveSettings()
  if IS_POCKET then return false end
  for _, s in ipairs(SETTINGS) do cfg[s.cfgKey] = s.get() end
  local f = fs.open(CONFIG_FILE, "w")
  if not f then return false end
  f.write(Cfg.jsonPretty(cfg) .. "\n")
  f.close()
  captureSettingsSaved()
  return true
end

local function cancelSettings()
  for i, s in ipairs(SETTINGS) do
    if SETTINGS_SAVED[i] ~= nil then s.set(SETTINGS_SAVED[i]) end
  end
end

-- Bitmap font for callsigns drawn next to player markers. 3x3-Mono is the
-- smallest font in the morefonts pack (4x3 sub-pixels per glyph); a 3-char
-- callsign fits in ~6-7 cells x 1 row -- same vertical footprint as the old
-- name-as-text label but narrower. Off-pixels in each touched cell still take
-- the chosen bg colour (no terrain transparency), so the label still appears
-- against a black panel -- just a smaller panel than before.
local mf, callsignFont
do
  local ok, m = pcall(dofile, "morefonts.lua")
  if ok and type(m) == "table" then
    mf = m
    local ok2, font = pcall(mf.loadFont, "fonts/3x3-Mono")
    if ok2 then callsignFont = font end
  end
end

local function callsign(name)
  return (name or "?"):sub(1, 3):upper()
end

-- 2-cell rounded blob for player markers; cells fully replaced with color+black.
local PLAYER_MARKER = { 0x2E, 0x1D }

-- Hollow circle, 2 cells wide -- same footprint as PLAYER_MARKER but outlined.
local WAYPOINT_MARKER = { 0x26, 0x19 }

-- Autopilot tunables.
local ARRIVAL_RADIUS = 15      -- blocks; stop when within this of target
local FOLLOW_LEAVE_RADIUS = 30 -- blocks; in FOLLOW phase, range above this resumes pursuit (hysteresis vs ARRIVAL_RADIUS)
local TURN_THRESHOLD = 20      -- degrees; |err| above this = pure turn, no forward
local FINE_THRESHOLD = 5       -- degrees; |err| above this = forward + correction
local TRAIL_STEP = 2           -- plot a trail dot every N cells from ship to target

local NAV_TYPES   = { "navigation_table", "ship_navigation_table", "compass" }
local NAV_METHODS = { "getRelativeAngle", "getYaw", "getRotationYaw", "getRotation" }
-- Edit minimap.cfg to tune (headingOffset, needleLength).
local HEADING_OFFSET_DEG = tonumber(cfg.headingOffset) or 0

local state = {
  bpp = 2,
  lod = 1,
  shipHeading = 0,
  target = nil,         -- { kind, name, x, z, color } - selected destination
  engaged = false,      -- autopilot driving controls?
  autoStatus = "",      -- short status string for the auto bar
  controls = {},        -- intended redstone state per channel; pending hardware
  targetCells = {},     -- list of clickable target hitboxes built each frame
  altitude = nil, pressure = nil, velocity = nil,
  vy = nil,             -- vertical velocity (m/s), derived from altitude finite-diff
  lastAltSample = nil,  -- { t, alt } feeding the finite-diff
  burnerLevel = nil,    -- 0-15, from inputs.liftLevel analog read
  phase = nil,          -- nil | CLIMB_TO_CRUISE | CRUISE | LAND
  altHoldActive = false,
  altHoldTarget = nil,
  aglHoldActive = false,
  aglHoldOffset = nil,  -- locked AGL offset (m above current groundY)
  altStep = 1,          -- step size for controls-screen +/- (cycles 1/5/10)
  burnerTarget = nil,   -- manual setpoint from CLI; controller ramps to it, then clears
  landRampStart = nil,      -- os.clock() when LAND phase began
  landRampStartLevel = nil, -- burner level snapshot at LAND entry
  liftIntegral = 0,         -- accumulated burner offset to correct altitude-dependent equilibrium
  liftLastTick = nil,       -- os.clock() at last PID tick (for integrator dt)
  liftSaturatedSince = nil, -- os.clock() when PID first wanted >15 with vy~0 and err>0
  groundY = nil,        -- max surface Y in sampled chunk window (from BlueMap)
  groundYMin = nil,     -- min surface Y in same window
  lastTapeCells = {},   -- cell keys we lit last tape draw, restored next frame
  lastTapeAlt = nil,    -- altitude value last drawn on tape (for skip-if-unchanged)
  lastTapeGround = nil, -- ground value last drawn on tape
  lastBurnerLevel = nil,-- burner level last drawn on tape marker
  shipId = nil,         -- pocket: rednet id of the ship after lookup
  lastUpdateAt = 0,     -- pocket: os.clock() when last state broadcast received
  lastDialCells = {},   -- same idea for the speedometer needle
  screen = "map",
  wpScroll = 0,
  settingIdx = 1,
  pinLock = false,     -- when true, map taps don't drop a pin (prevents fat-finger overwrite of current target)
  customControls = {}, -- map: custom control name -> active bool
  status = "starting",
  running = true,
  players = {},
  waypoints = {},
  sidecarAt = 0,
  -- Tile grid: world-aligned tiles keyed "i,j", each holds one server frame.
  -- 3x3 around screen center is fetched/refreshed; the draw path composes the
  -- visible view from whichever tiles are loaded. Pan never shows white edges
  -- as long as the relevant tile is cached.
  tiles = {},
  hasMap = false,    -- becomes true on first successful tile fetch
  tileBpp = nil,     -- bpp/lod/w/h captured when current grid was rendered;
  tileLod = nil,     -- mismatch with current values invalidates the grid.
  tileW = nil,
  tileH = nil,
  -- Tile (0, 0) is centered on (tileOriginX, tileOriginZ). The origin is
  -- re-anchored to the current viewport centre whenever the grid is wiped
  -- (zoom/resize) so the user's view fits inside the centre tile right after
  -- zoom; without this, ship near a world-tile edge would see a partial
  -- viewport until neighbours load.
  tileOriginX = 0,
  tileOriginZ = 0,
  lastPos = nil,
  lastError = nil,
  mapOffsetX = 0,   -- world-unit pan offset from ship position
  mapOffsetZ = 0,
  dragPrevX = nil,  -- last touch/drag cell for delta computation
  dragPrevY = nil,
  dragPrevTime = 0,
  isDragging = false,
  pendingMapTap = nil,   -- {x,y} of first monitor_touch in map area, pending drag/tap disambiguation
  pendingTapTimer = nil, -- timer id for committing the pending tap
}
local buttons = {}

local function findMonitor()
  local m = peripheral.find("monitor")
  if m then return m end
  return term.current()
end

local monitor = findMonitor()
if monitor.setTextScale then monitor.setTextScale(0.5) end
local width, height = monitor.getSize()
local unpackValues = table.unpack or unpack

-- The pocket has a tight 26x20 screen, so its OSD uses two rows: buttons on
-- height-1, coord/status on height. The ship's monitor keeps the one-row OSD.
local function mapHeight()
  return math.max(3, height - (IS_POCKET and 2 or 1))
end

local function isStale()
  return IS_POCKET and (os.clock() - (state.lastUpdateAt or 0)) > STATE_STALE_AFTER
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function pickLod(bpp)
  if bpp <= 4 then return 1 end
  if bpp <= 24 then return 2 end
  return 3
end

local function urlencode(value)
  return tostring(value):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

local function httpGetJson(url)
  local r, err = http.get(url, { ["accept"] = "application/json" })
  if not r then return nil, err end
  local body = r.readAll()
  r.close()
  return textutils.unserializeJSON(body), nil
end

-- Find nav peripheral by type then by method scan; mirrors how peripheral.find("speaker") works.
local function discoverNav()
  if NAV_PERIPHERAL then
    local p = peripheral.wrap(NAV_PERIPHERAL)
    if p then
      local m = NAV_METHOD
      if m and type(p[m]) == "function" then return p, m end
      for _, mm in ipairs(NAV_METHODS) do
        if type(p[mm]) == "function" then return p, mm end
      end
    end
  end
  for _, t in ipairs(NAV_TYPES) do
    local p = peripheral.find(t)
    if p then
      for _, m in ipairs(NAV_METHODS) do
        if type(p[m]) == "function" then return p, m end
      end
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p then
      for _, m in ipairs(NAV_METHODS) do
        if type(p[m]) == "function" then return p, m end
      end
    end
  end
  return nil, nil
end

local nav, navMethod = discoverNav()

local function readHeading()
  if not nav then return nil end
  local ok, result = pcall(nav[navMethod], nav)
  if not ok or result == nil then return nil end
  local rel
  if type(result) == "number" then rel = result
  elseif type(result) == "table" then rel = result.yaw or result.heading or result[1]
  end
  if not rel then return nil end
  -- Compass needle points at spawn (0, 0, 0). The peripheral returns its angle
  -- relative to ship-forward (CW degrees). Ship heading = world bearing to
  -- spawn minus that relative angle. Atan2 args use MC convention (X=east,
  -- Z=south, heading 0 = -Z = north, CW positive).
  if not state.lastPos then return nil end
  local sx, sz = state.lastPos.x, state.lastPos.z
  local bearingToSpawn = math.deg(math.atan2(-sx, sz))
  return (bearingToSpawn - rel + HEADING_OFFSET_DEG) % 360
end

local function applyPalette(palette)
  if not palette then return end
  for i = 1, math.min(#palette, 16) do
    local n = tonumber(palette[i], 16)
    if n then monitor.setPaletteColor(2 ^ (i - 1), n) end
  end
end

local info = httpGetJson(SERVER .. "/info")
if info and info.palette then applyPalette(info.palette) end

local function buildUrl(x, z)
  return SERVER .. "/frame?" .. table.concat({
    "x=" .. urlencode(math.floor(x * 10) / 10),
    "z=" .. urlencode(math.floor(z * 10) / 10),
    "w=" .. urlencode(width),
    "h=" .. urlencode(mapHeight()),
    "bpp=" .. urlencode(state.bpp),
    "lod=" .. urlencode(state.lod),
  }, "&")
end

local function decodeTextRow(packed)
  local out = {}
  for i = 1, #packed do
    out[i] = string.char(string.byte(packed, i) + 0x40)
  end
  return table.concat(out)
end

-- Pan-adjusted map centre. All tile fetches and overlay calls use this so
-- panning shifts both tiles and overlays together.
local function mapCenter()
  if not state.lastPos then return 0, 0 end
  return state.lastPos.x + (state.mapOffsetX or 0),
         state.lastPos.z + (state.mapOffsetZ or 0)
end

-- Tile grid helpers. The world is partitioned into width*mapH-cell tiles
-- aligned to the world origin; tile (i, j) covers world rect centered on
-- (i*tileWB, j*tileHB). Fetch URL uses that center.
local function tileKey(i, j) return i .. "," .. j end

local function tileWorldDim(mapH)
  local bX = state.bpp * SUB_W
  local bY = state.bpp * SUB_H
  return width * bX, mapH * bY, bX, bY
end

-- Cells in tile (i, j) have centres at (origin + i*tileWB) + (c - width/2)*bX
-- for c in [1, width]. Shift by half a cell so tile boundaries align with
-- the half-cell-offset cell grid (without this, boundary cells render as
-- black columns/rows). The origin is reset to the viewport centre on every
-- grid wipe (zoom/resize), so the user's current view sits inside tile (0,0).
local function tileIndexForWorld(wx, wz, mapH)
  local tileWB, tileHB, bX, bY = tileWorldDim(mapH)
  local ox = state.tileOriginX or 0
  local oz = state.tileOriginZ or 0
  return math.floor((wx - ox + (tileWB - bX) / 2) / tileWB),
         math.floor((wz - oz + (tileHB - bY) / 2) / tileHB)
end

-- Returns (packed_byte, fg_char, bg_char) for the cell at screen (col, row),
-- or nil if the relevant tile isn't loaded yet. Used by overlays that need
-- to read terrain underneath a stencil.
local function getCell(col, row, mapH, mcx, mcz)
  local bX = state.bpp * SUB_W
  local bY = state.bpp * SUB_H
  local tileWB = width * bX
  local tileHB = mapH * bY
  local wx = mcx + (col - width / 2) * bX
  local wz = mcz + (row - mapH / 2) * bY
  local ox = state.tileOriginX or 0
  local oz = state.tileOriginZ or 0
  local ti = math.floor((wx - ox + (tileWB - bX) / 2) / tileWB)
  local tj = math.floor((wz - oz + (tileHB - bY) / 2) / tileHB)
  local tile = state.tiles[tileKey(ti, tj)]
  if not tile then return nil end
  local tc = math.floor((wx - ox - ti * tileWB) / bX + width / 2 + 0.5)
  local tr = math.floor((wz - oz - tj * tileHB) / bY + mapH / 2 + 0.5)
  local row_text = tile.text[tr]
  if not row_text or tc < 1 or tc > #row_text then return nil end
  return string.byte(row_text, tc), tile.fg[tr]:sub(tc, tc), tile.bg[tr]:sub(tc, tc)
end

-- Packed byte 0x40 = pattern 0 (no fg subpixels lit). With bg='f' (black)
-- and fg='f', the cell renders solid black — used for "no tile loaded yet"
-- regions during pan or first boot.
local EMPTY_PACKED = string.char(0x40)
local EMPTY_FG     = "f"
local EMPTY_BG     = "f"

local function drawCachedMap(mapH)
  if not state.hasMap or not state.lastPos then return end
  local mcx, mcz = mapCenter()
  local bX = state.bpp * SUB_W
  local bY = state.bpp * SUB_H
  local tileWB = width * bX
  local tileHB = mapH * bY
  local halfDxX = (tileWB - bX) / 2
  local halfDxY = (tileHB - bY) / 2
  local ox = state.tileOriginX or 0
  local oz = state.tileOriginZ or 0
  for r = 1, mapH do
    local wz = mcz + (r - mapH / 2) * bY
    local tj = math.floor((wz - oz + halfDxY) / tileHB)
    local tr = math.floor((wz - oz - tj * tileHB) / bY + mapH / 2 + 0.5)
    local textRow, fgRow, bgRow = {}, {}, {}
    for c = 1, width do
      local wx = mcx + (c - width / 2) * bX
      local ti = math.floor((wx - ox + halfDxX) / tileWB)
      local tile = state.tiles[tileKey(ti, tj)]
      local row_text = tile and tile.text[tr]
      if row_text then
        local tc = math.floor((wx - ox - ti * tileWB) / bX + width / 2 + 0.5)
        if tc >= 1 and tc <= #row_text then
          textRow[c] = row_text:sub(tc, tc)
          fgRow[c]   = tile.fg[tr]:sub(tc, tc)
          bgRow[c]   = tile.bg[tr]:sub(tc, tc)
        else
          textRow[c], fgRow[c], bgRow[c] = EMPTY_PACKED, EMPTY_FG, EMPTY_BG
        end
      else
        textRow[c], fgRow[c], bgRow[c] = EMPTY_PACKED, EMPTY_FG, EMPTY_BG
      end
    end
    monitor.setCursorPos(1, r)
    monitor.blit(decodeTextRow(table.concat(textRow)),
                 table.concat(fgRow), table.concat(bgRow))
  end
end

local function worldToCell(wx, wz, cx, cz, mapH)
  local bX = state.bpp * SUB_W
  local bY = state.bpp * SUB_H
  local col = math.floor((wx - cx) / bX + width / 2 + 0.5)
  local row = math.floor((wz - cz) / bY + mapH / 2 + 0.5)
  return col, row
end

-- Inverse of worldToCell: screen cell → approximate world coordinate.
local function cellToWorld(col, row, cx, cz, mapH)
  local bX = state.bpp * SUB_W
  local bY = state.bpp * SUB_H
  local wx = (col - width  / 2) * bX + cx
  local wz = (row - mapH / 2) * bY + cz
  return wx, wz
end

-- (directionForHeading was only used by the stencil arrow; the needle uses the
-- raw heading directly.)

-- Convert MC yaw (0=S) to compass heading (0=N)
local function compassFromMcYaw(yaw)
  return ((yaw or 0) + 180) % 360
end

local function overlayCell(col, row, stenBits, color, mapH, override)
  if col < 1 or col > width or row < 1 or row > mapH then return end
  local mcx, mcz = mapCenter()
  local packed_byte, cell_fg, cell_bg = getCell(col, row, mapH, mcx, mcz)
  if not packed_byte then return end
  local cell_pattern = packed_byte - 0x40
  local new_pattern, new_fg, new_bg
  if stenBits == 0 then
    -- nothing to draw here; re-blit original cell
    new_pattern, new_fg, new_bg = cell_pattern, cell_fg, cell_bg
  elseif override then
    -- replace fg pattern with stencil; keep bg color so it blends with terrain
    new_pattern = stenBits
    new_fg, new_bg = color, cell_bg
  else
    -- OR stencil into existing pattern; both terrain-fg and stencil pixels recolored
    new_pattern = bit32.bor(cell_pattern, stenBits)
    new_fg, new_bg = color, cell_bg
  end
  if bit32.band(new_pattern, 0x20) ~= 0 then
    new_pattern = bit32.bxor(new_pattern, 0x3F)
    new_fg, new_bg = new_bg, new_fg
  end
  monitor.setCursorPos(col, row)
  monitor.blit(string.char(new_pattern + 0x80), new_fg, new_bg)
end

local function overlaySelfTriangle(heading, mapH, cx, cz)
  local rad = math.rad(heading or 0)
  local dx = math.sin(rad)
  local dy = -math.cos(rad)  -- compass 0 = N = up = -Y on screen

  -- When panned, ship is no longer at screen center; compute its actual cell.
  local centerCol, centerRow
  if state.lastPos and cx ~= nil then
    centerCol, centerRow = worldToCell(state.lastPos.x, state.lastPos.z, cx, cz, mapH)
  else
    centerCol = math.floor(width / 2 + 0.5)
    centerRow = math.floor(mapH / 2 + 0.5)
  end
  -- Don't draw if ship is scrolled off-screen.
  if centerCol < 1 or centerCol > width or centerRow < 1 or centerRow > mapH then return end
  local centerSubX = (centerCol - 1) * SUB_W + (SUB_W - 1) / 2
  local centerSubY = (centerRow - 1) * SUB_H + (SUB_H - 1) / 2

  local function lightSub(map, sxR, syR)
    local col = math.floor(sxR / SUB_W) + 1
    local row = math.floor(syR / SUB_H) + 1
    local sx = sxR - (col - 1) * SUB_W
    local sy = syR - (row - 1) * SUB_H
    if sx >= 0 and sx < SUB_W and sy >= 0 and sy < SUB_H then
      local key = col * 1024 + row
      map[key] = bit32.bor(map[key] or 0, bit32.lshift(1, sy * SUB_W + sx))
    end
  end

  -- Walk the needle in fine steps, mark each sub-pixel into a per-cell bitmap.
  local needleCells = {}
  local steps = NEEDLE_LENGTH_SUB * 5
  for i = 0, steps do
    local t = i / steps
    local sxR = math.floor(centerSubX + dx * NEEDLE_LENGTH_SUB * t + 0.5)
    local syR = math.floor(centerSubY + dy * NEEDLE_LENGTH_SUB * t + 0.5)
    lightSub(needleCells, sxR, syR)
  end

  -- Dark base mark at the needle root. Snap to 8 octants so cardinals get a
  -- 3-px cross (perp + behind) and diagonals get a 2-px L (one orthogonal
  -- pixel behind the base + one diagonally adjacent further behind it).
  local baseSxR = math.floor(centerSubX + 0.5)
  local baseSyR = math.floor(centerSubY + 0.5)
  local octant = math.floor(((((heading or 0) % 360) + 22.5) % 360) / 45)
  local crossOffsets
  if     octant == 0 then crossOffsets = { {-1, 0}, {1, 0}, {0, 1} }   -- N
  elseif octant == 2 then crossOffsets = { {0, -1}, {0, 1}, {-1, 0} }  -- E
  elseif octant == 4 then crossOffsets = { {-1, 0}, {1, 0}, {0, -1} }  -- S
  elseif octant == 6 then crossOffsets = { {0, -1}, {0, 1}, {1, 0} }   -- W
  elseif octant == 1 then crossOffsets = { {-1, 0}, {-1, 1} }          -- NE
  elseif octant == 3 then crossOffsets = { {-1, 0}, {-1, -1} }         -- SE
  elseif octant == 5 then crossOffsets = { {1, 0}, {1, -1} }           -- SW
  else                    crossOffsets = { {1, 0}, {1, 1} }            -- NW
  end
  local baseCells = {}
  for _, o in ipairs(crossOffsets) do
    lightSub(baseCells, baseSxR + o[1], baseSyR + o[2])
  end

  -- Re-blit each cell in the marker area. Cases:
  --   needle bits AND base bits  -> FG=red, BG=dark. Cell loses terrain bg
  --     and becomes a small anchor block, but base sub-pixels render as
  --     intended and the conflict on the centre cell is resolved.
  --   needle only -> red over the cached map cell bg
  --   base only   -> dark over the cached map cell bg
  --   neither     -> restore the cached cell
  local startCol = centerCol - math.floor(NEEDLE_AREA_W / 2)
  local startRow = centerRow - math.floor(NEEDLE_AREA_H / 2)
  for r = 0, NEEDLE_AREA_H - 1 do
    for c = 0, NEEDLE_AREA_W - 1 do
      local col = startCol + c
      local row = startRow + r
      local key = col * 1024 + row
      local redBits = needleCells[key] or 0
      local darkBits = bit32.band(baseCells[key] or 0, bit32.bnot(redBits))
      if redBits ~= 0 and darkBits ~= 0 then
        -- drawMarkerCell is defined lower in the file; inline its body.
        if col >= 1 and col <= width and row >= 1 and row <= mapH then
          local pattern, fg, bg = redBits, "2", "7"
          if bit32.band(pattern, 0x20) ~= 0 then
            pattern = bit32.bxor(pattern, 0x3F)
            fg, bg = bg, fg
          end
          monitor.setCursorPos(col, row)
          monitor.blit(string.char(pattern + 0x80), fg, bg)
        end
      elseif redBits ~= 0 then
        overlayCell(col, row, redBits, "2", mapH, true)
      elseif darkBits ~= 0 then
        overlayCell(col, row, darkBits, "7", mapH, true)
      else
        overlayCell(col, row, 0, "0", mapH, true)
      end
    end
  end
end

-- Fully replace a single cell with a teletext pattern using forced fg/bg (no terrain preservation).
local function drawMarkerCell(col, row, pattern, fg, bg, mapH)
  if col < 1 or col > width or row < 1 or row > mapH then return end
  if bit32.band(pattern, 0x20) ~= 0 then
    pattern = bit32.bxor(pattern, 0x3F)
    fg, bg = bg, fg
  end
  monitor.setCursorPos(col, row)
  monitor.blit(string.char(pattern + 0x80), fg, bg)
end

local PLAYER_HEX_SLOTS = { "0", "1", "2", "3", "4", "d" }
local function colorForPlayer(key)
  local sum = 0
  for i = 1, #key do sum = sum + string.byte(key, i) end
  return PLAYER_HEX_SLOTS[(sum % #PLAYER_HEX_SLOTS) + 1]
end

local function isSelected(kind, name)
  return state.target and state.target.kind == kind and state.target.name == name
end

local function overlayOtherPlayers(cx, cz, mapH)
  for _, p in ipairs(state.players or {}) do
    if p.name ~= PLAYER_NAME and p.position then
      local col, row = worldToCell(p.position.x, p.position.z, cx, cz, mapH)
      local color = colorForPlayer(p.uuid or p.name or "?")
      local fg, bg = color, "f"
      if isSelected("player", p.name) then fg, bg = "f", color end
      drawMarkerCell(col, row, PLAYER_MARKER[1], fg, bg, mapH)
      drawMarkerCell(col + 1, row, PLAYER_MARKER[2], fg, bg, mapH)
      table.insert(state.targetCells, {
        col1 = col, col2 = col + 1, row = row,
        kind = "player", name = p.name,
        x = p.position.x, z = p.position.z, color = color,
      })
    end
  end
end

local NAMED_HEX = {
  white="0", yellow="1", red="2", cyan="3", lightblue="3", lime="4",
  green="d", darkgreen="5", gray="8", lightgray="6", blue="9",
  brown="c", orange="e", black="f",
}
local function paletteHexFor(name)
  return NAMED_HEX[(name or ""):lower()] or "1"
end

local HEX_TO_COLOR = {
  ["0"]=colors.white,    ["1"]=colors.orange,    ["2"]=colors.magenta,
  ["3"]=colors.lightBlue,["4"]=colors.yellow,    ["5"]=colors.lime,
  ["6"]=colors.pink,     ["7"]=colors.gray,      ["8"]=colors.lightGray,
  ["9"]=colors.cyan,     ["a"]=colors.purple,    ["b"]=colors.blue,
  ["c"]=colors.brown,    ["d"]=colors.green,     ["e"]=colors.red,
  ["f"]=colors.black,
}

local function overlayWaypoints(cx, cz, mapH)
  for _, wp in ipairs(state.waypoints or {}) do
    if wp.x and wp.z then
      local col, row = worldToCell(wp.x, wp.z, cx, cz, mapH)
      local color = paletteHexFor(wp.color)
      local fg, bg = color, "f"
      if isSelected("waypoint", wp.name) then fg, bg = "f", color end
      drawMarkerCell(col, row, WAYPOINT_MARKER[1], fg, bg, mapH)
      drawMarkerCell(col + 1, row, WAYPOINT_MARKER[2], fg, bg, mapH)
      table.insert(state.targetCells, {
        col1 = col, col2 = col + 1, row = row,
        kind = "waypoint", name = wp.name,
        x = wp.x, z = wp.z, color = color,
      })
    end
  end
end

local function overlayMarkerLabels(cx, cz, mapH)
  -- Draw a 3-char callsign next to every visible player marker (mf path);
  -- fall back to the old 9-char ASCII label if morefonts didn't load.
  for _, p in ipairs(state.players or {}) do
    if p.name ~= PLAYER_NAME and p.position then
      local col, row = worldToCell(p.position.x, p.position.z, cx, cz, mapH)
      if row >= 1 and row <= mapH then
        local hexColor = colorForPlayer(p.uuid or p.name or "?")
        if mf and callsignFont then
          local tag = callsign(p.name)
          local subW = mf.calculateTextSize(tag, { font = callsignFont, condense = true })
          local cellW = math.max(1, math.ceil(subW / 2))
          local lx = col + 2
          if lx + cellW - 1 > width then lx = math.max(1, col - cellW - 1) end
          if lx >= 1 then
            monitor.setTextColor(HEX_TO_COLOR[hexColor] or colors.cyan)
            monitor.setBackgroundColor(colors.black)
            mf.writeOn(monitor, tag, lx, row, { font = callsignFont, condense = true })
          end
        else
          local name = p.name:sub(1, 9)
          local lx = col + 2
          if lx + #name - 1 > width then lx = math.max(1, col - #name - 1) end
          if lx >= 1 then
            monitor.setCursorPos(lx, row)
            monitor.setTextColor(HEX_TO_COLOR[hexColor] or colors.cyan)
            monitor.setBackgroundColor(colors.black)
            monitor.write(name:sub(1, math.max(0, width - lx + 1)))
          end
        end
      end
    end
  end
  -- Draw name next to the selected target (waypoint or player already covered above)
  if state.target and state.target.name and state.target.kind == "waypoint" then
    local col, row = worldToCell(state.target.x, state.target.z, cx, cz, mapH)
    if row >= 1 and row <= mapH then
      local name = state.target.name:sub(1, 10)
      local lx = col + 2
      if lx + #name - 1 > width then lx = math.max(1, col - #name - 1) end
      if lx >= 1 then
        monitor.setCursorPos(lx, row)
        monitor.setTextColor(HEX_TO_COLOR[state.target.color] or colors.yellow)
        monitor.setBackgroundColor(colors.black)
        monitor.write(name:sub(1, math.max(0, width - lx + 1)))
      end
    end
  end
end

local function overlayPin(cx, cz, mapH)
  if not state.target or state.target.kind ~= "pin" then return end
  local col, row = worldToCell(state.target.x, state.target.z, cx, cz, mapH)
  if row < 1 or row > mapH then return end
  local mc = math.max(1, math.min(width - 2, col))
  -- Draw [+] in orange as plain text over the blit map
  monitor.setCursorPos(mc, row)
  monitor.setTextColor(colors.orange)
  monitor.setBackgroundColor(colors.black)
  monitor.write(("[+]"):sub(1, width - mc + 1))
  -- Label to the right (or left if near edge)
  local name = (state.target.name or "Pin"):sub(1, 8)
  local lx = mc + 3
  if lx + #name - 1 > width then lx = math.max(1, mc - #name - 1) end
  if lx >= 1 and lx <= width then
    monitor.setCursorPos(lx, row)
    monitor.setTextColor(colors.orange)
    monitor.setBackgroundColor(colors.black)
    monitor.write(name:sub(1, width - lx + 1))
  end
end

local function overlayDotTrail(cx, cz, mapH)
  if not state.target then return end
  local tcol, trow = worldToCell(state.target.x, state.target.z, cx, cz, mapH)
  -- Ship's actual cell on the (potentially panned) map.
  local centerCol, centerRow
  if state.lastPos then
    centerCol, centerRow = worldToCell(state.lastPos.x, state.lastPos.z, cx, cz, mapH)
  else
    centerCol = math.floor(width / 2 + 0.5)
    centerRow = math.floor(mapH / 2 + 0.5)
  end
  local dxC = tcol - centerCol
  local dyC = trow - centerRow
  local steps = math.max(math.abs(dxC), math.abs(dyC))
  if steps < 2 then return end
  for i = TRAIL_STEP, steps - 1, TRAIL_STEP do
    local t = i / steps
    local c = math.floor(centerCol + dxC * t + 0.5)
    local r = math.floor(centerRow + dyC * t + 0.5)
    if c >= 1 and c <= width and r >= 1 and r <= mapH then
      overlayCell(c, r, 0x0C, state.target.color, mapH, true)
    end
  end
end

-- GPS altitude fallback. Computer y-position comes back coarse (often integer)
-- so the value gets EWMA-smoothed before being handed to the PID; otherwise the
-- D term chatters on the per-tick step changes.
local altEwma = nil
local function readAltitude()
  if not USE_ALTIMETER then
    if not state.lastPos or state.lastPos.y == nil then return state.altitude end
    altEwma = altEwma and (altEwma * 0.7 + state.lastPos.y * 0.3) or state.lastPos.y
    return altEwma
  end
  if not altSensor then return nil end
  local ok, h = pcall(altSensor.getHeight)
  if ok and type(h) == "number" then return h end
end
local function readPressure()
  if not altSensor then return nil end
  local ok, pr = pcall(altSensor.getAirPressure)
  if ok and type(pr) == "number" then return pr end
end

-- GPS velocity fallback: signed forward speed = horizontal position delta
-- projected onto the heading vector, sampled over a ~0.5s window and EWMA'd.
-- Magnitude-only would lose the negative half-circle of the speed dial.
local velSample, velEwma = nil, 0
local function readVelocity()
  if not USE_VELOCITY_SENSOR then
    if not state.lastPos then return state.velocity end
    local now = os.clock()
    if not velSample then
      velSample = { t = now, x = state.lastPos.x, z = state.lastPos.z }
      return 0
    end
    local dt = now - velSample.t
    if dt < 0.5 then return velEwma end
    local dx = state.lastPos.x - velSample.x
    local dz = state.lastPos.z - velSample.z
    -- MC compass: 0=N=-Z, 90=E=+X. Forward unit vector for heading h.
    local rad = math.rad(state.shipHeading or 0)
    local fwdX, fwdZ = math.sin(rad), -math.cos(rad)
    local signed = (dx * fwdX + dz * fwdZ) / dt
    velEwma = velEwma * 0.6 + signed * 0.4
    velSample = { t = now, x = state.lastPos.x, z = state.lastPos.z }
    return velEwma
  end
  if not velSensor then return nil end
  local ok, v = pcall(velSensor.getVelocity)
  if ok and type(v) == "number" then
    if VELOCITY_FLIPPED then v = -v end
    return v
  end
end

-- Altitude tape on the right edge. Zoned thermometer: white above ship, gray
-- between ship and ground, red below ground; black cursors at ship altitude
-- and ground level, numeric labels for each.
-- overlayAltitudeTape is forward-declared here so it can be referenced after
-- the do-block below.  All tape/burner constants and the two helper functions
-- (blitTapeCell, drawTapeLabel) live inside the do-block and become upvalues
-- of the closure -- this avoids 12 top-level local slots.
local overlayAltitudeTape
do
local TAPE_WIDTH = 3
local TAPE_PAD_RIGHT = 1
local TAPE_PAD_VERT  = 1
local TAPE_ABOVE  = "7"   -- dark gray (above ship altitude)
local TAPE_MID    = "8"   -- light gray (between ship and ground)
local TAPE_BELOW  = "e"   -- red/brick (below ground)
local TAPE_CURSOR = "f"   -- black (ship + ground tick)
local TAPE_LABEL_FG = "f" -- black numeric label text

-- Burner marker: 3 cells of yellow bg at the ship cursor row of the alt tape,
-- with the burner level (0-15) rendered as a centered 2-digit decimal.
local BURNER_MARKER_BG  = "4"  -- yellow
local BURNER_MARKER_FG  = "f"  -- black digits

local function blitTapeCell(col, row, pattern, fg, bg)
  monitor.setCursorPos(col, row)
  local emit = pattern
  local f, b = fg, bg
  if bit32.band(emit, 0x20) ~= 0 then
    emit = bit32.bxor(emit, 0x3F)
    f, b = b, f
  end
  monitor.blit(string.char(emit + 0x80), f, b)
end

local function drawTapeLabel(text, row, anchorCol, bg, fg)
  local startCol = anchorCol - #text + 1
  for i = 1, #text do
    local c = startCol + i - 1
    if c >= 1 and c <= width then
      monitor.setCursorPos(c, row)
      monitor.blit(text:sub(i, i), fg, bg)
      state.lastTapeCells[c * 1024 + row] = true
    end
  end
end

overlayAltitudeTape = function(mapH)
  -- Skip-if-unchanged: tape depends on altitude, groundY, and the burner marker.
  if SHOW_ALT_TAPE and state.altitude
      and state.altitude == state.lastTapeAlt
      and state.groundY == state.lastTapeGround
      and state.burnerLevel == state.lastBurnerLevel then
    return
  end
  for key in pairs(state.lastTapeCells) do
    local c = math.floor(key / 1024)
    local r = key - c * 1024
    overlayCell(c, r, 0, "0", mapH, true)
  end
  state.lastTapeCells = {}
  state.lastTapeAlt = nil
  state.lastTapeGround = nil
  state.lastBurnerLevel = nil
  if not SHOW_ALT_TAPE or not state.altitude then return end
  local topRow = 1 + TAPE_PAD_VERT
  local botRow = mapH - TAPE_PAD_VERT
  if botRow < topRow then return end
  local height_rows = botRow - topRow + 1
  local cols = {}
  for i = 1, TAPE_WIDTH do cols[i] = width - TAPE_PAD_RIGHT - TAPE_WIDTH + i end
  local maxSubY = height_rows * SUB_H - 1

  local altRatio = math.max(0, math.min(1, state.altitude / MAX_ALT))
  local altSubY = math.floor((1 - altRatio) * maxSubY + 0.5)
  local groundSubY = nil
  if state.groundY then
    local gr = math.max(0, math.min(1, state.groundY / MAX_ALT))
    groundSubY = math.floor((1 - gr) * maxSubY + 0.5)
  end

  -- Classify each sub-pixel into a color, then pick best 2-color blit per cell.
  local function subColor(globalSubY)
    if globalSubY == altSubY then return TAPE_CURSOR end
    if groundSubY and globalSubY == groundSubY then return TAPE_CURSOR end
    if globalSubY < altSubY then return TAPE_ABOVE end
    if groundSubY and globalSubY > groundSubY then return TAPE_BELOW end
    return TAPE_MID
  end

  -- When a burner reading is available, the cell-row containing the ship
  -- cursor is replaced with a yellow marker spelling out the burner level
  -- (so the ship cursor doubles as the burner indicator).
  local altRow = 1 + TAPE_PAD_VERT + math.floor(altSubY / SUB_H)
  local markerText
  if state.burnerLevel then
    markerText = string.format(" %2d", state.burnerLevel):sub(1, TAPE_WIDTH)
  end

  for r = topRow, botRow do
    if markerText and r == altRow then
      for i, c in ipairs(cols) do
        local ch = markerText:sub(i, i)
        if ch == "" then ch = " " end
        monitor.setCursorPos(c, r)
        monitor.blit(ch, BURNER_MARKER_FG, BURNER_MARKER_BG)
        state.lastTapeCells[c * 1024 + r] = true
      end
    else
      local rowTopSubY = (r - topRow) * SUB_H
      local subs = {}
      local counts = {}
      for sy = 0, SUB_H - 1 do
        for sx = 0, SUB_W - 1 do
          local color = subColor(rowTopSubY + sy)
          subs[sy * SUB_W + sx] = color
          counts[color] = (counts[color] or 0) + 1
        end
      end
      -- Pick top-two colors by count; cursor color always wins over its zone.
      local ranked = {}
      for color in pairs(counts) do ranked[#ranked + 1] = color end
      table.sort(ranked, function(a, b) return counts[a] > counts[b] end)
      local bg = ranked[1]
      local fg = ranked[2] or bg
      if bg == TAPE_CURSOR and fg ~= TAPE_CURSOR then bg, fg = fg, bg end
      local pattern = 0
      for i = 0, SUB_W * SUB_H - 1 do
        if subs[i] == fg and fg ~= bg then
          pattern = bit32.bor(pattern, bit32.lshift(1, i))
        end
      end
      for _, c in ipairs(cols) do
        blitTapeCell(c, r, pattern, fg, bg)
        state.lastTapeCells[c * 1024 + r] = true
      end
    end
  end

  -- Numeric labels: altitude near the ship row, ground near the ground row.
  -- Label bg = the cell's "above-cursor" zone color so it blends naturally.
  local labelAnchor = cols[1] - 2 -- one-col gap before tape
  local function labelRow(subY)
    return topRow + math.floor(subY / SUB_H)
  end
  drawTapeLabel(tostring(math.floor(state.altitude + 0.5)), altRow, labelAnchor, TAPE_MID, TAPE_LABEL_FG)
  if groundSubY and state.groundY then
    local groundRow = labelRow(groundSubY)
    if groundRow ~= altRow then
      drawTapeLabel(tostring(state.groundY), groundRow, labelAnchor, TAPE_MID, TAPE_LABEL_FG)
    end
  end

  state.lastTapeAlt = state.altitude
  state.lastTapeGround = state.groundY
  state.lastBurnerLevel = state.burnerLevel
end
end -- do: tape constants + helpers

-- Big speedometer in the bottom-left of the map area. Half-circle dial with
-- a dark panel background, white scale tick marks, and a red needle. Needle
-- sweeps left at -max, up at 0, right at +max -- supports negative speed.
-- overlaySpeedDial is forward-declared; DIAL_* constants live in do-block
-- below and become upvalues -- saves 7 top-level local slots.
local overlaySpeedDial
do
local DIAL_W = 7
local DIAL_H = 3
local DIAL_PAD_LEFT = 1   -- cells of map between dial and left edge
local DIAL_PAD_BOT  = 1   -- cells of map between dial and OSD
local DIAL_BG = "f"       -- void (contrasts with ocean)
local DIAL_TICK = "0"     -- white scale marks
local DIAL_NEEDLE = "2"   -- red needle

overlaySpeedDial = function(mapH)
  for key in pairs(state.lastDialCells) do
    local c = math.floor(key / 1024)
    local r = key - c * 1024
    overlayCell(c, r, 0, "0", mapH, true)
  end
  state.lastDialCells = {}
  if not SHOW_SPEED_DIAL or not state.velocity then return end

  local startCol = 1 + DIAL_PAD_LEFT
  local startRow = math.max(1, mapH - DIAL_PAD_BOT - DIAL_H + 1)
  local centerCol = startCol + math.floor(DIAL_W / 2)
  local centerRow = startRow + DIAL_H - 1
  -- Needle origin at bottom-center sub-pixel.
  local centerSubX = (centerCol - 1) * SUB_W + (SUB_W - 1) / 2
  local centerSubY = (centerRow - 1) * SUB_H + SUB_H - 1
  local radius = math.min(DIAL_W * SUB_W, DIAL_H * SUB_H * 2) / 2 - 1

  local needleCells = {}
  local tickCells = {}

  local function lightSub(map, sxR, syR)
    local col = math.floor(sxR / SUB_W) + 1
    local row = math.floor(syR / SUB_H) + 1
    local sx = sxR - (col - 1) * SUB_W
    local sy = syR - (row - 1) * SUB_H
    if col < startCol or col > startCol + DIAL_W - 1 then return end
    if row < startRow or row > startRow + DIAL_H - 1 then return end
    if sx < 0 or sx >= SUB_W or sy < 0 or sy >= SUB_H then return end
    local key = col * 1024 + row
    map[key] = bit32.bor(map[key] or 0, bit32.lshift(1, sy * SUB_W + sx))
  end

  -- Tick marks: 5 marks across the half-circle (-90, -45, 0, +45, +90 degrees).
  for _, deg in ipairs({-90, -45, 0, 45, 90}) do
    local rad = math.rad(deg)
    local sxR = math.floor(centerSubX + math.sin(rad) * radius + 0.5)
    local syR = math.floor(centerSubY - math.cos(rad) * radius + 0.5)
    lightSub(tickCells, sxR, syR)
  end

  -- Needle: walk from center to length=radius-1 at angle = ratio*90.
  local ratio = math.max(-1, math.min(1, state.velocity / MAX_SPEED))
  local angleDeg = ratio * 90
  local rad = math.rad(angleDeg)
  local dx = math.sin(rad)
  local dy = -math.cos(rad)
  local needleLen = radius - 1
  local steps = math.floor(needleLen * 5)
  for i = 0, steps do
    local t = i / steps
    local sxR = math.floor(centerSubX + dx * needleLen * t + 0.5)
    local syR = math.floor(centerSubY + dy * needleLen * t + 0.5)
    lightSub(needleCells, sxR, syR)
  end

  -- Render every cell in the dial area: panel bg + needle/tick if present.
  for r = startRow, startRow + DIAL_H - 1 do
    for c = startCol, startCol + DIAL_W - 1 do
      if r >= 1 and r <= mapH and c >= 1 and c <= width then
        local key = c * 1024 + r
        local pattern = needleCells[key] or 0
        local fg = DIAL_NEEDLE
        if pattern == 0 and tickCells[key] then
          pattern = tickCells[key]
          fg = DIAL_TICK
        end
        monitor.setCursorPos(c, r)
        local emit = pattern
        local f, b = fg, DIAL_BG
        if bit32.band(emit, 0x20) ~= 0 then
          emit = bit32.bxor(emit, 0x3F)
          f, b = b, f
        end
        monitor.blit(string.char(emit + 0x80), f, b)
        state.lastDialCells[key] = true
      end
    end
  end
end
end -- do: dial constants

local function setControl(name, on)
  on = on and true or false
  state.controls[name] = on
  local ch = CHANNELS[name]
  if not ch then return end
  local r = wrapRelay(ch.relay)
  if not r or type(r.setOutput) ~= "function" then return end
  pcall(r.setOutput, ch.side, on)
end

local function updateBurnerLevel()
  state.burnerLevel = Lift.currentLevel()
end

local function updateVy()
  if not state.altitude then return end
  local now = os.clock()
  if state.lastAltSample then
    local dt = now - state.lastAltSample.t
    if dt > 0 then
      local raw = (state.altitude - state.lastAltSample.alt) / dt
      state.vy = (state.vy or 0) * 0.7 + raw * 0.3
    end
  end
  state.lastAltSample = { t = now, alt = state.altitude }
end

-- Clear the altitude PI controller's integrator. Call on every mode change
-- (engage/disengage, new target, hold toggle, manual burner, land entry) so
-- the integrator restarts unbiased instead of carrying stale error from the
-- previous setpoint.
local function resetLiftIntegrator()
  state.liftIntegral = 0
  state.liftLastTick = nil
  state.liftSaturatedSince = nil
end

local function updatePhase()
  if not state.engaged then state.phase = nil; return end
  if not state.target or not state.lastPos then
    state.engaged = false
    state.phase = nil
    return
  end
  local dx = (state.target.x or 0) - state.lastPos.x
  local dz = (state.target.z or 0) - state.lastPos.z
  local range = math.sqrt(dx * dx + dz * dz)
  local agl
  if state.altitude and state.groundY then agl = state.altitude - state.groundY end

  if state.phase == "LAND" then
    if agl and agl < LANDED_ALT_MARGIN and math.abs(state.vy or 0) < LANDED_VY_THRESH then
      state.engaged = false
      state.phase = nil
      state.autoStatus = "LANDED"
    end
    return
  end

  -- FOLLOW phase: hovering over a player target. Re-enter pursuit if they've
  -- moved far enough away; otherwise stay put. Don't fall through to LAND.
  if state.phase == "FOLLOW" then
    if range > FOLLOW_LEAVE_RADIUS then
      state.phase = nil  -- re-init below to CLIMB_TO_CRUISE / CRUISE
    else
      return
    end
  end

  if range < ARRIVAL_RADIUS then
    if state.target.kind == "player" then
      -- Player targets follow indefinitely: hover here, ignore the LAND/ARRIVED
      -- paths. The user disengages via STOP or by picking a different target.
      state.phase = "FOLLOW"
      state.autoStatus = "FOLLOW"
      resetLiftIntegrator()  -- fresh integrator for the FOLLOW-altitude hold
      return
    end
    if state.altHoldActive or state.aglHoldActive then
      -- An altitude lock is on; hand altitude off to it instead of landing.
      state.engaged = false
      state.phase = nil
      setControl("forward", false); setControl("left", false); setControl("right", false)
      state.autoStatus = "ARRIVED"
    else
      state.phase = "LAND"
      state.landRampStart = os.clock()
      state.landRampStartLevel = state.burnerLevel or HOVER_BURNER
      resetLiftIntegrator()
    end
    return
  end

  if state.phase == "CLIMB_TO_CRUISE" then
    if agl and agl >= CRUISE_ALT_AGL - CLIMB_DONE_MARGIN then state.phase = "CRUISE" end
    return
  end

  if state.phase == nil then
    -- When an altitude lock is active the user has explicitly chosen the
    -- altitude; skip CLIMB_TO_CRUISE so horizontal nav starts immediately.
    if state.altHoldActive or state.aglHoldActive then
      state.phase = "CRUISE"
    elseif agl and agl < CRUISE_ALT_AGL - CLIMB_DONE_MARGIN then
      state.phase = "CLIMB_TO_CRUISE"
    else
      state.phase = "CRUISE"
    end
  end
end

local function altitudeController()
  if not state.engaged and not state.altHoldActive and not state.aglHoldActive and not state.burnerTarget then
    -- Idle: hand the burner back to the manual +/- controller on the same
    -- signals. Drop any in-flight pulse and force the outputs LOW so we
    -- never fight a person holding the button.
    Lift.idle()
    state.controls.liftUp = false
    state.controls.liftDown = false
    resetLiftIntegrator()
    return
  end

  -- Manual burner setpoint (from `burner N` CLI). Ramps burnerLevel toward
  -- burnerTarget, clears the target when reached, and bails before the
  -- altitude PID below. Disengaging via "stop" or any altHold/AUTO command
  -- clears burnerTarget.
  if state.burnerTarget then
    if not state.burnerLevel then return end
    if state.burnerLevel == state.burnerTarget then
      state.burnerTarget = nil
      return
    end
    Lift.commandLevel(state.burnerTarget)
    return
  end

  if not state.altitude or not state.burnerLevel then return end

  local desired
  if state.engaged and state.phase == "LAND" and state.landRampStart then
    local t = os.clock() - state.landRampStart
    local startLvl = state.landRampStartLevel or HOVER_BURNER
    local frac = math.min(1, t / math.max(0.001, LAND_RAMP_S))
    desired = math.floor(startLvl + (LAND_BURNER - startLvl) * frac + 0.5)
  else
    -- Altitude target precedence: ALT lock and AGL lock are explicit user
    -- intent and win over AUTO's default cruise-AGL. AUTO drives horizontal
    -- only when a lock is active.
    local targetAlt
    if state.altHoldActive then
      targetAlt = state.altHoldTarget
    elseif state.aglHoldActive then
      if not state.groundY then return end
      targetAlt = state.groundY + state.aglHoldOffset
    elseif state.engaged and state.groundY then
      -- FOLLOW phase holds at the (typically lower) FOLLOW_ALT_AGL so the ship
      -- hovers close enough to actually see the player. Explicit alt/AGL locks
      -- above this branch already take precedence.
      local agl_target = (state.phase == "FOLLOW") and FOLLOW_ALT_AGL or CRUISE_ALT_AGL
      targetAlt = state.groundY + agl_target
    end
    if not targetAlt then return end

    -- Delegate PI + D-on-velocity to the shared altitude.lua. Integrator
    -- state lives on `state.lift*` so it survives the function call and
    -- gets reset by the existing reset paths (engagement edges, etc.).
    local pid = { integral = state.liftIntegral or 0, lastTick = state.liftLastTick }
    local d, saturated = Altitude.tick(pid, state.altitude, state.vy, targetAlt, {
      HOVER = HOVER_BURNER, MIN_BURNER = MIN_BURNER,
      KP = LIFT_KP, KI = LIFT_KI, KD = LIFT_KD, I_MAX = LIFT_I_MAX,
    })
    state.liftIntegral = pid.integral
    state.liftLastTick = pid.lastTick
    desired = d
    if saturated then
      state.liftSaturatedSince = state.liftSaturatedSince or os.clock()
    else
      state.liftSaturatedSince = nil
    end
  end

  Lift.commandLevel(desired)
end

local function horizontalController()
  if not state.engaged or not state.target or not state.lastPos then
    setControl("forward", false); setControl("left", false); setControl("right", false)
    return
  end
  if state.phase == "CLIMB_TO_CRUISE" then
    setControl("forward", false); setControl("left", false); setControl("right", false)
    local stuck = state.liftSaturatedSince
      and (os.clock() - state.liftSaturatedSince) > CLIMB_STUCK_S
    state.autoStatus = stuck and "CLIMB MAX" or "CLIMB"
    return
  end
  if state.phase == "LAND" then
    setControl("forward", false); setControl("left", false); setControl("right", false)
    state.autoStatus = "LAND"
    return
  end
  if state.phase == "FOLLOW" then
    setControl("forward", false); setControl("left", false); setControl("right", false)
    state.autoStatus = "FOLLOW"
    return
  end
  local dx = (state.target.x or 0) - state.lastPos.x
  local dz = (state.target.z or 0) - state.lastPos.z
  local range = math.sqrt(dx * dx + dz * dz)
  local desired = math.deg(math.atan2(dx, -dz)) % 360
  local err = ((desired - (state.shipHeading or 0)) + 540) % 360 - 180
  if math.abs(err) > TURN_THRESHOLD then
    setControl("forward", false)
    setControl("left", err < 0); setControl("right", err > 0)
    state.autoStatus = (err < 0 and "TURN L" or "TURN R") .. string.format(" %dm", math.floor(range))
  elseif math.abs(err) > FINE_THRESHOLD then
    setControl("forward", true)
    setControl("left", err < 0); setControl("right", err > 0)
    state.autoStatus = string.format("FWD %s %dm", err < 0 and "L" or "R", math.floor(range))
  else
    setControl("forward", true); setControl("left", false); setControl("right", false)
    state.autoStatus = string.format("FWD %dm", math.floor(range))
  end
end

local function autopilotTick()
  Lift.tick()
  updatePhase()
  horizontalController()
  altitudeController()
end

local function clearMapArea(mapH)
  monitor.setBackgroundColor(colors.black)
  for r = 1, mapH do
    monitor.setCursorPos(1, r)
    monitor.clearLine()
  end
end

local function drawWaypointsScreen(mapH)
  clearMapArea(mapH)
  -- Build combined list: online players first, then waypoints
  local items = {}
  for _, p in ipairs(state.players or {}) do
    if p.name and p.position then
      table.insert(items, {
        kind = "player", name = p.name,
        x = p.position.x, z = p.position.z, color = nil,
      })
    end
  end
  for _, wp in ipairs(state.waypoints or {}) do
    if wp.x and wp.z then
      table.insert(items, {
        kind = "waypoint", name = wp.name,
        x = wp.x, z = wp.z, color = wp.color,
      })
    end
  end
  state.wpTotalItems = #items

  local wCount = #(state.waypoints or {})
  local pCount = #(state.players or {})
  monitor.setCursorPos(1, 1)
  monitor.setTextColor(colors.yellow); monitor.setBackgroundColor(colors.black)
  monitor.write(string.format("WP:%d  Players:%d", wCount, pCount))

  state.targetCells = {}
  local visRows = mapH - 1
  for i = 1, visRows do
    local idx  = i + state.wpScroll
    local item = items[idx]
    local row  = i + 1
    if row > mapH then break end
    monitor.setCursorPos(1, row)
    monitor.setBackgroundColor(colors.black); monitor.clearLine()
    if item then
      local isPlayer  = item.kind == "player"
      local selected  = isSelected(item.kind, item.name)
      local dist = ""
      if state.lastPos then
        local dx = item.x - state.lastPos.x
        local dz = item.z - state.lastPos.z
        dist = string.format(" %dm", math.floor(math.sqrt(dx*dx + dz*dz)))
      end
      local prefix = isPlayer and "@" or (selected and ">" or " ")
      local fg = isPlayer and colors.cyan
                           or (HEX_TO_COLOR[paletteHexFor(item.color)] or colors.white)
      local bg = selected and colors.gray or colors.black
      local nameStr = string.format("%-14s", (item.name or "?"):sub(1, 14))
      local line
      if isPlayer then
        line = prefix .. nameStr .. dist
      else
        line = prefix .. nameStr
             .. string.format("X%-5d Z%-5d", item.x, item.z) .. dist
      end
      monitor.setCursorPos(1, row)
      monitor.setTextColor(fg)
      monitor.setBackgroundColor(bg)
      monitor.write(line:sub(1, width))
      table.insert(state.targetCells, {
        col1 = 1, col2 = width, row = row,
        kind = item.kind, name = item.name,
        x = item.x, z = item.z,
        color = isPlayer and "b" or paletteHexFor(item.color),
      })
    end
  end
end

local function drawControlsScreen(mapH)
  clearMapArea(mapH)
  -- fastTick calls us every tick; reset here so the tappable rows we push
  -- below don't accumulate between fullRedraws (fullRedraw already clears,
  -- so this is a no-op there).
  state.targetCells = {}
  local row = 2
  local function readout(label, value, fg)
    monitor.setCursorPos(2, row)
    monitor.setTextColor(colors.lightGray); monitor.setBackgroundColor(colors.black)
    monitor.write(string.format("%-10s", label))
    monitor.setTextColor(fg or colors.white)
    monitor.write(value or "--")
    row = row + 1
  end
  local altStr = state.altitude    and string.format("%dm",      math.floor(state.altitude + 0.5))       or "--"
  local aglStr = (state.altitude and state.groundY)
                 and string.format("%dm", math.floor(state.altitude - state.groundY + 0.5))              or "--"
  local gndStr = state.groundY     and string.format("%dm",      state.groundY)                          or "--"
  local spdStr = state.velocity    and string.format("%.1fm/s",  state.velocity)                         or "--"
  local vyStr  = state.vy          and string.format("%+.1fm/s", state.vy)                               or "--"
  local hdgStr = state.shipHeading and string.format("%d\xb0",   math.floor(state.shipHeading + 0.5))    or "--"
  readout("ALT",     altStr, colors.yellow)
  readout("AGL",     aglStr, colors.orange)
  readout("GROUND",  gndStr, colors.brown)
  readout("SPEED",   spdStr, colors.lime)
  local vyFg = state.vy and (state.vy > 0.1 and colors.lime or state.vy < -0.1 and colors.red or colors.white) or colors.white
  readout("VERT",    vyStr,  vyFg)
  readout("HEADING", hdgStr, colors.cyan)
  -- Burner bar
  do
    local lvl    = state.burnerLevel or 0
    local barW   = math.max(4, width - 15)
    local filled = math.floor(lvl / 15 * barW + 0.5)
    monitor.setCursorPos(2, row)
    monitor.setTextColor(colors.lightGray); monitor.setBackgroundColor(colors.black)
    monitor.write(string.format("%-10s", "BURNER"))
    monitor.setTextColor(colors.yellow);  monitor.write("[")
    monitor.setTextColor(colors.lime);    monitor.write(string.rep("=", filled))
    monitor.setTextColor(colors.gray);    monitor.write(string.rep("-", barW - filled))
    monitor.setTextColor(colors.yellow);  monitor.write("]")
    monitor.setTextColor(colors.white);   monitor.write(string.format(" %2d", lvl))
    row = row + 1
  end
  -- ALT LOCK: tappable row
  do
    local active = state.altHoldActive
    local fg = active and colors.yellow or colors.white
    local bg = active and colors.gray   or colors.black
    local label
    if active and state.altHoldTarget then
      label = string.format("ALT LOCK  [ ON @ %dm ]", math.floor(state.altHoldTarget + 0.5))
    else
      label = "ALT LOCK  [  OFF  ]"
    end
    monitor.setCursorPos(2, row)
    monitor.setTextColor(fg); monitor.setBackgroundColor(bg)
    monitor.write(label:sub(1, width - 1))
    table.insert(state.targetCells, { col1 = 2, col2 = width, row = row, cmd = "alt" })
    row = row + 1
  end
  -- AGL LOCK: tappable row, mirrors ALT LOCK
  do
    local active = state.aglHoldActive
    local fg = active and colors.yellow or colors.white
    local bg = active and colors.gray   or colors.black
    local label
    if active and state.aglHoldOffset then
      label = string.format("AGL LOCK  [ ON @ %dm ]", math.floor(state.aglHoldOffset + 0.5))
    else
      label = "AGL LOCK  [  OFF  ]"
    end
    monitor.setCursorPos(2, row)
    monitor.setTextColor(fg); monitor.setBackgroundColor(bg)
    monitor.write(label:sub(1, width - 1))
    table.insert(state.targetCells, { col1 = 2, col2 = width, row = row, cmd = "agl" })
    row = row + 1
  end
  if state.engaged and state.autoStatus ~= "" then
    readout("AUTO", state.autoStatus, colors.lime)
  end
  -- Custom controls: one tappable row per cfg.customControls entry.
  for _, ctl in ipairs(CUSTOM_CONTROLS) do
    if row > mapH then break end
    local active = state.customControls[ctl.name] == true
    local fg = active and (HEX_TO_COLOR[paletteHexFor(ctl.activeColor)] or colors.orange)
                       or colors.white
    local bg = active and colors.gray or colors.black
    local label = string.format("%-10s[ %s ]",
      ctl.name:upper():sub(1, 9),
      active and ctl.activeLabel or ctl.inactiveLabel)
    monitor.setCursorPos(2, row)
    monitor.setTextColor(fg); monitor.setBackgroundColor(bg)
    monitor.write(label:sub(1, width - 1))
    table.insert(state.targetCells, {
      col1 = 2, col2 = width, row = row,
      cmd = "custom_toggle", name = ctl.name,
    })
    row = row + 1
  end
end

local function drawSettingsScreen(mapH)
  clearMapArea(mapH)
  state.targetCells = {}
  monitor.setCursorPos(1, 1)
  monitor.setTextColor(colors.yellow); monitor.setBackgroundColor(colors.black)
  local dirty = settingsDirty()
  monitor.write(dirty and "SETTINGS *" or "SETTINGS")
  local lastRow = 1
  for i, s in ipairs(SETTINGS) do
    local row = i + 1
    if row > mapH then break end
    local selected = state.settingIdx == i
    local changed  = s.get() ~= SETTINGS_SAVED[i]
    local bg  = selected and colors.gray or colors.black
    local nfg = selected and colors.white or colors.lightGray
    local vfg = changed and colors.orange or (selected and colors.yellow or colors.white)
    local namePart = string.format("%-14s", s.name)
    local valPart  = tostring(s.get())
    local pad = string.rep(" ", math.max(0, width - #namePart - #valPart))
    monitor.setCursorPos(1, row)
    monitor.setTextColor(nfg); monitor.setBackgroundColor(bg)
    monitor.write(namePart)
    monitor.setTextColor(vfg)
    monitor.write(valPart)
    monitor.setTextColor(nfg)
    monitor.write(pad)
    lastRow = row
  end
  -- SAVE / CANCEL: tappable buttons below the list. Live when dirty, dimmed when clean.
  local btnRow = math.min(mapH, lastRow + 2)
  if btnRow <= mapH then
    local saveLabel, cxlLabel = " SAVE ", " CANCEL "
    local saveBg = dirty and colors.lime or colors.gray
    local saveFg = dirty and colors.black or colors.lightGray
    local cxlBg  = dirty and colors.red  or colors.gray
    local cxlFg  = dirty and colors.white or colors.lightGray
    local saveCol = 2
    local cxlCol  = saveCol + #saveLabel + 2
    monitor.setCursorPos(saveCol, btnRow)
    monitor.setTextColor(saveFg); monitor.setBackgroundColor(saveBg); monitor.write(saveLabel)
    monitor.setCursorPos(cxlCol, btnRow)
    monitor.setTextColor(cxlFg);  monitor.setBackgroundColor(cxlBg);  monitor.write(cxlLabel)
    table.insert(state.targetCells, { col1 = saveCol, col2 = saveCol + #saveLabel - 1, row = btnRow, cmd = "setting_save" })
    table.insert(state.targetCells, { col1 = cxlCol,  col2 = cxlCol  + #cxlLabel  - 1, row = btnRow, cmd = "setting_cancel" })
  end
end

local function drawText(x, y, text, fg, bg)
  monitor.setCursorPos(x, y)
  monitor.setTextColor(fg or colors.white)
  monitor.setBackgroundColor(bg or colors.black)
  monitor.write(text)
end

local function drawButton(id, x, y, label, fg, bg)
  buttons[id] = { x1 = x, y1 = y, x2 = x + #label - 1, y2 = y }
  drawText(x, y, label, fg or colors.black, bg or colors.lightGray)
end

local function autoStatusColor(status)
  if not status or status == "" then return colors.white, colors.black end
  if status:find("CLIMB") then return colors.black, colors.yellow end
  if status == "LAND" or status == "LANDED" or status == "ARRIVED" then
    return colors.black, colors.orange
  end
  if status:find("TURN") or status:find("FWD") then return colors.black, colors.lime end
  return colors.white, colors.gray
end

local function fmtEta(secs)
  if secs < 60 then return string.format("%ds", math.floor(secs)) end
  return string.format("%dm%02ds", math.floor(secs / 60), math.floor(secs % 60))
end

local NAV_TABS = {
  { id = "screen_map",       label = " M ",  screen = "map"       },
  { id = "screen_waypoints", label = " WP ", screen = "waypoints" },
  { id = "screen_controls",  label = " C ",  screen = "controls"  },
  { id = "screen_settings",  label = " S ",  screen = "settings"  },
}

-- Draws a list of {text, color} pairs left-to-right starting at (startCol, row).
local function drawSegments(startCol, row, segments)
  local cx = startCol
  monitor.setBackgroundColor(colors.black)
  for _, seg in ipairs(segments) do
    if cx > width then break end
    local text = tostring(seg[1]):sub(1, width - cx + 1)
    if #text > 0 then
      monitor.setCursorPos(cx, row)
      monitor.setTextColor(seg[2])
      monitor.write(text)
      cx = cx + #text
    end
  end
  return cx
end

local function drawOsd(x, y, z)
  local btnRow, coordRow
  if IS_POCKET then
    btnRow   = height - 1
    coordRow = height
    monitor.setCursorPos(1, btnRow);   monitor.setBackgroundColor(colors.black); monitor.clearLine()
    monitor.setCursorPos(1, coordRow); monitor.setBackgroundColor(colors.black); monitor.clearLine()
  else
    btnRow   = height
    coordRow = height
    monitor.setCursorPos(1, btnRow); monitor.setBackgroundColor(colors.black); monitor.clearLine()
  end
  buttons = {}
  local col = 1

  -- Nav tabs (always shown)
  for _, tab in ipairs(NAV_TABS) do
    local active = state.screen == tab.screen
    drawButton(tab.id, col, btnRow, tab.label, colors.black, active and colors.white or colors.lightGray)
    col = col + #tab.label
  end
  col = col + 1

  if state.screen == "map" then
    drawButton("zoom_out", col, btnRow, " - "); col = col + 3
    drawButton("zoom_in",  col, btnRow, " + "); col = col + 3
    local panned = (state.mapOffsetX or 0) ~= 0 or (state.mapOffsetZ or 0) ~= 0
    if IS_POCKET then
      -- Pocket bar is too narrow for L2 + PIN + CTR; the L2 slot becomes a
      -- recenter button instead. Always drawn so the bar layout stays stable;
      -- cyan when there's a pan to undo, lightGray (inert-looking) when not.
      local rBg = panned and colors.cyan or colors.lightGray
      drawButton("recenter", col, btnRow, " R ", colors.black, rBg); col = col + 3
    else
      drawButton("lod", col, btnRow, " L" .. state.lod); col = col + 3
    end
    -- PIN lock: yellow bg when active blocks tap-to-pin so the current
    -- target can't be accidentally overwritten by a stray map tap.
    local pinBg = state.pinLock and colors.yellow or colors.lightGray
    drawButton("pin_lock_toggle", col, btnRow, " PIN ", colors.black, pinBg); col = col + 5
    -- Full CTR button only on monitor (pocket already has the R slot above).
    if not IS_POCKET and panned then
      drawButton("recenter", col, btnRow, " CTR ", colors.black, colors.cyan); col = col + 5
    end
    if state.target then
      col = col + 1
      local autoLabel = state.engaged and " STOP " or " AUTO "
      local autoBg = state.engaged and colors.lime or colors.lightGray
      drawButton("auto", col, btnRow, autoLabel, colors.black, autoBg); col = col + #autoLabel
      drawButton("clear_target", col, btnRow, " X "); col = col + 3
    end
    if not IS_POCKET and state.autoStatus and state.autoStatus ~= "" then
      local sfg, sbg = autoStatusColor(state.autoStatus)
      local label = " " .. state.autoStatus .. " "
      drawText(col + 1, btnRow, label, sfg, sbg)
      col = col + 1 + #label
    end
    local headingStr = (state.shipHeading and tostring(math.floor((state.shipHeading or 0) + 0.5))) or "--"
    local pCount = #(state.players or {})
    local pInfo  = "P" .. pCount
    if not IS_POCKET and state.hasMap and state.lastPos and state.players[1] and state.players[1].position then
      local pp = state.players[1]
      local pcol, prow = worldToCell(pp.position.x, pp.position.z, state.lastPos.x, state.lastPos.z, mapHeight())
      pInfo = pInfo .. ":" .. pcol .. "," .. prow
    end
    local segs
    if state.target then
      local dx    = (state.target.x or 0) - (state.lastPos and state.lastPos.x or 0)
      local dz    = (state.target.z or 0) - (state.lastPos and state.lastPos.z or 0)
      local range = math.floor(math.sqrt(dx * dx + dz * dz))
      local etaSeg = ""
      if state.engaged and state.velocity and state.velocity > 0.5 and range > 5 then
        etaSeg = " ETA:" .. fmtEta(range / state.velocity)
      end
      segs = {
        { (state.target.name or "?"),          colors.yellow    },
        { " " .. range .. "m",                 colors.lime      },
        { etaSeg,                               colors.cyan      },
        { string.format(" X%d Z%d", x, z),    colors.gray      },
        { " H" .. headingStr,                  colors.lightBlue },
      }
    else
      segs = {
        { string.format("X%d Z%d", x, z),     colors.gray      },
        { " H" .. headingStr,                  colors.lightBlue },
        { " " .. pInfo,                        colors.lightGray },
      }
      if state.velocity    then segs[#segs+1] = { string.format(" S%.1f", state.velocity),              colors.white } end
      if state.altitude    then segs[#segs+1] = { string.format(" A%d", math.floor(state.altitude+0.5)), colors.white } end
      if state.burnerLevel then segs[#segs+1] = { " Bn" .. state.burnerLevel,                           colors.white } end
      if isStale()         then segs[#segs+1] = { " STALE",                                             colors.red   } end
    end
    if IS_POCKET then
      drawSegments(1, coordRow, segs)
    else
      local totalLen = 0
      for _, s in ipairs(segs) do totalLen = totalLen + #tostring(s[1]) end
      local startCol = math.max(col + 1, width - totalLen + 1)
      drawSegments(startCol, coordRow, segs)
    end

  elseif state.screen == "waypoints" then
    local total   = state.wpTotalItems or (#(state.players or {}) + #(state.waypoints or {}))
    local canUp   = state.wpScroll > 0
    local canDown = state.wpScroll + mapHeight() - 1 < total
    drawButton("wp_scroll_up",   col, btnRow, " ^ ", colors.black, canUp   and colors.lightGray or colors.gray); col = col + 3
    drawButton("wp_scroll_down", col, btnRow, " v ", colors.black, canDown and colors.lightGray or colors.gray); col = col + 3
    if state.target then
      col = col + 1
      local autoLabel = state.engaged and " STOP " or " AUTO "
      local autoBg    = state.engaged and colors.lime or colors.lightGray
      drawButton("auto",         col, btnRow, autoLabel, colors.black, autoBg); col = col + #autoLabel
      drawButton("clear_target", col, btnRow, " X "); col = col + 3
    end
    local info = #(state.waypoints or {}) .. "wp " .. #(state.players or {}) .. "p"
    if width - #info + 1 > col then
      drawText(width - #info + 1, btnRow, info, colors.lightGray, colors.black)
    end

  elseif state.screen == "controls" then
    local stepLabel = string.format("%2d ", state.altStep or 1)
    drawButton("step_cycle",  col, btnRow, stepLabel); col = col + 3
    drawButton("burner_down", col, btnRow, " - "); col = col + 3
    drawButton("burner_up",   col, btnRow, " + "); col = col + 3
    -- Mode label follows the "lock + target" precedent (e.g. ALT HOLD @ 120m).
    -- AUTO is orthogonal to ALT/AGL lock: when both are active, both appear.
    local parts = {}
    if state.altHoldActive and state.altHoldTarget then
      parts[#parts+1] = string.format("ALT HOLD @ %dm", math.floor(state.altHoldTarget + 0.5))
    elseif state.aglHoldActive and state.aglHoldOffset then
      parts[#parts+1] = string.format("AGL HOLD @ %dm", math.floor(state.aglHoldOffset + 0.5))
    end
    if state.engaged then
      parts[#parts+1] = "AUTO " .. (state.autoStatus or "")
    end
    if #parts == 0 then parts[1] = "MANUAL" end
    local modeStr = table.concat(parts, "  ")
    if width - #modeStr + 1 > col then
      drawText(width - #modeStr + 1, btnRow, modeStr, colors.white, colors.black)
    end

  elseif state.screen == "settings" then
    drawButton("setting_prev", col, btnRow, " < "); col = col + 3
    drawButton("setting_next", col, btnRow, " > "); col = col + 3
    col = col + 1
    drawButton("setting_dec",  col, btnRow, " - "); col = col + 3
    drawButton("setting_inc",  col, btnRow, " + "); col = col + 3
    local s = SETTINGS[state.settingIdx]
    if s then
      local info = s.name .. ": " .. tostring(s.get())
      if width - #info + 1 > col then
        drawText(width - #info + 1, btnRow, info, colors.yellow, colors.black)
      end
    end
  end

  if state.lastError then
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.red)
    monitor.setBackgroundColor(colors.black)
    monitor.write(state.lastError:sub(1, width))
  end
end

local function drawError(message)
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.red)
  monitor.clear()
  drawText(1, 1, "BlueMap minimap error", colors.red, colors.black)
  drawText(1, 2, tostring(message):sub(1, width), colors.white, colors.black)
end

local function maybeFetchSidecar()
  if os.clock() < state.sidecarAt then return end
  state.sidecarAt = os.clock() + SIDECAR_INTERVAL
  local p = httpGetJson(SERVER .. "/players")
  if p and p.players then state.players = p.players end
  local w = httpGetJson(SERVER .. "/waypoints")
  if w then state.waypoints = w end
  if state.lastPos then
    local url = string.format("%s/height?x=%s&z=%s&r=%d",
      SERVER, urlencode(state.lastPos.x), urlencode(state.lastPos.z), GROUND_CHUNK_RADIUS)
    local h = httpGetJson(url)
    if h and type(h.groundMaxY) == "number" then
      state.groundY = h.groundMaxY
      state.groundYMin = h.groundMinY
    end
  end
end

local function fullRedraw()
  if not state.lastPos then return end
  if state.target and state.target.kind == "player" then
    for _, pp in ipairs(state.players or {}) do
      if pp.name == state.target.name and pp.position then
        state.target.x = pp.position.x
        state.target.z = pp.position.z
        break
      end
    end
  end
  local mapH = mapHeight()
  state.targetCells = {}
  if state.screen == "map" then
    if state.hasMap then
      drawCachedMap(mapH)
      state.lastTapeAlt = nil
      state.lastTapeGround = nil
      state.lastBurnerLevel = nil
      state.lastTapeCells = {}
      local cx, cz = mapCenter()
      overlayDotTrail(cx, cz, mapH)
      overlayWaypoints(cx, cz, mapH)
      overlayOtherPlayers(cx, cz, mapH)
      overlayPin(cx, cz, mapH)
      overlayMarkerLabels(cx, cz, mapH)
      overlayAltitudeTape(mapH)
      if not IS_POCKET then overlaySpeedDial(mapH) end
      overlaySelfTriangle(state.shipHeading, mapH, cx, cz)
    else
      clearMapArea(mapH)
    end
  elseif state.screen == "waypoints" then
    drawWaypointsScreen(mapH)
  elseif state.screen == "controls" then
    drawControlsScreen(mapH)
  elseif state.screen == "settings" then
    drawSettingsScreen(mapH)
  end
  drawOsd(math.floor(state.lastPos.x), math.floor(state.lastPos.y or 0), math.floor(state.lastPos.z))
end

-- Fetch one tile (ti, tj) at the captured bpp/lod and store it. If state.bpp
-- or state.lod changed mid-flight, discard the result -- the tile would be
-- world-aligned to a stale grid.
local function fetchTile(ti, tj, fetchBpp, fetchLod, mapH)
  local tileWB, tileHB = tileWorldDim(mapH)
  local cx = (state.tileOriginX or 0) + ti * tileWB
  local cz = (state.tileOriginZ or 0) + tj * tileHB
  local data, err = httpGetJson(buildUrl(cx, cz))
  if data and data.text
     and state.bpp == fetchBpp and state.lod == fetchLod
     and state.tileW == width and state.tileH == mapH then
    state.tiles[tileKey(ti, tj)] = { text = data.text, fg = data.fg, bg = data.bg }
    state.hasMap = true
    return true
  end
  if data and data.error then state.lastError = data.error
  elseif err then state.lastError = err end
  return false
end

local function mapTick()
  maybeFetchSidecar()
  if not IS_POCKET then
    local x, y, z = gps.locate(0.5)
    if not x then drawError("No GPS lock"); return end
    state.lastPos = { x = x, y = y or 0, z = z }
  end
  if not state.lastPos then
    drawError(state.shipId and "Waiting for ship state..." or "Looking for ship...")
    return
  end

  local mapH = mapHeight()
  -- Grid invalidation: any zoom/resize wipes tiles. They map to different
  -- world rects under new bpp, so reusing them would draw garbage.
  local mcx, mcz = mapCenter()
  if state.tileBpp ~= state.bpp or state.tileLod ~= state.lod
     or state.tileW ~= width or state.tileH ~= mapH then
    state.tiles = {}
    state.hasMap = false
    state.tileBpp = state.bpp
    state.tileLod = state.lod
    state.tileW = width
    state.tileH = mapH
    -- Re-anchor tile (0, 0) on the current viewport so the user's view sits
    -- inside the centre tile right after zoom (no partial neighbour tiles).
    state.tileOriginX = mcx
    state.tileOriginZ = mcz
  end

  local ci, cj = tileIndexForWorld(mcx, mcz, mapH)

  -- Evict tiles outside a 5x5 buffer to bound memory.
  for k in pairs(state.tiles) do
    local si, sj = k:match("(-?%d+),(-?%d+)")
    si, sj = tonumber(si), tonumber(sj)
    if not si or math.abs(si - ci) > 2 or math.abs(sj - cj) > 2 then
      state.tiles[k] = nil
    end
  end

  -- Phased fetch: server has tight memory (gunicorn workers OOM on 9
  -- concurrent renders at low bpp / big monitor). Do the centre alone first
  -- so a cold start paints the ship's tile fast, then the 8 neighbours in
  -- batches of 2 with a redraw between each so the map grows visibly.
  local fetchBpp, fetchLod = state.bpp, state.lod
  if not state.tiles[tileKey(ci, cj)] then
    fetchTile(ci, cj, fetchBpp, fetchLod, mapH)
    if state.hasMap then fullRedraw() end
  end

  -- Zoom debounce: rapid scroll-wheel zoom would wipe the grid and start a
  -- fresh 9-tile fetch every step, hammering the server with throwaway
  -- renders. After a zoom we hold off on the 8 neighbour fetches for ~1s;
  -- subsequent zooms reset the timer. The centre tile still loads eagerly so
  -- the user sees their current zoom level immediately.
  local zoomSettling = state.zoomSettledAt and os.clock() < state.zoomSettledAt

  if not zoomSettling then
    local neighborBatches = {
      {{-1, 0}, {1, 0}},
      {{0, -1}, {0, 1}},
      {{-1, -1}, {1, 1}},
      {{1, -1}, {-1, 1}},
    }
    for _, batch in ipairs(neighborBatches) do
      local fetchers = {}
      for _, off in ipairs(batch) do
        local ti, tj = ci + off[1], cj + off[2]
        if not state.tiles[tileKey(ti, tj)] then
          local cti, ctj = ti, tj
          table.insert(fetchers, function() fetchTile(cti, ctj, fetchBpp, fetchLod, mapH) end)
        end
      end
      if #fetchers > 0 then
        parallel.waitForAll(table.unpack(fetchers))
        if state.hasMap then fullRedraw() end
      end
    end
  end

  if state.hasMap then
    state.status = "ok"
    -- Final redraw every tick so state changes that don't touch tiles (pin
    -- placed, target changed, ship moved within current tile, etc.) repaint
    -- their overlays. Pre-PR mapTick always called fullRedraw at the end;
    -- the new fetch-driven redraws above only fire when tiles arrived, so
    -- without this final redraw a steady-state mapTick becomes a no-op and
    -- the pin marker (only drawn in fullRedraw, not fastTick) lags by up to
    -- FRAME_INTERVAL.
    fullRedraw()
  else
    drawError(state.lastError or "Loading map...")
  end
end

local function mapLoop()
  while state.running do
    local ok, err = pcall(mapTick)
    if not ok then state.lastError = tostring(err) end
    -- Interruptible sleep: pan/zoom queue "map_dirty" to wake immediately
    -- rather than waiting the full FRAME_INTERVAL for fresh tiles.
    local interval = os.startTimer(FRAME_INTERVAL)
    local dirty = false
    while true do
      local ev, p1 = os.pullEvent()
      if ev == "map_dirty" then
        dirty = true
        os.cancelTimer(interval)
        break
      elseif ev == "timer" and p1 == interval then
        break
      end
    end
    if dirty then
      -- Short settle: drain any extra dirty events that stacked up from rapid
      -- gesture steps so we fetch once for the resting position, not once per cell.
      local settle = os.startTimer(0.05)
      while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == settle then break end
        -- map_dirty events during the settle window are intentionally consumed
      end
    end
  end
end

local function fastTick()
  if not IS_POCKET then
    local h = readHeading()
    if h then state.shipHeading = h end
    state.altitude = readAltitude()
    state.pressure = readPressure()
    state.velocity = readVelocity()
    updateVy()
    updateBurnerLevel()
    autopilotTick()
  end
  if state.lastPos then
    local mapH = mapHeight()
    if state.screen == "map" and state.hasMap then
      overlayAltitudeTape(mapH)
      if not IS_POCKET then overlaySpeedDial(mapH) end
      local fcx, fcz = mapCenter()
      overlaySelfTriangle(state.shipHeading, mapH, fcx, fcz)
    elseif state.screen == "controls" then
      drawControlsScreen(mapH)
    end
    drawOsd(math.floor(state.lastPos.x), math.floor(state.lastPos.y or 0), math.floor(state.lastPos.z))
  end
end

local function fastLoop()
  while state.running do
    local ok, err = pcall(fastTick)
    if not ok then state.lastError = tostring(err) end
    sleep(NAV_INTERVAL)
  end
end

-- Forward declarations for functions defined later that applyCommand calls.
-- Without these, Lua sees the names as globals (nil) when applyCommand is compiled.
local saveControlState
local loadControlState

-- Mutates state in response to a UI command. Shared by the local touch handler
-- and (on the ship) the rednet command listener, so a pocket tap and a monitor
-- tap funnel through the same logic.
local function applyCommand(cmd)
  if type(cmd) ~= "table" then return end
  local id = cmd.cmd
  if id == "zoom_in" then
    state.bpp = clamp(state.bpp / 2, 0.25, 128)
    state.lod = pickLod(state.bpp)
    state.tiles = {}; state.hasMap = false  -- bpp change re-maps tile coords
    state.zoomSettledAt = os.clock() + 1.0  -- defer neighbour fetches to coalesce rapid scroll
    os.queueEvent("map_dirty")
  elseif id == "zoom_out" then
    state.bpp = clamp(state.bpp * 2, 0.25, 128)
    state.lod = pickLod(state.bpp)
    state.tiles = {}; state.hasMap = false
    state.zoomSettledAt = os.clock() + 1.0
    os.queueEvent("map_dirty")
  elseif id == "lod" then
    state.lod = state.lod + 1
    if state.lod > 3 then state.lod = 1 end
    state.tiles = {}; state.hasMap = false
    state.zoomSettledAt = os.clock() + 1.0
    os.queueEvent("map_dirty")
  elseif id == "auto" then
    if state.target then
      state.engaged = not state.engaged
      state.phase = nil
      resetLiftIntegrator()
      if not state.engaged then
        setControl("forward", false); setControl("left", false); setControl("right", false)
      end
    end
  elseif id == "alt" then
    if state.altHoldActive then
      state.altHoldActive = false
      state.altHoldTarget = nil
    else
      state.altHoldActive = true
      state.altHoldTarget = state.altitude
      -- ALT and AGL are mutually exclusive; the last press wins.
      state.aglHoldActive = false
      state.aglHoldOffset = nil
    end
    resetLiftIntegrator()
    saveControlState()
  elseif id == "agl" then
    -- Toggle AGL lock at current AGL. Requires groundY to compute the offset;
    -- silently bail if unknown so the user can retry once BlueMap responds.
    if state.aglHoldActive then
      state.aglHoldActive = false
      state.aglHoldOffset = nil
    elseif state.altitude and state.groundY then
      state.aglHoldActive = true
      state.aglHoldOffset = math.max(0, state.altitude - state.groundY)
      state.altHoldActive = false
      state.altHoldTarget = nil
    end
    resetLiftIntegrator()
    saveControlState()
  elseif id == "step_cycle" then
    -- Cycle the +/- step on the controls screen: 1 -> 5 -> 10 -> 1.
    local cur = state.altStep or 1
    state.altStep = (cur == 1 and 5) or (cur == 5 and 10) or 1
  elseif id == "clear_target" then
    state.target = nil
    state.engaged = false
    state.phase = nil
    state.autoStatus = ""
    resetLiftIntegrator()
    setControl("forward", false); setControl("left", false); setControl("right", false)
  elseif id == "set_target" and type(cmd.target) == "table" then
    state.target = {
      kind = cmd.target.kind,
      name = cmd.target.name,
      x = cmd.target.x,
      z = cmd.target.z,
      color = cmd.target.color,
    }
    state.engaged = false
    state.autoStatus = ""
    resetLiftIntegrator()
    os.queueEvent("map_dirty")  -- wake mapLoop so overlayPin renders without waiting for FRAME_INTERVAL

  -- ---- CLI commands ---------------------------------------------------------
  -- Each handler is the receiving end of a `ship <cmd>` invocation; see
  -- computercraft/ship.lua for the sending side.

  elseif id == "goto" and type(cmd.x) == "number" and type(cmd.z) == "number" then
    state.target = { kind = "cli", name = "GOTO", x = cmd.x, z = cmd.z, color = "1" }
    state.engaged = true
    state.phase = nil
    -- ALT/AGL lock is preserved across goto; AUTO drives horizontal only when
    -- a lock is active. burnerTarget is cleared because manual burner conflicts.
    state.burnerTarget = nil
    state.autoStatus = ""
    resetLiftIntegrator()

  elseif id == "goto_wp" and type(cmd.name) == "string" then
    local target = cmd.name:lower()
    for _, wp in ipairs(state.waypoints or {}) do
      if type(wp.name) == "string" and wp.name:lower() == target then
        state.target = {
          kind = "waypoint", name = wp.name, x = wp.x, z = wp.z,
          color = paletteHexFor(wp.color),
        }
        state.engaged = true
        state.phase = nil
        state.burnerTarget = nil
        state.autoStatus = ""
        resetLiftIntegrator()
        break
      end
    end

  elseif id == "set_burner" and type(cmd.level) == "number" then
    local lvl = math.floor(cmd.level)
    if lvl >= 0 and lvl <= 15 then
      -- Manual burner override; abandon any autopilot / hold currently driving it.
      state.engaged = false
      state.phase = nil
      state.altHoldActive = false
      state.altHoldTarget = nil
      state.aglHoldActive = false
      state.aglHoldOffset = nil
      state.burnerTarget = lvl
      state.autoStatus = ""
      resetLiftIntegrator()
      setControl("forward", false); setControl("left", false); setControl("right", false)
      saveControlState()
    end

  elseif id == "stop" then
    state.target = nil
    state.engaged = false
    state.phase = nil
    state.altHoldActive = false
    state.altHoldTarget = nil
    state.aglHoldActive = false
    state.aglHoldOffset = nil
    state.burnerTarget = nil
    state.autoStatus = ""
    resetLiftIntegrator()
    setControl("forward", false); setControl("left", false); setControl("right", false)
    saveControlState()

  elseif id == "hold" then
    if type(cmd.altitude) == "number" then
      state.altHoldActive = true
      state.altHoldTarget = cmd.altitude
      state.aglHoldActive = false
      state.aglHoldOffset = nil
      state.burnerTarget = nil
    elseif state.altHoldActive then
      state.altHoldActive = false
      state.altHoldTarget = nil
    else
      state.altHoldActive = true
      state.altHoldTarget = state.altitude
      state.aglHoldActive = false
      state.aglHoldOffset = nil
      state.burnerTarget = nil
    end
    resetLiftIntegrator()
    saveControlState()
  elseif id == "agl_set" then
    -- CLI: `minimap agl [N]`. No arg = toggle at current AGL. With arg = lock
    -- at N m above current ground. Requires groundY when engaging.
    if type(cmd.offset) == "number" then
      if state.groundY then
        state.aglHoldActive = true
        state.aglHoldOffset = math.max(0, cmd.offset)
        state.altHoldActive = false
        state.altHoldTarget = nil
        state.burnerTarget = nil
      end
    elseif state.aglHoldActive then
      state.aglHoldActive = false
      state.aglHoldOffset = nil
    elseif state.altitude and state.groundY then
      state.aglHoldActive = true
      state.aglHoldOffset = math.max(0, state.altitude - state.groundY)
      state.altHoldActive = false
      state.altHoldTarget = nil
      state.burnerTarget = nil
    end
    resetLiftIntegrator()
    saveControlState()

  elseif id == "screen_map"       then state.screen = "map";       fullRedraw()
  elseif id == "screen_waypoints" then state.screen = "waypoints"; state.wpScroll = 0; fullRedraw()
  elseif id == "screen_controls"  then state.screen = "controls";  fullRedraw()
  elseif id == "screen_settings"  then state.screen = "settings";  fullRedraw()

  elseif id == "pin_lock_toggle" then
    state.pinLock = not state.pinLock

  elseif id == "recenter" then
    state.mapOffsetX = 0
    state.mapOffsetZ = 0
    state.isDragging = false
    fullRedraw()

  elseif id == "wp_scroll_up" then
    state.wpScroll = math.max(0, state.wpScroll - 1)
  elseif id == "wp_scroll_down" then
    local total = state.wpTotalItems or (#(state.players or {}) + #(state.waypoints or {}))
    local maxScroll = math.max(0, total - (mapHeight() - 1))
    state.wpScroll = math.min(maxScroll, state.wpScroll + 1)

  elseif id == "custom_toggle" then
    local name = cmd.name
    if type(name) ~= "string" then return end
    local ctl
    for _, c in ipairs(CUSTOM_CONTROLS) do
      if c.name == name then ctl = c; break end
    end
    if not ctl then return end
    local active = not (state.customControls[name] == true)
    state.customControls[name] = active
    -- inverted: active = LOW signal; normal: active = HIGH signal
    setControl(name, ctl.inverted ~= active)
    saveControlState()

  elseif id == "burner_up" then
    -- Context-sensitive: bump whichever altitude target is locked, else burner.
    -- Step is the controls-screen step button (1/5/10).
    local step = state.altStep or 1
    if state.altHoldActive and state.altHoldTarget then
      state.altHoldTarget = state.altHoldTarget + step
      resetLiftIntegrator()
    elseif state.aglHoldActive and state.aglHoldOffset then
      state.aglHoldOffset = state.aglHoldOffset + step
      resetLiftIntegrator()
    else
      local lvl = math.min(15, (state.burnerLevel or state.burnerTarget or HOVER_BURNER) + step)
      applyCommand({ cmd = "set_burner", level = lvl })
    end
  elseif id == "burner_down" then
    local step = state.altStep or 1
    if state.altHoldActive and state.altHoldTarget then
      state.altHoldTarget = state.altHoldTarget - step
      resetLiftIntegrator()
    elseif state.aglHoldActive and state.aglHoldOffset then
      state.aglHoldOffset = math.max(0, state.aglHoldOffset - step)
      resetLiftIntegrator()
    else
      local lvl = math.max(0, (state.burnerLevel or state.burnerTarget or HOVER_BURNER) - step)
      applyCommand({ cmd = "set_burner", level = lvl })
    end

  elseif id == "setting_prev" then
    state.settingIdx = math.max(1, state.settingIdx - 1)
  elseif id == "setting_next" then
    state.settingIdx = math.min(#SETTINGS, state.settingIdx + 1)
  elseif id == "setting_inc" then
    local s = SETTINGS[cmd.idx or state.settingIdx]
    if s then s.set(math.min(s.max, s.get() + s.step)) end
    if state.screen == "settings" then fullRedraw() end
  elseif id == "setting_dec" then
    local s = SETTINGS[cmd.idx or state.settingIdx]
    if s then s.set(math.max(s.min, s.get() - s.step)) end
    if state.screen == "settings" then fullRedraw() end
  elseif id == "setting_save" then
    saveSettings()
    if state.screen == "settings" then fullRedraw() end
  elseif id == "setting_cancel" then
    cancelSettings()
    if state.screen == "settings" then fullRedraw() end
  end
end

-- Commands that only affect local UI state -- never forward to the ship.
local LOCAL_CMDS = {
  screen_map=true, screen_waypoints=true, screen_controls=true, screen_settings=true,
  wp_scroll_up=true, wp_scroll_down=true,
  setting_prev=true, setting_next=true,
  pin_lock_toggle=true,
  recenter=true,
  zoom_in=true, zoom_out=true, lod=true,
}

-- Pocket forwards every command to the ship over rednet, signed with the
-- shared secret. Ship applies locally.
local function dispatchCommand(cmd)
  if LOCAL_CMDS[cmd.cmd] then
    applyCommand(cmd)
    return
  end
  if IS_POCKET then
    if state.shipId then
      cmd.secret = CONTROL_SECRET
      pcall(rednet.send, state.shipId, cmd, CMD_PROTOCOL)
    end
  else
    applyCommand(cmd)
  end
end

-- Pan by (dx, dy) screen cells. Tiles are world-aligned so panning is just
-- a viewport offset change -- no frame mutation. The draw path composes from
-- whichever tiles are loaded; uncovered regions render as black until the
-- mapLoop fetches them. map_dirty wakes the loop to fetch any new neighbors
-- the pan brought into view.
local function applyDrag(dx, dy)
  local bX = state.bpp * SUB_W
  local bY = state.bpp * SUB_H
  state.mapOffsetX = (state.mapOffsetX or 0) - dx * bX
  state.mapOffsetZ = (state.mapOffsetZ or 0) - dy * bY
  state.isDragging = true
  if state.hasMap then fullRedraw() end
  os.queueEvent("map_dirty")
end

-- commitPendingTap is stored on the state table so it can be called from
-- both handleTouch and eventLoop without needing a top-level local slot.
state._commitTap = function()
  local tap = state.pendingMapTap
  state.pendingMapTap  = nil
  state.pendingTapTimer = nil
  if not tap then return end
  if state.screen == "map" and not state.pinLock
     and state.lastPos and state.hasMap and tap.y <= mapHeight() then
    local cx, cz = mapCenter()
    local wx, wz = cellToWorld(tap.x, tap.y, cx, cz, mapHeight())
    dispatchCommand({
      cmd = "set_target",
      target = {
        kind  = "pin",
        name  = "Pin",
        x     = math.floor(wx + 0.5),
        z     = math.floor(wz + 0.5),
        color = "e",
      },
    })
  end
end

local function handleTouch(evtName, side, x, y)
  local mapH = mapHeight()
  -- Drag detection for map screen: rapid consecutive touches in the map area.
  -- monitor_touch fires for every cell entered during a drag, so we need to
  -- disambiguate drag from tap before committing pin placement.
  local isMonitorTouch = (evtName == "monitor_touch")
  if state.screen == "map" and state.lastPos and state.hasMap and y <= mapH then
    local now = os.clock()
    local px, py, pt = state.dragPrevX, state.dragPrevY, state.dragPrevTime or 0
    state.dragPrevX, state.dragPrevY, state.dragPrevTime = x, y, now
    if px ~= nil and py ~= nil and (now - pt) < 0.6 then
      local dx, dy = x - px, y - py
      if math.abs(dx) >= 1 or math.abs(dy) >= 1 then
        -- Cancel any pending tap — this turned out to be a drag gesture.
        state.pendingMapTap  = nil
        state.pendingTapTimer = nil
        applyDrag(dx, dy)
        return  -- consume as drag, not a tap
      end
    end
    state.isDragging = false
    -- For monitor_touch, the first contact in a map area is ambiguous: it
    -- could be a tap or the start of a drag.  Defer pin placement by 0.25s so
    -- we can cancel it if the next event is a drag step.
    if isMonitorTouch and px == nil then
      state.pendingMapTap  = { x = x, y = y }
      state.pendingTapTimer = os.startTimer(0.25)
      return
    end
  else
    state.dragPrevX, state.dragPrevY = nil, nil
    state.isDragging = false
    -- Moved out of map area — commit any pending tap (conservative: treat it
    -- as intentional since a drag would have moved within the map).
    if state.pendingMapTap then state._commitTap() end
  end

  for id, btn in pairs(buttons) do
    if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
      local c = { cmd = id }
      if id == "setting_inc" or id == "setting_dec" then
        c.idx = state.settingIdx
      end
      dispatchCommand(c)
      return
    end
  end
  for _, t in ipairs(state.targetCells or {}) do
    if y == t.row and x >= t.col1 and x <= t.col2 then
      if t.cmd then
        dispatchCommand({ cmd = t.cmd, name = t.name })
      else
        dispatchCommand({
          cmd = "set_target",
          target = { kind = t.kind, name = t.name, x = t.x, z = t.z, color = t.color },
        })
      end
      return
    end
  end
  -- Map tap: place a pin at the tapped world location (unless PIN lock is on).
  if state.screen == "map" and not state.pinLock
     and state.lastPos and state.hasMap and y <= mapHeight() then
    local cx, cz = mapCenter()
    local wx, wz = cellToWorld(x, y, cx, cz, mapHeight())
    dispatchCommand({
      cmd = "set_target",
      target = {
        kind  = "pin",
        name  = "Pin",
        x     = math.floor(wx + 0.5),
        z     = math.floor(wz + 0.5),
        color = "e",
      },
    })
  end
end

-- Snapshot of the ship state that gets broadcast over rednet and returned in
-- response to a local "ship_state_request" event from ship.lua.
local function stateSnapshot()
  return {
    lastPos       = state.lastPos,
    shipHeading   = state.shipHeading,
    altitude      = state.altitude,
    burnerLevel   = state.burnerLevel,
    velocity      = state.velocity,
    vy            = state.vy,
    groundY       = state.groundY,
    target        = state.target,
    engaged       = state.engaged,
    altHoldActive = state.altHoldActive,
    altHoldTarget = state.altHoldTarget,
    aglHoldActive = state.aglHoldActive,
    aglHoldOffset = state.aglHoldOffset,
    altStep       = state.altStep,
    burnerTarget  = state.burnerTarget,
    phase         = state.phase,
    autoStatus    = state.autoStatus,
    bpp           = state.bpp,
    lod           = state.lod,
    cruiseAltAgl    = CRUISE_ALT_AGL,
    minAltAgl       = MIN_ALT_AGL,
    followAltAgl    = FOLLOW_ALT_AGL,
    hoverBurner     = HOVER_BURNER,
    maxSpeed        = MAX_SPEED,
    maxAlt          = MAX_ALT,
    settingsSaved   = SETTINGS_SAVED,   -- so pocket can flag dirty/clean accurately
    customControls     = state.customControls,
    customControlsMeta = CUSTOM_CONTROLS, -- schema so pocket renders the ship's actual control list
  }
end

local function eventLoop()
  while state.running do
    local event = { os.pullEvent() }
    if event[1] == "monitor_touch" or event[1] == "mouse_click" then
      handleTouch(unpackValues(event))
    elseif event[1] == "mouse_drag" then
      -- Pocket terminal drag: event = { "mouse_drag", button, x, y }
      if state.screen == "map" and state.lastPos and state.hasMap then
        local mx, my = event[3], event[4]
        if state.dragPrevX ~= nil then
          local dx = mx - state.dragPrevX
          local dy = my - state.dragPrevY
          if dx ~= 0 or dy ~= 0 then applyDrag(dx, dy) end
        end
        state.dragPrevX, state.dragPrevY = mx, my
      end
    elseif event[1] == "mouse_up" then
      -- End of drag: clear drag state so next click isn't treated as drag delta.
      state.dragPrevX, state.dragPrevY = nil, nil
      state.isDragging = false
    elseif event[1] == "mouse_scroll" then
      -- Scroll wheel / two-finger swipe on pocket: zoom in/out on the map.
      -- direction = -1 (scroll up / pinch open) → zoom in (smaller bpp)
      -- direction =  1 (scroll down / pinch close) → zoom out (larger bpp)
      if state.screen == "map" then
        local dir = event[2]  -- -1 or 1
        dispatchCommand({ cmd = dir < 0 and "zoom_in" or "zoom_out" })
      end
    elseif event[1] == "timer" then
      -- Commit a deferred monitor_touch pin tap once no drag has cancelled it.
      if event[2] == state.pendingTapTimer then
        state._commitTap()
      end
    elseif event[1] == "term_resize" then
      width, height = monitor.getSize()
    elseif event[1] == "key" and event[2] == keys.q then
      state.running = false
    elseif event[1] == "ship_cmd" and type(event[2]) == "table" then
      -- Local CLI on the same computer. On the ship we apply directly; on
      -- the pocket we hop through dispatchCommand so it forwards over rednet.
      if IS_POCKET then dispatchCommand(event[2]) else applyCommand(event[2]) end
    elseif event[1] == "ship_state_request" then
      os.queueEvent("ship_state_response", stateSnapshot())
    elseif event[1] == "ship_waypoints_request" then
      -- Used by the shell autocompleter for `minimap wp <name>`. Just names,
      -- no coords, since the completer only ranks/filters strings.
      local names = {}
      for _, wp in ipairs(state.waypoints or {}) do
        if type(wp.name) == "string" then names[#names + 1] = wp.name end
      end
      os.queueEvent("ship_waypoints_response", names)
    end
  end
end

-- Ship: broadcast a state snapshot every STATE_BROADCAST_INTERVAL and apply
-- inbound commands. Pocket: lookup the ship and consume its state broadcasts.
local function rednetLoop()
  if not modemName then
    while state.running do sleep(1) end
    return
  end
  if IS_POCKET then
    while state.running do
      if not state.shipId then
        state.shipId = rednet.lookup(SHIP_PROTO, SHIP_HOSTNAME)
        if not state.shipId then sleep(LOOKUP_RETRY_INTERVAL) end
      else
        local id, msg = rednet.receive(STATE_PROTOCOL, 1.0)
        if id == state.shipId and type(msg) == "table" then
          if msg.lastPos then state.lastPos = msg.lastPos end
          state.shipHeading   = msg.shipHeading or state.shipHeading
          state.altitude      = msg.altitude
          state.burnerLevel   = msg.burnerLevel
          state.velocity      = msg.velocity
          state.vy            = msg.vy
          state.groundY       = msg.groundY
          -- Detect target identity change so the pocket redraws immediately
          -- when the ship confirms a tap-placed pin (without this the new
          -- pin marker only appears at the next mapTick).
          local _ot, _nt = state.target, msg.target
          local _targetChanged = (_ot == nil) ~= (_nt == nil)
              or (_ot and _nt and (_ot.x ~= _nt.x or _ot.z ~= _nt.z or _ot.name ~= _nt.name or _ot.kind ~= _nt.kind))
          state.target        = msg.target
          if _targetChanged then os.queueEvent("map_dirty") end
          state.engaged       = msg.engaged
          state.altHoldActive = msg.altHoldActive
          state.altHoldTarget = msg.altHoldTarget
          state.aglHoldActive = msg.aglHoldActive
          state.aglHoldOffset = msg.aglHoldOffset
          if msg.altStep then state.altStep = msg.altStep end
          state.burnerTarget  = msg.burnerTarget
          state.phase         = msg.phase
          state.autoStatus    = msg.autoStatus or ""
          -- bpp/lod are local rendering settings; don't let the ship broadcast
          -- overwrite the pocket's own zoom level.
          if msg.cruiseAltAgl   then CRUISE_ALT_AGL        = msg.cruiseAltAgl   end
          if msg.minAltAgl      then MIN_ALT_AGL           = msg.minAltAgl      end
          if msg.followAltAgl   then FOLLOW_ALT_AGL        = msg.followAltAgl   end
          if msg.hoverBurner    then HOVER_BURNER          = msg.hoverBurner    end
          if msg.maxSpeed       then MAX_SPEED             = msg.maxSpeed       end
          if msg.maxAlt         then MAX_ALT               = msg.maxAlt         end
          if type(msg.customControls) == "table" then state.customControls = msg.customControls end
          if type(msg.customControlsMeta) == "table" then CUSTOM_CONTROLS = msg.customControlsMeta end
          if type(msg.settingsSaved) == "table" then
            for i = 1, #SETTINGS do
              if msg.settingsSaved[i] ~= nil then SETTINGS_SAVED[i] = msg.settingsSaved[i] end
            end
          end
          state.lastUpdateAt = os.clock()
        end
      end
    end
  else
    local nextBroadcast = 0
    while state.running do
      local id, msg = rednet.receive(CMD_PROTOCOL, 0.1)
      if id and type(msg) == "table" and authOk(msg) then
        applyCommand(msg)
      end
      if os.clock() >= nextBroadcast then
        pcall(rednet.broadcast, stateSnapshot(), STATE_PROTOCOL)
        nextBroadcast = os.clock() + STATE_BROADCAST_INTERVAL
      end
    end
  end
end

local function resetAllOutputs()
  if IS_POCKET then return end
  for name in pairs(CHANNELS) do setControl(name, false) end
  Lift.reset()
end

-- Persist / restore the controls that have physical side-effects so a reboot
-- doesn't leave relays in an unknown state.  Only runs on the ship.
saveControlState = function()
  if IS_POCKET then return end
  local ok, data = pcall(textutils.serialiseJSON, {
    customControls = state.customControls,
    altHoldActive  = state.altHoldActive,
    altHoldTarget  = state.altHoldTarget,
    aglHoldActive  = state.aglHoldActive,
    aglHoldOffset  = state.aglHoldOffset,
  })
  if not ok then return end
  local f = fs.open("controls.state", "w")
  if not f then return end
  f.write(data)
  f.close()
end

loadControlState = function()
  if IS_POCKET then return end
  if not fs.exists("controls.state") then return end
  local f = fs.open("controls.state", "r")
  local raw = f.readAll()
  f.close()
  local ok, data = pcall(textutils.unserialiseJSON, raw)
  if not ok or type(data) ~= "table" then return end
  -- Restore custom control toggles and re-fire their relays.
  if type(data.customControls) == "table" then
    for name, active in pairs(data.customControls) do
      if type(name) == "string" and type(active) == "boolean" then
        state.customControls[name] = active
        for _, ctl in ipairs(CUSTOM_CONTROLS) do
          if ctl.name == name then
            setControl(name, ctl.inverted ~= active)
            break
          end
        end
      end
    end
  end
  -- Restore altitude locks.
  if data.altHoldActive == true and type(data.altHoldTarget) == "number" then
    state.altHoldActive = true
    state.altHoldTarget = data.altHoldTarget
  end
  if data.aglHoldActive == true and type(data.aglHoldOffset) == "number" then
    state.aglHoldActive = true
    state.aglHoldOffset = data.aglHoldOffset
  end
  print("Control state restored from " .. "controls.state")
end

monitor.setBackgroundColor(colors.black)
monitor.clear()
-- A pulse left HIGH by a previous shutdown would jam the burner. Clear every
-- output before we start so the script always boots from a known state.
resetAllOutputs()
-- Restore persisted control state AFTER the reset so saved relay states win.
loadControlState()
if modemName then
  parallel.waitForAny(mapLoop, fastLoop, eventLoop, rednetLoop)
else
  parallel.waitForAny(mapLoop, fastLoop, eventLoop)
end
-- Clean exit: drop everything so a STOP after `q` doesn't leave a relay HIGH.
resetAllOutputs()
