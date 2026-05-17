-- startup-pocket.lua: pocket variant of startup.lua. Install by saving this as
-- "startup.lua" on the pocket. On every boot it self-updates from the server
-- (remote /startup-pocket.lua -> local startup.lua), then syncs minimap-pocket
-- and runs it. Network failures are non-fatal — whatever is on disk runs.
-- __SERVER_URL__ is substituted by the server (app.py) from CLIENT_SERVER_URL.
local SERVER = "__SERVER_URL__"
local CONFIG = "minimap-pocket.cfg"

local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  local s = f.readAll()
  f.close()
  return s
end

local function writeFile(p, s)
  local f = fs.open(p, "w")
  f.write(s)
  f.close()
end

local function fetchText(url)
  local ok, r = pcall(http.get, url)
  if not ok or not r then return nil end
  local body = r.readAll()
  r.close()
  return body
end

local function fetchJson(url)
  local body = fetchText(url)
  if not body then return nil end
  local ok, parsed = pcall(textutils.unserialiseJSON, body)
  if ok then return parsed end
  return nil
end

local function syncFile(remoteName, localName)
  local remote = fetchText(SERVER .. "/" .. remoteName)
  if not remote then return false end
  if readFile(localName) == remote then return false end
  if fs.exists(localName) then fs.delete(localName) end
  writeFile(localName, remote)
  print("Updated " .. localName)
  return true
end

-- 1. Self-update. The pocket's local startup.lua mirrors remote /startup-pocket.lua.
if syncFile("startup-pocket.lua", "startup.lua") then
  print("startup.lua updated; rebooting...")
  sleep(0.5)
  os.reboot()
end

-- 2. Pull the pocket client (same minimap.lua content under a different name).
syncFile("minimap-pocket.lua", "minimap-pocket.lua")

-- 2a. CLI dispatcher. Invoke commands as `minimap <cmd>`; the minimap.lua
-- shim below forwards to ship.lua.
syncFile("ship.lua", "ship.lua")

-- The long-running program here is minimap-pocket.lua, so `minimap` alone
-- isn't a thing on the pocket. Drop a thin shim so `minimap <cmd>` and
-- `minimap --help` work the same as on the ship.
local minimapShim = 'shell.run("ship", ...)\n'
if readFile("minimap.lua") ~= minimapShim then
  writeFile("minimap.lua", minimapShim)
end

syncFile("cfgutil.lua", "cfgutil.lua")
local Cfg = dofile("cfgutil.lua")

-- 3. Merge any new default config keys into minimap-pocket.cfg without overwriting.
-- Only pocket-relevant keys; the ship owns controller/peripheral tunables.
-- Always re-serialize in pretty form so compact configs from earlier builds
-- get auto-beautified.
local defaults = fetchJson(SERVER .. "/config.defaults.pocket")
if type(defaults) == "table" then
  local raw = readFile(CONFIG)
  local current = nil
  if raw then
    local ok, parsed = pcall(textutils.unserialiseJSON, raw)
    if ok and type(parsed) == "table" then current = parsed end
  end
  current = current or {}
  local added = Cfg.deepMergeMissing(defaults, current)
  local serialized = Cfg.jsonPretty(current) .. "\n"
  if readFile(CONFIG) ~= serialized then
    writeFile(CONFIG, serialized)
    if #added > 0 then
      print("Added config defaults: " .. table.concat(added, ", "))
    end
  end
end

-- 4. Shell autocomplete for `minimap <subcommand> [args]` (the pocket has the
-- minimap.lua shim that forwards to ship.lua; we register against its path).
local SUBCOMMANDS = {"goto", "burner", "stop", "hold", "status", "wp", "help", "--help"}

local function suffixesFromPrefix(list, prefix)
  local out = {}
  for _, item in ipairs(list) do
    if item:sub(1, #prefix) == prefix and #item > #prefix then
      out[#out + 1] = item:sub(#prefix + 1)
    end
  end
  return out
end

local function fetchWaypointNames()
  os.queueEvent("ship_waypoints_request")
  local deadline = os.startTimer(0.3)
  while true do
    local e, p1 = os.pullEvent()
    if e == "ship_waypoints_response" and type(p1) == "table" then return p1 end
    if e == "timer" and p1 == deadline then return {} end
  end
end

local function minimapCompleter(_, index, argument, previous)
  if index == 1 then
    return suffixesFromPrefix(SUBCOMMANDS, argument)
  end
  if index == 2 and previous[1] == "wp" then
    return suffixesFromPrefix(fetchWaypointNames(), argument)
  end
  return {}
end

local minimapPath = shell.resolveProgram("minimap")
if minimapPath then
  shell.setCompletionFunction(minimapPath, minimapCompleter)
end

shell.run("bg", "minimap-pocket")
