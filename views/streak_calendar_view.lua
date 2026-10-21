--[[
Reading streak calendar - the combined streak popup.

Current and best streak shown side by side, above a pageable full-history
calendar of your reading with the daily/weekly streaks marked. Extracted from
insights_view.lua so that file stays focused on the main insights page; this
same popup is opened from there (tapping any streak cell) and straight from the
Tools menu, both via M.show(streaks) with the table from
Data.calculateStreaks().

Calendar day cells (see buildStreakMonthGrid), top to bottom:
  - the day number                small, centred at the top of the cell
  - the cover of the book read
    most that day                 when several books were read up to two more
                                  sit behind it (down and to the right), like
                                  books stacked - only the backmost one has a
                                  shadow;
                                  with more than three a "+1" / "+2" ... tag
                                  at the bottom right counts the rest
  - the streak line               a line across the foot of the cell:
                                  dark (Colors.streakRead) = a day with reading,
                                  light (Colors.streakGap) = another day of a
                                  week that had any reading, none = a week
                                  with no reading at all

The popup fills the whole screen.

Gestures on the popup:
  - Tap a ‹ / › arrow, swipe left/right, or Left/Right keys   page one month
  - Tap a day in the calendar                                  list of the books read that day
                                                               (or a notice if nothing was read)
  - Any other tap / swipe / key                                close

All display data is precomputed by M.show and stashed on the StreakDatePopup
instance, so paging only re-lays-out the (cheap) widgets - it never re-queries
the database.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen
local InfoMessage = require("ui/widget/infomessage")

-- Shared modules, passed in as one named table by main.lua (see there). Same
-- Locale/Colors/Fonts/UI/Data/Prefs the insights view uses, so this popup
-- reads the same colors, fonts and reading data.
local deps = ...
local Locale, Colors, Fonts, UI, Data, Prefs, VS, BookList =
    deps.Locale, deps.Colors, deps.Fonts, deps.UI, deps.Data, deps.Prefs, deps.VS, deps.BookList
-- Frame, rounded corners and shadow of the covers (Settings > Appearance >
-- Covers), the same look as in the Book info popup.
local CoverFrame, CoverThumbs = deps.CoverFrame, deps.CoverThumbs
local DateUtil = deps.DateUtil
-- Cover loading for the calendar's day cells: the file of a book (by its
-- checksum / title) and the cover read from it - the same two the Book info
-- popup uses for a row of a book list.
local BookInfoData, Ratings = deps.BookInfoData, deps.Ratings
local T = require("ffi/util").template

local _            = Locale._
local N_           = Locale.N_
local formatCount  = Locale.formatCount

-- A YYYY-MM-DD string in the configured date format ("?" when missing).
local formatDateForDisplay = Locale.formatDateOrUnknown

-- Font faces for this popup's four text roles, sourced from the shared Fonts
-- settings module (see fonts.lua) so they're user-configurable via the "Fonts"
-- Tools-menu entry. Fonts.getFace() already caches per-role, so this is cheap
-- to rebuild on every (re)build - which is what keeps a just-changed font
-- setting picked up immediately, without needing our own extra cache. Mirrors
-- getCachedFonts/buildSerifFonts in insights_view.lua so both popups match.
local function getCachedFonts()
    return {
        section = Fonts.getFace("insights_section"),
        value   = Fonts.getFace("insights_value"),
        label   = Fonts.getFace("insights_label"),
        small   = Fonts.getFace("insights_small"),
    }
end

local buildValueLine = UI.buildValueLine

-- Weekday column labels for the streak calendar. Already translated in the
-- .po files (reused from the Book progress calendar), so no new strings are
-- needed here. Index 1..7 = Sun..Sat.
local STREAK_WEEKDAY_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

-- Days in a Y/M calendar month, and the number of leading blank cells before
-- day 1 given the configured week-start day (0 = Sun, 1 = Mon).
local function streakMonthShape(year, month, week_start_wd)
    local first_ts    = os.time{ year = year, month = month, day = 1, hour = 12 }
    local first_wd    = tonumber(os.date("%w", first_ts))
    local lead_blanks = (first_wd - week_start_wd + 7) % 7
    local days_in_month = DateUtil.daysInMonth(year, month)
    return days_in_month, lead_blanks
end

-- Whether to show week numbers (Settings ▸ Date & time ▸
-- "Show week numbers"). Off by default.
local function showWeekNumbers()
    return VS and VS.readShowWeekNumbers and VS.readShowWeekNumbers()
end

-- Metrics for the optional "Week" column: its own width (sized to the
-- "Week" header label, which is always wider than a 2-digit week number)
-- plus the padding on either side of the thin separator line to its right.
-- col_w is the column's own drawing width; prefix_w is the *total* extra
-- horizontal space the column + separator take up, so callers can subtract
-- it from the available width before splitting the remainder into 7 equal
-- day columns. Both are 0 when show_week is false, so the calendar lays out
-- exactly as it did before this option existed.
-- Whether to draw the streak line under the covers (Settings ▸ Date & time ▸
-- "Show streak bar under covers"). Off by default: the covers then use the
-- line's height too.
local function showStreakBar()
    return VS and VS.readShowStreakBar and VS.readShowStreakBar() or false
end

local WEEK_COL_SIDE_PAD = Screen:scaleBySize(4)
local function weekColumnMetrics(show_week, small_font)
    if not show_week then return 0, 0 end
    local label_w = TextWidget:new{ text = _("Week"), face = small_font }:getSize().w
    local col_w = label_w + 2 * WEEK_COL_SIDE_PAD
    local prefix_w = col_w + WEEK_COL_SIDE_PAD + Size.line.thin + WEEK_COL_SIDE_PAD
    return col_w, prefix_w
end

-- The stand-in for a book without a (readable) cover: a light card
-- with a book icon and, under it, the first few characters of the title in a
-- small face (cut with an ellipsis when too long for the card).
local NOCOVER_FILL   = 0xEC
local NOCOVER_STROKE = 0x6E
-- no_outline: the card sits inside the covers' own frame, which is its edge.
local function paintNoCover(bb, x, y, w, h, title, no_outline)
    if w < 2 or h < 2 then return end
    local stroke = Blitbuffer.Color8(NOCOVER_STROKE)
    local line   = math.max(1, Screen:scaleBySize(1))

    -- Card: filled, then outlined (square corners).
    bb:paintRect(x, y, w, h, Blitbuffer.Color8(NOCOVER_FILL))
    if not no_outline then bb:paintBorder(x, y, w, h, line, stroke) end

    -- Too small for any detail.
    if w < Screen:scaleBySize(26) or h < Screen:scaleBySize(34) then return end

    -- Title text, small; only when there is one and it fits under the icon.
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

-- The calendar can be paged into the future; this is where it stops (32-bit
-- os.time() cannot go past 2038).
local LAST_CALENDAR_YEAR = 2037

-- Caches that outlive one popup, so opening the calendar again is quick.
--   COVER_CACHE  scaled covers, key "md5|WxH" -> blitbuffer, or false when the
--                book has no readable cover. Not freed explicitly: dropping
--                the reference lets the blitbuffer's own finaliser free it,
--                so a popup still on screen can never lose a cover under it.
--   DATA_CACHE   the reading data of the whole history (month list, days read,
--                books per day). Reused until a new reading record appears
--                (MAX(start_time) moves) or the date changes - the two big
--                queries over the whole statistics table are what made the
--                window slow to open.
local COVER_CACHE, COVER_CACHE_N, COVER_CACHE_MAX = {}, 0, 150
local DATA_CACHE = nil
-- Returned by the cover callback for a cover that is not loaded yet.
local COVER_PENDING = {}

-- Covers are also kept on disk, so they survive a restart of KOReader (one
-- small thumbnail per book, shared with the year shelf - see
-- lib/coverthumbs.lua). A long press on the calendar's title (or deleting the
-- folder) starts over, e.g. after changing a book's cover.
local THUMB_W, THUMB_H = CoverThumbs.THUMB_W, CoverThumbs.THUMB_H
local diskBase, scaleTo, readThumb, writeThumb, markNoCover =
    CoverThumbs.diskBase, CoverThumbs.scaleTo, CoverThumbs.readThumb,
    CoverThumbs.writeThumb, CoverThumbs.markNoCover

-- Throws the whole cover cache away: the thumbnails (and "no cover" markers)
-- on disk and the scaled covers in memory, so every cover is read again from
-- its book. Used by a long press on the calendar's title.
local function clearCoverCache()
    CoverThumbs.clearDisk()
    COVER_CACHE, COVER_CACHE_N = {}, 0   -- dropped; the finalisers free them
end

-- One day cell of the calendar, painted in one go (see the header comment for
-- what it holds). `covers` lists what to draw, back to front:
--   { bb = <scaled cover or nil for the placeholder>, x, y, w, h, fw, fh, decor }
--   (cell-relative; w x h is the card with its frame, fw x fh with the shadow too)
local DayCell = Widget:extend{
    cell_w     = 0,
    cell_h     = 0,
    num_widget = nil,
    num_top    = 0,
    covers     = nil,
    faded      = false, -- a day of the previous / next month: covers drawn light
    badge      = nil,   -- TextWidget with the "+1" tag
    bar_color  = nil,   -- streak line colour, nil = no line
    bar_h      = 0,
    round_l    = false, -- the line starts here (previous day has none): round its left end
    round_r    = false, -- the line ends here (next day has none): round its right end
    under_l    = nil,   -- colour of the light line the rounded left end sits on
    under_r    = nil,   -- same for the right end
}

function DayCell:getSize()
    return Geom:new{ w = self.cell_w, h = self.cell_h }
end

