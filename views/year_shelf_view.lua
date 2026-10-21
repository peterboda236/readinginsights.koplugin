--[[
Reading Insights - the year shelf.

A full-screen window with the covers of the books read in a year, laid out
like books on a shelf: oldest first, left to right, wrapping from row to row,
with the (short) name of the month above the first cover of that month (the
same abbreviations as under the monthly charts of the Reading insights window).
When a month runs over into the next row the name is repeated above the first
cover of that row, so every row reads on its own:

    may.   jún.                       júl.
    [] []  [] [] [] [] [] []  []  ... [] []
    júl.   aug.   szept.     okt.
    [] []  [] []  [] [] []   [] [] []

Every cover is drawn at the same height and keeps its own proportions, so only
the widths differ. The height is the biggest one at which ALL the books of the
year fit on the screen: the shelf never scrolls or pages.

Opened by tapping the year in the Reading insights window (or from its
hamburger menu), on top of it - closing it reveals the insights window again.
It can also be the sleep screen's content (Settings > Sleep screen), see
"readonly" below.

  - Title bar     "Reading shelf", an X on the right to close, a hamburger
                  menu on the left (see below). Swiping down anywhere also
                  closes the window.
  - Year row      under the title bar, built like the year row of the
                  Reading insights window: the shown year in the middle, the
                  previous / next year on either side (tap them, or swipe
                  left / right, or press Left / Right).
  - The shelf     a book lands in the month of its last reading entry of that
                  year (with "only finished books" in the month it was
                  finished). Tap a cover for its Book info popup.
  - Hamburger     "Show only finished books" - a check mark in front of it
                  when on; the choice is remembered.

The covers have the look chosen under Settings > Appearance > Covers (frame,
rounded corners, shadow), the same as in the Book info popup and the Reading
calendar.

The covers are read the same way as in the Reading calendar (and share its
thumbnail cache on disk, <settings>/readinginsights/covercache/<md5>.jpg): the
first paint takes what is already cached and draws a plain outline for the rest,
which are then loaded a few at a time while the window stays usable (the shelf
is laid out again as the real proportions of the covers become known). A book
without a cover is drawn like in the Reading streak calendar: an outlined card
with a book icon and the start of its title - but without a grey fill.

  YearShelf.show{
      ui         = <the KOReader UI, handed on to the Book info popup>,
      year       = <the year to open on>,
      year_range = { min_year = ..., max_year = ... }  (optional),
      getBooks   = function(year, finished_only) -> list of book records
                   (the same records the insights book lists use),
      readonly   = true for the sleep screen: no hamburger menu, no X, taps /
                   swipe down / keys do nothing (swipe left / right still
                   changes the year), and everything - the covers included, as
                   far as a short time budget allows - is loaded and drawn
                   inside init(), with nothing left for a timer,
  }
]]--

local Blitbuffer = require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen

local deps = ...
local Locale, Colors, Fonts, UI, BookList, BookInfoData, Ratings =
    deps.Locale, deps.Colors, deps.Fonts, deps.UI, deps.BookList, deps.BookInfoData, deps.Ratings
local VS, CoverFrame, CoverThumbs = deps.VS, deps.CoverFrame, deps.CoverThumbs
local T = require("ffi/util").template
local _ = Locale._

local SETTING_FINISHED_ONLY = "reading_insights_shelf_finished_only"

local function readFinishedOnly()
    return G_reader_settings ~= nil and G_reader_settings:isTrue(SETTING_FINISHED_ONLY)
end

local function saveFinishedOnly(on)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTING_FINISHED_ONLY, on and true or false)
    end
end

-- ---------------------------------------------------------------------------
-- Month labels
-- ---------------------------------------------------------------------------

-- Month 13 is the bucket of books that have no usable date: "-".
local NO_MONTH = 13
local function monthLabel(m)
    if m < 1 or m > 12 then return "\xE2\x80\x93" end
    -- The same short names as under the monthly charts of the Reading
    -- insights window (lower case with a dot in Hungarian).
    return Locale.shortMonthName(m)
end

-- The month (1..12) a book is shelved in, NO_MONTH when it has no date in the
-- shown year (a book added by hand without a date, say).
local function monthOf(book, year)
    if book.manual and not book.date_known then return NO_MONTH end
    local ts = tonumber(book.last_read) or 0
    if ts <= 0 then return NO_MONTH end
    local d = os.date("*t", ts)
    if not d or d.year ~= year then return NO_MONTH end
    return d.month
end

