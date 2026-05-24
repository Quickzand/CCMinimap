-- Local TERM mirror for the ship computer. The main `minimap` process remains
-- the only ship controller; this runs the shared minimap UI in local-client mode.
if multishell and multishell.setTitle and multishell.getCurrent then
  multishell.setTitle(multishell.getCurrent(), "minimap-term")
end

_G.MINIMAP_TERM_CLIENT = true
local ok, err = pcall(dofile, "minimap.lua")
_G.MINIMAP_TERM_CLIENT = nil
if not ok then error(err, 0) end
