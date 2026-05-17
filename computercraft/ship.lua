-- ship.lua: CLI dispatcher for ship commands. Run via `ship <subcommand> ...`
-- or via the per-command shims (goto, burner, stop, hold, status, wp) that
-- the startup script installs alongside it.
--
-- The same script runs on the ship CC, the pocket, or any dedicated remote
-- controller. Routing:
--   * On the ship itself (altitude_sensor attached) commands are delivered as
--     a local "ship_cmd" os.queueEvent that minimap's eventLoop picks up.
--   * Anywhere else, the command is broadcast on CMD_PROTOCOL with the
--     shared controlSecret -- same path the pocket UI already uses.
--
-- Adding a new command:
--   1. Add a function under `commands` (keyed by the shell name).
--   2. Add a matching `elseif id == "..."` branch in minimap.lua applyCommand.
--   3. Optionally add the name to SHIM_NAMES in startup.lua so a bare
--      `mycmd ...` invocation works without `ship` prefix.

local SHIP_HOST       = "airship"
local STATE_PROTOCOL  = "airship-state"
local CMD_PROTOCOL    = "airship-cmd"

local function readConfig()
  for _, name in ipairs({"minimap.cfg", "minimap-pocket.cfg"}) do
    if fs.exists(name) then
      local f = fs.open(name, "r")
      local raw = f and f.readAll() or ""
      if f then f.close() end
      local ok, parsed = pcall(textutils.unserialiseJSON, raw)
      if ok and type(parsed) == "table" then return parsed end
    end
  end
  return {}
end

local cfg = readConfig()
local AIRSHIP_NAME   = tostring(cfg.airshipName or "main")
local CONTROL_SECRET = tostring(cfg.controlSecret or "")
local SHIP_HOSTNAME  = SHIP_HOST .. "-" .. AIRSHIP_NAME

local function openWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m and type(m.isWireless) == "function" and m.isWireless() then
        if not rednet.isOpen(name) then pcall(rednet.open, name) end
        return name
      end
    end
  end
  return nil
end

-- "Am I the ship?" -- the ship has the altitude sensor; pocket and remote
-- controllers don't.
local function isShip()
  return peripheral.find("altitude_sensor") ~= nil
end

local function send(cmd)
  if isShip() then
    os.queueEvent("ship_cmd", cmd)
    return true
  end
  if not openWirelessModem() then
    print("no wireless modem; can't reach ship")
    return false
  end
  cmd.secret = CONTROL_SECRET
  rednet.broadcast(cmd, CMD_PROTOCOL)
  return true
end

-- Query local minimap (works on ship and pocket; both reply to the event).
local function localStatus(timeout)
  os.queueEvent("ship_state_request")
  local deadline = os.startTimer(timeout or 1.0)
  while true do
    local e, p1 = os.pullEvent()
    if e == "ship_state_response" then return p1 end
    if e == "timer" and p1 == deadline then return nil end
  end
end

-- Remote fallback: listen for one ship state broadcast on CMD-less rednet.
local function remoteStatus(timeout)
  if not openWirelessModem() then return nil end
  local deadline = os.startTimer(timeout or 2.0)
  while true do
    local e, p1, p2, p3 = os.pullEvent()
    if e == "rednet_message" and p3 == STATE_PROTOCOL then return p2 end
    if e == "timer" and p1 == deadline then return nil end
  end
end

local function fmtCoord(n) return n and tostring(math.floor(n + 0.5)) or "?" end

local function printStatus(s)
  if not s then
    print("no state received (is minimap running?)")
    return
  end
  local lp = s.lastPos or {}
  print(string.format("X %s  Z %s  H %s  Alt %s  Burner %s",
    fmtCoord(lp.x), fmtCoord(lp.z), fmtCoord(s.shipHeading),
    fmtCoord(s.altitude), tostring(s.burnerLevel or "?")))
  local mode = "idle"
  if s.engaged then
    mode = "AUTO " .. (s.phase or "")
  elseif s.altHoldActive then
    mode = "HOLD " .. (s.altHoldTarget and fmtCoord(s.altHoldTarget) or "")
  elseif s.burnerTarget then
    mode = "BURNER->" .. tostring(s.burnerTarget)
  end
  print("Mode: " .. mode)
  if s.target then
    print(string.format("Target: %s X%d Z%d",
      tostring(s.target.name or "?"),
      math.floor(s.target.x or 0), math.floor(s.target.z or 0)))
  end