-- ---------------------------------------------------------------------------
-- Covers (same cache as the Reading calendar's day cells)
-- ---------------------------------------------------------------------------

local COVER_CACHE, COVER_CACHE_N, COVER_CACHE_MAX = {}, 0, 400
local COVER_PENDING = {}     -- returned for a cover that is not loaded yet
-- width / height of every cover seen so far (key: the book), so the shelf can
-- be laid out before the covers are scaled. A book without a cover counts as
-- a plain 2:3 card, like in the Reading streak calendar.
local ASPECT = {}
local NOCOVER_ASPECT = 2 / 3
local function clampAspect(a)
    if not a or a ~= a then return NOCOVER_ASPECT end
    return math.max(0.3, math.min(1.5, a))
end
local function bookKey(book) return tostring(book.md5 or book.id_book) end
local THUMB_W, THUMB_H = CoverThumbs.THUMB_W, CoverThumbs.THUMB_H
local diskBase, scaleTo, readThumb, writeThumb, markNoCover =
    CoverThumbs.diskBase, CoverThumbs.scaleTo, CoverThumbs.readThumb,
    CoverThumbs.writeThumb, CoverThumbs.markNoCover

-- Scales `bb` to w x h, frees `bb`. The cell's proportions come from this very
-- cover, so the picture is scaled to fill the cell exactly (that keeps every
-- cover of a row the same height to the pixel); only a cover whose proportions
-- the cell had to bend (an extreme one) is fitted, aspect kept, instead.
local function scaleToCell(bb, w, h)
    local rw, rh = bb:getWidth(), bb:getHeight()
    if rw > 0 and rh > 0 and w > 0 and h > 0
            and math.abs((rw / rh) / (w / h) - 1) <= 0.04 then
        return require("ui/renderimage"):scaleBlitBuffer(bb, w, h, true)
    end
    return scaleTo(bb, w, h)
end

-- ---------------------------------------------------------------------------
-- The shelf itself: one widget that paints every label and cover, and
-- remembers where each cover was drawn, so a tap can be matched to a book.
-- ---------------------------------------------------------------------------

local NOCOVER_STROKE = 0x6E

-- The stand-in for a book without a (readable) cover, drawn like in the
-- Reading streak calendar: a card outline with a book icon and, under it, the
-- start of the title in a small face (cut with an ellipsis when too long) -
-- but with no fill, so nothing is painted behind the title.
-- `plain` (a cover that is only not loaded yet) draws just the outline.
-- no_outline: the card sits inside the covers' own frame, which is its edge.
local function paintNoCover(bb, x, y, w, h, title, plain, no_outline)
    if w < 2 or h < 2 then return end
    local stroke = Blitbuffer.Color8(NOCOVER_STROKE)
    local line   = math.max(1, Screen:scaleBySize(1))

    if not no_outline then bb:paintBorder(x, y, w, h, line, stroke) end
    if plain then return end

    -- Too small for any detail.
    if w < Screen:scaleBySize(26) or h < Screen:scaleBySize(34) then return end

    local icon_w = math.floor(math.min(w * 0.36, h * 0.28))
    local icon_h = math.floor(icon_w * 1.2)
    local gap    = math.floor(icon_h * 0.3)
    local tw
    local pad = math.max(2, math.floor(w * 0.08))
    if type(title) == "string" and title ~= "" then
        -- Fixed size 8 (the smallest size the plugin's fonts use), whatever
        -- the font size settings are.
        local face
        pcall(function() face = require("ui/font"):getFace("NotoSans-Regular.ttf", 8) end)
        face = face or Fonts.getScaledFace("stats_label", 0.4)
        local okt, widget = pcall(TextWidget.new, TextWidget, {
            text = title, face = face, max_width = w - 2 * pad,
            fgcolor = Blitbuffer.Color8(0x40),
        })
        if okt and widget then tw = widget end
    end
    local th = tw and tw:getSize().h or 0
    local total = icon_h + (tw and (gap + th) or 0)
    if tw and total > h - 2 * pad then
        tw:free(); tw = nil; total = icon_h
    end

    local iy = y + math.floor((h - total) / 2)
    local ix = x + math.floor((w - icon_w) / 2)
    local t  = math.max(1, math.floor(icon_w / 11))

    -- Book icon: outlined volume, a spine line near the left edge and the
    -- page block's line near the bottom.
    pcall(bb.paintBorder, bb, ix, iy, icon_w, icon_h, t, stroke, math.max(1, math.floor(icon_w * 0.1)))
    bb:paintRect(ix + math.floor(icon_w * 0.28), iy, t, icon_h, stroke)
    bb:paintRect(ix + math.floor(icon_w * 0.28), iy + icon_h - math.floor(icon_h * 0.22), icon_w - math.floor(icon_w * 0.28), t, stroke)

    if tw then
        local sz = tw:getSize()
        tw:paintTo(bb, x + math.floor((w - sz.w) / 2), iy + icon_h + gap)
        tw:free()
    end
end

-- Every cover is cover_h high; the cells differ only in width (cell.w) and
-- sit at their own x (cell.x, relative to the left edge of the shelf). A cell
-- holds the framed cover (decor.border on every side of the picture) and its
-- shadow (decor.shadow right and down), so cell.w = picture + 2 * border +
-- shadow, and the same in height.
local ShelfGrid = Widget:extend{
    rows     = nil,   -- list of rows, each a list of { book, label, cover, x, w }
    decor    = nil,   -- { border, radius, shadow } of the covers
    left     = 0,     -- x of the shelf's left edge
    cover_h  = 0,
    label_h  = 0,
    row_h    = 0,
    w        = 0,
    h        = 0,
}

function ShelfGrid:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function ShelfGrid:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    self.hits = {}
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)

    for r, row in ipairs(self.rows or {}) do
        local ry = y + (r - 1) * self.row_h
        local cy = ry + self.label_h
        for _c, cell in ipairs(row) do
            local cx = x + self.left + cell.x
            if cell.label then
                local lh = cell.label:getSize().h
                cell.label:paintTo(bb, cx, ry + math.max(0, self.label_h - lh))
            end
            local cover = cell.cover
            local decor = self.decor or { border = 0, radius = 0, shadow = 0 }
            -- The framed card without its shadow.
            local card_w = cell.w - decor.shadow
            local card_h = self.cover_h - decor.shadow
            if cover == COVER_PENDING then
                -- Not loaded yet: an empty outline of the full size.
                paintNoCover(bb, cx, cy, card_w, card_h, nil, true)
            elseif cover then
                local cw, ch = cover:getWidth(), cover:getHeight()
                local ow, oh = cw + 2 * decor.border, ch + 2 * decor.border
                local ox = math.floor((card_w - ow) / 2)
                local oy = math.floor((card_h - oh) / 2)
                if CoverFrame then
                    CoverFrame.paint(bb, cx + ox, cy + oy, ow, oh, cover, decor)
                else
                    bb:blitFrom(cover, cx + ox, cy + oy, 0, 0, cw, ch)
                    -- like ImageWidget: a picture is not inverted by night mode
                    if Screen.night_mode then bb:invertRect(cx + ox, cy + oy, cw, ch) end
                    bb:paintBorder(cx + ox, cy + oy, cw, ch, Size.line.thin, Blitbuffer.COLOR_BLACK)
                end
            elseif CoverFrame then
                -- A book without a cover gets the same frame, rounded
                -- corners and shadow as the covers (its own outline only
                -- when there is no frame).
                local title = cell.book.title
                local no_outline = decor.border > 0
                CoverFrame.paint(bb, cx, cy, card_w, card_h, function(b, ix, iy, iw, ih)
                    b:paintRect(ix, iy, iw, ih, Blitbuffer.COLOR_WHITE)
                    paintNoCover(b, ix, iy, iw, ih, title, false, no_outline)
                end, decor)
            else
                paintNoCover(bb, cx, cy, card_w, card_h, cell.book.title)
            end
            table.insert(self.hits, {
                x = cx, y = cy, w = cell.w, h = self.cover_h, book = cell.book,
            })
        end
    end
end

function ShelfGrid:bookAt(px, py)
    for _i, hit in ipairs(self.hits or {}) do
        if px >= hit.x and px < hit.x + hit.w and py >= hit.y and py < hit.y + hit.h then
            return hit.book
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local YearShelfPopup = InputContainer:extend{
    modal = true,
    ui = nil,
    year = nil,
    year_range = nil,
    getBooks = nil,
    -- Sleep-screen use: no hamburger menu / X, nothing reacts to a tap, a key
    -- or a swipe down (a stray touch or the wake key must not close it), and
    -- the covers are loaded right in init() (see _rebuild).
    readonly = false,
}

function YearShelfPopup:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        if not self.readonly then
            self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
        end
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if Device:hasKeys() and not self.readonly then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self.year = tonumber(self.year) or tonumber(os.date("%Y"))
    self.finished_only = readFinishedOnly()
    -- Show the window first, load the covers after it (not on the sleep
    -- screen: nothing runs there after the first paint).
    self._defer_disk = not self.readonly
    self:_rebuild()
end

-- The year's books as shelf items { book, month }, oldest first. Remembered per
-- (year, finished-only), so paging and re-laying-out never ask again.
function YearShelfPopup:_items()
    self._item_cache = self._item_cache or {}
    local key = tostring(self.year) .. (self.finished_only and ":f" or ":a")
    local hit = self._item_cache[key]
    if hit then return hit end

    local ok, books = pcall(self.getBooks, self.year, self.finished_only)
    if not ok or type(books) ~= "table" then
        require("logger").warn("ReadingInsights: year shelf could not load the books: " .. tostring(books))
        books = {}
    end
    local items = {}
    for _i, book in ipairs(books) do
        table.insert(items, { book = book, month = monthOf(book, self.year) })
    end
    table.sort(items, function(a, b)
        if a.month ~= b.month then return a.month < b.month end
        local ta, tb = tonumber(a.book.last_read) or 0, tonumber(b.book.last_read) or 0
        if ta ~= tb then return ta < tb end
        return (a.book.title or "") < (b.book.title or "")
    end)
    self._item_cache[key] = items
    return items
end

-- The file of a book (by checksum, else guessed from its title), nil when
-- unknown. Remembered per popup.
function YearShelfPopup:_fileOf(book)
    self._file_cache = self._file_cache or {}
    local key = tostring(book.md5 or book.id_book)
    local hit = self._file_cache[key]
    if hit ~= nil then return hit or nil end
    local file
    if Ratings and Ratings.fileFor and book.md5 and book.md5 ~= "" then
        local ok, f = pcall(Ratings.fileFor, book.md5, book.title, book.authors)
        if ok then file = f end
    end
    self._file_cache[key] = file or false
    return file
end

-- The width / height of a book's cover, as far as it is known without opening
-- the book (remembered, or read from the thumbnail on disk); nil when unknown.
-- A book with no cover gives the 2:3 of the plain card.
function YearShelfPopup:_aspectOf(book)
    if book.manual then return NOCOVER_ASPECT end
    local key = bookKey(book)
    if ASPECT[key] then return ASPECT[key] end
    local base = diskBase(book)
    if base then
        if lfs.attributes(base .. ".none", "mode") == "file" then
            ASPECT[key] = NOCOVER_ASPECT
            return NOCOVER_ASPECT
        end
        -- From the file header: decoding every thumbnail just to learn its
        -- size (and then once more to draw it) is what made the first
        -- opening after a restart slow.
        local tw, th = CoverThumbs.thumbSize(base)
        if not tw then
            local thumb = readThumb(base)
            if thumb then
                tw, th = thumb:getWidth(), thumb:getHeight()
                pcall(function() thumb:free() end)
            end
        end
        if tw and th and tw > 0 and th > 0 then
            ASPECT[key] = clampAspect(tw / th)
            return ASPECT[key]
        end
    end
    return nil
end

-- The cover of a book scaled to fit w x h (aspect kept); nil when the book has
-- no readable cover, COVER_PENDING when cached_only and it is not loaded yet.
function YearShelfPopup:_coverFor(book, w, h, cached_only)
    if book.manual then return nil end
    local key = bookKey(book) .. "|" .. w .. "x" .. h
    local hit = COVER_CACHE[key]
    if hit ~= nil then return hit or nil end

    local function remember(v)
        if COVER_CACHE_N >= COVER_CACHE_MAX then
            COVER_CACHE, COVER_CACHE_N = {}, 0   -- dropped; the finalisers free them
        end
        COVER_CACHE[key] = v or false
        COVER_CACHE_N = COVER_CACHE_N + 1
        return v
    end

    -- On disk: quick (a small picture) - but decoding dozens of them still
    -- delays the window, so a popup that shows itself first (_defer_disk)
    -- leaves them to _loadPending(); only the sleep screen reads them here.
    local base = diskBase(book)
    if base then
        if lfs.attributes(base .. ".none", "mode") == "file" then
            return remember(nil)
        end
        local thumb = not (cached_only and self._defer_disk) and readThumb(base) or nil
        if thumb then
            local ok, res = pcall(scaleToCell, thumb, w, h)
            if ok and res then return remember(res) end
        end
    end

    if cached_only then
        self._pending = self._pending or {}
        if not self._pending[key] then
            self._pending[key] = { book = book, w = w, h = h }
            self._pending_order = self._pending_order or {}
            table.insert(self._pending_order, key)
        end
        return COVER_PENDING
    end

    -- Slow: open the book and read its cover; keep a thumbnail of it on disk.
    local scaled
    local file = self:_fileOf(book)
    if file and BookInfoData and BookInfoData.getCover then
        local ok, raw = pcall(BookInfoData.getCover, nil, file)
        if ok and raw then
            local rw, rh = raw:getWidth(), raw:getHeight()
            if rw > 0 and rh > 0 then ASPECT[bookKey(book)] = clampAspect(rw / rh) end
            local ok2, res = pcall(function()
                local thumb = scaleTo(raw, THUMB_W, THUMB_H, true)   -- frees raw
                if base then writeThumb(base, thumb) end
                return scaleToCell(thumb, w, h)                      -- frees thumb
            end)
            if ok2 and res then
                scaled = res
            else
                pcall(function() raw:free() end)
            end
        elseif ok and base and lfs.attributes(file, "mode") == "file" then
            markNoCover(base)   -- the book is there but has no cover
        end
    end
    -- No cover: the plain card, 2:3.
    if not scaled and not ASPECT[bookKey(book)] then
        ASPECT[bookKey(book)] = NOCOVER_ASPECT
    end
    return remember(scaled)
end

-- Reads one book's cover from its file the slow way, keeping a thumbnail of it
-- on disk and its proportions in memory - but no scaled copy: the shelf is laid
-- out from the proportions, and the cover is then scaled from the thumbnail.
function YearShelfPopup:_primeCover(book)
    if book.manual then return end
    local key = bookKey(book)
    local base = diskBase(book)
    local file = self:_fileOf(book)
    if file and BookInfoData and BookInfoData.getCover then
        local ok, raw = pcall(BookInfoData.getCover, nil, file)
        if ok and raw then
            local rw, rh = raw:getWidth(), raw:getHeight()
            if rw > 0 and rh > 0 then ASPECT[key] = clampAspect(rw / rh) end
            local ok2 = pcall(function()
                local thumb = scaleTo(raw, THUMB_W, THUMB_H, true)   -- frees raw
                if base then writeThumb(base, thumb) end
                thumb:free()
            end)
            if not ok2 then pcall(function() raw:free() end) end
        elseif ok and base and lfs.attributes(file, "mode") == "file" then
            markNoCover(base)   -- the book is there but has no cover
        end
    end
    if not ASPECT[key] then ASPECT[key] = NOCOVER_ASPECT end
end

-- Sleep screen: nothing may be left for a timer, so the covers that are not on
-- disk yet are read right here - but only for a couple of seconds in all, so
-- going to sleep is never held up for long; the books past the budget are drawn
-- as plain cards this time (and are cached for the next one once the shelf is
-- opened normally, or by the next sleep screen).
local PRIME_BUDGET_SECONDS = 2.0
function YearShelfPopup:_primeCovers(items)
    local deadline = os.clock() + PRIME_BUDGET_SECONDS
    for _i, it in ipairs(items) do
        if self:_aspectOf(it.book) == nil then
            if os.clock() > deadline then break end
            pcall(self._primeCover, self, it.book)
        end
    end
end

-- Loads the covers the paint had to leave out, a few per UI tick (so the
-- window stays usable), repainting after each batch.
function YearShelfPopup:_loadPending()
    self._pending_task = nil
    if self._closed then return end
    local order = self._pending_order
    if not order or #order == 0 then return end
    -- As many covers as fit in a short time slice, then one repaint: the
    -- window fills in quickly instead of being rebuilt after every 3 covers.
    local started = CoverThumbs.clock()
    while true do
        local key = table.remove(order, 1)
        if not key then break end
        local item = self._pending and self._pending[key]
        if self._pending then self._pending[key] = nil end
        if item then pcall(self._coverFor, self, item.book, item.w, item.h) end
        if CoverThumbs.clock() - started >= 0.3 then break end
    end
    self._pending, self._pending_order = nil, nil
    self:_rebuild()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    -- Whatever the rebuild still found missing is loaded the same way.
    self:_schedulePending(0.01)
end

function YearShelfPopup:_schedulePending(delay)
    if self._pending_task then
        UIManager:unschedule(self._pending_task)
        self._pending_task = nil
    end
    if self._pending_order and #self._pending_order > 0 then
        self._pending_task = function() self:_loadPending() end
        UIManager:scheduleIn(delay or 0.05, self._pending_task)
    end
end

function YearShelfPopup:_freeCovers()
    -- Nothing to free: covers live in COVER_CACHE for the next opening.
    self._closed = true
    if self._pending_task then
        UIManager:unschedule(self._pending_task)
        self._pending_task = nil
    end
    self._pending, self._pending_order = nil, nil
end

function YearShelfPopup:_yearAvailable(delta)
    local yr = self.year_range
    if not yr or not yr.min_year or not yr.max_year then return false end
    local y = self.year + delta
    return y >= yr.min_year and y <= yr.max_year
end

function YearShelfPopup:_rebuild()
    local screen_w, screen_h = self.dimen.w, self.dimen.h
    -- Covers not loaded yet are collected again by this build.
    self._pending, self._pending_order = nil, nil

    local face_section = Fonts.getFace("insights_section")
    local face_label   = Fonts.getFace("insights_label")
    local face_month
    pcall(function() face_month = Fonts.getScaledFace("stats_label", 0.8) end)
    face_month = face_month or face_label

    -- Title bar: hamburger menu on the left, the X on the right, a line under it.
    local title_bar = TitleBar:new{
        fullscreen             = true,
        width                  = screen_w,
        align                  = "left",
        title                  = _("Reading shelf"),
        -- No hamburger menu and no X on the sleep screen (readonly).
        left_icon              = (not self.readonly) and "appbar.menu" or nil,
        left_icon_tap_callback = (not self.readonly) and function() self:onShowMenu() end or nil,
        close_callback         = (not self.readonly) and function() UIManager:close(self) end or nil,
        show_parent            = self,
        top_v_padding          = Size.padding.default,
        bottom_v_padding       = Size.padding.default,
    }
    self.title_bar = title_bar
    local side_pad = Size.padding.large
    local title_sep = UI.padded(side_pad,
        Colors.newBar(screen_w - 2 * side_pad, Size.line.thick, Colors.separator()))
    self._top_h = title_bar:getSize().h

    -- Year row: built like the year row of the Reading insights window
    -- (buildYearHeader in insights_view.lua) - the same header background,
    -- padding, faces and arrow / gap spacing - so the two read the same:
    -- previous year ‹ | selected year | › next year.
    local content_w  = screen_w - 2 * side_pad
    local inner_pad  = Size.padding.default
    local arrow_gap  = Size.padding.small
    local yr_pad_v   = Size.padding.small

    local sample_arrow = TextWidget:new{ text = "\xE2\x80\xB9", face = face_label }
    local arrow_w = sample_arrow:getSize().w
    sample_arrow:free()
    local sample_yr = TextWidget:new{ text = tostring(self.year - 1), face = face_label }
    local yr_side_w = sample_yr:getSize().w
    sample_yr:free()
    local slot_w = arrow_w + arrow_gap + yr_side_w + inner_pad

    local function makeSlot(yr, glyph, left, visible)
        if not visible then return HorizontalSpan:new{ width = slot_w } end
        local arrow_tw = TextWidget:new{ text = glyph, face = face_label, fgcolor = Colors.label() }
        local yr_tw    = TextWidget:new{ text = tostring(yr), face = face_label, fgcolor = Colors.label() }
        if left then
            return HorizontalGroup:new{
                align = "center",
                arrow_tw, HorizontalSpan:new{ width = arrow_gap }, yr_tw,
                HorizontalSpan:new{ width = inner_pad },
            }
        end
        return HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = inner_pad }, yr_tw,
            HorizontalSpan:new{ width = arrow_gap }, arrow_tw,
        }
    end
    local left_slot  = makeSlot(self.year - 1, "\xE2\x80\xB9", true,  self:_yearAvailable(-1))
    local right_slot = makeSlot(self.year + 1, "\xE2\x80\xBA", false, self:_yearAvailable(1))

    local year_tw = TextWidget:new{
        text = tostring(self.year), face = face_section, fgcolor = Colors.section(),
    }
    local remaining = math.max(0, content_w - 2 * slot_w - year_tw:getSize().w)
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l
    local year_header = FrameContainer:new{
        background     = Colors.headerBg(),
        bordersize     = 0,
        padding_top    = yr_pad_v,
        padding_bottom = yr_pad_v,
        padding_left   = 0,
        padding_right  = 0,
        HorizontalGroup:new{
            align = "center",
            left_slot,
            HorizontalSpan:new{ width = side_l },
            year_tw,
            HorizontalSpan:new{ width = side_r },
            right_slot,
        },
    }
    -- Drawn with a little room from the screen's edge, like the lines around it.
    local year_row_padded = UI.padded(side_pad, year_header)
    local year_sep = UI.padded(side_pad,
        Colors.newBar(content_w, Size.line.thin, Colors.separator()))
    -- The same small gaps as in the insights window: header - gap - thin line
    -- - gap - what follows.
    local year_gap = Size.padding.small
    self._year_row_top    = self._top_h + title_sep:getSize().h
    self._year_row_bottom = self._year_row_top + year_header:getSize().h
        + year_gap + year_sep:getSize().h + year_gap

    -- The shelf area: what is left of the screen under the year row.
    local shelf_top = self._year_row_bottom
    local avail_h   = screen_h - shelf_top - Size.padding.large
    local avail_w   = content_w

    -- Geometry. One shelf row is: the month name line, then the covers.
    local gap = Screen:scaleBySize(6)
    local sample = TextWidget:new{ text = "MMM", face = face_month }
    local label_h = sample:getSize().h + Screen:scaleBySize(2)
    sample:free()

    -- The covers' look (Settings > Appearance > Covers): the frame adds to the
    -- picture's size on every side, the shadow right and down; both are part of
    -- a cell, so H and the cell widths below are of the whole thing.
    local decor = (VS and VS.Opt and VS.Opt.coverDecor and VS.Opt.coverDecor())
        or { border = 0, radius = 0, shadow = 0 }
    local extra = decor.shadow + 2 * decor.border
    self._decor = decor

    local items = self:_items()
    local n = #items
    if self.readonly then self:_primeCovers(items) end
    local aspects = {}
    for i, it in ipairs(items) do
        aspects[i] = clampAspect(self:_aspectOf(it.book))   -- 2:3 until known
    end

    -- The covers into rows at a cover height H, left to right. Rows are broken
    -- where they leave the least room unused over the whole shelf (squared
    -- leftover per row, the last row free), among the layouts with the fewest
    -- rows - so the right edge is as even as the covers allow. Then the room
    -- left in a row is shared out between its gaps, at most MAX_EXTRA more per
    -- gap; the last row and a row that would need more keep the normal gap and
    -- stay left-aligned. Returns the rows, each a list of
    -- { i = index of the book, x, w } (x relative to the shelf's left edge).
    local MAX_EXTRA = gap * 2
    local function pack(H)
        local ws = {}
        for i = 1, n do
            local pic_w = math.max(1, math.floor(aspects[i] * math.max(1, H - extra) + 0.5))
            ws[i] = math.min(avail_w, pic_w + extra)
        end
        -- dp[i]: the best way to lay out the first i covers (fewest rows, then
        -- least waste); prev[i] where its last row starts.
        local dp_rows, dp_bad, prev = { [0] = 0 }, { [0] = 0 }, {}
        for i = 1, n do
            local best_r, best_b, best_j
            local used = -gap
            for j = i - 1, 0, -1 do
                used = used + gap + ws[j + 1]
                if used > avail_w and j < i - 1 then break end
                local cost = (i == n) and 0 or (math.max(0, avail_w - used) / avail_w) ^ 2
                local r, bad = dp_rows[j] + 1, dp_bad[j] + cost
                if not best_r or r < best_r or (r == best_r and bad < best_b - 1e-12) then
                    best_r, best_b, best_j = r, bad, j
                end
            end
            dp_rows[i], dp_bad[i], prev[i] = best_r, best_b, best_j
        end
        local ranges, i = {}, n
        while i > 0 do
            table.insert(ranges, 1, { prev[i] + 1, i })
            i = prev[i]
        end
        local rows = {}
        for r, rg in ipairs(ranges) do
            local row, sum = {}, 0
            local k = rg[2] - rg[1] + 1
            for q = rg[1], rg[2] do sum = sum + ws[q] end
            local extra = 0
            if r < #ranges and k > 1 then
                local left = avail_w - (sum + (k - 1) * gap)
                extra = math.min(math.max(0, left) / (k - 1), MAX_EXTRA)
            end
            local pos = 0
            for q = rg[1], rg[2] do
                local cx = math.floor(pos + 0.5)
                table.insert(row, { i = q, x = cx, w = ws[q] })
                pos = pos + ws[q] + gap + extra
            end
            table.insert(rows, row)
        end
        return rows
    end
    local function heightOf(nrows, H)
        return nrows * (label_h + H) + math.max(0, nrows - 1) * gap
    end

    -- The biggest H at which every book fits on the screen (no scrolling, no
    -- pages). Capped so a year with a few books does not get giant covers.
    local H = 1
    local packed = {}
    if n > 0 then
        local hi = math.max(1, math.min(avail_h - label_h, math.floor(avail_w * 0.375) + extra))
        local lo = 1
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if heightOf(#pack(mid), mid) <= avail_h then lo = mid else hi = mid - 1 end
        end
        H = lo
        packed = pack(H)
    end
    local row_h = label_h + H + gap

    local shown = {}
    for _r, prow in ipairs(packed) do
        -- A month name above the first cover of a month and of every row.
        local labeled = {}
        for c, pc in ipairs(prow) do
            labeled[c] = (c == 1) or items[pc.i].month ~= items[prow[c - 1].i].month
        end
        local out = {}
        for c, pc in ipairs(prow) do
            local it = items[pc.i]
            local label
            if labeled[c] then
                -- Up to the next name (or the end of the row).
                local nxt = c + 1
                while nxt <= #prow and not labeled[nxt] do nxt = nxt + 1 end
                local right = (nxt <= #prow) and (prow[nxt].x - gap) or avail_w
                label = TextWidget:new{
                    text = monthLabel(it.month), face = face_month, fgcolor = Colors.label(),
                    max_width = math.max(1, right - pc.x),
                }
            end
            table.insert(out, {
                book  = it.book,
                label = label,
                x     = pc.x,
                w     = pc.w,
                cover = self:_coverFor(it.book, math.max(1, pc.w - extra), math.max(1, H - extra), true),
            })
        end
        table.insert(shown, out)
    end

    -- Sleep screen: whatever could not be loaded is drawn as a plain card, and
    -- nothing is queued for later.
    if self.readonly then
        for _r, row in ipairs(shown) do
            for _c, cell in ipairs(row) do
                if cell.cover == COVER_PENDING then cell.cover = nil end
            end
        end
        self._pending, self._pending_order = nil, nil
    end

    local content = VerticalGroup:new{
        align = "left",
        title_bar,
        title_sep,
        year_row_padded,
        VerticalSpan:new{ width = year_gap },
        year_sep,
        VerticalSpan:new{ width = year_gap },
    }
    if #shown > 0 then
        self.grid = ShelfGrid:new{
            rows = shown, decor = decor, left = side_pad, cover_h = H,
            label_h = label_h, row_h = row_h,
            w = screen_w, h = #shown * row_h,
        }
        table.insert(content, self.grid)
    else
        self.grid = nil
        local text = self.finished_only
            and T(_("No books finished in %1"), tostring(self.year))
            or  T(_("No books in %1"), tostring(self.year))
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = math.max(avail_h, 1) },
            TextWidget:new{ text = text, face = face_label, fgcolor = Colors.label() },
        })
    end

    local layers = OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        allow_mirroring = false,
        content,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        width      = screen_w,
        height     = screen_h,
        layers,
    }
