-- lift.lua: burner / lift driver abstraction.
--
-- Two modes:
--   "burner" -- the original Create Aeronautics rig: two pulsed redstone
--     channels (liftUp / liftDown) toggle a Create stockpile switch by +/-1,
--     and an analog input reads the current burner level back. The PID
--     commands a target level and the driver pulses toward it.
--   "direct" -- a single relay+side output where the redstone analog level
--     (0-15) IS the burner setpoint. Open-loop; no peripheral feedback.
--
-- Spruce (the C2 framework) uses "direct" for cheap drones that don't carry
-- the stockpile-switch accumulator. CCMinimap pilots default to "burner".
--
-- Usage:
--   local Lift = dofile("lift.lua")
--   Lift.init({ mode = "burner", channels = ..., inputs = ..., outputs = ...,
--               pulseSeconds = 0.2 })
--   In the controller tick:
--     Lift.tick()                       -- advance pulse state machine
--     state.burnerLevel = Lift.currentLevel()
--     Lift.commandLevel(desiredLevel)   -- 0..15; driver gets us there
--     Lift.idle()                       -- release outputs on stop

local Lift = {}

local config = nil
local relayCache = {}
local pulseState = {}   -- name -> { stage = "on"|"off", endsAt = clock }
local trackedLevel = nil  -- last commanded level; falls back to feedback in burner mode

local function wrapRelay(name)
  if not name then return nil end
  if relayCache[name] then return relayCache[name] end
  local ok, r = pcall(peripheral.wrap, name)
  if ok and r then relayCache[name] = r end
  return relayCache[name]
end

-- An empty/nil relay means "wire goes straight to a side of this computer",
-- which is how cheap turtle drones are built. Fall back to the local redstone
-- API in that case. CCMinimap rigs always pass a real relay name so they
-- keep going through the redstone_relay peripheral.
local function setOutput(relayName, side, on)
  if not relayName or relayName == "" then
    pcall(redstone.setOutput, side, on and true or false)
    return
  end
  local r = wrapRelay(relayName)
  if not r or type(r.setOutput) ~= "function" then return end
  pcall(r.setOutput, side, on and true or false)
end

local function setAnalogOutput(relayName, side, level)
  if not relayName or relayName == "" then
    pcall(redstone.setAnalogOutput, side, level)
    return
  end
  local r = wrapRelay(relayName)
  if not r or type(r.setAnalogOutput) ~= "function" then return end
  pcall(r.setAnalogOutput, side, level)
end

function Lift.init(opts)
  config = opts or {}
  config.channels = config.channels or {}
  config.inputs   = config.inputs   or {}
  config.outputs  = config.outputs  or {}
  config.pulseSeconds = config.pulseSeconds or 0.2
  pulseState = {}
  -- Burner mode reads ground truth from the analog input, so we start
  -- "unknown" (nil) until that input is read. Direct mode is open-loop:
  -- the level we last set IS the truth, and at boot we haven't set
  -- anything, so seed it to 0 so callers see "Bn0" instead of nothing
  -- and the PID's `if not burnerLevel then return` guard doesn't block.
  trackedLevel = (config.mode == "direct") and 0 or nil
end

local function pulseChannel(name)
  if pulseState[name] then return false end
  local ch = config.channels[name]
  if not ch then return false end
  setOutput(ch.relay, ch.side, true)
  pulseState[name] = { stage = "on", endsAt = os.clock() + config.pulseSeconds }
  return true
end

