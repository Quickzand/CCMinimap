-- Local TERM mirror for the ship computer. The main `minimap` process remains
-- the only ship controller; this runs the shared minimap UI in local-client mode.
if multishell and multishell.setTitle and multishell.getCurrent then
  multishell.setTitle(multishell.getCurrent(), "minimap-term")
end

local ok, err = pcall(shell.run, "minimap-ui", "--term-client")
if not ok then error(err, 0) end
