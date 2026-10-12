--[[--
The NOTES tab: the notes folder as a list (newest first) under a "New note" item, opened in KOReader's
text editor plugin. New notes start from a dated path in the folder, which the editor lets you rename.
]]

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Utf8Proc = require("ffi/utf8proc")
local datetime = require("datetime")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local Screen = require("device").screen

local NOTES_DIR = "/mnt/us/documents/notes"

local NotesMenu = {
    dir = NOTES_DIR,
}

local function listNotes(dir)
    local notes = {}
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return notes end
    for name in iter, dir_obj do
        local path = dir .. "/" .. name
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and not util.stringStartsWith(name, ".") then
            table.insert(notes, { name = name, path = path, mtime = attr.modification })
        end
    end
    table.sort(notes, function(a, b) return a.mtime > b.mtime end)
    return notes
end

--- Shows the notes list over the current window; `on_home` is called by a swipe up from the bottom edge.
function NotesMenu:show(ui, on_home)
    local editor = ui.texteditor
    if not editor then
        UIManager:show(InfoMessage:new{ text = _("The text editor plugin is disabled.") })
        return
    end
    if not util.makePath(self.dir) then
        UIManager:show(InfoMessage:new{ text = _("Cannot create the notes folder:") .. "\n" .. self.dir })
        return
    end

    local menu
    local function refresh()
        if menu and UIManager:isWidgetShown(menu) then
            menu:switchItemTable(nil, self:genItemTable(editor, refresh))
        end
    end
    menu = Menu:new{
        title = Utf8Proc.uppercase_dumb(_("Notes")),
        subtitle = self.dir,
        item_table = self:genItemTable(editor, refresh),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    -- Same bottom-edge swipe as everywhere else: back to Home.
    local edge_y = Screen:getHeight() * G_defaults:readSetting("DTAP_ZONE_MINIBAR").y
    function menu:onSwipe(arg, ges)
        if ges.direction == "north" and ges.pos.y >= edge_y then
            UIManager:close(self)
            if on_home then on_home() end
            return true
        end
        return Menu.onSwipe(self, arg, ges)
    end
    UIManager:show(menu)
end

function NotesMenu:genItemTable(editor, refresh)
    local items = {
        {
            text = _("New note"),
            bold = true,
            callback = function()
                local path = string.format("%s/%s.txt", self.dir, os.date("%Y-%m-%d %H.%M"))
                editor:newFile(path, refresh)
            end,
        },
    }
    for _, note in ipairs(listNotes(self.dir)) do
        table.insert(items, {
            text = note.name,
            mandatory = datetime.secondsToDateTime(note.mtime),
            callback = function()
                editor:checkEditFile(note.path, false, false, refresh)
            end,
        })
    end
    return items
end

return NotesMenu
