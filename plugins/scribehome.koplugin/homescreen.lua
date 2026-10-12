--[[--
The home window: a status line, the book in hand with three recent ones, and a tab bar.

Everything is painted directly on a fixed grid (px on the Scribe's 1860×2480 portrait screen, 96 px
margins, 2 px rules), so each element lands exactly where the design puts it. Type sizes are points at
300 ppi, set in KOReader's UI faces (cfont, tfont), so the UI font settings apply. The SYSTEM tab swaps
the book area for the system panel; the status line and the tab bar stay.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NotesMenu = require("notesmenu")
local ReadHistory = require("readhistory")
local RenderImage = require("ui/renderimage")
local RenderText = require("ui/rendertext")
local SystemPanel = require("systempanel")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Utf8Proc = require("ffi/utf8proc")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

-- Grid, in px.
local MARGIN = 96
local RULE = 2
local GAP = 32            -- between a rule and the blocks it separates
local GUTTER = 64         -- between the cover and the text column
local COVER_W, COVER_H = 900, 1350
local RECENT_W, RECENT_H = 400, 600
local RECENT_COUNT = 3
local BAR_H = 24          -- progress bar
local BAR_GAP = 24        -- progress bar to its percentage
local AUTHOR_STEP = 144   -- title's last baseline to the author's baseline
local AUTHOR_CLEAR = 96   -- author's last baseline to the progress bar, at least
local AUTHOR_LEADING = 0.15
local TAB_H = 160
local TAB_PAD = 32        -- tab label to its cell's sides, at least
local BLOCK_INSET = 64    -- text inside the big placeholder block
local RECENT_INSET = 32   -- text inside a recent book's placeholder block
local VALUE_GAP = 64      -- system panel: widest label to the value column
local ROW_PAD = 14        -- system panel: rule to cap height, and descender to the next rule
local TOGGLE_W, TOGGLE_H = 176, 80

-- Type sizes, in pt.
local PT = {
    status = 16,
    title = 48,
    author = 26,
    percent = 26,
    tab = 26,
    recent = 26,
    label = 16,
    value = 26,
    toggle = 16,
}

local MIN_PT = 12 -- smallest size text is shrunk to so its longest word fits

local FLASH_INTERVAL = 30 * 60 -- s between full-screen flashes while Home stays up

local TABS = {
    { id = "library", text = _("Library") },
    { id = "notes", text = _("Notes") },
    { id = "terminal", text = _("Terminal") },
    { id = "system", text = _("System") },
}

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.COLOR_LIGHT_GRAY

local function upper(text)
    return Utf8Proc.uppercase_dumb(text)
end

-- Font:getFace() scales its size by Screen:scaleBySize() (min(w, h) / 600, rounded up): hand it the
-- size that lands on the point size's em in px at 300 ppi.
local function getFace(name, pt)
    local em = pt * 300 / 72
    return Font:getFace(name, (em - 0.01) / (math.min(Screen:getWidth(), Screen:getHeight()) / 600))
end

local function textWidth(face, text)
    return RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, false).x
end

-- The face at `pt`, or smaller (down to `min_pt`) until the widest word of `text` fits `width`:
-- a word wider than its column would otherwise be broken mid-word.
local function fitFace(name, pt, min_pt, text, width)
    local face
    while true do
        face = getFace(name, pt)
        local widest = 0
        for word in text:gmatch("%S+") do
            widest = math.max(widest, textWidth(face, word))
        end
        if widest <= width or pt <= min_pt then break end
        pt = pt - 1
    end
    return face, pt
end

-- Height of "H" above the baseline: type is placed by its cap height, as on the rest of the grid.
local function capHeight(face)
    return RenderText:getGlyph(face, 0x48).t
end

-- Side bearings of the first/last glyph (ASCII only), so flush text has its ink, not its origin, on
-- the margin.
local function leftBearing(face, text)
    local b = text:byte(1)
    return (b and b < 128) and (RenderText:getGlyph(face, b).l or 0) or 0
end

local function rightBearing(face, text)
    local b = text:byte(-1)
    if not (b and b < 128) then return 0 end
    local glyph = RenderText:getGlyph(face, b)
    return glyph.ax - glyph.l - glyph.bb:getWidth()
end

local function drawText(bb, x, baseline, face, text, color)
    RenderText:renderUtf8Text(bb, x, baseline, face, text, true, false, color or BLACK)
end

local function inside(pos, rect)
    return pos.x >= rect.x and pos.x < rect.x + rect.w and pos.y >= rect.y and pos.y < rect.y + rect.h
end

-- Wrapped, flush-left text: returns the box, the y to paint it at so its first cap height starts at
-- cap_y, its first baseline, and its line count and pitch.
local function textBox(text, face, width, max_lines, cap_y, leading, bgcolor)
    leading = leading or 0
    local line_px = math.floor((1 + leading) * face.size + 0.5)
    local box = TextBoxWidget:new{
        text = text,
        face = face,
        width = width,
        line_height = leading,
        height = max_lines * line_px,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        bgcolor = bgcolor or WHITE,
    }
    local y = cap_y - (box:getBaseline() - capHeight(face))
    local lines = math.max(1, math.floor(box.height / box:getLineHeight() + 0.5))
    return box, y, y + box:getBaseline(), lines, box:getLineHeight()
end

-- CoverBrowser's book info cache, when that plugin is enabled (loaded plugins are on package.path).
local function getBookInfoManager()
    local ok, bim = pcall(require, "bookinfomanager")
    return ok and bim or nil
end

-- The cached cover scaled to fill w×h (centred, cropping what overflows), or nil.
local function renderCover(bim, file, w, h)
    local info = bim:getBookInfo(file, true)
    if not info then return nil end
    local src = info.cover_bb
    if not (src and info.has_cover) or info.ignore_cover then
        if src then src:free() end
        return nil
    end
    local scale = math.max(w / src:getWidth(), h / src:getHeight())
    local sw = math.max(w, math.floor(src:getWidth() * scale + 0.5))
    local sh = math.max(h, math.floor(src:getHeight() * scale + 0.5))
    local scaled = RenderImage:scaleBlitBuffer(src, sw, sh) -- frees src if it had to scale
    local cover = Blitbuffer.new(w, h, scaled:getType())
    cover:blitFrom(scaled, 0, 0, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    scaled:free()
    return cover
end

-- Whether the cache lacks a cover good enough for w×h (never extracted, or a thumbnail made smaller).
local function needsExtraction(bim, file, w, h)
    local info = bim:getBookInfo(file)
    if not info or info.cover_fetched ~= "Y" then return true end
    return info.has_cover and bim.isCachedCoverInvalid(info, { max_cover_w = w, max_cover_h = h }) and true
end

-- A plain grey block with text set inside it (the placeholder for a missing cover or book).
local function renderBlock(text, w, h, pt, inset)
    local face = fitFace("tfont", pt, MIN_PT, text, w - 2 * inset)
    local block = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    block:fill(GREY)
    local max_lines = math.max(1, math.floor((h - 2 * inset) / face.size))
    local box, y = textBox(text, face, w - 2 * inset, max_lines, inset, 0, GREY)
    box:paintTo(block, inset - leftBearing(face, text), y)
    box:free(true)
    return block
end

local function bookTitleAuthors(ui, file)
    local props = ui.bookinfo and ui.bookinfo:getDocProps(file, nil, true)
    local title = props and (props.display_title or props.title)
    if not title or title == "" then
        local _, filename = util.splitFilePathName(file)
        title = filemanagerutil.splitFileNameType(filename)
    end
    local authors = props and props.authors
    if authors and authors ~= "" then
        authors = authors:gsub("\n", ", ")
    else
        authors = nil
    end
    return title, authors
end

local function bookPercent(file)
    local info = BookList.getBookInfo(file)
    if info.status == "complete" then return 1 end
    return info.percent_finished or 0
end

-- The book in hand (KOReader's last file, which tapping it resumes) and up to RECENT_COUNT others from
-- the history.
local function currentAndRecent()
    local current = G_reader_settings:readSetting("lastfile")
    if current and lfs.attributes(current, "mode") ~= "file" then
        current = nil
    end
    local recent = {}
    for _, item in ipairs(ReadHistory.hist) do
        if #recent == RECENT_COUNT then break end
        if item.file ~= current and lfs.attributes(item.file, "mode") == "file" then
            table.insert(recent, item.file)
        end
    end
    return current, recent
end

local HomeScreen = InputContainer:extend{
    name = "scribehome",
    ui = nil, -- the FileManager we sit on
    covers_fullscreen = true, -- hint for UIManager:_repaint()
    body = "home", -- or "system"
}

HomeScreen.instance = nil -- the one shown, if any

function HomeScreen:init()
    HomeScreen.instance = self
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.tick_func = function() self:tick() end
    self.extract_tried = {}
    self:computeGrid()
    self:updateStatus()
    self:build()
end

function HomeScreen:computeGrid()
    local W, H = self.dimen.w, self.dimen.h
    local g = {}
    g.right = W - MARGIN
    -- Bottom up: tab bar, margin, recent covers, rule, current cover, rule.
    g.tab_y = H - TAB_H
    g.recent_y = g.tab_y - MARGIN - RECENT_H
    g.rule2_y = g.recent_y - GAP - RULE
    g.cover_y = g.rule2_y - GAP - COVER_H
    g.rule1_y = g.cover_y - GAP - RULE
    g.col_x = MARGIN + COVER_W + GUTTER
    g.col_w = g.right - g.col_x

    -- Status line: cap height starting on the top margin.
    g.status_face = getFace("cfont", PT.status)
    g.status_baseline = MARGIN + capHeight(g.status_face)
    local pad = 16 -- so a repaint covers the previous text's ink
    local time_w = textWidth(g.status_face, "00:00")
    local battery_w = textWidth(g.status_face, "100%")
    g.time_box = Geom:new{ x = MARGIN - pad, y = MARGIN - pad, w = time_w + 2 * pad, h = g.status_baseline - MARGIN + 2 * pad }
    g.battery_box = Geom:new{ x = g.right - battery_w - pad, y = g.time_box.y, w = battery_w + 2 * pad, h = g.time_box.h }
    g.status_rect = Geom:new{ x = 0, y = 0, w = W, h = g.rule1_y }

    -- Tabs: four equal cells; labels at PT.tab unless the widest would not fit its cell.
    g.tab_w = math.floor(W / #TABS)
    local labels = {}
    for i, tab in ipairs(TABS) do
        labels[i] = upper(tab.text)
    end
    local pt
    g.tab_face, pt = fitFace("cfont", PT.tab, MIN_PT, table.concat(labels, " "), g.tab_w - 2 * TAB_PAD)
    if pt < PT.tab then
        logger.dbg("ScribeHome: tab labels set at", pt, "pt to fit", g.tab_w, "px cells")
    end
    self.grid = g
end

function HomeScreen:updateStatus()
    self.time_text = os.date("%H:%M")
    self.battery_text = string.format("%d%%", Device:getPowerDevice():getCapacity())
end

--[[ Building: each body becomes a list of painters and of tap targets. ]]

function HomeScreen:build()
    self:freeItems()
    self.items, self.rules, self.hits = {}, {}, {}
    self.dithered = nil
    if self.body == "system" then
        self:buildSystem()
    else
        self:buildHome()
    end
    self:buildTabs()
end

function HomeScreen:freeItems()
    if not self.items then return end
    for _, item in ipairs(self.items) do
        if item.free then item.free() end
    end
    self.items = nil
end

function HomeScreen:addPaint(paint, free)
    table.insert(self.items, { paint = paint, free = free })
end

function HomeScreen:addHit(rect, callback)
    table.insert(self.hits, { rect = rect, callback = callback })
end

-- Rules are painted after the rest: a text box paints its background over its whole box, which may
-- reach a rule above its first cap height.
function HomeScreen:addRule(y)
    table.insert(self.rules, y)
end

function HomeScreen:addImage(image, x, y)
    self:addPaint(function(bb, x0, y0)
        bb:blitFrom(image, x0 + x, y0 + y, 0, 0, image:getWidth(), image:getHeight())
    end, function()
        image:free()
    end)
end

function HomeScreen:addTextBox(box, x, y)
    self:addPaint(function(bb, x0, y0)
        box:paintTo(bb, x0 + x, y0 + y)
    end, function()
        box:free(true)
    end)
end

function HomeScreen:addText(text, face, x, baseline, color)
    self:addPaint(function(bb, x0, y0)
        drawText(bb, x0 + x, y0 + baseline, face, text, color)
    end)
end

-- A book's cover, or a grey block with its title; covers missing from the cache (or cached too small)
-- are queued for extraction.
function HomeScreen:addCover(bim, file, title, x, y, w, h, pt, inset)
    local image = bim and renderCover(bim, file, w, h)
    if image then
        self.dithered = true
    else
        image = renderBlock(title, w, h, pt, inset)
    end
    -- Once per book while we are shown, so a book whose extraction fails is not retried forever.
    if bim and not self.extract_tried[file] and needsExtraction(bim, file, w, h) then
        self.extract_tried[file] = true
        table.insert(self.to_extract, { filepath = file, cover_specs = { max_cover_w = w, max_cover_h = h } })
    end
    self:addImage(image, x, y)
end

function HomeScreen:buildHome()
    local g = self.grid
    local current, recent = currentAndRecent()
    local bim = getBookInfoManager()
    self.to_extract = {}
    self:addRule(g.rule1_y)

    if current then
        local title, authors = bookTitleAuthors(self.ui, current)
        self:addCover(bim, current, title, MARGIN, g.cover_y, COVER_W, COVER_H, PT.title, BLOCK_INSET)

        -- Text column: title from the cover's top, author under it, progress on the cover's bottom.
        local tface = fitFace("tfont", PT.title, MIN_PT, title, g.col_w)
        local aface = getFace("cfont", PT.author)
        local pface = getFace("cfont", PT.percent)
        local bar_y = g.cover_y + COVER_H - BAR_H
        local first_baseline = g.cover_y + capHeight(tface)
        local author_box, author_dy, author_lines, author_px
        if authors then
            -- Up to two lines; the title gets what is left above them. Laid out with its first cap
            -- height at 0, so author_dy is the box's offset from that cap height.
            local __
            author_box, author_dy, __, author_lines, author_px = textBox(authors, aface, g.col_w, 2, 0, AUTHOR_LEADING)
        end
        local last_baseline_max = bar_y - AUTHOR_CLEAR
        if authors then
            last_baseline_max = last_baseline_max - (author_lines - 1) * author_px - AUTHOR_STEP
        end
        local max_lines = math.max(1, math.floor((last_baseline_max - first_baseline) / tface.size) + 1)
        local box, box_y, baseline, lines, line_px = textBox(title, tface, g.col_w, max_lines, g.cover_y)
        self:addTextBox(box, g.col_x - leftBearing(tface, title), box_y)
        if authors then
            local author_baseline = baseline + (lines - 1) * line_px + AUTHOR_STEP
            self:addTextBox(author_box, g.col_x - leftBearing(aface, authors),
                author_baseline - capHeight(aface) + author_dy)
        end

        local percent = bookPercent(current)
        local label = string.format("%d%%", math.floor(percent * 100 + 1e-6))
        local label_x = g.right - textWidth(pface, label) + rightBearing(pface, label)
        -- Digits centred on the bar.
        local label_baseline = math.floor(bar_y + BAR_H / 2 + RenderText:getGlyph(pface, 0x30).t / 2 + 0.5)
        local bar_w = label_x - BAR_GAP - g.col_x
        self:addPaint(function(bb, x0, y0)
            bb:paintRect(x0 + g.col_x, y0 + bar_y, bar_w, BAR_H, GREY)
            local fill = math.floor(bar_w * math.min(1, math.max(0, percent)) + 0.5)
            if fill > 0 then
                bb:paintRect(x0 + g.col_x, y0 + bar_y, fill, BAR_H, BLACK)
            end
        end)
        self:addText(label, pface, label_x, label_baseline)

        local open = function() self:openBook(current) end
        self:addHit(Geom:new{ x = MARGIN, y = g.cover_y, w = COVER_W, h = COVER_H }, open)
        self:addHit(Geom:new{ x = g.col_x, y = g.cover_y, w = g.col_w, h = COVER_H }, open)
    else
        local block = renderBlock(_("NO BOOK OPEN"), COVER_W, COVER_H, PT.title, BLOCK_INSET)
        self:addImage(block, MARGIN, g.cover_y)
    end

    if #recent > 0 then
        self:addRule(g.rule2_y)
        local step = (g.right - MARGIN - RECENT_W) / math.max(1, RECENT_COUNT - 1)
        for i, file in ipairs(recent) do
            local x = MARGIN + math.floor((i - 1) * step + 0.5)
            local title = bookTitleAuthors(self.ui, file)
            self:addCover(bim, file, title, x, g.recent_y, RECENT_W, RECENT_H, PT.recent, RECENT_INSET)
            self:addHit(Geom:new{ x = x, y = g.recent_y, w = RECENT_W, h = RECENT_H }, function()
                self:openBook(file)
            end)
        end
    end

    if #self.to_extract > 0 then
        self:extractCovers(bim, self.to_extract)
    end
end

-- The system panel: a table of rows under the status line (the first one hangs from its rule), values
-- in a column right of the widest label, then the actions.
function HomeScreen:buildSystem()
    local g = self.grid
    local lface = getFace("cfont", PT.label)
    local vface = getFace("cfont", PT.value)
    local aface = getFace("tfont", PT.value)
    local rows = SystemPanel.rows()
    local label_w = 0
    for _, row in ipairs(rows) do
        label_w = math.max(label_w, textWidth(lface, upper(row.label)))
    end
    local value_x = MARGIN + label_w + VALUE_GAP
    local vcap = capHeight(vface)
    local face_h, face_asc = vface.ftsize:getHeightAndAscender()
    local descent = math.ceil(face_h - face_asc)
    local value_w = g.right - value_x
    local y = g.rule1_y

    -- One row: a rule, the caps label, and either a wrapped value, a Wi-Fi toggle or an action.
    local function addRow(label, value, toggle, action)
        self:addRule(y)
        local cap_y = y + RULE + ROW_PAD
        local baseline, lines, line_px = cap_y + vcap, 1, 0
        if value then
            local box, box_y
            box, box_y, baseline, lines, line_px = textBox(value, vface, value_w, 3, cap_y, 0.1)
            self:addTextBox(box, value_x - leftBearing(vface, value), box_y)
        end
        local row_bottom = baseline + (lines - 1) * line_px + descent + ROW_PAD
        if action then
            local text = upper(label)
            self:addText(text, aface, MARGIN - leftBearing(aface, text), baseline)
            self:addHit(Geom:new{ x = 0, y = y, w = self.dimen.w, h = row_bottom - y }, action)
        else
            local text = upper(label)
            self:addText(text, lface, MARGIN - leftBearing(lface, text), baseline)
        end
        if toggle ~= nil then
            local mid = baseline - math.floor(vcap / 2)
            local box_y = mid - TOGGLE_H / 2
            local tface = getFace("tfont", PT.toggle)
            local tcap = capHeight(tface)
            for i, state in ipairs({ true, false }) do
                local bx = value_x + (i - 1) * (TOGGLE_W - RULE)
                local text = state and _("ON") or _("OFF")
                local active = state == toggle
                local tx = bx + math.floor((TOGGLE_W - textWidth(tface, text)) / 2)
                self:addPaint(function(bb, x0, y0)
                    bb:paintRect(x0 + bx, y0 + box_y, TOGGLE_W, TOGGLE_H, BLACK)
                    if not active then
                        bb:paintRect(x0 + bx + RULE, y0 + box_y + RULE, TOGGLE_W - 2 * RULE, TOGGLE_H - 2 * RULE, WHITE)
                    end
                    drawText(bb, x0 + tx, y0 + mid + math.floor(tcap / 2), tface, text, active and WHITE or BLACK)
                end)
            end
            self:addHit(Geom:new{ x = 0, y = y, w = self.dimen.w, h = row_bottom - y }, function()
                self:toggleWifi(not toggle)
            end)
        end
        y = row_bottom
    end

    for _, row in ipairs(rows) do
        addRow(row.label, row.value, row.toggle)
    end
    addRow(_("Restart shell"), nil, nil, SystemPanel.restart)
    addRow(_("Reboot"), nil, nil, SystemPanel.reboot)
    addRow(_("Power off"), nil, nil, SystemPanel.powerOff)
    addRow(_("Amazon UI on next boot"), nil, nil, SystemPanel.amazonUiOnNextBoot)
    self:addRule(y)
    if y + RULE > g.tab_y - MARGIN then
        logger.warn("ScribeHome: system panel ends at", y + RULE, "past", g.tab_y - MARGIN)
    end
end

function HomeScreen:buildTabs()
    local g = self.grid
    local W = self.dimen.w
    local cap = capHeight(g.tab_face)
    local baseline = g.tab_y + math.floor((TAB_H + cap) / 2)
    self:addPaint(function(bb, x0, y0)
        bb:paintRect(x0, y0 + g.tab_y, W, TAB_H, BLACK)
    end)
    for i, tab in ipairs(TABS) do
        local cell_x = (i - 1) * g.tab_w
        local cell_w = i == #TABS and W - cell_x or g.tab_w
        local text = upper(tab.text)
        local tx = cell_x + math.floor((cell_w - textWidth(g.tab_face, text)) / 2)
        local active = tab.id == "system" and self.body == "system"
        self:addPaint(function(bb, x0, y0)
            if active then
                bb:paintRect(x0 + cell_x, y0 + g.tab_y, cell_w, TAB_H, WHITE)
            end
            drawText(bb, x0 + tx, y0 + baseline, g.tab_face, text, active and BLACK or WHITE)
        end)
        self:addHit(Geom:new{ x = cell_x, y = g.tab_y, w = cell_w, h = TAB_H }, function()
            self:onTab(tab.id)
        end)
    end
end

--[[ Painting ]]

function HomeScreen:paintStatusBox(bb, x0, y0, which)
    local g = self.grid
    local box = g[which .. "_box"]
    bb:paintRect(x0 + box.x, y0 + box.y, box.w, box.h, WHITE)
    if which == "time" then
        local text = self.time_text
        drawText(bb, x0 + MARGIN - leftBearing(g.status_face, text), y0 + g.status_baseline, g.status_face, text)
    else
        local text = self.battery_text
        local x = g.right - textWidth(g.status_face, text) + rightBearing(g.status_face, text)
        drawText(bb, x0 + x, y0 + g.status_baseline, g.status_face, text)
    end
end

function HomeScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, WHITE)
    self:paintStatusBox(bb, x, y, "time")
    self:paintStatusBox(bb, x, y, "battery")
    for _, item in ipairs(self.items) do
        item.paint(bb, x, y)
    end
    for _, rule_y in ipairs(self.rules) do
        bb:paintRect(x + MARGIN, y + rule_y, self.grid.right - MARGIN, RULE, BLACK)
    end
end

-- Rebuilds the current body and repaints the whole window.
function HomeScreen:refresh(refreshtype)
    self:build()
    UIManager:setDirty(self, refreshtype or "ui", nil, self.dithered)
end

--- Back to the home page, rebuilt (the books may have changed) and flashed clean.
function HomeScreen:land()
    self.body = "home"
    self:updateStatus()
    self.last_flash = os.time()
    self:refresh("full")
end

--[[ Clock: once a minute, on the minute, repaint just the time (and the battery when it changed). ]]

function HomeScreen:scheduleTick()
    UIManager:unschedule(self.tick_func)
    UIManager:scheduleIn(60 - os.date("*t").sec + 0.1, self.tick_func)
end

function HomeScreen:tick()
    self:scheduleTick()
    local old_battery = self.battery_text
    self:updateStatus()
    -- Under another window: the new time shows when we are uncovered.
    if UIManager:getTopmostVisibleWidget() ~= self then return end
    if os.time() - self.last_flash >= FLASH_INTERVAL then
        self.last_flash = os.time()
        UIManager:setDirty(self, "full", nil, self.dithered)
        return
    end
    self:repaintStatus("time")
    if self.battery_text ~= old_battery then
        self:repaintStatus("battery")
    end
end

function HomeScreen:repaintStatus(which)
    self:paintStatusBox(Screen.bb, self.dimen.x, self.dimen.y, which)
    UIManager:setDirty(nil, "fast", self.grid[which .. "_box"])
end

function HomeScreen:onShow()
    self.last_flash = os.time()
    self:scheduleTick()
end

function HomeScreen:onSuspend()
    UIManager:unschedule(self.tick_func)
end

function HomeScreen:onResume()
    self:updateStatus()
    self:scheduleTick()
end

--[[ Covers missing from CoverBrowser's cache are extracted by its background job, then shown. ]]

function HomeScreen:extractCovers(bim, files)
    if not bim:extractInBackground(files) then return end
    local tries = 0
    local function check()
        if HomeScreen.instance ~= self then return end
        tries = tries + 1
        for _, f in ipairs(files) do
            local specs = f.cover_specs
            if needsExtraction(bim, f.filepath, specs.max_cover_w, specs.max_cover_h) and tries < 60 then
                UIManager:scheduleIn(1, check)
                return
            end
        end
        if self.body == "home" and UIManager:getTopmostVisibleWidget() == self then
            self:refresh("ui")
        end
    end
    UIManager:scheduleIn(1, check)
end

--[[ Input ]]

function HomeScreen:onTap(_, ges)
    if inside(ges.pos, self.grid.status_rect) then
        self:land()
        return true
    end
    for _, hit in ipairs(self.hits) do
        if inside(ges.pos, hit.rect) then
            hit.callback()
            return true
        end
    end
    return true
end

function HomeScreen:onSwipe(_, ges)
    local edge_y = self.dimen.h * G_defaults:readSetting("DTAP_ZONE_MINIBAR").y
    if ges.direction == "north" and ges.pos.y >= edge_y then
        self:land()
    end
    return true
end

function HomeScreen:onTab(id)
    if id == "library" then
        -- The file manager under us, at the home folder.
        UIManager:close(self, "flashui")
        self.ui.file_chooser:goHome()
    elseif id == "notes" then
        NotesMenu:show(self.ui, function() self:land() end)
    elseif id == "terminal" then
        if self.ui.terminal then
            self.ui.terminal:onTerminalStart()
        else
            UIManager:show(InfoMessage:new{ text = _("The terminal plugin is disabled.") })
        end
    elseif id == "system" then
        self.body = "system"
        self:refresh("flashui")
    end
end

function HomeScreen:toggleWifi(on)
    SystemPanel.setWifi(on, function()
        if HomeScreen.instance == self and self.body == "system" then
            self:refresh("ui")
        end
    end)
    -- The address comes some seconds after the switch: look again.
    UIManager:scheduleIn(8, function()
        if HomeScreen.instance == self and self.body == "system" and UIManager:getTopmostVisibleWidget() == self then
            self:refresh("ui")
        end
    end)
end

function HomeScreen:openBook(file)
    -- ReaderUI broadcasts ShowingReader, which closes the file manager and us.
    require("apps/reader/readerui"):showReader(file)
end

function HomeScreen:onShowingReader()
    UIManager:close(self)
end

function HomeScreen:onCloseWidget()
    UIManager:unschedule(self.tick_func)
    self:freeItems()
    if HomeScreen.instance == self then
        HomeScreen.instance = nil
    end
end

return HomeScreen
