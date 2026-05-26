-- CLI shim. Keep `minimap <subcommand>` reserved for shell commands; the
-- long-running ship/pocket/TERM UI lives in minimap-ui.lua.
return shell.run("ship", ...)
