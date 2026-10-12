--[[--
Home screen and launcher.

The home window (see homescreen.lua) sits on top of the file manager and is where the device lands:
every new file manager instance (KOReader starting, or the reader closing) shows it, and so does waking
from sleep, which closes the reader first. From the reader and the file browser, a swipe up from the
bottom edge opens it, as does a tap on the reader's status bar.

@module koplugin.ScribeHome
--]]

local Device = require("device")
local Event = require("ui/event")
local HomeScreen = require("homescreen")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Where a swipe up must start, and where a tap hits the reader's status bar: the reader footer's own
-- tap zone (bottom 1/13 of the screen).
local function bottomEdge()
    local zone = G_defaults:readSetting("DTAP_ZONE_MINIBAR")
    return { ratio_x = zone.x, ratio_y = zone.y, ratio_w = zone.w, ratio_h = zone.h }
end

-- Swipe zones a swipe up from the bottom edge would otherwise reach: the reader's bottom menu and page
-- turns, the file browser's page turns, and the gestures plugin's edge swipes (which cover the corners).
local SWIPE_OVERRIDES = {
    "filemanager_swipe",
    "readerconfigmenu_swipe",
    "readerconfigmenu_ext_swipe",
    "rolling_swipe",
    "paging_swipe",
    "one_finger_swipe_left_edge_up",
    "one_finger_swipe_right_edge_up",
    "one_finger_swipe_bottom_edge_left",
    "one_finger_swipe_bottom_edge_right",
}

local ScribeHome = WidgetContainer:extend{
    name = "scribehome",
    is_doc_only = false,
}

function ScribeHome:init()
    self.is_docless = self.ui.document == nil
    if Device:isTouchDevice() then
        self:setupTouchZones()
    end
    if self.is_docless then
        -- A new file manager means we just landed: KOReader started, or the reader was closed.
        UIManager:nextTick(function()
            self:showHome()
        end)
    end
end

function ScribeHome:setupTouchZones()
    local zones = {
        {
            id = "scribehome_swipe",
            ges = "swipe",
            screen_zone = bottomEdge(),
            handler = function(ges)
                if ges.direction ~= "north" then return end
                self:goHome()
                return true
            end,
            overrides = SWIPE_OVERRIDES,
        },
    }
    if not self.is_docless then
        table.insert(zones, {
            id = "scribehome_footer_tap",
            ges = "tap",
            screen_zone = bottomEdge(),
            handler = function()
                -- Only while the status bar is shown: otherwise the tap brings it back, as usual.
                local view = self.ui.view
                if not (view and view.footer_visible) or view.flipping_visible then return end
                self:goHome()
                return true
            end,
            overrides = { "readerfooter_tap" },
        })
    end
    self.ui:registerTouchZones(zones)
end

function ScribeHome:goHome()
    if self.is_docless then
        self:showHome()
    else
        self:closeReader()
    end
end

-- Shows Home over our file manager, or brings an open one back to its home page.
function ScribeHome:showHome()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance ~= self.ui or self.ui.tearing_down then return end
    local home = HomeScreen.instance
    if home and home.ui == self.ui then
        home:land()
        return
    end
    if home then
        UIManager:close(home)
    end
    UIManager:show(HomeScreen:new{ ui = self.ui }, "full")
end

-- Closes the book the way the reader's file browser button does; the file manager that replaces the
-- reader then shows Home.
function ScribeHome:closeReader()
    local ui = self.ui
    if ui.tearing_down or not ui.document then return end
    ui:handleEvent(Event:new("CloseReaderMenu"))
    ui:handleEvent(Event:new("CloseConfigMenu"))
    ui:onHome()
end

function ScribeHome:onResume()
    UIManager:nextTick(function()
        self:goHome()
    end)
end

function ScribeHome:onCloseWidget()
    -- Home cannot outlive its file manager (an empty window stack is what lets KOReader exit).
    local home = HomeScreen.instance
    if self.is_docless and home and home.ui == self.ui then
        UIManager:close(home)
    end
end

return ScribeHome
