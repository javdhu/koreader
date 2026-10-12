--[[--
What the SYSTEM tab shows and does: the device's state, read fresh each time, and the actions behind
its buttons. Drawing is homescreen.lua's job.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Version = require("version")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- Its presence makes the next boot start Amazon's UI instead of this shell (checked by the jav upstart
-- jobs). /mnt/base-us is the same storage without the FUSE layer, which is unavailable while USB drive
-- mode is on.
local AMAZON_UI_FLAGS = { "/mnt/us/jav-off", "/mnt/base-us/jav-off" }

local SystemPanel = {}

local function firstLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

-- SSID and IPv4 address of the Wi-Fi interface (nil when down or unassociated).
local function wifiAddress(ifname)
    local ok, NetInfo = pcall(require, "ffi/netinfo")
    if not ok then return end
    local ni = NetInfo:new()
    local ok_retrieve, interfaces = pcall(ni.retrieve, ni)
    local ssid, ip
    if ok_retrieve then
        for _, iface in ipairs(interfaces) do
            if iface.name == ifname then
                ssid, ip = iface.ssid, iface.ipv4
            end
        end
    else
        logger.warn("SystemPanel: cannot read network interfaces:", interfaces)
    end
    ni:free()
    return ssid, ip
end

--- Returns the panel's rows: { label = ..., value = ... }, or { label = ..., toggle = bool } for Wi-Fi.
function SystemPanel.rows()
    local NetworkMgr = require("ui/network/manager")
    local ssid, ip = wifiAddress(NetworkMgr:getNetworkInterfaceName() or "wlan0")
    local disk = util.diskUsage("/mnt/us")
    return {
        { label = _("Wi-Fi"), toggle = NetworkMgr:isWifiOn() and true or false },
        { label = _("Network"), value = ssid or _("Not connected") },
        { label = _("IP"), value = ip or _("No address") },
        { label = _("SSH"), value = ip and ("ssh root@" .. ip) or _("No address") },
        { label = _("Battery"), value = string.format("%d%%", Device:getPowerDevice():getCapacity()) },
        { label = _("Storage"), value = disk.available and T(_("%1 free on /mnt/us"), util.getFriendlySize(disk.available)) or _("/mnt/us unavailable") },
        { label = _("Firmware"), value = firstLine("/etc/prettyversion.txt") or _("Unknown") },
        { label = _("Build"), value = Version:getCurrentRevision() or _("Unknown") },
    }
end

--- Turns Wi-Fi on or off through KOReader's network manager; done() runs once the change is through.
function SystemPanel.setWifi(on, done)
    local NetworkMgr = require("ui/network/manager")
    if on then
        NetworkMgr:toggleWifiOn(done, false, true)
    else
        NetworkMgr:toggleWifiOff(done, true)
    end
end

-- KOReader cannot reboot or power off a Kindle by itself (Device:canReboot() is false: Amazon's
-- framework normally owns that), so this follows UIManager's reboot_action/poweroff_action with the
-- system's own commands.
local function shutdown(reboot)
    local Screensaver = require("ui/screensaver")
    if reboot then
        Screensaver:setup("reboot", _("Rebooting…"))
    else
        Screensaver:setup("poweroff", _("Powered off"))
    end
    Screensaver:show()
    logger.info("SystemPanel:", reboot and "rebooting" or "powering off")
    UIManager:broadcastEvent(Event:new(reboot and "Reboot" or "PowerOff"))
    UIManager:broadcastEvent(Event:new("Close", { keep_screensaver = true }))
    -- Let the screensaver be painted first.
    UIManager:nextTick(function()
        Device:saveSettings()
        G_reader_settings:flush()
        os.execute(reboot and "/sbin/reboot" or "/sbin/poweroff")
        UIManager:quit()
    end)
end

function SystemPanel.restart()
    UIManager:show(ConfirmBox:new{
        text = _("Restart KOReader?"),
        ok_text = _("Restart"),
        ok_callback = function()
            UIManager:broadcastEvent(Event:new("Restart"))
        end,
    })
end

function SystemPanel.reboot()
    UIManager:show(ConfirmBox:new{
        text = _("Reboot the device?"),
        ok_text = _("Reboot"),
        ok_callback = function()
            UIManager:nextTick(shutdown, true)
        end,
    })
end

function SystemPanel.powerOff()
    UIManager:show(ConfirmBox:new{
        text = _("Power off the device?"),
        ok_text = _("Power off"),
        ok_callback = function()
            UIManager:nextTick(shutdown, false)
        end,
    })
end

function SystemPanel.amazonUiOnNextBoot()
    UIManager:show(ConfirmBox:new{
        text = T(_("Start the Amazon UI on the next boot?\n\nThis creates %1."), AMAZON_UI_FLAGS[1]),
        ok_text = _("Continue"),
        ok_callback = function()
            local made, err
            for _, path in ipairs(AMAZON_UI_FLAGS) do
                local f
                f, err = io.open(path, "w")
                if f then
                    f:close()
                    made = path
                    break
                end
            end
            if not made then
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not create %1:\n%2"), AMAZON_UI_FLAGS[1], err),
                })
                return
            end
            logger.info("SystemPanel: created", made)
            UIManager:show(ConfirmBox:new{
                text = _("The Amazon UI will start on the next boot. Reboot now?"),
                ok_text = _("Reboot"),
                cancel_text = _("Later"),
                ok_callback = function()
                    UIManager:nextTick(shutdown, true)
                end,
            })
        end,
    })
end

return SystemPanel