function DayCell:paintTo(bb, x, y)
    local w, h = self.cell_w, self.cell_h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)

    for _i, c in ipairs(self.covers or {}) do
        local cx, cy = x + c.x, y + c.y
        if c.bb then
            if CoverFrame then
                CoverFrame.paint(bb, cx, cy, c.w, c.h, c.bb, c.decor)
            else
                bb:blitFrom(c.bb, cx, cy, 0, 0, c.bb:getWidth(), c.bb:getHeight())
                -- like ImageWidget: a picture is not inverted by night mode
                if Screen.night_mode then bb:invertRect(cx, cy, c.bb:getWidth(), c.bb:getHeight()) end
            end
        elseif CoverFrame then
            -- A book without a cover gets the same frame, rounded corners
            -- and shadow as the covers (its own outline only when there is
            -- no frame).
            local no_outline = ((c.decor and c.decor.border) or 0) > 0
            CoverFrame.paint(bb, cx, cy, c.w, c.h, function(b, ix, iy, iw, ih)
                paintNoCover(b, ix, iy, iw, ih, c.title, no_outline)
            end, c.decor)
        else
            paintNoCover(bb, cx, cy, c.w, c.h, c.title)
        end
        if self.faded then
            -- Blend towards the page background. Night mode inverts the
            -- whole buffer afterwards (white background -> black), so the
            -- same "lighten" blend fades the cover towards black there.
            local sh = (c.decor and c.decor.shadow) or 0
            bb:lightenRect(cx, cy, c.w + sh, c.h + sh, 0.6)
        end
    end

    if self.num_widget then
        local nw = self.num_widget:getSize().w
        self.num_widget:paintTo(bb, x + math.floor((w - nw) / 2), y + self.num_top)
    end

    if self.badge then
        local bs  = self.badge:getSize()
        local pad   = Screen:scaleBySize(2)   -- left / right
        local pad_v = 0                       -- above / below: just the text's own line space
        local bw, bh = bs.w + 2 * pad, bs.h + 2 * pad_v
        local bx = x + w - bw - Screen:scaleBySize(1)
        local by = y + h - self.bar_h - bh - Screen:scaleBySize(1)
        -- On the bottom right corner of the front cover (the last one drawn),
        -- inside it, not beside it.
        local front = self.covers and self.covers[#self.covers]
        if front and front.w and front.w > 0 then
            local inset = Size.line.thin
            bx = x + front.x + front.w - bw - inset
            by = y + front.y + front.h - bh - inset
        end
        bb:paintRect(bx, by, bw, bh, Blitbuffer.COLOR_WHITE)
        bb:paintBorder(bx, by, bw, bh, Size.line.thin, Blitbuffer.COLOR_BLACK)
        self.badge:paintTo(bb, bx + pad, by + pad_v)
    end

    if self.bar_color and self.bar_h > 0 then
        -- A day of the previous / next month: the line is half as thick and
        -- lighter, still sitting on the cell's bottom edge. The covers keep
        -- their place (they are laid out for the full-thickness line).
        local bh = self.bar_h
        if self.faded then bh = math.max(1, math.floor(bh / 2)) end
        local by = y + h - bh
        local rl = self.round_l and bh > 1
        local rr = self.round_r and bh > 1
        -- A streak starting / ending next to the light weekly line: that line
        -- runs on under the rounded end, so the end does not leave a notch.
        local cap = math.ceil(bh / 2) + 1
        if rl and self.under_l then
            bb:paintRect(x, by, cap, bh, self.under_l)
        end
        if rr and self.under_r then
            bb:paintRect(x + w - cap, by, cap, bh, self.under_r)
        end
        -- The line row by row; a rounded end starts further in on the rows
        -- near the top / bottom edge (a half circle of the line's thickness).
        local rad = bh / 2
        for i = 0, bh - 1 do
            local inset = 0
            if rl or rr then
                local dy = (i + 0.5) - rad
                inset = math.floor(rad - math.sqrt(math.max(0, rad * rad - dy * dy)) + 0.5)
            end
            local lx = x + (rl and inset or 0)
            local rx = x + w - (rr and inset or 0)
            if rx > lx then
                bb:paintRect(lx, by + i, rx - lx, 1, self.bar_color)
            end
        end
        if self.faded then
            -- Same blend in night mode: the inversion afterwards turns the
            -- fade towards white into a fade towards the dark background.
            bb:lightenRect(x, by, w, bh, 0.6)
        end
    end
end

-- One month's grid of day cells for the streak-date popup calendar (weekday
-- header row + week rows; the month/year title lives in the paging header
-- built separately - see buildStreakCalHeader/StreakDatePopup below).
--   read_set: { ["YYYY-MM-DD"] = true } days that had reading.
--     A day in read_set gets the dark streak line (Colors.streakRead). Any
--     OTHER day that shares its calendar week (row) with a read day gets the
--     light one (Colors.streakGap) - once a week has any reading its weekly
--     streak is secured, so the rest of that week is marked to show it. Days
--     in a week with no reading at all get no line.
--   day_books: { ["YYYY-MM-DD"] = { book, ... } } most-read first (see
--     Data.getDayBooksInRange); cover_for(book, w, h) -> a cover scaled to fit
--     w x h, or nil. Only days of the shown month get covers.
--   cell_w, cell_h, week_start_wd: shared sizing/layout computed once by the
--     caller. Day cells sit flush horizontally - no gap between the
--     consecutive days of a week - while a small `row_gap` separates the week
--     rows.
local function buildStreakMonthGrid(year, month, read_set, fonts, cell_w, cell_h, week_start_wd,
        show_week, week_col_w, day_books, cover_for, show_bar)
    local today_str = os.date("%Y-%m-%d")
    -- The day number is smaller than the Book progress calendar's: it only
    -- labels the cell, the cover is the picture.
    local day_font  = Fonts.getScaledFace("stats_label", 0.8)
    local bold_face = Fonts.getBoldFace("stats_label")
    pcall(function()
        local Font = require("ui/font")
        local sz = day_font.orig_size or day_font.size
        if sz then bold_face = Font:getFace("NotoSans-Bold.ttf", sz) or bold_face end
    end)

    local week_prefix_w = show_week and (week_col_w + 2 * WEEK_COL_SIDE_PAD + Size.line.thin) or 0
    local grid_w  = week_prefix_w + 7 * cell_w
    local row_gap = Screen:scaleBySize(6)
    local grid = VerticalGroup:new{ align = "center" }
    -- Geometry + dates of the day cells, handed back to the caller so it can
    -- build one tap zone per day (tap a day -> that day's book list).
    --   top        y offset of the first week row inside the grid
    --   row_pitch  distance between the tops of two consecutive week rows
    --   dates[r][c] the "YYYY-MM-DD" of week row r (1..6), column c (1..7)
    local day_meta = {
        cell_w = cell_w, cell_h = cell_h, grid_w = grid_w, week_prefix_w = week_prefix_w,
        row_pitch = cell_h + row_gap, dates = {},
    }

    -- The optional "Week" column prefix: a gray label/number cell, then a
    -- thin gray separator line, then a bit of breathing room either side.
    local function weekPrefix(text, height, is_bold)
        if not show_week then return nil end
        local label = TextWidget:new{
            text = text,
            face = is_bold and Fonts.getBoldFace("stats_label") or fonts.small,
            fgcolor = Blitbuffer.COLOR_GRAY,
        }
        return HorizontalGroup:new{
            align = "center",
            CenterContainer:new{ dimen = Geom:new{ w = week_col_w, h = height }, label },
            HorizontalSpan:new{ width = WEEK_COL_SIDE_PAD },
            Colors.newBar(Size.line.thin, height, Colors.separator()),
            HorizontalSpan:new{ width = WEEK_COL_SIDE_PAD },
        }
    end

    -- Weekday header row (each label centered over its day column), with
    -- the gray "Week" column label in front when the option is on.
    local header_row = HorizontalGroup:new{}
    local header_label_h = TextWidget:new{ text = _(STREAK_WEEKDAY_SHORT[1]), face = fonts.small }:getSize().h
    local week_header = weekPrefix(_("Week"), header_label_h)
    if week_header then table.insert(header_row, week_header) end
    for i = 0, 6 do
        local wd = ((week_start_wd + i) % 7) + 1
        local label_w = TextWidget:new{ text = _(STREAK_WEEKDAY_SHORT[wd]), face = fonts.small, fgcolor = Colors.label() }
        table.insert(header_row, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = label_w:getSize().h }, label_w,
        })
    end
    table.insert(grid, header_row)
    table.insert(grid, Colors.newBar(grid_w, Size.padding.small, Blitbuffer.COLOR_WHITE))
    day_meta.top = header_row:getSize().h + Size.padding.small

    local days_in_month, lead_blanks = streakMonthShape(year, month, week_start_wd)

    -- The real "YYYY-MM-DD" date for a cell offset from this month's day 1.
    -- cell_day < 1 lands in the previous month, > days_in_month in the next;
    -- os.time normalises both (and year rollover) for us.
    local function cellDate(cell_day)
        return os.date("%Y-%m-%d",
            os.time{ year = year, month = month, day = cell_day, hour = 12 })
    end

    -- Cell metrics: number on top, streak line at the foot, the cover(s) in
    -- between.
    local pad     = Screen:scaleBySize(3)
    local bar_h   = show_bar and Screen:scaleBySize(5) or 0
    local num_top = Screen:scaleBySize(2)
    local num_h   = TextWidget:new{ text = "88", face = day_font }:getSize().h
    local area_top = num_top + num_h + pad
    local area_w   = cell_w - 2 * pad
    local area_h   = cell_h - area_top - bar_h - pad
    -- The "+N" tag: smaller than before, in bold.
    local badge_face = Fonts.getScaledFace("stats_label", 0.6)
    pcall(function()
        local sz = badge_face.orig_size or badge_face.size
        if sz then
            badge_face = require("ui/font"):getFace("NotoSans-Bold.ttf", sz) or badge_face
        end
    end)
    local back_off = Screen:scaleBySize(6)

    -- The covers' look, as set under Settings > Appearance > Covers. The frame
    -- adds to the picture's size on every side, the shadow right and down.
    local decor = (VS and VS.Opt and VS.Opt.coverDecor and VS.Opt.coverDecor())
        or { border = 0, radius = 0, shadow = 0 }
    local deco_border, deco_shadow = decor.border, decor.shadow
    local deco_extra = deco_shadow + 2 * deco_border

    -- The covers of one day: back to front, cell-relative. One book is
    -- centred in the free area; two or three are drawn as one book on another
    -- - the runners-up peek out behind the front one at the bottom right, a
    -- step each. More than MAX_STACK books show a "+N" tag for the rest.
    local MAX_STACK = 3
    local function dayCovers(books)
        local k = math.min(#books, MAX_STACK)
        local steps = k - 1
        local off = back_off * steps
        local bw, bh = area_w - off, area_h - off
        if bw < 8 or bh < 8 then return nil end

        local function fit(book)
            -- The box of the picture itself: what is left after the frame
            -- and the shadow.
            local pbw, pbh = bw - deco_extra, bh - deco_extra
            if pbw < 4 or pbh < 4 then pbw, pbh = bw, bh end
            local bb = cover_for and cover_for(book, pbw, pbh) or nil
            if bb == COVER_PENDING then return { pending = true, w = 0, h = 0 } end
            local w, h
            if bb then
                w, h = bb:getWidth(), bb:getHeight()
            else
                h = pbh
                w = math.floor(h * 2 / 3)
                if w > pbw then w = pbw; h = math.floor(w * 3 / 2) end
            end
            w, h = w + 2 * deco_border, h + 2 * deco_border
            return {
                bb = bb, w = w, h = h, fw = w + deco_shadow, fh = h + deco_shadow,
                title = book.title, decor = decor,
            }
        end

        -- All the shown covers are asked for before giving up on a pending
        -- one, so every book is queued for loading too (not only after paging).
        local list, pending = {}, false
        for n = 1, k do
            list[n] = fit(books[n])
            if list[n].pending then pending = true end
        end
        if pending then return nil end
        local front = list[1]
        if k == 1 then
            front.x = pad + math.floor((area_w - front.fw) / 2)
            front.y = area_top + math.floor((area_h - front.fh) / 2)
            return { front }
        end
        -- Several books: the first (front) one sits at the top left, the
        -- others peek out behind it at the bottom right, a step each. Only
        -- the backmost cover (the one at the bottom of the pile) throws a
        -- shadow - it is the pile's shadow; the covers above it have none,
        -- so no shadow falls across a neighbouring cover.
        local back_decor = { border = decor.border, radius = decor.radius, shadow = 0 }
        for n = 1, k - 1 do
            list[n].decor = back_decor
            list[n].fw, list[n].fh = list[n].w, list[n].h
        end
        local mw, mh = 0, 0
        for n = 1, k do
            local d = (n - 1) * back_off
            mw = math.max(mw, d + list[n].fw)
            mh = math.max(mh, d + list[n].fh)
        end
        local gx = pad + math.floor((area_w - mw) / 2)
        local gy = area_top + math.floor((area_h - mh) / 2)
        -- Book n sits n-1 steps down and to the right of the front one.
        local out = {}
        for n = k, 1, -1 do
            local c = list[n]
            local d = (n - 1) * back_off
            c.x = gx + d
            c.y = gy + d
            out[#out + 1] = c
        end
        return out
    end

    -- The kind of streak line of any cell (also one outside the grid, e.g.
    -- the day before the first cell): "read" for a read day, "gap" for another
    -- day of a week with reading, nil for none. Used to find where the line
    -- (of either kind) starts and ends, so those ends can be rounded.
    local grid_start = 1 - lead_blanks
    local function barKindAt(cell_day)
        if read_set[cellDate(cell_day)] then return "read" end
        local row_base = grid_start + math.floor((cell_day - grid_start) / 7) * 7
        for col = 0, 6 do
            if read_set[cellDate(row_base + col)] then return "gap" end
        end
        return nil
    end

    -- Fixed six-week grid: always 6 rows starting from the first day's row, so
    -- every month is the same height. Leading cells show the previous month's
    -- tail, trailing cells the next month's start (faded covers).
    local start_cell_day = 1 - lead_blanks
    for r = 0, 5 do
        if r > 0 then
            table.insert(grid, Colors.newBar(grid_w, row_gap, Blitbuffer.COLOR_WHITE))
        end
        local base = start_cell_day + r * 7

        -- Did this calendar week (row) have any reading? If so, its remaining
        -- days get the light (weekly-streak) line. Checked across the row's
        -- real dates, so a read day in an adjacent month still counts.
        local week_has_read = false
        for col = 0, 6 do
            if read_set[cellDate(base + col)] then
                week_has_read = true
                break
            end
        end

        local row = HorizontalGroup:new{}
        day_meta.dates[r + 1] = {}
        if show_week then
            -- ISO week number of the row's first (leftmost) column, whatever
            -- the configured week-start day - a row is one calendar week
            -- either way, so it has exactly one ISO week number.
            local row_date = cellDate(base)
            local ry = tonumber(row_date:sub(1, 4))
            local rm = tonumber(row_date:sub(6, 7))
            local rd = tonumber(row_date:sub(9, 10))
            table.insert(row, weekPrefix(tostring(Locale.isoWeekNumber(ry, rm, rd)), cell_h))
        end
        for col = 0, 6 do
            local cell_day = base + col
            local day_str  = cellDate(cell_day)
            day_meta.dates[r + 1][col + 1] = day_str
            local is_this_month = (cell_day >= 1 and cell_day <= days_in_month)

            local bar_color
            if not show_bar then
                bar_color = nil
            elseif read_set[day_str] then
                bar_color = Colors.streakRead()
            elseif week_has_read then
                bar_color = Colors.streakGap()
            end

            -- The previous / next month's days (the grey numbers) show their
            -- covers too, just faded.
            local books = day_books and day_books[day_str] or nil
            local covers, badge
            if books and #books > 0 then
                covers = dayCovers(books)
                if #books > MAX_STACK then
                    badge = TextWidget:new{
                        text = "+" .. tostring(#books - MAX_STACK),
                        face = badge_face,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                end
            end

            local kind = bar_color and barKindAt(cell_day) or nil
            table.insert(row, DayCell:new{
                cell_w = cell_w, cell_h = cell_h,
                num_widget = TextWidget:new{
                    text = tostring(tonumber(day_str:sub(9, 10))),
                    face = (day_str == today_str) and bold_face or day_font,
                    fgcolor = is_this_month and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
                },
                num_top   = num_top,
                faded     = not is_this_month,
                covers    = covers,
                badge     = badge,
                bar_color = bar_color,
                bar_h     = bar_h,
                -- The dark streak line is rounded where the streak starts /
                -- ends (the day before / after is not a read day); the light
                -- weekly line where it starts / ends with no line next to it.
                -- Beside a light line the rounded end is laid on it.
                round_l   = (bar_color and barKindAt(cell_day - 1) ~= kind) and (kind == "read" or barKindAt(cell_day - 1) == nil) and true or false,
                round_r   = (bar_color and barKindAt(cell_day + 1) ~= kind) and (kind == "read" or barKindAt(cell_day + 1) == nil) and true or false,
                under_l   = (kind == "read" and barKindAt(cell_day - 1) == "gap") and Colors.streakGap() or nil,
                under_r   = (kind == "read" and barKindAt(cell_day + 1) == "gap") and Colors.streakGap() or nil,
            })
        end
        table.insert(grid, row)
    end

    return grid, day_meta
end

-- The list of { year, month } the streak spans, oldest first. One entry is one
-- page of the streak-date popup calendar.
local function streakMonthList(range_start, range_end)
    if not range_start or not range_end then return nil end
    local sy, sm = Data.parseDateYMD(range_start)
    local ey, em = Data.parseDateYMD(range_end)
    if not sy or not ey then return nil end
    local months = {}
    local y, m = sy, sm
    while (y < ey) or (y == ey and m <= em) do
        table.insert(months, { year = y, month = m })
        m = m + 1
        if m > 12 then m = 1; y = y + 1 end
    end
    return months
end

-- Month/year title with ‹ / › paging arrows, mirroring the Book progress
-- calendar's header (buildBookCalendarHeader). Both arrow slots are always the
-- same fixed width whether or not the arrow is shown, so the title stays
-- centered and the header doesn't jump sideways while paging. Returns the row
-- widget plus the arrow slot widths and the row height, for hit-testing.
-- fgcolor defaults to Colors.section() (the calendar month header's look);
-- the streak history popup's page-range subheading passes fonts.label /
-- Colors.label() instead so it reads as a subheading under the section title
-- rather than a second, equally-heavy title. arrow_font/arrow_fgcolor let a
-- caller keep the title itself small/light while still drawing the ‹ / ›
-- glyphs in the bigger/bolder style of the calendar month header above -
-- the streak history popup's page-range subheading does this so its chevrons
-- match the ones on the combined streak popup instead of looking like a
-- smaller, non-bold pair of their own. Both default to section_font/fgcolor,
-- so every other caller (which doesn't pass them) is unaffected.
local function buildStreakCalHeader(title_str, content_width, section_font, prev_available, next_available,
        fgcolor, arrow_font, arrow_fgcolor)
    fgcolor = fgcolor or Colors.section()
    arrow_font    = arrow_font or section_font
    arrow_fgcolor = arrow_fgcolor or fgcolor
    local arrow_pad = Size.padding.default
    local left_glyph_w  = TextWidget:new{ text = "\xe2\x80\xb9", face = arrow_font }:getSize().w
    local right_glyph_w = TextWidget:new{ text = "\xe2\x80\xba", face = arrow_font }:getSize().w
    local slot_w = math.max(left_glyph_w, right_glyph_w) + 2 * arrow_pad

    local function makeArrow(glyph, visible)
        if not visible then return HorizontalSpan:new{ width = slot_w } end
        local tw = TextWidget:new{ text = glyph, face = arrow_font, fgcolor = arrow_fgcolor }
        local extra = slot_w - 2 * arrow_pad - tw:getSize().w
        return FrameContainer:new{
            background = nil, bordersize = 0, margin = 0,
            padding_top = 0, padding_bottom = 0,
            padding_left  = arrow_pad + math.floor(extra / 2),
            padding_right = arrow_pad + math.ceil(extra / 2),
            tw,
        }
    end

    local left_widget  = makeArrow("\xe2\x80\xb9", prev_available)
    local right_widget = makeArrow("\xe2\x80\xba", next_available)
    local title_w = TextWidget:new{ text = title_str, face = section_font, fgcolor = fgcolor }

    local remaining = content_width - left_widget:getSize().w - right_widget:getSize().w - title_w:getSize().w
    if remaining < 0 then remaining = 0 end
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l

    local header_row = HorizontalGroup:new{
        align = "center",
        left_widget,
        HorizontalSpan:new{ width = side_l },
        title_w,
        HorizontalSpan:new{ width = side_r },
        right_widget,
    }

    -- Same small padding above and below the text as every other section
    -- header (UI.buildSectionHeader). The height returned below includes it,
    -- and every tap zone is computed from that returned height, so the
    -- arrows' and the title's zones keep covering the whole header.
    local padded_header = FrameContainer:new{
        background     = nil,
        bordersize     = 0,
        margin         = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = 0,
        padding_right  = 0,
        header_row,
    }
    return padded_header, left_widget:getSize().w, right_widget:getSize().w, padded_header:getSize().h
end


-- A single day's bar: filled from the left with Colors.activeBar() up to
-- `ratio` (0..1) of `width`, the rest filled with Colors.inactiveBar() -
-- same two-segment idea as the monthly/weekly bar charts elsewhere in this
-- plugin, just drawn as one flat horizontal bar per row instead of a column,
-- the way the source "reading hours" patch drew its own per-day bars.
local STREAK_HISTORY_BAR_HEIGHT = Screen:scaleBySize(10)
local function buildDayBar(ratio, width)
    if not width or width <= 0 then return nil end
    ratio = tonumber(ratio) or 0
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end

    local fill_w = math.floor(width * ratio + 0.5)
    if ratio > 0 and fill_w == 0 then fill_w = 1 end
    if fill_w > width then fill_w = width end
    local rest_w = width - fill_w

    local bar_row = HorizontalGroup:new{ align = "top" }
    -- Filled portion matches the streak calendar's "read day" cell color
    -- (Colors.streakRead(), same fill as a daily-streak day square) rather
    -- than the generic activeBar() color, so the popup's bars and the
    -- calendar it opens from read as the same visual language.
    if fill_w > 0 then table.insert(bar_row, Colors.newBar(fill_w, STREAK_HISTORY_BAR_HEIGHT, Colors.streakRead())) end
    -- The empty remainder stays plain white rather than the shared
    -- inactive-bar gray, so the Streak History popup's bars read as
    -- "filled portion on a blank track" instead of a two-tone gray bar.
    if rest_w > 0 then table.insert(bar_row, Colors.newBar(rest_w, STREAK_HISTORY_BAR_HEIGHT, Blitbuffer.COLOR_WHITE)) end
    bar_row.dimen = Geom:new{ w = width, h = STREAK_HISTORY_BAR_HEIGHT }
    return bar_row
end

-- How many rows one page of the streak history popup shows: 14 days in the
-- daily views, 14 weeks in the weekly ones. Paging (arrows / swipe / keys)
-- moves between pages instead of scrolling, so a streak of any length only
-- ever builds this many row widgets at a time.
local STREAK_HISTORY_PAGE_SIZE = 14

-- Landscape shows half as many rows per page (the screen is much shorter
-- there, and the page would otherwise be taller than it); portrait keeps
-- the full page. Looked up on every rebuild rather than once, so a rotation
-- while the popup is open is picked up too.
local function streakHistoryPageSize()
    if UI.isLandscapeScreen() then
        return math.floor(STREAK_HISTORY_PAGE_SIZE / 2)
    end
    return STREAK_HISTORY_PAGE_SIZE
end

-- The four views of the popup, in the order of its selectable list:
-- { unit, metric }. unit "day" = one row per day, "week" = one row per week;
-- metric "time" / "pages" = what the bars and values show.
local STREAK_VIEWS = {
    { "day",  "time"  },
    { "day",  "pages" },
    { "week", "time"  },
    { "week", "pages" },
}

-- Name of a view in the list.
local function viewLabel(unit, metric)
    if unit == "week" then
        return metric == "pages" and _("Weekly streak (pages)") or _("Weekly streak (time)")
    end
    return metric == "pages" and _("Daily streak (pages)") or _("Daily streak (time)")
end

-- Short name of a view, for the caption above the summary row.
local function viewShortLabel(unit, metric)
    if unit == "week" then
        return metric == "pages" and _("Weekly (pages)") or _("Weekly (time)")
    end
    return metric == "pages" and _("Daily (pages)") or _("Daily (time)")
end

-- "YYYY-MM-DD" n days after (or before, n < 0) date_str.
local function addDays(date_str, n)
    local y, m, d = Data.parseDateYMD(date_str)
    if not y then return date_str end
    return os.date("%Y-%m-%d", os.time{ year = y, month = m, day = d, hour = 12 } + n * 86400)
end

-- A week row's label: its date range, short (\"Sep 22 \xE2\x80\x93 28\" within one
-- month, \"Sep 29 \xE2\x80\x93 Oct 5\" across two). `start` is the week's first day.
local function weekLabel(start)
    local last = addDays(start, 6)
    local first_s = Locale.formatShortMonthDay(start)
    if start:sub(1, 7) == last:sub(1, 7) then
        local last_s = Locale.formatDayOfMonth(tonumber(last:sub(9, 10)))
        return first_s .. " \xE2\x80\x93 " .. last_s
    end
    return first_s .. " \xE2\x80\x93 " .. Locale.formatShortMonthDay(last)
end

local function textWidth(text, face)
    local w = TextWidget:new{ text = text, face = face }
    local width = w:getSize().w
    pcall(function() w:free() end)
    return width
end

--[[
The streak history popup: one bar per day (or per week) of a streak. From top
to bottom:

  - the date range the current page covers, with the ‹ / › paging arrows - it
    is the popup's title. Tapping it jumps back to the first page (the newest
    end of the streak, i.e. the current date)
  - a caption naming the view (Daily streak (time) / Daily streak (pages) /
    Weekly streak (time) / Weekly streak (pages)), styled like the monthly
    chart's caption on the insights page: tapping it opens a list of the four
    views (the one in use marked with a check mark). There is no other
    time/pages toggle in the popup
  - the rows, \"date | bar | value\" - at most STREAK_HISTORY_PAGE_SIZE (14) of
    them: days in a daily view, whole weeks (one row per week of the weekly
    streak, even those with days off) in a weekly view
  - a caption (\"Current streak - Daily (time)\") and, under its line, one summary
    row: the streak's length in days or weeks of the picked view and the dates
    it spans

Pageable rather than scrollable (‹ / › arrows, swipe, or Left/Right keys page;
any other tap/swipe/key closes). It opens on page 1 - the newest end of the
streak.

All display data is precomputed once by showStreakHistory and stashed on the
instance, so paging and switching the view only re-lays-out the (cheap) widgets
- neither ever re-queries the database.
]]--
local StreakHistoryPopup = InputContainer:extend{
    modal = true,
}

function StreakHistoryPopup:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self.metric = (self.metric == "pages") and "pages" or "time"
    self.unit   = (self.unit == "week") and "week" or "day"
    self.page_index = self.page_index or 1
    self._week_stats = {}
    self._max = {}
    self:_rebuild()
end

function StreakHistoryPopup:_centeredRect(widget)
    local size = widget:getSize()
    return Geom:new{
        x = self.dimen.x + math.floor((self.dimen.w - size.w) / 2),
        y = self.dimen.y + math.floor((self.dimen.h - size.h) / 2),
        w = size.w, h = size.h,
    }
end

-- Time and pages of one week (the sum of its seven days), cached.
function StreakHistoryPopup:_weekStats(week_start)
    local hit = self._week_stats[week_start]
    if hit then return hit end
    local seconds, pages = 0, 0
    for i = 0, 6 do
        local d = self.stats[addDays(week_start, i)]
        if d then
            seconds = seconds + d.seconds
            pages   = pages   + d.pages
        end
    end
    hit = { seconds = seconds, pages = pages }
    self._week_stats[week_start] = hit
    return hit
end

-- The rows of the view being shown (newest first) and the label / stats of one.
function StreakHistoryPopup:_items()
    return (self.unit == "week") and self.weeks or self.days
end

function StreakHistoryPopup:_statsOf(item)
    if self.unit == "week" then return self:_weekStats(item) end
    return self.stats[item]
end

function StreakHistoryPopup:_labelOf(item)
    if self.unit == "week" then return weekLabel(item) end
    -- Translated "Mon D" label (e.g. "Sep 22", Hungarian "Szept. 22") rather
    -- than a bare numeric day/month, which reads ambiguously at a glance.
    return Locale.formatShortMonthDay(item)
end

-- "<oldest> - <newest>" of items[first..last] (the list is newest first), in
-- the configured date format. A week ends on its last day.
function StreakHistoryPopup:_rangeText(items, unit, first, last)
    local newest = items[first]
    if unit == "week" then newest = addDays(newest, 6) end
    return formatDateForDisplay(items[last], true) .. " \xE2\x80\x93 " .. formatDateForDisplay(newest)
end

-- The caption above the summary row: which streak (current / best).
function StreakHistoryPopup:_caption()
    return self.title_str
end

-- Natural width of the left (\"123 days\") column, the widest range text and
-- the height of one row - measured from the real strings and fonts, over both
-- summary rows (daily and weekly) so switching views never resizes the box.
function StreakHistoryPopup:_measureInfo(fonts)
    local left_w, range_w, row_h = 0, 0, 0
    for _, r in pairs(self.infos or {}) do
        local v  = TextWidget:new{ text = r.value, face = fonts.value }
        local u  = TextWidget:new{ text = r.unit,  face = fonts.label }
        local rg = TextWidget:new{ text = r.range, face = fonts.label }
        left_w  = math.max(left_w, v:getSize().w + Size.padding.large + u:getSize().w)
        range_w = math.max(range_w, rg:getSize().w)
        row_h   = math.max(row_h, v:getSize().h, u:getSize().h, rg:getSize().h)
        v:free() u:free() rg:free()
    end
    -- A little slack so the unit's TextBoxWidget never wraps on rounding.
    left_w = left_w + Screen:scaleBySize(4)
    return left_w, range_w, row_h
end

-- Width taken by the vertical separator between the two columns of an info row.
local function infoSeparatorWidth()
    return 2 * Size.padding.large + Size.line.medium
end

-- Height of everything in the box except the rows: the box padding, the range
-- header, the view caption, the rows' caption, the summary row and the
-- space-line-space groups between them. (A little slack included.)
function StreakHistoryPopup:_fixedHeight()
    local group = 2 * Size.padding.small + Size.line.thin
    return 2 * (self.inner_padding + Size.border.window)
        + self._range_h_est
        + self._list_row_h
        + self._caption_h + 2 * group + (Size.line.thick - Size.line.thin)
        + self._info_row_h
        + Screen:scaleBySize(24)
end

-- Rows per page: the usual page size, but never more than the screen can hold
-- together with everything above and below the rows. Looked up on every
-- rebuild (like streakHistoryPageSize) so a rotation is picked up too.
function StreakHistoryPopup:_pageSize()
    local base = streakHistoryPageSize()
    if not self._row_unit_h then return base end
    local fit = math.floor((Screen:getHeight() - self:_fixedHeight() + self._row_gap) / self._row_unit_h)
    return math.max(3, math.min(base, fit))
end

-- The summary row at the bottom of the popup: "value unit | range" of the
-- picked view's streak (its length in days or weeks and the dates it spans),
-- styled like the value rows of the insights page - a bold value, a plain unit
-- next to it, a vertical separator, then the label-font text.
function StreakHistoryPopup:_buildInfo(cont_w, fonts)
    local r = self.infos and self.infos[self.unit]
    if not r then return nil end
    local sep_w   = infoSeparatorWidth()
    -- The separator sits at 1/4 of the row width (its centre), so the left
    -- column is a quarter minus half the separator - unless the "123 days"
    -- text is wider than that.
    local left_w  = math.max(self._info_left_w, math.floor(cont_w / 4 - sep_w / 2))
    local right_w = math.max(Screen:scaleBySize(20), cont_w - left_w - sep_w)
    local row_h   = self._info_row_h

    local value_line = buildValueLine(fonts.value, fonts.label, left_w, r.value, r.unit)
    local range = TextWidget:new{
        text = r.range, face = fonts.label, fgcolor = Colors.label(), max_width = right_w,
    }
    return HorizontalGroup:new{
        align = "center",
        UI.fixedCol(value_line, left_w, row_h),
        UI.buildColumnSeparator(Size.padding.large, row_h),
        UI.fixedCol(range, right_w, row_h),
    }
end

-- The caption naming the view in use, like the monthly chart's caption on the
-- insights page (label font and colour, small padding, indented): a tap opens
-- the list of the four views (see _showViewPicker).
function StreakHistoryPopup:_buildViewCaption(cont_w, fonts)
    local label = TextWidget:new{
        text = viewLabel(self.unit, self.metric), face = fonts.label, fgcolor = Colors.label(),
        max_width = cont_w,
    }
    return FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = 0,
        margin         = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = 0,   -- flush with the dates of the rows below
        padding_right  = 0,
        label,
    }
end

-- One "date | bar | value" row. bar_w is the bar's own pixel width (already
-- sized to leave room for the date and value columns); max_value is the
-- largest value (seconds or pages, whichever self.metric is) across every
-- row in the list, so every bar's fill is relative to the same scale.
function StreakHistoryPopup:_buildRow(item, stats, max_value, fonts)
    local seconds = stats and stats.seconds or 0
    local pages   = stats and stats.pages   or 0
    local value   = (self.metric == "pages") and pages or seconds
    local value_str
    if self.metric == "pages" then
        value_str = pages == 0 and "---" or formatCount(pages)
    else
        value_str = seconds == 0 and "---" or Locale.formatDuration(seconds, true)
    end

    local date_widget  = TextWidget:new{ text = self:_labelOf(item), face = fonts.small, fgcolor = Colors.label() }
    local value_widget = TextWidget:new{ text = value_str,  face = fonts.small, fgcolor = Colors.value() }

    local ratio = (max_value > 0) and (value / max_value) or 0
    local bar = buildDayBar(ratio, self._bar_w) or HorizontalSpan:new{ width = self._bar_w }

    local row_h = math.max(date_widget:getSize().h, value_widget:getSize().h, bar:getSize().h)

    return HorizontalGroup:new{
        align = "center",
        UI.fixedCol(date_widget, self._date_col_w, row_h),
        HorizontalSpan:new{ width = self._col_gap },
        bar,
        HorizontalSpan:new{ width = self._col_gap },
        UI.fixedCol(RightContainer:new{
            dimen = Geom:new{ w = self._value_col_w, h = row_h }, value_widget,
        }, self._value_col_w, row_h),
    }, row_h
end

-- Everything measured once, on the first build: fonts, the column widths of
-- both units, the heights used for the page size and - in landscape - the
-- narrower box. Done once so paging and switching views never resize the box.
function StreakHistoryPopup:_measure(fonts)
    local cont_w = self.content_width

    self._col_gap = Size.padding.default
    self._row_gap = 0 -- no gap between the rows

    local ok, bold = pcall(Fonts.getBoldFace, "insights_label")
    self._label_bold = (ok and bold) or fonts.label

    -- Date column per unit, from the widest possible label: the daily one in
    -- every month (month-name widths vary by language, e.g. Hungarian
    -- "Szept. 30" is wider than English "Sep 30"), the weekly one for a week
    -- that crosses into the next month.
    local day_date_w, week_date_w = 0, 0
    for m = 1, 12 do
        day_date_w = math.max(day_date_w,
            textWidth(Locale.formatShortMonthDay(string.format("2024-%02d-30", m)), fonts.small))
        week_date_w = math.max(week_date_w,
            textWidth(weekLabel(string.format("2024-%02d-28", m)), fonts.small))
    end
    -- Value column per unit, from a realistic worst case for both metrics.
    local slack = Screen:scaleBySize(4)
    local day_value_w = math.max(
        textWidth(Locale.formatDuration(23 * 3600 + 59 * 60, true), fonts.small),
        textWidth(formatCount(999), fonts.small)) + slack
    local week_value_w = math.max(
        textWidth(Locale.formatDuration(99 * 3600 + 59 * 60, true), fonts.small),
        textWidth(formatCount(9999), fonts.small)) + slack
    self._cols = {
        day  = { date_w = day_date_w,  value_w = day_value_w  },
        week = { date_w = week_date_w, value_w = week_value_w },
    }

    -- Vertical budget for _pageSize().
    local arrow_probe = TextWidget:new{ text = "\xe2\x80\xb9", face = fonts.section }
    self._range_h_est = arrow_probe:getSize().h + 2 * Size.padding.small + Screen:scaleBySize(4)
    arrow_probe:free()
    local caption_probe = TextWidget:new{ text = "0", face = fonts.section }
    self._caption_h = caption_probe:getSize().h
    caption_probe:free()
    local date_probe = TextWidget:new{ text = "0", face = fonts.small }
    self._row_unit_h = date_probe:getSize().h + self._row_gap
    date_probe:free()
    self._info_left_w, self._info_range_w, self._info_row_h = self:_measureInfo(fonts)

    -- The view caption's height (text plus the padding above and below).
    local label_h = TextWidget:new{ text = "Ag", face = fonts.label }:getSize().h
    self._list_row_h = label_h + 2 * Size.padding.small

    -- Landscape only: the box doesn't need most of a wide screen. Limit it to
    -- 50% of the screen width - or, if that is too little, to the narrowest
    -- width at which everything still fits: the date range with both paging
    -- arrows on one line (the widest range over every page of both units),
    -- the names of the views, the caption, one row of each unit and the
    -- summary row. Never wider than the usual width passed in.
    if UI.isLandscapeScreen() then
        local arrow_pad = Size.padding.default
        local slot_w = math.max(textWidth("\xe2\x80\xb9", fonts.section), textWidth("\xe2\x80\xba", fonts.section))
            + 2 * arrow_pad
        local need = 0

        local ps = self:_pageSize()
        for _, unit in ipairs({ "day", "week" }) do
            local items = (unit == "week") and self.weeks or self.days
            for first = 1, #items, ps do
                local last = math.min(first + ps - 1, #items)
                need = math.max(need, textWidth(self:_rangeText(items, unit, first, last), fonts.section)
                    + 2 * slot_w + 2 * arrow_pad)
            end
            local c = self._cols[unit]
            need = math.max(need, c.date_w + c.value_w + 2 * self._col_gap + Screen:scaleBySize(60))
        end

        for _, v in ipairs(STREAK_VIEWS) do
            need = math.max(need,
                textWidth(viewLabel(v[1], v[2]), fonts.label),
                textWidth(self:_caption(), fonts.section))
        end

        -- The summary row: separator at 1/4, the left text must fit in the
        -- first quarter, the range in the remaining three quarters.
        local sep_w = infoSeparatorWidth()
        need = math.max(need,
            4 * (self._info_left_w + sep_w / 2),
            (4 / 3) * (self._info_range_w + sep_w / 2) + Screen:scaleBySize(4))

        local half_content = math.floor(Screen:getWidth() * 0.5) - 2 * self.inner_padding
        self.content_width = math.min(self.content_width, math.max(half_content, math.ceil(need)))
        cont_w = self.content_width
    end
    self._rows_w = cont_w
end

function StreakHistoryPopup:_rebuild()
    local fonts = self.fonts
    if not self._cols then self:_measure(fonts) end
    local cont_w = self.content_width

    -- Columns of the unit being shown.
    local cols = self._cols[self.unit]
    self._date_col_w, self._value_col_w = cols.date_w, cols.value_w
    self._bar_w = self._rows_w - self._date_col_w - self._value_col_w - 2 * self._col_gap
    if self._bar_w < Screen:scaleBySize(20) then self._bar_w = Screen:scaleBySize(20) end

    local items = self:_items()

    -- The running max (seconds and pages) is computed once per unit, across
    -- the *whole* streak rather than just the page being shown, and cached -
    -- so a bar's fill is always proportional to the streak's busiest day (or
    -- week), whichever page you're paged to.
    if not self._max[self.unit] then
        local max_seconds, max_pages = 0, 0
        for _, item in ipairs(items) do
            local d = self:_statsOf(item)
            if d then
                if d.seconds > max_seconds then max_seconds = d.seconds end
                if d.pages   > max_pages   then max_pages   = d.pages   end
            end
        end
        self._max[self.unit] = { seconds = max_seconds, pages = max_pages }
    end
    local max_value = (self.metric == "pages") and self._max[self.unit].pages or self._max[self.unit].seconds

    -- This page's slice of the (newest-first) list.
    local total      = #items
    local page_size  = self:_pageSize()
    self._total_pages = math.max(1, math.ceil(total / page_size))
    if self.page_index < 1 then self.page_index = 1 end
    if self.page_index > self._total_pages then self.page_index = self._total_pages end
    local start_i = (self.page_index - 1) * page_size + 1
    local end_i = math.min(start_i + page_size - 1, total)
    local page_items = {}
    for i = start_i, end_i do page_items[#page_items + 1] = items[i] end

    local content = VerticalGroup:new{ align = "left" }
    -- thick: the heavier line the insights page draws above its section
    -- headers (used above the streak caption).
    local function divider(thick)
        table.insert(content, VerticalSpan:new{ width = Size.padding.small })
        table.insert(content, Colors.newBar(cont_w, thick and Size.line.thick or Size.line.thin, Colors.separator()))
        table.insert(content, VerticalSpan:new{ width = Size.padding.small })
    end

    -- Title: the date range this page covers, with the ‹ / › paging arrows.
    -- The list is newest-first, so the range reads oldest (the page's last
    -- entry) to newest (its first). Tapping the title jumps back to page 1.
    local range_str = "\xE2\x80\x93"
    if #page_items > 0 then
        range_str = self:_rangeText(page_items, self.unit, 1, #page_items)
    end
    local prev_available = self.page_index > 1
    local next_available = self.page_index < self._total_pages
    local range_header, range_left_w, range_right_w, range_header_h = buildStreakCalHeader(
        range_str, cont_w, fonts.section, prev_available, next_available)
    table.insert(content, range_header)
    -- Both arrow tap zones (below) stay registered at their reserved slot
    -- width, whether or not an arrow is drawn there right now: a fast second
    -- tap landing just as the last page removes that arrow is then routed to
    -- _goToPage (which no-ops) instead of falling through to close the popup.
    self._range_header_h = range_header_h
    self._range_left_w, self._range_right_w = range_left_w, range_right_w

    -- The caption naming the view (a tap lists the four views).
    table.insert(content, self:_buildViewCaption(cont_w, fonts))

    -- The rows.
    local rows = VerticalGroup:new{}
    for _, item in ipairs(page_items) do
        local row = self:_buildRow(item, self:_statsOf(item), max_value, fonts)
        table.insert(rows, row)
    end
    table.insert(content, rows)

    divider(true)

    -- Caption (which streak, in which view) above the line of the summary row.
    local caption = TextWidget:new{
        text = self:_caption(), face = fonts.section, fgcolor = Colors.section(),
        max_width = cont_w,
    }
    table.insert(content, caption)   -- left-aligned

    divider()

    local info = self:_buildInfo(cont_w, fonts)
    if info then table.insert(content, info) end

    self.box_content = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding        = self.inner_padding,
        content,
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, self.box_content }

    -- Absolute tap zones: the title (‹ / › arrows page, the middle jumps to
    -- page 1) and one per view of the list. Anything else closes the popup.
    local box_rect = self:_centeredRect(self.box_content)
    local border_w = Size.border.window
    local header_x = box_rect.x + border_w + self.inner_padding
    local header_y = box_rect.y + border_w + self.inner_padding
    local tap_pad = Screen:scaleBySize(14)

    self._nav_zones = {}
    table.insert(self._nav_zones, {
        dimen = Geom:new{ x = header_x + self._range_left_w + tap_pad, y = header_y - tap_pad,
            w = math.max(1, cont_w - self._range_left_w - self._range_right_w - 2 * tap_pad),
            h = self._range_header_h + 2 * tap_pad },
        first_page = true,
    })
    table.insert(self._nav_zones, {
        dimen = Geom:new{ x = header_x - tap_pad, y = header_y - tap_pad,
            w = self._range_left_w + 2 * tap_pad, h = self._range_header_h + 2 * tap_pad },
        delta = -1,
    })
    table.insert(self._nav_zones, {
        dimen = Geom:new{ x = header_x + cont_w - self._range_right_w - tap_pad, y = header_y - tap_pad,
            w = self._range_right_w + 2 * tap_pad, h = self._range_header_h + 2 * tap_pad },
        delta = 1,
    })

    local list_y = header_y + self._range_header_h
    -- The caption's tap zone spans the whole row.
    self._list_zones = {
        { dimen = Geom:new{ x = header_x, y = list_y, w = cont_w, h = self._list_row_h } },
    }
end

-- Re-lays-out after `change()` altered the state, repainting the old and the
-- new box (their height can differ with the number of rows).
function StreakHistoryPopup:_relayout(change)
    local old_rect = self:_centeredRect(self.box_content)
    change()
    self:_rebuild()
    local new_rect = self:_centeredRect(self.box_content)
    local x1 = math.min(old_rect.x, new_rect.x)
    local y1 = math.min(old_rect.y, new_rect.y)
    local x2 = math.max(old_rect.x + old_rect.w, new_rect.x + new_rect.w)
    local y2 = math.max(old_rect.y + old_rect.h, new_rect.y + new_rect.h)
    UIManager:setDirty("all", function()
        return "ui", Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
    end)
    return true
end

function StreakHistoryPopup:_goToPage(delta)
    local total = self._total_pages or 1
    local idx = self.page_index + delta
    if idx < 1 or idx > total then return true end
    return self:_relayout(function() self.page_index = idx end)
end

-- Picks one of the four views (and remembers it for the next opening). A new
-- unit starts on page 1: a day page and a week page are not the same stretch.
function StreakHistoryPopup:_selectView(unit, metric)
    if unit == self.unit and metric == self.metric then return true end
    VS.saveStreakHistoryMetricSetting(metric)
    VS.saveStreakHistoryUnitSetting(unit)
    return self:_relayout(function()
        if unit ~= self.unit then self.page_index = 1 end
        self.unit, self.metric = unit, metric
    end)
end

-- The list of the four views, the one in use marked with a check mark (same
-- look as the pickers of the insights page).
function StreakHistoryPopup:_showViewPicker()
    local ButtonDialog = require("ui/widget/buttondialog")
    local popup_self = self
    local dialog
    local buttons = {}
    for _i, v in ipairs(STREAK_VIEWS) do
        local unit, metric = v[1], v[2]
        local current = (unit == self.unit and metric == self.metric)
        table.insert(buttons, {{
            -- U+2713 CHECK MARK in front of the view currently in use.
            text  = (current and "\xe2\x9c\x93 " or "    ") .. viewLabel(unit, metric),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                popup_self:_selectView(unit, metric)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        modal                 = true,
        shrink_unneeded_width = true,
        buttons               = buttons,
    }
    -- A plain "ui" refresh when it closes instead of the flashing one.
    dialog.onCloseWidget = function(this)
        UIManager:setDirty(nil, function()
            return "ui", this.movable and this.movable.dimen
        end)
    end
    UIManager:show(dialog)
    return true
end

function StreakHistoryPopup:onTap(arg, ges_ev)
    if ges_ev and ges_ev.pos then
        local x, y = ges_ev.pos.x, ges_ev.pos.y
        for _, zone in ipairs(self._nav_zones or {}) do
            if UI.hitTest({ dimen = zone.dimen }, x, y) then
                if zone.first_page then
                    if self.page_index == 1 then return true end
                    return self:_goToPage(1 - self.page_index)
                end
                return self:_goToPage(zone.delta)
            end
        end
        for _, zone in ipairs(self._list_zones or {}) do
            if UI.hitTest({ dimen = zone.dimen }, x, y) then
                return self:_showViewPicker()
            end
        end
    end
    UIManager:close(self)
    return true
end

function StreakHistoryPopup:onSwipe(arg, ges_ev)
    if not ges_ev then UIManager:close(self) return true end
    local dir = ges_ev.direction
    if dir == "west" or dir == "left"  then return self:_goToPage(1)  end
    if dir == "east" or dir == "right" then return self:_goToPage(-1) end
    UIManager:close(self)
    return true
end

function StreakHistoryPopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:_goToPage(1)  end
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:_goToPage(-1) end
    UIManager:close(self)
    return true
end

function StreakHistoryPopup:onClose()
    UIManager:close(self)
    return true
end

function StreakHistoryPopup:onShow()
    UIManager:setDirty(self, function() return "ui", self:_centeredRect(self.box_content) end)
    return true
end

function StreakHistoryPopup:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self:_centeredRect(self.box_content) end)
end

-- The full "YYYY-MM-DD" day list for [start_date, end_date], newest first.
local function dateRangeListDesc(start_date, end_date)
    local sy, sm, sd = Data.parseDateYMD(start_date)
    local ey, em, ed = Data.parseDateYMD(end_date)
    if not sy or not ey then return {} end
    local t_start = os.time{ year = sy, month = sm, day = sd, hour = 12 }
    local t_end   = os.time{ year = ey, month = em, day = ed, hour = 12 }
    local list = {}
    local t = t_end
    while t >= t_start do
        table.insert(list, os.date("%Y-%m-%d", t))
        t = t - 86400
    end
    return list
end

-- The week-start dates from `start_date` to `end_date` (both week starts, as
-- the weekly streak stores them), newest first - every week of the streak,
-- also one whose days were not all read.
local function weekListDesc(start_date, end_date)
    local list = {}
    local d, guard = end_date, 0
    while d >= start_date and guard < 10000 do
        table.insert(list, d)
        d = addDays(d, -7)
        guard = guard + 1
    end
    return list
end

-- Lays out the popup box (fonts, width) and shows it for the given day and
-- week lists, their stats and the two summary rows.
local function showHistoryPopup(title_str, days, weeks, stats, infos)
    local fonts = getCachedFonts()
    local inner_padding = Size.padding.large
    local screen_w = Screen:getWidth()
    local box_width = math.floor(screen_w * 0.88)
    local content_width = box_width - 2 * inner_padding

    UIManager:show(StreakHistoryPopup:new{
        fonts           = fonts,
        content_width   = content_width,
        inner_padding   = inner_padding,
        title_str       = title_str,
        days            = days,
        weeks           = weeks,
        stats           = stats,
        infos           = infos,
        metric          = VS.readStreakHistoryMetricSetting(),
        unit            = VS.readStreakHistoryUnitSetting(),
    })
end

-- Opens the per-day / per-week bar-list history for one streak - "current" or
-- "best" - from the `streaks` table (Data.calculateStreaks()). Tapping
-- "Current streak"/"Best streak" on the insights page opens this (see
-- ReadingInsightsPopup's tap_cd/tap_cw/tap_bd/tap_bw in insights_view.lua);
-- the combined calendar popup above (M.show) stays reachable from the
-- hamburger menu and the Tools-menu entry.
-- "<from> – <to>" in the configured date format for a streak's stored dates
-- ({ start, end_ }); "–" when there are none. A weekly streak is stored as the
-- start dates of its first and last week, so its range ends on the last day of
-- that final week (for the running week that is its upcoming last day, not
-- today). `unit` is "days" or "weeks".
local function streakRangeText(dates, unit)
    local dash = "\xE2\x80\x93"
    if not (dates and dates.start) then return dash end
    local from_date, to_date = dates.start, dates.end_
    if unit == "weeks" then
        to_date = addDays(to_date, 6)
    end
    return formatDateForDisplay(from_date, true) .. " " .. dash .. " " .. formatDateForDisplay(to_date)
end

local function showStreakHistory(streaks, which)
    streaks = streaks or {}
    local prefix = (which == "best") and "best" or "current"
    local dates = streaks[prefix .. "_days_dates"]
    if not dates or not dates.start then
        UIManager:show(InfoMessage:new{ text = _("No streak dates") })
        return
    end
    local week_dates = streaks[prefix .. "_weeks_dates"]

    -- The whole streak, newest first - the popup pages through it rather
    -- than truncating it, so however long the streak ran is all shown.
    local days  = dateRangeListDesc(dates.start, dates.end_)
    local weeks = (week_dates and week_dates.start and week_dates.end_)
        and weekListDesc(week_dates.start, week_dates.end_) or {}

    -- One query for the span of both lists (a weekly streak reaches further
    -- back than the daily one, as days off do not break it).
    local from_date, to_date = dates.start, dates.end_
    if #weeks > 0 then
        local wfrom, wto = weeks[#weeks], addDays(weeks[1], 6)
        if wfrom < from_date then from_date = wfrom end
        if wto > to_date then to_date = wto end
    end
    local stats = Data.getDailyStatsInRange(from_date, to_date)
    local title_str = (which == "best") and _("Best streak") or _("Current streak")

    -- "123 days | <range>" and "17 weeks | <range>": the summary row of the
    -- daily and of the weekly views.
    local n_days  = streaks[prefix .. "_days"]  or #days
    local n_weeks = streaks[prefix .. "_weeks"] or #weeks
    local infos = {
        day  = { value = formatCount(n_days),  unit = N_("day",  "days",  n_days),
                 range = streakRangeText(dates, "days") },
        week = { value = formatCount(n_weeks), unit = N_("week", "weeks", n_weeks),
                 range = streakRangeText(week_dates, "weeks") },
    }

    showHistoryPopup(title_str, days, weeks, stats, infos)
end

-- KOReader's statistics plugin (its getBookStat() builds the per-book stats
-- page a tapped list row opens). This popup isn't handed a ui, so look the
-- plugin up on the live ReaderUI (inside a book) or FileManager (file browser).
-- nil if neither has it; rows then simply aren't tappable.
local function findStatsPlugin()
    for _, mod in ipairs({ "apps/reader/readerui", "apps/filemanager/filemanager" }) do
        local ok, M = pcall(require, mod)
        local inst = ok and M and M.instance
        if inst and inst.statistics and inst.statistics.getBookStat then
            return inst.statistics
        end
    end
    return nil
end

-- Tapping a day in the calendar: the books read on that day with the time
-- spent on each, in the same list the insights page uses for a month/year
-- ("2026. 03. 12: 2 books read (7:20:31)"). A day with no reading at all
-- gets a notice instead.
local function showDayBooks(date_str)
    local date_label = formatDateForDisplay(date_str)
    local books = Data.getBooksForPeriod("%Y-%m-%d", date_str) or {}
    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No reading on %1"), date_label),
        })
        return
    end
    -- "2026. 03. 12." -> "2026. 03. 12" so the title reads "2026. 03. 12: 2 ..."
    -- (the dot would otherwise sit right in front of the colon).
    local title_date = (date_label:gsub("%.$", ""))
    local title = T(N_("%1 - %2 book", "%1 - %2 books", #books),
            title_date, formatCount(#books))
        .. " (" .. Locale.formatDuration(Data.sumDuration(books), false) .. ")"
    -- The streak popup (and the insights popup under it) are modal, and
    -- KOReader's UIManager keeps modal widgets above non-modal ones, so the
    -- list is shown modal too (opts.modal) to land on top. The popups stay
    -- open underneath untouched; closing the list simply reveals them again.
    BookList.showBookList(title, books, nil, findStatsPlugin(), { modal = true })
end

-- The streaks popup itself: a full-screen modal laying out (top to bottom) one
-- pageable calendar month - each day with its number, the cover of the book
-- read most that day and the streak line - then current and best streak
-- side by side (name, date range, days | weeks). The calendar pages one month
-- at a time (‹ / › arrows, swipe, or Left/Right keys); any other tap/swipe/key
-- dismisses the popup. All the display data is precomputed by showStreaksPopup
-- and stashed on the instance, so paging only re-lays-out the (cheap) widgets,
-- never re-queries the database.
local StreakDatePopup = InputContainer:extend{
    modal = true,
}

function StreakDatePopup:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
        self.ges_events.Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self.month_index = self.month_index or 1
    self._defer_disk = self.lazy_covers and true or false   -- first paint only (see onShow)
    self:_rebuild()
end

function StreakDatePopup:_centeredRect(widget)
    local size = widget:getSize()
    return Geom:new{
        x = self.dimen.x + math.floor((self.dimen.w - size.w) / 2),
        y = self.dimen.y + math.floor((self.dimen.h - size.h) / 2),
        w = size.w, h = size.h,
    }
end

-- The file of a book of the statistics DB (by checksum, else guessed from its
-- title / author - fine for a cover), nil when unknown. Remembered per popup.
function StreakDatePopup:_fileOf(book)
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

-- The cover of a book scaled to fit w x h (aspect kept), nil when the book has
-- no readable cover. Opening a book to read its cover is slow, so each result
-- (also a "no cover" one) is kept in COVER_CACHE across popups.
-- With `cached_only` a cover that is not in the cache yet is not loaded:
-- COVER_PENDING is returned and the cover is queued for _loadPending().
function StreakDatePopup:_coverFor(book, w, h, cached_only)
    local key = tostring(book.md5 or book.id_book) .. "|" .. w .. "x" .. h
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

    -- On disk: quick (a small picture), so it is also done for the first paint.
    local base = diskBase(book)
    if base then
        if lfs.attributes(base .. ".none", "mode") == "file" then
            return remember(nil)
        end
        -- The first paint of a lazy popup leaves the thumbnails to
        -- _loadPending(), so the window shows up at once after a restart.
        local thumb = not (cached_only and self._defer_disk) and readThumb(base) or nil
        if thumb then
            local ok, res = pcall(scaleTo, thumb, w, h)
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
            local ok2, res = pcall(function()
                local thumb = scaleTo(raw, THUMB_W, THUMB_H, true)   -- frees raw
                if base then writeThumb(base, thumb) end
                return scaleTo(thumb, w, h)                          -- frees thumb
            end)
            if ok2 and res then
                scaled = res
            else
                pcall(function() raw:free() end)
            end
        elseif ok and base and lfs.attributes(file, "mode") == "file" then
            -- The book is there but has no cover: remember that.
            markNoCover(base)
        end
    end
    return remember(scaled)
end

-- Loads the covers the first paint had to leave out, one book per UI tick (so
-- the popup stays usable), then rebuilds and repaints once.
function StreakDatePopup:_loadPending()
    self._pending_task = nil
    if self._closed then return end
    local order = self._pending_order
    if not order or #order == 0 then return end
    local key = table.remove(order, 1)
    local item = self._pending and self._pending[key]
    if self._pending then self._pending[key] = nil end
    if item then pcall(self._coverFor, self, item.book, item.w, item.h) end
    if #order > 0 then
        self._pending_task = function() self:_loadPending() end
        UIManager:scheduleIn(0.01, self._pending_task)
    else
        self._pending, self._pending_order = nil, nil
        self:_rebuild()
        UIManager:setDirty(self, function() return "ui", self.dimen end)
        -- Anything the rebuild still found missing is loaded the same way.
        self:_schedulePending()
    end
end

function StreakDatePopup:_schedulePending()
    if self._pending_task then
        UIManager:unschedule(self._pending_task)
        self._pending_task = nil
    end
    if self._pending_order and #self._pending_order > 0 then
        self._pending_task = function() self:_loadPending() end
        UIManager:scheduleIn(0.05, self._pending_task)
    end
end

function StreakDatePopup:_freeCovers()
    -- Nothing to free: covers live in COVER_CACHE for the next opening.
    self._closed = true
    if self._pending_task then
        UIManager:unschedule(self._pending_task)
        self._pending_task = nil
    end
    self._pending, self._pending_order = nil, nil
end

function StreakDatePopup:_rebuild()
    local fonts  = self.fonts
    local layout = self.layout
    local col_w  = self.col_width
    local cont_w = self.content_width
    local inner_padding = self.inner_padding
    local screen_w, screen_h = self.dimen.w, self.dimen.h
    -- Covers not loaded yet are collected again by this build.
    self._pending, self._pending_order = nil, nil

    -- Title bar like the Reading insights window's: the title on the left,
    -- an X to close on the right, and a line under it. The calendar and the
    -- streak section live in the screen below it.
    local title_bar = TitleBar:new{
        fullscreen       = true,
        width            = screen_w,
        align            = "left",
        title            = _("Reading calendar"),
        -- No X on the sleep screen (opts.readonly), as in the Reading
        -- insights window: there is nothing to close by tapping it.
        close_callback   = (not self.readonly) and function() UIManager:close(self) end or nil,
        show_parent      = self,
        top_v_padding    = Size.padding.default,
        bottom_v_padding = Size.padding.default,
    }
    local title_sep = UI.padded(inner_padding,
        Colors.newBar(screen_w - 2 * inner_padding, Size.line.thick, Colors.separator()))
    local top_h = title_bar:getSize().h + title_sep:getSize().h
    self._top_h = top_h
    -- The page's bottom edge: the streak section sits right on it (just this
    -- much air under it), the calendar above takes the space that is left.
    local bottom_pad = Size.padding.default

    -- Everything below the calendar is built first, so its height is known
    -- and the calendar's day cells can take all the rest of the screen:
    --   the most recent reading day (left-aligned), the divider line, then the
    --   current / best streak section.
    local tail = {}
    -- (The "Last read: <date>" line used to sit here; it is gone so the
    -- calendar above gets its height - larger covers.)
    table.insert(tail, Colors.newBar(cont_w, Size.padding.large, Blitbuffer.COLOR_WHITE))
    table.insert(tail, Colors.newBar(cont_w, Size.line.thick, Colors.separator()))
    -- (No separate gap here: the standard section header below carries its
    -- own small padding above and below its text, like in every other view.)

    -- Current and best streak side by side.
    --   [ Current streak | Best streak ]   section headers
    --   ---------------------------------   thin divider
    --   [ days | weeks   | days | weeks ]
    -- The days|weeks value line (fonts.value) sets the height (row_h) of the
    -- value row, so both streaks' cells are the same height.
    local inner_gap = math.floor(layout.column_gap / 2)
    local half_col  = math.floor((col_w - inner_gap) / 2)
    local row_h = buildValueLine(fonts.value, fonts.label, half_col, "0", N_("day", "days", 0)):getSize().h

    -- The shared section header (UI.buildSectionHeader), exactly as on the
    -- Reading insights page and the Book progress popup.
    local cur_hdr  = UI.buildSectionHeader(fonts.section, _("Current streak"), col_w, 0, Colors.headerBg())
    local best_hdr = UI.buildSectionHeader(fonts.section, _("Best streak"),    col_w, 0, Colors.headerBg())
    -- Everything from here through the days|weeks row is the tappable
    -- "Current streak" / "Best streak" section (see the streak_zones block
    -- below): remembering where it starts lets that block measure its
    -- on-screen height without hardcoding every row/spacer size twice.
    local tail_streak_start = #tail + 1
    table.insert(tail, UI.buildTwoColRow(cur_hdr, best_hdr, layout))
    table.insert(tail, VerticalSpan:new{ width = Size.padding.small })
    table.insert(tail, Colors.newBar(cont_w, Size.line.thin, Colors.separator()))
    table.insert(tail, VerticalSpan:new{ width = Size.padding.small })

    -- Stats row: each streak's column split into days | weeks, at row_h.
    local function daysWeeksCell(days, weeks)
        local dline = buildValueLine(fonts.value, fonts.label, half_col, formatCount(days),  N_("day",  "days",  days))
        local wline = buildValueLine(fonts.value, fonts.label, half_col, formatCount(weeks), N_("week", "weeks", weeks))
        return HorizontalGroup:new{
            align = "center",
            UI.fixedCol(dline, half_col, row_h),
            UI.buildColumnSeparator(inner_gap, row_h),
            UI.fixedCol(wline, half_col, row_h),
        }
    end
    table.insert(tail, UI.buildTwoColRow(
        daysWeeksCell(self.cur_days,  self.cur_weeks),
        daysWeeksCell(self.best_days, self.best_weeks),
        layout))
    local tail_streak_end = #tail
    local tail_h = 0
    for _i, w in ipairs(tail) do tail_h = tail_h + w:getSize().h end

    local content = VerticalGroup:new{ align = "left" }

    -- Calendar page on top: one month with the days' covers and streak lines,
    -- and a ‹ / › paging header. Its arrow tap zones are placed from the
    -- header's on-screen position below; since the calendar is the first thing
    -- in the box, that header sits right under the box padding.
    self._nav_zones = {}
    self._day_zones = {}
    self._grid_meta = nil
    self._left_w, self._right_w, self._header_h = nil, nil, 0
    if self.months and #self.months > 0 then
        local show_week = showWeekNumbers()
        local week_col_w, week_prefix_w = weekColumnMetrics(show_week, fonts.small)
        local cell_w = math.floor((cont_w - week_prefix_w) / 7)
        local mo   = self.months[self.month_index]
        local title_str = Locale.formatMonthYear(mo.year, mo.month)
        local prev_available = self.month_index > 1
        -- Not closed at the end: the calendar pages on into the future
        -- (months are added as needed, see _goToMonth), up to the last year
        -- 32-bit os.time() can handle.
        local next_available = self.month_index < #self.months
            or mo.year < LAST_CALENDAR_YEAR or mo.month < 12
        local header, left_w, right_w, header_h =
            buildStreakCalHeader(title_str, cont_w, fonts.section, prev_available, next_available)

        -- The day cells take the screen height that is left: all of it minus
        -- the paddings, the month header, the weekday row, the gaps between
        -- the six week rows and the streak section below. Never more than
        -- four times as tall as wide, never so small that a cover cannot be told.
        local row_gap = Screen:scaleBySize(6)
        local weekday_h = TextWidget:new{ text = _(STREAK_WEEKDAY_SHORT[1]), face = fonts.small }:getSize().h
            + Size.padding.small
        local avail = screen_h - top_h - inner_padding - bottom_pad - header_h - Size.padding.default
            - weekday_h - 5 * row_gap - tail_h - Screen:scaleBySize(4)
        local cell_h = math.floor(avail / 6)
        cell_h = math.min(cell_h, cell_w * 4)   -- only a sanity cap: the cells take the whole free height
        cell_h = math.max(cell_h, Screen:scaleBySize(22))

        local grid, grid_meta = buildStreakMonthGrid(mo.year, mo.month, self.read_set,
            fonts, cell_w, cell_h, self.week_start_wd, show_week, week_col_w,
            self.day_books, function(book, w, h) return self:_coverFor(book, w, h, self.lazy_covers) end,
            showStreakBar())
        grid_meta.header_h = header_h
        grid_meta.drawn_w  = grid:getSize().w
        self._grid_meta = grid_meta

        table.insert(content, header)
        table.insert(content, VerticalSpan:new{ width = Size.padding.small })
        -- Center the day grid (a few px narrower than cont_w after rounding)
        -- under the full-width header.
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = cont_w, h = grid:getSize().h }, grid,
        })
        self._header_h = header_h
        self._left_w   = prev_available and left_w or nil
        self._right_w  = next_available and right_w or nil
        -- The arrows keep their width when hidden, so the title between them
        -- is always the same stretch of the header (its tap zone, below).
        self._hdr_left_w, self._hdr_right_w = left_w, right_w
    end

    -- Whatever height the day cells could not use (they are capped, and
    -- rounded down) goes into a white gap between the calendar and the
    -- streak section, so that section ends at the bottom of the screen.
    local head_n = #content
    local head_h = 0
    for i = 1, head_n do head_h = head_h + content[i]:getSize().h end
    local gap_h = math.max(1, screen_h - top_h - inner_padding - bottom_pad - head_h - tail_h)
    table.insert(content, Colors.newBar(cont_w, gap_h, Blitbuffer.COLOR_WHITE))
    head_n = head_n + 1
    for _i, w in ipairs(tail) do table.insert(content, w) end
    local streak_section_start_idx = head_n + tail_streak_start
    local streak_section_end_idx   = head_n + tail_streak_end

    -- Full-screen white page, the padded content centred on it.
    self.box_content = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = 0,
        radius         = 0,
        margin         = 0,
        padding_top    = inner_padding,
        padding_bottom = bottom_pad,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        Colors.newBar(screen_w, screen_h, Blitbuffer.COLOR_WHITE),
        VerticalGroup:new{
            align = "left",
            title_bar,
            title_sep,
            CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = screen_h - top_h },
                self.box_content,
            },
        },
    }

    -- Absolute tap zones for the ‹ / › arrows, computed from geometry (same
    -- approach as the Book progress calendar's header).
    -- The box is centred in the screen below the title bar.
    local box_size = self.box_content:getSize()
    local box_rect = Geom:new{
        x = math.floor((screen_w - box_size.w) / 2),
        y = top_h + math.floor((screen_h - top_h - box_size.h) / 2),
        w = box_size.w, h = box_size.h,
    }
    local header_x = box_rect.x + inner_padding
    local header_y = box_rect.y + inner_padding
    local tap_pad  = Screen:scaleBySize(14)
    -- Tapping the month title jumps to the current month.
    if self._hdr_left_w and self._hdr_right_w then
        table.insert(self._nav_zones, {
            dimen = Geom:new{ x = header_x + self._hdr_left_w + tap_pad, y = header_y - tap_pad,
                w = cont_w - self._hdr_left_w - self._hdr_right_w - 2 * tap_pad,
                h = self._header_h + 2 * tap_pad },
            today = true,
        })
    end
    if self._left_w then
        table.insert(self._nav_zones, {
            dimen = Geom:new{ x = header_x - tap_pad, y = header_y - tap_pad,
                w = self._left_w + 2 * tap_pad, h = self._header_h + 2 * tap_pad },
            delta = -1,
        })
    end
    if self._right_w then
        table.insert(self._nav_zones, {
            dimen = Geom:new{ x = header_x + cont_w - self._right_w - tap_pad, y = header_y - tap_pad,
                w = self._right_w + 2 * tap_pad, h = self._header_h + 2 * tap_pad },
            delta = 1,
        })
    end

    -- One tap zone per day cell of the calendar (6 week rows x 7 columns).
    -- Position: the grid is centered under the header, which is followed by
    -- Size.padding.default; inside the grid the weekday header row and the
    -- first week row follow (day_meta.top), then each further row sits
    -- day_meta.row_pitch lower. Tapping a day opens that day's book list.
    local gm = self._grid_meta
    if gm then
        local grid_x = header_x + math.floor((cont_w - gm.drawn_w) / 2)
        local grid_y = header_y + gm.header_h + Size.padding.default + gm.top
        for r = 0, 5 do
            for c = 0, 6 do
                local date = gm.dates[r + 1] and gm.dates[r + 1][c + 1]
                if date then
                    table.insert(self._day_zones, {
                        dimen = Geom:new{
                            x = grid_x + gm.week_prefix_w + c * gm.cell_w,
                            y = grid_y + r * gm.row_pitch,
                            w = gm.cell_w, h = gm.cell_h,
                        },
                        date = date,
                    })
                end
            end
        end
    end

    -- Tap zones for the "Current streak" / "Best streak" columns themselves
    -- - tapping either opens that streak's per-day history popup (see
    -- StreakDatePopup:onTap below). Measured from the actual laid-out
    -- widgets rather than a second copy of every row/spacer height, so this
    -- can't silently drift out of sync with the section it covers.
    local function sumHeights(list, from_idx, to_idx)
        local h = 0
        for i = from_idx, to_idx do h = h + list[i]:getSize().h end
        return h
    end
    local section_y = header_y + sumHeights(content, 1, streak_section_start_idx - 1)
    local section_h = sumHeights(content, streak_section_start_idx, streak_section_end_idx)
    self._streak_zones = {
        { dimen = Geom:new{ x = header_x, y = section_y, w = col_w, h = section_h }, which = "current" },
        { dimen = Geom:new{ x = header_x + cont_w - col_w, y = section_y, w = col_w, h = section_h }, which = "best" },
    }
end

function StreakDatePopup:_goToMonth(delta)
    local n = self.months and #self.months or 0
    if n == 0 then return true end
    local idx = self.month_index + delta
    if idx < 1 then return true end
    -- Past the last month with data: add the following months on the fly.
    while idx > #self.months do
        local last = self.months[#self.months]
        local y, m = last.year, last.month + 1
        if m > 12 then m = 1; y = y + 1 end
        if y > LAST_CALENDAR_YEAR then return true end
        table.insert(self.months, { year = y, month = m })
    end
    self.month_index = idx
    self:_rebuild()
    -- The popup is full screen, so a page change repaints all of it.
    UIManager:setDirty("all", function() return "ui", self.dimen end)
    self:_schedulePending()
    return true
end

-- Jumps to the page of the current calendar month.
function StreakDatePopup:_goToToday()
    local year, month = tonumber(os.date("%Y")), tonumber(os.date("%m"))
    for i, mo in ipairs(self.months or {}) do
        if mo.year == year and mo.month == month then
            if i == self.month_index then return true end
            return self:_goToMonth(i - self.month_index)
        end
    end
    return true
end

function StreakDatePopup:onTap(arg, ges_ev)
    if ges_ev then
        local x, y = ges_ev.pos.x, ges_ev.pos.y
        -- Title bar: only the X (right end) closes; the title itself does nothing.
        if self._top_h and y < self._top_h then
            if x > self.dimen.w - 2 * self._top_h then
                UIManager:close(self)
            end
            return true
        end
        for _, zone in ipairs(self._nav_zones or {}) do
            local d = zone.dimen
            if x >= d.x and x <= d.x + d.w and y >= d.y and y <= d.y + d.h then
                if zone.today then return self:_goToToday() end
                return self:_goToMonth(zone.delta)
            end
        end
        for _, zone in ipairs(self._streak_zones or {}) do
            local d = zone.dimen
            if x >= d.x and x <= d.x + d.w and y >= d.y and y <= d.y + d.h then
                showStreakHistory(self.streaks, zone.which)
                return true
            end
        end
        for _, zone in ipairs(self._day_zones or {}) do
            local d = zone.dimen
            if x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h then
                showDayBooks(zone.date)
                return true
            end
        end
    end
    UIManager:close(self)
    return true
end

-- Long press on the title ("Reading calendar"): drop the cover cache and
-- load every cover again. A long press anywhere else does nothing.
function StreakDatePopup:onHold(arg, ges_ev)
    local pos = ges_ev and ges_ev.pos
    if not (pos and self._top_h and pos.y < self._top_h
            and pos.x <= self.dimen.w - 2 * self._top_h) then
        return true
    end
    clearCoverCache()
    self._file_cache = nil
    self._pending, self._pending_order = nil, nil
    self:_rebuild()
    UIManager:setDirty("all", function() return "ui", self.dimen end)
    self:_schedulePending()
    return true
end

function StreakDatePopup:onSwipe(arg, ges_ev)
    if not ges_ev then UIManager:close(self) return true end
    local dir = ges_ev.direction
    if dir == "west" or dir == "left"  then return self:_goToMonth(1)  end
    if dir == "east" or dir == "right" then return self:_goToMonth(-1) end
    UIManager:close(self)
    return true
end

function StreakDatePopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:_goToMonth(1)  end
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:_goToMonth(-1) end
    UIManager:close(self)
    return true
end

function StreakDatePopup:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self._defer_disk = false   -- the first paint is done: later pages read the disk as before
    self:_schedulePending()
    return true
end

function StreakDatePopup:onCloseWidget()
    self:_freeCovers()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

-- The combined streak popup: current and best streak side by side, above a
-- calendar of your reading with the streaks marked. Opened by tapping any of
-- the streak cells on the insights page, and from the menu - always the same
-- popup. `streaks` is the table from Data.calculateStreaks().
local function showStreaksPopup(streaks, opts)
    streaks = streaks or {}
    -- opts.sync: load every cover before the first paint (the sleep screen is
    -- painted once, right before the device sleeps - nothing may arrive later).
    -- opts.readonly: sleep-screen use - the title bar has no close X.
    opts = opts or {}
    local fonts = getCachedFonts()
    local inner_padding = Size.padding.large
    local column_gap = Size.padding.large
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Full screen: the box is as wide as the screen (the day cells need every
    -- pixel for the covers).
    local box_width = screen_w
    local layout = UI.buildLayout(box_width - 2 * inner_padding, 0, column_gap)
    local col_width = layout.col_width
    local content_width = layout.content_width

    -- The most recent reading day overall, shown once under the calendar
    -- ("-" when nothing has been read yet).
    local last_read = streaks.last_read_date
        or (streaks.current_days_dates and streaks.current_days_dates.end_)
    if not last_read then
        local max_t = Data.getMaxStartTime()
        if max_t and max_t > 0 then last_read = os.date("%Y-%m-%d", max_t) end
    end
    local last_read_str = T(_("Last read: %1"),
        last_read and formatDateForDisplay(last_read) or "\xE2\x80\x93")

    -- Calendar span: from the month of the very first reading record up to
    -- today, so the whole history pages through with its reading marked. The
    -- read set covers the whole shown span. Falls back to the earliest streak
    -- start (or today) if the first-reading month can't be read.
    -- The result is cached (DATA_CACHE) until a new reading record shows up.
    local today     = os.date("%Y-%m-%d")
    local watermark = Data.getMaxStartTime() or 0
    local cached = DATA_CACHE
    local months, read_set, day_books
    if cached and cached.today == today and cached.watermark == watermark then
        months, read_set, day_books = cached.months, cached.read_set, cached.day_books
    else
        local range_end = today
        local yr = Data.getYearRange()
        local list_start = (yr and yr.min_year)
            and string.format("%04d-%02d-01", yr.min_year, yr.min_month or 1)
            or nil
        if not list_start then
            local starts = {}
            if streaks.current_days_dates and streaks.current_days_dates.start then
                starts[#starts + 1] = streaks.current_days_dates.start
            end
            if streaks.best_days_dates and streaks.best_days_dates.start then
                starts[#starts + 1] = streaks.best_days_dates.start
            end
            table.sort(starts)
            list_start = starts[1] or today
        end
        if list_start > range_end then list_start = range_end end

        months = streakMonthList(list_start, range_end)
        -- The books read on each day (most read first), for the covers in the
        -- day cells: one query for the whole span, so paging never asks again.
        day_books = months and (Data.getDayBooksInRange(list_start, range_end) or {}) or {}
        -- A day has reading exactly when it has a book: no second scan of the
        -- statistics table needed for the "days read" set.
        read_set = {}
        for d in pairs(day_books) do read_set[d] = true end
        DATA_CACHE = { today = today, watermark = watermark,
                       months = months, read_set = read_set, day_books = day_books }
    end
    local week_start_wd = (Prefs and Prefs.weekStartWday and Prefs.weekStartWday()) or 1

    local popup_months
    if months then
        popup_months = {}
        for i, mo in ipairs(months) do popup_months[i] = mo end
    end

    local popup = StreakDatePopup:new{
        fonts         = fonts,
        layout        = layout,
        col_width     = col_width,
        content_width = content_width,
        inner_padding = inner_padding,

        streaks       = streaks,
        last_read_str = last_read_str,
        cur_days      = streaks.current_days  or 0,
        cur_weeks     = streaks.current_weeks or 0,
        best_days     = streaks.best_days     or 0,
        best_weeks    = streaks.best_weeks    or 0,

        read_set      = read_set,
        day_books     = day_books,
        -- A copy: the popup appends future months to it, the cached list
        -- must stay as it is.
        months        = popup_months,
        week_start_wd = week_start_wd,
        month_index   = months and #months or 1,
        lazy_covers   = not opts.sync,
        readonly      = opts.readonly or false,
    }

    UIManager:show(popup)
    return popup
end


-- Module export.
--   show(streaks)          the combined current/best streak calendar popup,
--                          used both from the menu and (previously) from the
--                          insights page's streak cells.
--   showHistory(streaks, which)
--                          the pageable per-day bar-list popup for one whole
--                          streak ("current" or "best") - what the streak
--                          cells on the insights page open now.
return {
    show        = showStreaksPopup,   -- show(streaks, { sync = true, readonly = true } for the sleep screen)
    showHistory = showStreakHistory,
}
