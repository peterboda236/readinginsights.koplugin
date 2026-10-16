--[[
Reading Insights - the sleep screen.

What the device shows while it sleeps (once "Reading insights" is picked in
Settings > Screen > Sleep screen > Wallpaper) is chosen here, with two
settings of its own:

  content      what is drawn:
                 insights        the Reading insights window (default)
                 heatmap         the reading heatmap popup
                 streak          the current / best streak popup
                 book_progress   the Book progress popup ("This book")
                 book_calendar   the Book progress calendar popup
                 book_info       the Book info popup
                 records         the Records popup
               The three book ones are drawn from the open book; from the
               file manager, from the last book read (lib/lastbook.lua).
  background   what is behind the popup:
                 cover           the cover of the book being read (or, from
                                 the file manager, of the last book read)
                 plain           a plain page: white, or black in KOReader's
                                 night mode (see below)
                 custom          a picture of your own, read from
                                 <KOReader settings dir>/readinginsights/wallpapers/
                                 (one chosen in the menu, or a random one
                                 each time - the way Book card does it)
  fit          how a cover / custom picture is put on the screen:
                 fit             whole picture, aspect ratio kept (default)
                 stretch         stretched to the whole screen
                 zoom            enlarged to fill the screen, the overflow
                                 cropped (centred)

Night mode: KOReader's night mode inverts what the screen paints, so a page
painted "white" is shown black and the popups' white cards are shown black
with light text - no colours are picked here, the plain background simply
follows the dark mode. Covers and custom pictures are painted pre-inverted in
night mode, so they keep looking like the original.

Everything is built SYNCHRONOUSLY, inside the "Suspend" event, before core
schedules the actual suspend: the stats of the running session are written
to the database, every query is run (nothing is left to a scheduleIn() that
could fire while the device is already going to sleep), the widgets are
shown and the screen is repainted with UIManager:forceRePaint(). Only then
does the Suspend handler return.

  SleepScreen.show(ui, before_paint)
                         -> list of the widgets that were shown (bottom
                            first), to hand to SleepScreen.close()
  SleepScreen.close(list)
  SleepScreen.preview(ui, touchmenu_instance)
                         -> the same screen, shown on demand from the menu;
                            a tap, a swipe or the Back key closes it again
]]--

local deps = ...
local Locale       = deps.Locale
local Prefs        = deps.Prefs
local Insights     = deps.Insights
local Records      = deps.Records
local Heatmap      = deps.Heatmap
local Streak       = deps.Streak
local BookCalendar = deps.BookCalendar
local LastBook     = deps.LastBook
local StatsPopup   = deps.StatsPopup
local BookInfo     = deps.BookInfo
local BookInfoData = deps.BookInfoData
local InsightsData = deps.InsightsData
local _ = Locale._

local Blitbuffer      = require("ffi/blitbuffer")
local DataStorage     = require("datastorage")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local Screen          = Device.screen
local UIManager       = require("ui/uimanager")
local Widget          = require("ui/widget/widget")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")

local M = {}

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
local CONTENT_SETTING    = "readinginsights_sleep_content"
local BACKGROUND_SETTING = "readinginsights_sleep_background"

M.DEFAULT_CONTENT    = "insights"
M.DEFAULT_BACKGROUND = "cover"

-- Menu order.
function M.contents()
    return {
        { id = "insights",      text = Locale.insightsTitle() },
        { id = "heatmap",       text = _("Reading heatmap") },
        { id = "streak",        text = _("Reading streak") },
        { id = "book_progress", text = _("Book progress") },
        { id = "book_calendar", text = _("Book progress calendar") },
        { id = "book_info",     text = _("Book info") },
        { id = "records",       text = _("Records") },
    }
end

function M.backgrounds()
    return {
        { id = "cover",  text = _("Book cover") },
        { id = "plain",  text = _("Follow theme") },
        { id = "custom", text = _("Custom image") },
    }