end

-- Repaints the whole window after the year / page / filter changed.
function YearShelfPopup:_refresh()
    self:_rebuild()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self:_schedulePending()
    return true
end

function YearShelfPopup:_goToYear(delta)
    if not self:_yearAvailable(delta) then return true end
    self.year = self.year + delta
    return self:_refresh()
end

-- Hamburger menu: the "only finished books" switch.
function YearShelfPopup:onShowMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local title_bar = self.title_bar
    dialog = ButtonDialog:new{
        -- This window is modal, and UIManager stacks a non-modal window shown
        -- over it underneath it.
        modal = true,
        shrink_unneeded_width = true,
        buttons = {
            {{
                -- U+2713 CHECK MARK in front of it while it is on.
                text  = (self.finished_only and "\xE2\x9C\x93 " or "    ")
                        .. _("Show only finished books"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self.finished_only = not self.finished_only
                    saveFinishedOnly(self.finished_only)
                    self:_refresh()
                end,
            }},
        },
        anchor = title_bar and title_bar.left_button and function()
            return title_bar.left_button.image.dimen
        end or nil,
    }
    UIManager:show(dialog)
    return true
end

function YearShelfPopup:_openBook(book)
    if not (BookList and BookList.openBookInfo) then return end
    BookList.openBookInfo(book, {
        ui = self.ui,
        -- In the finished-books view each book's date is the day it was
        -- finished already.
        show_dates = self.finished_only,
        modal = true,
    })
end

function YearShelfPopup:onTap(arg, ges_ev)
    if not ges_ev then return true end
    local x, y = ges_ev.pos.x, ges_ev.pos.y

    -- Title bar: the X (right end) closes, the hamburger (left end) opens the
    -- menu. (The buttons handle their own taps first; this is the fallback.)
    if self._top_h and y < self._top_h then
        if x > self.dimen.w - 1.5 * self._top_h then
            UIManager:close(self)
        elseif x < 1.5 * self._top_h then
            self:onShowMenu()
        end
        return true
    end

    -- Year row: tap the previous / next year to go there.
    if y >= self._year_row_top and y < self._year_row_bottom then
        if x < self.dimen.w / 3 then return self:_goToYear(-1) end
        if x > self.dimen.w * 2 / 3 then return self:_goToYear(1) end
        return true
    end

    if self.grid then
        local book = self.grid:bookAt(x, y)
        if book then
            self:_openBook(book)
            return true
        end
    end
    return true
end

function YearShelfPopup:onSwipe(arg, ges_ev)
    if not ges_ev then return true end
    local dir = ges_ev.direction
    if dir == "west" then return self:_goToYear(1)  end
    if dir == "east" then return self:_goToYear(-1) end
    -- Swiping down closes the window (not on the sleep screen, where a stray
    -- touch must not dismiss it).
    if (dir == "south" or dir == "down") and not self.readonly then
        UIManager:close(self)
    end
    return true
end

function YearShelfPopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "Left" } })  then return self:_goToYear(-1) end
    if key and key:match({ { "Right" } }) then return self:_goToYear(1) end
    -- The shelf is one screen: nothing to page through.
    if key and key:match({ { "RPgFwd", "LPgFwd", "Down", "RPgBack", "LPgBack", "Up" } }) then return true end
    UIManager:close(self)
    return true
end

function YearShelfPopup:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self:_schedulePending()
    return true
end

function YearShelfPopup:onCloseWidget()
    self:_freeCovers()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

-- ---------------------------------------------------------------------------

local function show(opts)
    opts = opts or {}
    if type(opts.getBooks) ~= "function" then return end
    local popup = YearShelfPopup:new{
        ui         = opts.ui,
        year       = opts.year,
        year_range = opts.year_range,
        getBooks   = opts.getBooks,
        readonly   = opts.readonly or false,
    }
    UIManager:show(popup, opts.readonly and "full" or nil)
    return popup
end

return {
    show = show,
}