end

local commands = {}

commands["goto"] = function(args)
  local x = tonumber(args[1]); local z = tonumber(args[2])
  if not x or not z then print("usage: goto X Z"); return end
  send({cmd = "goto", x = x, z = z})
  print(string.format("goto %d %d", x, z))
end

commands["burner"] = function(args)
  local n = tonumber(args[1])
  if not n then print("usage: burner N  (0-15)"); return end
  n = math.floor(n)
  if n < 0 or n > 15 then print("burner level must be 0-15"); return end
  send({cmd = "set_burner", level = n})
  print("burner -> " .. n)
end

commands["stop"] = function()
  send({cmd = "stop"})
  print("stop")
end

commands["hold"] = function(args)
  local alt = tonumber(args[1])
  send({cmd = "hold", altitude = alt})
  print(alt and ("hold at " .. math.floor(alt + 0.5)) or "hold toggle")
end

commands["wp"] = function(args)
  if #args == 0 then print("usage: wp <name>"); return end
  local name = table.concat(args, " ")
  send({cmd = "goto_wp", name = name})
  print("wp " .. name)
end

-- Set or clear the control password locally. Pocket stores plaintext (its
-- threat model permits it -- the pocket lives in your inventory); ship stores
-- only the SHA-256 hash so a looted ship leaks no recoverable password. The
-- two devices are configured independently: type the same password on each.
-- Reboots after writing so the running minimap picks up the new value.
commands["password"] = function(args)
  local newPw = args[1] or ""
  local cfgPath
  if pocket then
    cfgPath = "minimap-pocket.cfg"
  elseif isShip() then
    cfgPath = "minimap.cfg"
  else
    print("run `minimap password` on the ship or the pocket")
    return
  end
  if not fs.exists(cfgPath) then
    print(cfgPath .. " not found; reboot once to create it")
    return
  end
  local f = fs.open(cfgPath, "r")
  local raw = f.readAll(); f.close()
  local ok, c = pcall(textutils.unserialiseJSON, raw)
  if not ok or type(c) ~= "table" then
    print("can't parse " .. cfgPath)
    return
  end

  if pocket then
    c.controlSecret = newPw
  else
    if not fs.exists("sha256.lua") then
      print("sha256.lua missing; reboot to fetch it then retry")
      return
    end
    local Sha = dofile("sha256.lua")
    c.controlSecret = nil
    c.controlSecretHash = (newPw == "") and "" or Sha.hash(newPw)
    c.authVersion = 1
  end

  local body
  if fs.exists("cfgutil.lua") then
    local Cfg = dofile("cfgutil.lua")
    body = Cfg.jsonPretty(c) .. "\n"
  else
    body = textutils.serialiseJSON(c)
  end
  if fs.exists(cfgPath) then fs.delete(cfgPath) end
  f = fs.open(cfgPath, "w"); f.write(body); f.close()

  if newPw == "" then
    print("password cleared on this " .. (pocket and "pocket" or "ship"))
  elseif pocket then
    print("password set on this pocket (plaintext on disk)")
  else
    print("password set on this ship (hash stored, plaintext discarded)")
  end
  print("rebooting to apply...")
  sleep(0.5)
  os.reboot()
end

commands["status"] = function()
  local s
  if isShip() or pocket then
    s = localStatus(1.0)
  else
    s = remoteStatus(2.0)
  end
  printStatus(s)
end

commands["help"] = function()
  print("Ship CLI. All forms work; pick whichever is easier to type.")
  print("")
  print("  minimap goto X Z         autopilot to coordinate X,Z")
  print("  minimap burner N         drive burner to level N (0-15)")
  print("  minimap stop             disengage everything")
  print("  minimap hold [alt]       toggle altitude hold (optional alt)")
  print("  minimap wp <name>        autopilot to a named waypoint")
  print("  minimap status           position / heading / mode")
  print("  minimap password [<p>]   set/clear control password (per device)")
  print("")
  print("Each subcommand also exists as a bare shim, e.g. `goto 100 200`.")
end
commands["--help"] = commands["help"]
commands["-h"]     = commands["help"]

local args = {...}
local sub = table.remove(args, 1) or "help"
local handler = commands[sub]
if not handler then
  print("unknown command: " .. sub)
  commands.help()
  return
end
handler(args)