end

function M.fits()
    return {
        { id = "fit",     text = _("Fit") },
        { id = "stretch", text = _("Stretch") },
        { id = "zoom",    text = _("Zoom") },
    }
end

local function isValid(list, id)
    for _i, item in ipairs(list) do
        if item.id == id then return true end
    end
    return false
end

function M.readContent()
    local v = Prefs.read(CONTENT_SETTING, M.DEFAULT_CONTENT)
    if not isValid(M.contents(), v) then return M.DEFAULT_CONTENT end
    return v
end

function M.saveContent(id)
    if isValid(M.contents(), id) then Prefs.save(CONTENT_SETTING, id) end
end

function M.readBackground()
    local v = Prefs.read(BACKGROUND_SETTING, M.DEFAULT_BACKGROUND)
    if not isValid(M.backgrounds(), v) then return M.DEFAULT_BACKGROUND end
    return v
end

function M.saveBackground(id)
    if isValid(M.backgrounds(), id) then Prefs.save(BACKGROUND_SETTING, id) end
end

local FIT_SETTING = "readinginsights_sleep_fit"
M.DEFAULT_FIT = "fit"

function M.readFit()
    local v = Prefs.read(FIT_SETTING, M.DEFAULT_FIT)
    if not isValid(M.fits(), v) then return M.DEFAULT_FIT end
    return v
end

function M.saveFit(id)
    if isValid(M.fits(), id) then Prefs.save(FIT_SETTING, id) end
end

-- ---------------------------------------------------------------------
-- Custom pictures: <settings dir>/readinginsights/wallpapers/
-- (the same scheme as Book card's wallpaper, in this plugin's own folder)
-- ---------------------------------------------------------------------
local WALLPAPER_SETTING = "readinginsights_sleep_wallpaper"
M.RANDOM = "*random*"   -- stored in the setting when "Random" is chosen
M.SUBDIR = "readinginsights/wallpapers"
M.EXTS   = { png = true, jpg = true, jpeg = true, bmp = true, gif = true, webp = true }

function M.wallpaperDir()
    return DataStorage:getSettingsDir() .. "/" .. M.SUBDIR
end

local function ensureWallpaperDir()
    local d = M.wallpaperDir()
    if lfs.attributes(d, "mode") == "directory" then return true end
    local ok = pcall(require("util").makePath, d .. "/")
    return ok and lfs.attributes(d, "mode") == "directory"
end

