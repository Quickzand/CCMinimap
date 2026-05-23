-- chatctl.lua: optional chat_box control bridge for CCMinimap.
--
-- Listens for chat from exactly one configured player and routes lines that
-- start with `!minimap` through the same ship.lua CLI dispatcher used by the
-- shell command path.

local CONFIG_FILE = "minimap.cfg"

local function readConfig()
  if not fs.exists(CONFIG_FILE) then return {} end
  local f = fs.open(CONFIG_FILE, "r")
  if not f then return {} end
  local raw = f.readAll()
  f.close()
  local ok, parsed = pcall(textutils.unserialiseJSON, raw)
  if ok and type(parsed) == "table" then return parsed end
  return {}
end

local cfg = readConfig()
if cfg.chatControlEnabled ~= true then return end

local playerName = tostring(cfg.playerName or "")
if playerName == "" then return end

local chatBox = peripheral.find("chat_box")
if not chatBox then return end

local function parseChatCommand(line)
  if type(line) ~= "string" then return nil end
  local prefix = "!minimap"
  if line:sub(1, #prefix):lower() ~= prefix then return nil end
  local rest = line:sub(#prefix + 1)
  if rest:match("^%s*$") then return { "help" } end
  if type(shell.tokenize) == "function" then
    local ok, args = pcall(shell.tokenize, rest)
    if ok and type(args) == "table" then return args end
  end
  local args = {}
  for token in rest:gmatch("%S+") do args[#args + 1] = token end
  return args
end

_G.__ship_module = true
local ok, Ship = pcall(dofile, "ship.lua")
_G.__ship_module = nil
if not ok or type(Ship) ~= "table" or type(Ship.run) ~= "function" then return end

while true do
  local _, username, message = os.pullEvent("chat")
  if username == playerName then
    local args = parseChatCommand(message)
    if args and #args > 0 then
      pcall(Ship.run, args)
    end
  end
end
