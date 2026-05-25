-- Self-updating boot: pulls latest startup.lua and minimap.lua from the server,
-- merges any new default config keys without overwriting existing ones, then
-- launches minimap. Network failures are non-fatal -- whatever is on disk runs.
-- __SERVER_URL__ is substituted by the server (app.py) from CLIENT_SERVER_URL.
local SERVER = "__SERVER_URL__"
local CONFIG = "minimap.cfg"

local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  local s = f.readAll()
  f.close()
  return s
end

local function writeFile(p, s)
  local dir = fs.getDir(p)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
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

local function syncFile(name)
  local remote = fetchText(SERVER .. "/" .. name)
  if not remote then return false end
  if readFile(name) == remote then return false end
  if fs.exists(name) then fs.delete(name) end
  writeFile(name, remote)
  print("Updated " .. name)
  return true
end

-- 1. Self-update. If startup.lua itself changed, reboot so the new code runs.
if syncFile("startup.lua") then
  print("startup.lua updated; rebooting...")
  sleep(0.5)
  os.reboot()
end

-- 2. Update minimap.lua in place (not yet loaded, so no reboot needed).
syncFile("minimap.lua")
syncFile("minimap-term.lua")
syncFile("minimap/cache.lua")
syncFile("minimap/lift.lua")
syncFile("minimap/altitude.lua")
syncFile("minimap/lookray.lua")
syncFile("minimap/cfgutil.lua")
syncFile("minimap/sha256.lua")

-- 2a. CLI dispatcher. Invoke commands as `minimap <cmd>`; minimap.lua
-- forwards to ship.lua when called with args.
syncFile("ship.lua")
syncFile("chatctl.lua")

-- 2b. Shared Lua modules are synced under minimap/ before minimap.lua
-- launches so its `dofile(...)` calls succeed.
local Cfg = dofile("minimap/cfgutil.lua")

-- 3. Merge new default config keys without overwriting existing ones, then
-- write the result back in pretty form. Writing every boot canonicalises the
-- layout (compact configs from earlier builds get auto-beautified) and lets
-- new nested defaults (e.g. a new channel) propagate to existing configs.
local defaults = fetchJson(SERVER .. "/config.defaults")
local current = nil
local raw = readFile(CONFIG)
if raw then
  local ok, parsed = pcall(textutils.unserialiseJSON, raw)
  if ok and type(parsed) == "table" then current = parsed end
end
if type(defaults) == "table" then
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
current = current or {}

-- 4. Shell autocomplete for `minimap <subcommand> [args]`. Registered before
-- minimap launches so the prompt has completions available immediately.
local SUBCOMMANDS = {"goto", "lookgoto", "look", "burner", "stop", "hold", "agl", "status", "wp", "ctl", "password", "help", "--help"}

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

shell.run("bg", "minimap")
if current.termMirrorEnabled ~= false then
  shell.run("bg", "minimap-term")
end
shell.run("bg", "chatctl")
