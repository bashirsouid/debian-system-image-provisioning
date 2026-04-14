pcall(require, "luarocks.loader")

local naughty = require("naughty")
local awful = require("awful")

local system_rc = "/etc/xdg/awesome/rc.lua"
local ok, err = pcall(dofile, system_rc)
if not ok then
    error("failed to load system Awesome config from " .. system_rc .. ": " .. tostring(err))
end

awful.spawn.once("xterm -fa Monospace -fs 11")
awful.spawn.once("picom --config $HOME/.config/picom/picom.conf")

naughty.notify({
    title = "QEMU sample Awesome config active",
    text = "Loaded the repo sample config into this temporary VM home."
})