-- { { name, label }, ... } sorted by label; `name` is the plain file name
-- (what is stored), `label` drops the extension.
function M.listWallpapers()
    ensureWallpaperDir()
    local out = {}
    pcall(function()
        for name in lfs.dir(M.wallpaperDir()) do
            local ext = name:match("%.([^%.]+)$")
            if name ~= "." and name ~= ".." and ext and M.EXTS[ext:lower()] then
                out[#out + 1] = { name = name, label = name:match("^(.+)%.[^%.]+$") or name }
            end
        end
    end)
    table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
    return out
end

-- Absolute path, or nil when there is no such file. Refuses anything with a
-- path separator: the name comes out of settings, which can be hand-edited.
local function wallpaperPath(name)
    if type(name) ~= "string" or name == "" then return nil end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
    if name == "." or name == ".." then return nil end
    local path = M.wallpaperDir() .. "/" .. name
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    return path
end

function M.selectedWallpaper()
    local v = Prefs.read(WALLPAPER_SETTING, false)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

function M.wallpaperLabel()
    local name = M.selectedWallpaper()
    if not name then return _("None") end
    if name == M.RANDOM then return _("Random") end
    for _i, it in ipairs(M.listWallpapers()) do
        if it.name == name then return it.label end
    end
    return name
end

local last_random_name
-- The file to draw now: the chosen one, or (Random) one picked from the
-- folder, never the same twice in a row when there is a choice.
local function activeWallpaper()
    local name = M.selectedWallpaper()
    if name ~= M.RANDOM then return name end
    local list = M.listWallpapers()
    if #list == 0 then return nil end
    local pool = list
    if #list > 1 and last_random_name then
        pool = {}
        for _i, it in ipairs(list) do
            if it.name ~= last_random_name then pool[#pool + 1] = it end
        end
    end
    local pick = pool[math.random(#pool)]
    last_random_name = pick.name
    return pick.name
end

-- sub_item_table for "Custom image": Random, then every picture in the
-- folder, then a disabled footnote naming the folder (shown even when it is
-- empty, so you always see where to put pictures). Picking one also switches
-- the background to "Custom image".
function M.buildWallpaperMenu()
    local items = {}
    local function pick(value)
        return function(touchmenu_instance)
            Prefs.save(WALLPAPER_SETTING, value)
            M.saveBackground("custom")
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end
    end
    items[#items + 1] = {
        text = _("Random"),
        radio = true,
        checked_func = function() return M.selectedWallpaper() == M.RANDOM end,
        keep_menu_open = true,
        callback = pick(M.RANDOM),
        separator = true,
    }
    local list = M.listWallpapers()
    for i, it in ipairs(list) do
        items[#items + 1] = {
            text = it.label,
            radio = true,
            checked_func = function() return M.selectedWallpaper() == it.name end,
            keep_menu_open = true,
            callback = pick(it.name),
            separator = (i == #list) or nil,
        }
    end
    local dir = M.wallpaperDir()
    if #list == 0 then
        items[#items + 1] = {
            text = (_("No images in {dir}"):gsub("{dir}", function() return dir end)),
            enabled = false,
            separator = true,
        }
    end
    items[#items + 1] = {
        text = (_("Images are loaded from {dir}"):gsub("{dir}", function() return dir end)),
        enabled = false,
    }
    return items
end

-- ---------------------------------------------------------------------
-- Which book is "the book"
-- ---------------------------------------------------------------------

-- The open book if there is one, else the last book read (KOReader's own
-- "last file" setting, which is what core's cover sleep screen falls back to
-- too). Returns the file path or nil.
local function currentBookFile(ui)
    local file = ui and ui.document and ui.document.file or nil
    if file then return file end
    local last = G_reader_settings and G_reader_settings:readSetting("lastfile")
    if last and lfs.attributes(last, "mode") == "file" then return last end
    return nil
end

local function hasOpenBook(ui)
    return ui ~= nil and ui.document ~= nil
end

-- A fresh cover BlitBuffer for the book (caller owns it), or nil.
local function loadCover(ui)
    local ok, bb = pcall(function()
        if hasOpenBook(ui) then
            return BookInfoData.getCover(ui)
        end
        local file = currentBookFile(ui)
        if file then return BookInfoData.getCover(nil, file) end
        return nil
    end)
    if ok then return bb end
    logger.warn("ReadingInsights sleep screen: cover failed:", tostring(bb))
    return nil
end

-- ---------------------------------------------------------------------
-- Background widget
-- ---------------------------------------------------------------------

-- A decoded picture of the custom folder (caller owns it), or nil.
local function loadWallpaper()
    local path = wallpaperPath(activeWallpaper())
    if not path then return nil end
    local ok, bb = pcall(function()
        return require("ui/renderimage"):renderImageFile(path, false)
    end)
    if ok and bb then return bb end
    logger.info("ReadingInsights sleep screen: picture could not be decoded:", path)
    return nil
end

-- A full-screen page: a plain white page with the picture put on it the way
-- the "Image fit" setting says. The picture is scaled once, here, to its
-- final size (the source is freed); paintTo only blits.
local ImagePage = Widget:extend{ bb = nil, w = 0, h = 0, pw = 0, ph = 0 }

function ImagePage:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function ImagePage:paintTo(target, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    target:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    if not self.bb then return end
    -- Centred; a picture larger than the screen (zoom) is cropped on both
    -- sides, a smaller one (fit) is surrounded by the page.
    local ox = math.floor((self.w - self.pw) / 2)
    local oy = math.floor((self.h - self.ph) / 2)
    local dx, dy = math.max(0, ox), math.max(0, oy)
    local sx, sy = math.max(0, -ox), math.max(0, -oy)
    local cw = math.min(self.pw - sx, self.w - dx)
    local ch = math.min(self.ph - sy, self.h - dy)
    if cw <= 0 or ch <= 0 then return end
    pcall(function() target:blitFrom(self.bb, x + dx, y + dy, sx, sy, cw, ch) end)
end

function ImagePage:free()
    if self.bb then
        pcall(function() self.bb:free() end)
        self.bb = nil
    end
end
ImagePage.onCloseWidget = ImagePage.free

-- Scales `src` (taking ownership) for the fit mode; returns bb, w, h.
local function prepareImage(src, fit, screen_w, screen_h)
    local bw, bh = src:getWidth(), src:getHeight()
    local tw, th
    if fit == "stretch" then
        tw, th = screen_w, screen_h
    elseif fit == "zoom" then
        local scale = math.max(screen_w / bw, screen_h / bh)
        tw, th = math.max(screen_w, math.ceil(bw * scale)), math.max(screen_h, math.ceil(bh * scale))
    else
        local scale = math.min(screen_w / bw, screen_h / bh)
        tw, th = math.max(1, math.floor(bw * scale)), math.max(1, math.floor(bh * scale))
    end
    local scaled = require("ui/renderimage"):scaleBlitBuffer(src, tw, th, true)
    -- KOReader's night mode inverts the whole panel at refresh, so a picture
    -- that should keep looking like itself is painted pre-inverted (the same
    -- compensation ImageWidget and Book card's wallpaper apply).
    if Screen.night_mode and scaled.invertRect then
        scaled:invertRect(0, 0, scaled:getWidth(), scaled:getHeight())
    end
    return scaled, scaled:getWidth(), scaled:getHeight()
end

-- The page (picture or plain) as one widget to show under the popup.
local function buildBackground(src_bb)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local page = ImagePage:new{ w = screen_w, h = screen_h }
    if src_bb then
        local ok, bb, pw, ph = pcall(prepareImage, src_bb, M.readFit(), screen_w, screen_h)
        if ok and bb then
            page.bb, page.pw, page.ph = bb, pw, ph
        else
            logger.warn("ReadingInsights sleep screen: picture failed:", tostring(bb))
            pcall(function() src_bb:free() end)
        end
    end
    return page
end

-- ---------------------------------------------------------------------
-- Contents
-- ---------------------------------------------------------------------

-- Each builder returns the (already built, already shown) popup, or nil when
-- it cannot be made right now - the caller then falls back to the insights
-- window. They must not leave work for later: every query runs inside.

local function showInsights(ui)
    local popup = Insights.Popup:new{ ui = ui, readonly = true }
    UIManager:show(popup, "full")
    return popup
end

-- Heatmap.Popup only calls getDailyReadingDataForRange on `popup_self`; this
-- is the same stand-in main.lua's gesture entry uses (a { date = seconds }
-- map for the range, one calendar year at a time).
local function heatmapSource()
    return {
        getDailyReadingDataForRange = function(_self, start_t, end_t, shared_conn)
            local year_start = tonumber(os.date("%Y", start_t))
            local year_end   = tonumber(os.date("%Y", end_t))
            local start_str  = os.date("%Y-%m-%d", start_t)
            local end_str    = os.date("%Y-%m-%d", end_t)
            local merged = {}
            for year = year_start, year_end do
                local year_map = InsightsData.getDailyReadingData(year, shared_conn)
                for dstr, seconds in pairs(year_map) do
                    if dstr >= start_str and dstr <= end_str then
                        merged[dstr] = seconds
                    end
                end
            end
            return merged
        end,
    }
end

local function showHeatmap(ui)
    local popup = Heatmap.Popup:new{
        popup_self   = heatmapSource(),
        periods_back = 0,
        readonly     = true,
    }
    UIManager:show(popup)
    return popup
end

local function showStreak(ui)
    return Streak.show(InsightsData.calculateStreaks(), { sync = true })
end

local function showRecords(ui)
    local popup = Records.Popup:new{ ui = ui }
    UIManager:show(popup)
    return popup
end

-- The open book, or - from the file manager - the last book read, as kept by
-- lib/lastbook.lua. Returns the snapshot (nil with an open book) and whether
-- there is anything to draw.
local function lastBookSnapshot(ui)
    if hasOpenBook(ui) then return nil, true end
    local snap = LastBook and LastBook.get() or nil
    return snap, snap ~= nil
end

local function showBookProgress(ui)
    local snap, ok = lastBookSnapshot(ui)
    if not ok then return nil end
    local popup
    if snap then
        if type(snap.stats) ~= "table" then return nil end
        popup = StatsPopup:new{ snapshot = snap.stats, readonly = true }
    else
        popup = StatsPopup:new{ ui = ui, readonly = true }
    end
    UIManager:show(popup)
    return popup
end

local function showBookCalendar(ui)
    local snap, ok = lastBookSnapshot(ui)
    if not ok then return nil end
    -- Same inputs main.lua's menu/gesture entry computes; checked here
    -- BEFORE opening so a book without reading data never pops up the
    -- "No reading data" message on the sleep screen.
    local stats
    if snap then
        stats = snap.stats
        ui = nil
    else
        stats = StatsPopup.gatherStats{ ui = ui }
    end
    if type(stats) ~= "table" or not stats.book_id then return nil end
    local total = stats.total_pages_for_calendar
    if not total or total <= 0 then return nil end
    return BookCalendar.show{
        ui                = ui,
        book_id           = stats.book_id,
        total_pages       = total,
        finish_timestamp  = stats.finish_timestamp,
        started_timestamp = stats.started_timestamp,
    }
end

local function showBookInfo(ui)
    local snap, ok = lastBookSnapshot(ui)
    if not ok then return nil end
    local popup
    if snap then
        -- the book of a list row, in effect: read from its file
        popup = BookInfo:new{
            file = snap.file,
            book = {
                id_book = snap.book_id,
                md5     = snap.md5,
                title   = snap.title or "",
                authors = snap.authors,
            },
        }
    else
        popup = BookInfo:new{ ui = ui }
    end
    UIManager:show(popup)
    return popup
end

local BUILDERS = {
    insights      = showInsights,
    heatmap       = showHeatmap,
    streak        = showStreak,
    records       = showRecords,
    book_progress = showBookProgress,
    book_calendar = showBookCalendar,
    book_info     = showBookInfo,
}

-- ---------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------

function M.show(ui, before_paint)
    -- 1. The running session is still only in memory: write it to the
    --    statistics database first, so every query below sees it.
    pcall(InsightsData.flushStatsToDB, ui)

    local content = M.readContent()
    local shown = {}

    -- 2. Background (the Insights window fills the screen, so it has none).
    local function build(content_id)
        local builder = BUILDERS[content_id] or showInsights
        local bg
        if content_id ~= "insights" then
            local kind = M.readBackground()
            local src_bb
            if kind == "cover" then
                src_bb = loadCover(ui)
            elseif kind == "custom" then
                src_bb = loadWallpaper()
            end
            bg = buildBackground(src_bb)
            UIManager:show(bg, "full")
            shown[#shown + 1] = bg
        end

        local ok, popup = pcall(builder, ui)
        if not ok then
            logger.warn("ReadingInsights sleep screen:", content_id, "failed:", tostring(popup))
            popup = nil
        end
        return popup, bg
    end

    local popup, bg = build(content)
    if not popup then
        -- Not possible right now (no open book, no data, or an error):
        -- fall back to the insights window rather than a blank screen.
        if bg then
            UIManager:close(bg)
            shown[#shown] = nil
        end
        if content ~= "insights" then
            local ok2, p2 = pcall(showInsights, ui)
            popup = ok2 and p2 or nil
        end
    end
    if popup then shown[#shown + 1] = popup end

    -- Optional hook (main.lua: put core's own sleep screen widgets back on
    -- top of what was just shown).
    if before_paint then pcall(before_paint) end

    -- 3. Paint it now, synchronously - before the Suspend handler returns,
    --    and therefore before core schedules the actual suspend.
    pcall(function() UIManager:forceRePaint() end)
    pcall(function()
        if UIManager.waitForVSync then UIManager:waitForVSync() end
    end)

    return shown
end

-- ---------------------------------------------------------------------
-- Offscreen rendering (used by lib/imageexport.lua)
-- ---------------------------------------------------------------------

-- Frees a widget that was built but never shown. The usual onCloseWidget
-- handlers are NOT run: they ask for a screen refresh, and nothing of this
-- was ever on the screen.
local function discard(w)
    if not w then return end
    w._closed = true
    pcall(function()
        if w.scroll_container and w.scroll_container.free then
            w.scroll_container:free()
        end
    end)
    pcall(function() if w.free then w:free() end end)
end

-- Builds the sleep screen exactly like show() does - same content, same
-- background, same fit - but paints it into a bitmap of its own instead of
-- onto the screen, so it can run at any time (while reading, on a timer)
-- without flashing anything. Returns the bitmap (caller owns it and must
-- free it), or nil + a reason: "nodata" (nothing can be drawn right now) or
-- "render" (drawing failed).
--
-- The builders above call UIManager:show() as part of building; for the
-- duration of the build that call only collects the widget, so nothing
-- reaches the screen and no refresh is scheduled. Readonly popups load and
-- draw everything inside init() (see ReadingInsightsPopup), so once the
-- builder has returned the widget is complete and can be painted at once.
function M.renderToBlitbuffer(ui)
    pcall(InsightsData.flushStatsToDB, ui)

    local content = M.readContent()
    local orig_show = UIManager.show
    UIManager.show = function() end

    local popup, page
    local ok_build, err_build = pcall(function()
        local function build(content_id)
            local builder = BUILDERS[content_id] or showInsights
            local bg
            if content_id ~= "insights" then
                local kind = M.readBackground()
                local src_bb
                if kind == "cover" then
                    src_bb = loadCover(ui)
                elseif kind == "custom" then
                    src_bb = loadWallpaper()
                end
                bg = buildBackground(src_bb)
            end
            local ok, p = pcall(builder, ui)
            if not ok then
                logger.warn("ReadingInsights image export:", content_id, "failed:", tostring(p))
                p = nil
            end
            return p, bg
        end

        popup, page = build(content)
        if not popup then
            -- Same fallback as show(): the insights window.
            discard(page)
            page = nil
            if content ~= "insights" then
                local ok2, p2 = pcall(showInsights, ui)
                popup = ok2 and p2 or nil
            end
        end
    end)
    UIManager.show = orig_show

    if not ok_build then
        logger.warn("ReadingInsights image export: build failed:", tostring(err_build))
        discard(popup)
        discard(page)
        return nil, "render"
    end
    if not popup then
        discard(page)
        return nil, "nodata"
    end

    local w, h = Screen:getWidth(), Screen:getHeight()
    local bb_type
    pcall(function() bb_type = Screen.bb and Screen.bb:getType() end)

    -- Blitbuffer.new(w, h, type) is a plain constructor (not a method).
    local ok_bb, bb
    if bb_type then ok_bb, bb = pcall(Blitbuffer.new, w, h, bb_type) end
    if not (ok_bb and bb) then ok_bb, bb = pcall(Blitbuffer.new, w, h) end
    if not (ok_bb and bb) then
        logger.warn("ReadingInsights image export: no offscreen bitmap:", tostring(bb))
        discard(popup)
        discard(page)
        return nil, "render"
    end

    local ok_paint, err_paint = pcall(function()
        bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
        if page then page:paintTo(bb, 0, 0) end
        popup:paintTo(bb, 0, 0)
        -- KOReader's night mode inverts what the screen paints (see the
        -- header). A bitmap of our own is not inverted by anything, so do
        -- it here: the file then looks like what the screen would show.
        if Screen.night_mode and bb.invertRect then
            bb:invertRect(0, 0, w, h)
        end
    end)
    discard(popup)
    discard(page)
    if not ok_paint then
        pcall(function() bb:free() end)
        logger.warn("ReadingInsights image export: paint failed:", tostring(err_paint))
        return nil, "render"
    end
    return bb
end

-- ---------------------------------------------------------------------
-- Preview (menu entry: Sleep screen > Preview)
-- ---------------------------------------------------------------------

-- The preview is the sleep screen rendered offscreen (the same bitmap the
-- image export writes) and shown in one self-contained full-screen widget.
-- Building the real popups on the screen and closing them again went wrong
-- for some of them (the book progress popup could not be closed), and
-- closed the menu; a single bitmap widget has neither problem. The menu
-- stays open underneath and is there again when the preview is closed.
local PreviewImage = InputContainer:extend{ bb = nil, on_close = nil }

function PreviewImage:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
            Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { AnyKey = { { Device.input.group.Any } } }
    end
end

function PreviewImage:getSize()
    return self.dimen
end

function PreviewImage:paintTo(target, x, y)
    self.dimen.x, self.dimen.y = x, y
    if not self.bb then return end
    local w, h = self.bb:getWidth(), self.bb:getHeight()
    -- The bitmap already has night mode applied (see renderToBlitbuffer);
    -- the screen applies it once more, so undo it while blitting.
    if Screen.night_mode and target.invertblitFrom then
        target:invertblitFrom(self.bb, x, y, 0, 0, w, h)
    else
        target:blitFrom(self.bb, x, y, 0, 0, w, h)
    end
end

function PreviewImage:_close()
    if self._closed then return true end
    self._closed = true
    if self.on_close then self.on_close() end
    return true
end

PreviewImage.onTap    = PreviewImage._close
PreviewImage.onSwipe  = PreviewImage._close
PreviewImage.onHold   = PreviewImage._close
PreviewImage.onAnyKey = PreviewImage._close

function PreviewImage:onCloseWidget()
    if self.bb then
        pcall(function() self.bb:free() end)
        self.bb = nil
    end
end

local preview_widget   -- what is on the screen right now, if anything

local function closePreview()
    local w = preview_widget
    preview_widget = nil
    if not w then return end
    UIManager:close(w)
    UIManager:setDirty("all", "full")
end

-- Shows the sleep screen the way it would be drawn on suspend, with the
-- current settings. Tap, swipe, hold or any key closes it.
function M.preview(ui, touchmenu_instance)
    if preview_widget then return end
    UIManager:nextTick(function()
        if preview_widget then return end
        local ok, bb = pcall(M.renderToBlitbuffer, ui)
        if not ok or not bb then
            logger.warn("ReadingInsights sleep screen: preview failed:", tostring(bb))
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Nothing to preview."),
                timeout = 2,
            })
            return
        end
        preview_widget = PreviewImage:new{ bb = bb, on_close = closePreview }
        UIManager:show(preview_widget, "full")
    end)
end

-- Closes what show() returned, top-most first.
function M.close(list)
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do
        local w = list[i]
        if w then pcall(function() UIManager:close(w) end) end
    end
end

return M