-- Advance the pulse state machine. Cycle is `pulseSeconds` HIGH then
-- `pulseSeconds` LOW before another pulse on the same channel can fire.
function Lift.tick()
  if config.mode ~= "burner" then return end
  local now = os.clock()
  local done = {}
  for name, p in pairs(pulseState) do
    if now >= p.endsAt then
      if p.stage == "on" then
        local ch = config.channels[name]
        if ch then setOutput(ch.relay, ch.side, false) end
        p.stage = "off"
        p.endsAt = now + config.pulseSeconds
      else
        done[#done + 1] = name
      end
    end
  end
  for _, n in ipairs(done) do pulseState[n] = nil end
end

-- Read the burner level. In burner mode the analog input is ground truth;
-- in direct mode we return the level we last commanded.
function Lift.currentLevel()
  if config.mode == "direct" then
    return trackedLevel
  end
  local inp = config.inputs.liftLevel
  if not inp then return trackedLevel end
  local r = wrapRelay(inp.relay)
  if not r or type(r.getAnalogInput) ~= "function" then return trackedLevel end
  local ok, v = pcall(r.getAnalogInput, inp.side)
  if ok and type(v) == "number" then return v end
  return trackedLevel
end

-- Drive the burner toward `level` (0..15). Both modes step by at most +/-1
-- per call: burner mode pulses liftUp/liftDown once, direct mode writes
-- trackedLevel+/-1 to setAnalogOutput. The controller is expected to keep
-- calling each tick until currentLevel() matches.
--
-- Direct mode needs this slew limit because the PID is tuned around the
-- burner-mode rig, where the pulse cycle naturally rate-limits the burner.
-- Without it, a single tick of high vy makes raw clamp to 0 and the analog
-- output slams the burner OFF (then the next tick slams it to 15, etc).
function Lift.commandLevel(level)
  if type(level) ~= "number" then return end
  level = math.max(0, math.min(15, math.floor(level + 0.5)))
  if config.mode == "direct" then
    local cur = trackedLevel or 0
    local step
    if level > cur then step = cur + 1
    elseif level < cur then step = cur - 1
    else step = cur
    end
    local out = config.outputs.lift
    if out then setAnalogOutput(out.relay, out.side, step) end
    trackedLevel = step
    return
  end
  local cur = Lift.currentLevel()
  trackedLevel = level
  if not cur then return end
  if level > cur then pulseChannel("liftUp")
  elseif level < cur then pulseChannel("liftDown")
  end
end

-- Set the burner level directly, bypassing the slew limit. Use this for
-- explicit manual commands (`burner 5`) where the operator wants the
-- burner to jump straight to a value -- not the PID-pacing path. In
-- burner mode there's still no way to "jump" without a stockpile-switch
-- transaction; fall back to commandLevel so the pulse driver gets us
-- there in N ticks.
function Lift.setLevel(level)
  if type(level) ~= "number" then return end
  level = math.max(0, math.min(15, math.floor(level + 0.5)))
  if config.mode == "direct" then
    local out = config.outputs.lift
    if out then setAnalogOutput(out.relay, out.side, level) end
    trackedLevel = level
    return
  end
  Lift.commandLevel(level)
end

-- Release control of the lift. Used when leaving AUTO/HOLD/manual modes.
--
-- Burner mode: drop any in-flight pulse and force the up/down relays LOW so
-- the operator's manual +/- buttons (wired to the same relay outputs) aren't
-- fought by stale CC outputs. Create's stockpile switch keeps the burner at
-- its current level, so the ship hovers.
--
-- Direct mode: FREEZE -- leave the analog output where it was. The redstone
-- relay block holds the last value across CC inactivity, so the burner stays
-- where the last command put it. Without this the ship dropped to 0 after
-- landing (overwriting landBurnerLevel) or after STOP (overwriting cruise).
function Lift.idle()
  if config.mode == "direct" then
    return
  end
  pulseState.liftUp = nil
  pulseState.liftDown = nil
  local cu = config.channels.liftUp
  local cd = config.channels.liftDown
  if cu then setOutput(cu.relay, cu.side, false) end
  if cd then setOutput(cd.relay, cd.side, false) end
  trackedLevel = nil
end

-- Hard reset to a known-safe state. Only called at boot, since the redstone
-- relay block remembers its last analog level across CC reboots and a stale
-- "15" left over from a previous session would slam the burner on startup.
function Lift.reset()
  if config.mode == "direct" then
    local out = config.outputs.lift
    if out then setAnalogOutput(out.relay, out.side, 0) end
    trackedLevel = 0
    return
  end
  Lift.idle()
end

return Lift
