-- Local TERM mirror for the ship computer. The main `minimap` process remains
-- the only ship controller; this runs the shared minimap UI in local-client mode.
return shell.run("minimap", "--term-client")
