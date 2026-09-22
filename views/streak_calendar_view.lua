--[[
Reading streak calendar - the combined streak popup.

Current and best streak shown side by side, above a pageable full-history
calendar of your reading with the daily/weekly streaks marked. Extracted from
insights_view.lua so that file stays focused on the main insights page; this
same popup is opened from there (tapping any streak cell) and straight from the
Tools menu, both via M.show(streaks) with the table from
Data.calculateStreaks().

Calendar cell shading (see buildStreakMonthGrid):
  - a day with reading            daily-streak fill (Colors.streakRead)
  - another day in a week that
    had any reading                weekly-streak gap fill (Colors.streakGap)
  - a day in a week with no
    reading at all                 white

Gestures on the popup:
  - Tap a ‹ / › arrow, swipe left/right, or Left/Right keys   page one month
  - Any other tap / swipe / key                                close

All display data is precomputed by M.show and stashed on the StreakDatePopup
instance, so paging only re-lays-out the (cheap) widgets - it never re-queries
the database.
]]--

local Blitbuffer = require("ffi/blitbuffer")
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
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local InfoMessage = require("ui/widget/infomessage")

-- Shared modules, passed in as one named table by main.lua (see there). Same
-- Locale/Colors/Fonts/UI/Data/Prefs the insights view uses, so this popup
-- reads the same colors, fonts and reading data.
local deps = ...
local Locale, Colors, Fonts, UI, Data, Prefs, VS =
    deps.Locale, deps.Colors, deps.Fonts, deps.UI, deps.Data, deps.Prefs, deps.VS

local _            = Locale._
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase
local formatCount  = Locale.formatCount

-- Format a YYYY-MM-DD string in the configured date format (Settings ▸
-- Advanced settings ▸ Date & time ▸ "Date format" - see Locale.formatDate).
-- no_trailing_dot: the "2026.07.20." pattern only - omit the final dot (used
-- for the first date in a range).
local function formatDateForDisplay(date_str, no_trailing_dot)
    if not date_str then return "?" end
    return Locale.formatDate(date_str, no_trailing_dot)
end

local MONTH_NAMES_FULL = {
    _("January"), _("February"), _("March"), _("April"), _("May "), _("June"),
    _("July"), _("August"), _("September"), _("October"), _("November"), _("December"),
}
-- Hungarian month title needs "2026. augusztus" (year, dot, lowercase month),
-- not the "August 2026" pattern MONTH_NAMES_FULL gives elsewhere - mirrors
-- MONTH_FULL_HU_LC in book_calendar_view.lua so both calendars' headers read
-- the same way in Hungarian.
local MONTH_NAMES_FULL_HU_LC = {
    "január", "február", "március", "április", "május", "június",
    "július", "augusztus", "szeptember", "október", "november", "december",
}

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

-- A bold "value" + plain "unit" line (e.g. "7" + "days"), laid out to fit
-- col_width. Mirrors buildValueLine in insights_view.lua so the streak stats
-- line up with the ones on the insights page.
local function buildValueLine(font_value, font_label, col_width, value, unit)
    if value == "" then
        return TextBoxWidget:new{
            text      = unit,
            face      = font_label,
            fgcolor   = Colors.label(),
            width     = col_width,
            alignment = "left",
        }
    end

    local value_widget = TextWidget:new{ text = value, face = font_value, fgcolor = Colors.value() }
    local value_width = value_widget:getSize().w
    local text_desc_width = col_width - value_width - Size.padding.large
    return HorizontalGroup:new{
        align = "center",
        value_widget,
        HorizontalSpan:new{ width = Size.padding.large },
        TextBoxWidget:new{
            text      = unit,
            face      = font_label,
            fgcolor   = Colors.label(),
            width     = text_desc_width,
            alignment = "left",
        },
    }
end

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
    local days_in_month = tonumber(os.date("%d", os.time{ year = year, month = month + 1, day = 0, hour = 12 }))
    return days_in_month, lead_blanks
end

-- Relative luminance (0..255) of a "#RRGGBB" hex string.
local function hexLuminance(hex)
    local n = tostring(hex):gsub("#", "")
    local r = tonumber(n:sub(1, 2), 16) or 0
    local g = tonumber(n:sub(3, 4), 16) or 0
    local b = tonumber(n:sub(5, 6), 16) or 0
    return 0.299 * r + 0.587 * g + 0.114 * b
end

-- Day-number color that stays legible on a given cell fill: white on a dark
-- fill, black on a light one. Keeps the number readable on the dark read-day
-- cell without needing a separate color setting.
local function streakNumColor(fill_hex)
    return (hexLuminance(fill_hex) < 128) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
end

-- Whether to show week numbers (Prefs ▸ Advanced settings ▸ Date & time ▸
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
local WEEK_COL_SIDE_PAD = Screen:scaleBySize(4)
local function weekColumnMetrics(show_week, small_font)
    if not show_week then return 0, 0 end
    local label_w = TextWidget:new{ text = _("Week"), face = small_font }:getSize().w
    local col_w = label_w + 2 * WEEK_COL_SIDE_PAD
    local prefix_w = col_w + WEEK_COL_SIDE_PAD + Size.line.thin + WEEK_COL_SIDE_PAD
    return col_w, prefix_w
end

-- One month's grid of day cells for the streak-date popup calendar (weekday
-- header row + week rows; the month/year title lives in the paging header
-- built separately - see buildStreakCalHeader/StreakDatePopup below).
--   read_set: { ["YYYY-MM-DD"] = true } days that had reading during the streak.
--     A day in read_set is drawn as a daily-streak cell (Colors.streakRead).
--     Any OTHER day that shares its calendar week (row) with a read day is
--     drawn as a weekly-streak gap cell (Colors.streakGap) - once a week has
--     any reading its weekly streak is secured, so the rest of that week is
--     shaded to show it. Days in a week with no reading at all stay white. The
--     day number is drawn on each cell in a color chosen for legibility (see
--     streakNumColor), gray for adjacent-month days, bold on today.
--   cell, week_start_wd: shared sizing/layout computed once by the caller.
--     Day squares (side `cell`) sit flush horizontally - no gap between the
--     consecutive days of a week - while a small `row_gap` separates the week
--     rows, so each week reads as one solid strip.
local function buildStreakMonthGrid(year, month, read_set, fonts, cell, week_start_wd, show_week, week_col_w)
    local today_str = os.date("%Y-%m-%d")
    -- Day-number face matches the Book progress calendar's day cells
    -- (Fonts.getFace("stats_label")/getBoldFace) rather than this popup's
    -- own "insights_small" - the two calendars are meant to look alike.
    local day_font  = Fonts.getFace("stats_label")
    local bold_face = Fonts.getBoldFace("stats_label")
    -- Clear white band between week rows (days within a week stay flush). Drawn
    -- as an explicit full-width white bar rather than a zero-width VerticalSpan:
    -- a zero-width child gets dropped from this centered VerticalGroup's height,
    -- which both swallowed the row gap and left the grid under-reporting its
    -- size (so the divider below it crept up over the calendar).
    local week_prefix_w = show_week and (week_col_w + 2 * WEEK_COL_SIDE_PAD + Size.line.thin) or 0
    local grid_w  = week_prefix_w + 7 * cell
    local row_gap = Screen:scaleBySize(6)
    local grid = VerticalGroup:new{ align = "center" }

    -- The optional "Week" column prefix: a gray label/number cell, then a
    -- thin gray separator line, then a bit of breathing room either side -
    -- built fresh for each row (header or day row) at the given height, so
    -- the separator only ever spans one row at a time (the white row_gap
    -- bars between weeks already provide a natural break in the line).
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
            dimen = Geom:new{ w = cell, h = label_w:getSize().h }, label_w,
        })
    end
    table.insert(grid, header_row)
    table.insert(grid, Colors.newBar(grid_w, Size.padding.small, Blitbuffer.COLOR_WHITE))

    local days_in_month, lead_blanks = streakMonthShape(year, month, week_start_wd)

    -- The real "YYYY-MM-DD" date for a cell offset from this month's day 1.
    -- cell_day < 1 lands in the previous month, > days_in_month in the next;
    -- os.time normalises both (and year rollover) for us.
    local function cellDate(cell_day)
        return os.date("%Y-%m-%d",
            os.time{ year = year, month = month, day = cell_day, hour = 12 })
    end

    -- Fixed six-week grid: always 6 rows starting from the first day's row, so
    -- every month is the same height. Leading cells show the previous month's
    -- tail, trailing cells the next month's start. Days of the shown month get a
    -- legible day number (even future / not-yet-read ones); the adjacent months'
    -- days get a gray number so they read as faint context only.
    local start_cell_day = 1 - lead_blanks
    for r = 0, 5 do
        if r > 0 then
            table.insert(grid, Colors.newBar(grid_w, row_gap, Blitbuffer.COLOR_WHITE))
        end
        local base = start_cell_day + r * 7

        -- Did this calendar week (row) have any reading? If so, its remaining
        -- days are shaded as weekly-streak gap days. Checked across the row's
        -- real dates, so a read day in an adjacent month still counts.
        local week_has_read = false
        for col = 0, 6 do
            if read_set[cellDate(base + col)] then
                week_has_read = true
                break
            end
        end

        local row = HorizontalGroup:new{}
        if show_week then
            -- ISO week number of the row's first (leftmost) column, whatever
            -- the configured week-start day - a row is one calendar week
            -- either way, so it has exactly one ISO week number.
            local row_date = cellDate(base)
            local ry = tonumber(row_date:sub(1, 4))
            local rm = tonumber(row_date:sub(6, 7))
            local rd = tonumber(row_date:sub(9, 10))
            table.insert(row, weekPrefix(tostring(Locale.isoWeekNumber(ry, rm, rd)), cell))
        end
        for col = 0, 6 do
            local cell_day = base + col
            local day_str  = cellDate(cell_day)
            local is_this_month = (cell_day >= 1 and cell_day <= days_in_month)
            -- Read day -> daily-streak fill; other day in a week with reading ->
            -- weekly-streak gap fill; everything else -> white.
            local fill_color, fill_hex
            if read_set[day_str] then
                fill_color, fill_hex = Colors.streakRead(), Colors.getHex("streak_read")
            elseif week_has_read then
                fill_color, fill_hex = Colors.streakGap(), Colors.getHex("streak_gap")
            else
                fill_color, fill_hex = Blitbuffer.COLOR_WHITE, "#FFFFFF"
            end
            -- Shown-month days keep a legible (auto-contrast) number; the
            -- previous/next month's days are drawn gray as context only.
            local num_color = is_this_month and streakNumColor(fill_hex) or Blitbuffer.COLOR_GRAY
            local num_w = TextWidget:new{
                text = tostring(tonumber(day_str:sub(9, 10))),
                face = (day_str == today_str) and bold_face or day_font,
                fgcolor = num_color,
            }
            table.insert(row, OverlapGroup:new{
                dimen = Geom:new{ w = cell, h = cell },
                Colors.newBar(cell, cell, fill_color),
                CenterContainer:new{ dimen = Geom:new{ w = cell, h = cell }, num_w },
            })
        end
        table.insert(grid, row)
    end

    return grid
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
    return header_row, left_widget:getSize().w, right_widget:getSize().w, header_row:getSize().h
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

-- How many day-rows one page of the streak history popup shows. Paging
-- (arrows / swipe / keys) moves between pages instead of scrolling, so a
-- streak of any length only ever builds this many row widgets at a time.
local STREAK_HISTORY_PAGE_SIZE = 21

--[[
The streak history popup: one bar per day of a streak's date range, each row
"date | bar | value". Pageable (STREAK_HISTORY_PAGE_SIZE rows per page)
rather than scrollable, so a months-long streak is browsed a page at a time
instead of building/scrolling hundreds of rows - mirrors StreakDatePopup's
month paging above (‹ / › arrows, swipe, or Left/Right keys page; any other
tap/swipe/key closes). It always opens on page 1 - the newest end of the
streak. Below the section
title ("Current streak" / "Best streak") a second row shows the date range
the current page covers. The value column (time or pages) is a single tap
zone spanning every row, so tapping any row's value on the right retoggles
the whole list between the two metrics and re-lays-out in place - that tap
zone is checked before the nav zones so it keeps working across every page.

All display data (the full day list, its seconds/pages, and the running max
across the *whole* streak - not just the visible page, so a bar's fill stays
meaningful whichever page you're looking at) is precomputed once by
M.showHistory and stashed on the instance; paging and toggling the metric
only re-lays-out the (cheap) widgets for the current page - neither ever
re-queries the database.
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
    self.metric = self.metric or "time"
    self.page_index = self.page_index or 1
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

-- One "date | bar | value" row. bar_w is the bar's own pixel width (already
-- sized to leave room for the date and value columns); max_value is the
-- largest value (seconds or pages, whichever self.metric is) across every
-- row in the list, so every bar's fill is relative to the same scale.
function StreakHistoryPopup:_buildRow(date_str, day_stats, max_value, fonts)
    local seconds = day_stats and day_stats.seconds or 0
    local pages   = day_stats and day_stats.pages   or 0
    local value   = (self.metric == "pages") and pages or seconds
    local value_str
    if self.metric == "pages" then
        value_str = pages == 0 and "---" or formatCount(pages)
    else
        value_str = seconds == 0 and "---" or Locale.formatDuration(seconds, true)
    end

    -- Translated "Mon D" label (e.g. "Sep 22", Hungarian "Szept. 22") rather
    -- than a bare numeric day/month, which reads ambiguously at a glance -
    -- see Locale.formatShortMonthDay.
    local date_label = Locale.formatShortMonthDay(date_str)

    local date_widget  = TextWidget:new{ text = date_label, face = fonts.small, fgcolor = Colors.label() }
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

function StreakHistoryPopup:_rebuild()
    local fonts = self.fonts
    local cont_w = self.content_width

    -- Column widths sized once (on the first build) from realistic
    -- worst-case labels for *both* metrics (not just whichever is showing
    -- right now), so toggling between time and pages never needs the bar to
    -- resize. The date column is measured from the actual translated
    -- "Mon D" label in every month (not a hardcoded numeric pattern), since
    -- month-name widths vary by language (e.g. Hungarian "Szept. 30" is
    -- wider than English "Sep 30") - widening it here also widens the same
    -- self._col_gap used again below on the value column's side, so the two
    -- ends of the row stay in balance. Paging (not scrolling) means every
    -- page's rows fit without a scrollbar to allow for.
    if not self._date_col_w then
        local max_date_w = 0
        for m = 1, 12 do
            local label = Locale.formatShortMonthDay(string.format("2024-%02d-30", m))
            local tw = TextWidget:new{ text = label, face = fonts.small }
            max_date_w = math.max(max_date_w, tw:getSize().w)
            tw:free()
        end
        self._date_col_w = max_date_w

        local sample_time_str  = Locale.formatDuration(23 * 3600 + 59 * 60, true)
        local sample_pages_str = formatCount(999)
        local sample_time  = TextWidget:new{ text = sample_time_str,  face = fonts.small }
        local sample_pages = TextWidget:new{ text = sample_pages_str, face = fonts.small }
        self._value_col_w = math.max(sample_time:getSize().w, sample_pages:getSize().w)
            + Screen:scaleBySize(4)
        sample_time:free()
        sample_pages:free()

        self._col_gap = Size.padding.default
        self._rows_w = cont_w
        self._bar_w = self._rows_w - self._date_col_w - self._value_col_w - 2 * self._col_gap
        if self._bar_w < Screen:scaleBySize(20) then self._bar_w = Screen:scaleBySize(20) end
    end

    -- The running max (seconds and pages) is computed once, across the
    -- *whole* streak rather than just the page being shown, and cached - so
    -- a bar's fill is always proportional to the streak's actual busiest
    -- day (the "total time" scale), whichever page you're paged to, and
    -- paging or toggling the metric never needs to rescan the full list.
    if not self._max_computed then
        local max_seconds, max_pages = 0, 0
        for _, date_str in ipairs(self.days) do
            local d = self.stats[date_str]
            if d then
                if d.seconds > max_seconds then max_seconds = d.seconds end
                if d.pages   > max_pages   then max_pages   = d.pages   end
            end
        end
        self._max_seconds, self._max_pages = max_seconds, max_pages
        self._max_computed = true
    end
    local max_value = (self.metric == "pages") and self._max_pages or self._max_seconds

    -- This page's slice of the (newest-first) day list.
    local total_days = #self.days
    self._total_pages = math.max(1, math.ceil(total_days / STREAK_HISTORY_PAGE_SIZE))
    if self.page_index < 1 then self.page_index = 1 end
    if self.page_index > self._total_pages then self.page_index = self._total_pages end
    local start_i = (self.page_index - 1) * STREAK_HISTORY_PAGE_SIZE + 1
    local end_i = math.min(start_i + STREAK_HISTORY_PAGE_SIZE - 1, total_days)
    local page_days = {}
    for i = start_i, end_i do page_days[#page_days + 1] = self.days[i] end

    local content = VerticalGroup:new{ align = "left" }

    local title = TextWidget:new{ text = self.title_str, face = fonts.section, fgcolor = Colors.section() }
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = cont_w, h = title:getSize().h }, title,
    })
    table.insert(content, VerticalSpan:new{ height = Size.padding.small })

    -- Date range this page covers ("Sep 13 – Sep 22"), with ‹ / › paging
    -- arrows when there's more than one page - the day list is newest-first,
    -- so the range reads oldest (page_days' last entry) to newest (its
    -- first). Same paging header widget the calendar popup's month view
    -- uses above, in the label role for the date text (so it reads as a
    -- subheading under the title) but the section role's bigger/bolder font
    -- for the ‹ / › arrows themselves, so they match the chevrons on the
    -- combined streak popup rather than a smaller, non-bold pair of their
    -- own. Dates use the same user-configured format (Locale.formatDate via
    -- formatDateForDisplay) as the current/best streak's date range on that
    -- same combined popup, instead of the short "Mon D" label used per row -
    -- so, e.g., "16/04/2026 – 22/09/2026" in Hungarian's dd/mm/yyyy setting.
    local range_str = "\xE2\x80\x93"
    if #page_days > 0 then
        range_str = formatDateForDisplay(page_days[#page_days], true)
            .. " \xE2\x80\x93 " .. formatDateForDisplay(page_days[1])
    end
    local prev_available = self.page_index > 1
    local next_available = self.page_index < self._total_pages
    local range_header, range_left_w, range_right_w, range_header_h = buildStreakCalHeader(
        range_str, cont_w, fonts.label, prev_available, next_available,
        Colors.label(), fonts.section, Colors.section())
    table.insert(content, range_header)
    self._range_header_h = range_header_h
    -- Always keep both tap zones (below) registered at their reserved slot
    -- width, whether or not an arrow is actually drawn there right now (see
    -- buildStreakCalHeader: the slot is always reserved, arrow or not). A
    -- fast succession of taps in the same spot can land exactly when the
    -- last page removes that arrow; _goToPage already no-ops silently when
    -- there's nowhere to go, so routing that tap there (instead of falling
    -- through to onTap's default close-the-popup) keeps the popup open.
    self._range_left_w  = range_left_w
    self._range_right_w = range_right_w

    table.insert(content, VerticalSpan:new{ height = Size.padding.default })
    table.insert(content, Colors.newBar(cont_w, Size.line.thin, Colors.separator()))
    table.insert(content, VerticalSpan:new{ height = Size.padding.default })

    local rows = VerticalGroup:new{}
    local row_h = nil
    local row_gap = Screen:scaleBySize(6)
    for i, date_str in ipairs(page_days) do
        local row, h = self:_buildRow(date_str, self.stats[date_str], max_value, fonts)
        row_h = row_h or h
        if i > 1 then table.insert(rows, VerticalSpan:new{ height = row_gap }) end
        table.insert(rows, row)
    end
    row_h = row_h or Screen:scaleBySize(20)
    table.insert(content, rows)

    self.box_content = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding        = self.inner_padding,
        content,
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, self.box_content }

    -- Absolute tap/hit zones: the range header's ‹ / › arrows (paging - see
    -- onTap below, same nav_zone convention as StreakDatePopup) and the
    -- value column, spanning every row on this page. Tapping the value
    -- column toggles self.metric and rebuilds; anything else closes the
    -- popup.
    local box_rect = self:_centeredRect(self.box_content)
    local border_w = Size.border.window
    local header_x = box_rect.x + border_w + self.inner_padding
    local header_y = box_rect.y + border_w + self.inner_padding + title:getSize().h + Size.padding.small
    local tap_pad = Screen:scaleBySize(14)

    self._nav_zones = {}
    if self._range_left_w then
        table.insert(self._nav_zones, {
            dimen = Geom:new{ x = header_x - tap_pad, y = header_y - tap_pad,
                w = self._range_left_w + 2 * tap_pad, h = self._range_header_h + 2 * tap_pad },
            delta = -1,
        })
    end
    if self._range_right_w then
        table.insert(self._nav_zones, {
            dimen = Geom:new{ x = header_x + cont_w - self._range_right_w - tap_pad, y = header_y - tap_pad,
                w = self._range_right_w + 2 * tap_pad, h = self._range_header_h + 2 * tap_pad },
            delta = 1,
        })
    end

    local rows_x = header_x
    local rows_y = header_y + self._range_header_h + Size.padding.default
        + Size.line.thin + Size.padding.default
    local visible_rows = #page_days
    local rows_h = visible_rows * row_h + math.max(0, visible_rows - 1) * row_gap
    self._value_zone = Geom:new{
        x = rows_x + self._rows_w - self._value_col_w,
        y = rows_y,
        w = self._value_col_w,
        h = rows_h,
    }
end

function StreakHistoryPopup:_goToPage(delta)
    local total = self._total_pages or 1
    local idx = self.page_index + delta
    if idx < 1 or idx > total then return true end
    local old_rect = self:_centeredRect(self.box_content)
    self.page_index = idx
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

function StreakHistoryPopup:onTap(arg, ges_ev)
    if ges_ev and ges_ev.pos then
        for _, zone in ipairs(self._nav_zones or {}) do
            local d = zone.dimen
            if UI.hitTest({ dimen = d }, ges_ev.pos.x, ges_ev.pos.y) then
                return self:_goToPage(zone.delta)
            end
        end
        if UI.hitTest({ dimen = self._value_zone }, ges_ev.pos.x, ges_ev.pos.y) then
            self.metric = (self.metric == "pages") and "time" or "pages"
            VS.saveStreakHistoryMetricSetting(self.metric)
            local old_rect = self:_centeredRect(self.box_content)
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

-- The full "YYYY-MM-DD" day list for [start_date, end_date], newest first -
-- same order the source "reading hours" patch listed its last-30-days rows
-- in.
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

-- Lays out the popup box (fonts, width) and shows it for a given day
-- list/stats/title. The day list is the *whole* streak, newest first - the
-- popup itself only ever builds STREAK_HISTORY_PAGE_SIZE rows at a time (see
-- StreakHistoryPopup:_rebuild), paging through the rest instead of building
-- or scrolling through hundreds of rows for a months-long streak. It always
-- opens on page 1, i.e. the newest end of the streak (StreakHistoryPopup:init
-- already defaults page_index to 1, so nothing needs setting here).
local function showHistoryPopup(title_str, days, stats)
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
        stats           = stats,
        metric          = VS.readStreakHistoryMetricSetting(),
    })
end

-- Opens the per-day bar-list history for one streak - "current" or "best" -
-- from the `streaks` table (Data.calculateStreaks()). Tapping "Current
-- streak"/"Best streak" on the insights page opens this (see
-- ReadingInsightsPopup's tap_cd/tap_cw/tap_bd/tap_bw in insights_view.lua);
-- the combined calendar popup above (M.show) stays reachable from the
-- hamburger menu and the Tools-menu entry.
local function showStreakHistory(streaks, which)
    streaks = streaks or {}
    local dates_key = (which == "best") and "best_days_dates" or "current_days_dates"
    local dates = streaks[dates_key]
    if not dates or not dates.start then
        UIManager:show(InfoMessage:new{ text = _("No streak dates") })
        return
    end

    -- The whole streak, newest first - the popup pages through it rather
    -- than truncating it, so however long the streak ran is all shown.
    local days = dateRangeListDesc(dates.start, dates.end_)
    local stats = Data.getDailyStatsInRange(dates.start, dates.end_)
    local title_str = (which == "best") and _("Best streak") or _("Current streak")

    showHistoryPopup(title_str, days, stats)
end

-- The streaks popup itself: a modal box laying out (top to bottom) one pageable
-- calendar month with the reading/streaks marked, then current and best streak
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
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self.month_index = self.month_index or 1
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

function StreakDatePopup:_rebuild()
    local fonts  = self.fonts
    local layout = self.layout
    local col_w  = self.col_width
    local cont_w = self.content_width
    local inner_padding = self.inner_padding

    local content = VerticalGroup:new{ align = "left" }

    -- Calendar page on top: one month of the streak, with the days that had
    -- reading marked, and a ‹ / › paging header. Its arrow tap zones are placed
    -- from the header's on-screen position below; since the calendar is the
    -- first thing in the box, that header sits right under the box padding.
    self._nav_zones = {}
    self._left_w, self._right_w, self._header_h = nil, nil, 0
    if self.months and #self.months > 0 then
        -- Day squares sit flush (no gap between days), so the whole grid is
        -- exactly 7 cells wide; cell size is a seventh of the content width -
        -- unless cal_cell_override is set (see showStreaksPopup's landscape
        -- handling below), in which case the calendar is drawn smaller than
        -- the box and centered within it, so the box itself can stay full
        -- width for the streak figures below without the grid overflowing
        -- the screen's height.
        local show_week = showWeekNumbers()
        local week_col_w, week_prefix_w = weekColumnMetrics(show_week, fonts.small)
        local cell = self.cal_cell_override or math.floor((cont_w - week_prefix_w) / 7)
        local mo   = self.months[self.month_index]
        local is_hu = (getLangBase() == "hu")
        local title_str = is_hu
            and string.format("%04d. %s", mo.year, MONTH_NAMES_FULL_HU_LC[mo.month])
            or  (MONTH_NAMES_FULL[mo.month] .. " " .. tostring(mo.year))
        local prev_available = self.month_index > 1
        local next_available = self.month_index < #self.months
        local header, left_w, right_w, header_h =
            buildStreakCalHeader(title_str, cont_w, fonts.section, prev_available, next_available)
        local grid = buildStreakMonthGrid(mo.year, mo.month, self.read_set,
            fonts, cell, self.week_start_wd, show_week, week_col_w)

        table.insert(content, header)
        table.insert(content, VerticalSpan:new{ height = Size.padding.default })
        -- Center the day grid (a few px narrower than cont_w after rounding)
        -- under the full-width header.
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = cont_w, h = grid:getSize().h }, grid,
        })
        -- Explicit white spacer (not a VerticalSpan) so there is a clear gap
        -- between the calendar and the divider line below it.
        table.insert(content, Colors.newBar(cont_w, Size.padding.large, Blitbuffer.COLOR_WHITE))
        table.insert(content, Colors.newBar(cont_w, Size.line.thick, Colors.separator()))
        table.insert(content, VerticalSpan:new{ height = Size.padding.large })

        self._header_h = header_h
        self._left_w   = prev_available and left_w or nil
        self._right_w  = next_available and right_w or nil
    end

    -- Below the calendar: current and best streak side by side.
    --   [ Current streak | Best streak ]   section headers
    --   [ date range     | date range   ]
    --   ---------------------------------   thin divider
    --   [ days | weeks   | days | weeks ]
    -- The days|weeks value line (fonts.value) is the tallest of the three text
    -- roles here, so its line height sets a single row height (row_h) that the
    -- section-header and date rows above are also pinned to - all three rows
    -- then read as the same height, with their text vertically centred.
    local inner_gap = math.floor(layout.column_gap / 2)
    local half_col  = math.floor((col_w - inner_gap) / 2)
    local row_h = buildValueLine(fonts.value, fonts.label, half_col, "0", N_("day", "days", 0)):getSize().h

    local cur_hdr  = TextWidget:new{ text = _("Current streak"), face = fonts.section, fgcolor = Colors.section() }
    local best_hdr = TextWidget:new{ text = _("Best streak"),    face = fonts.section, fgcolor = Colors.section() }
    -- Everything from here through the days|weeks row below is the tappable
    -- "Current streak" / "Best streak" section (see the streak_zones block
    -- near the end of this function): remembering where it starts in
    -- `content` lets that block measure its on-screen height without
    -- hardcoding every row/spacer size here a second time.
    local streak_section_start_idx = #content + 1
    table.insert(content, UI.buildTwoColRow(
        UI.fixedCol(cur_hdr,  col_w, row_h),
        UI.fixedCol(best_hdr, col_w, row_h),
        layout))
    table.insert(content, VerticalSpan:new{ height = Size.padding.default })

    local cur_date  = TextWidget:new{ text = self.cur_date_str,  face = fonts.label, fgcolor = Colors.label() }
    local best_date = TextWidget:new{ text = self.best_date_str, face = fonts.label, fgcolor = Colors.label() }
    table.insert(content, UI.buildTwoColRow(
        UI.fixedCol(cur_date,  col_w, row_h),
        UI.fixedCol(best_date, col_w, row_h),
        layout))

    table.insert(content, VerticalSpan:new{ height = Size.padding.large })
    table.insert(content, Colors.newBar(cont_w, Size.line.thin, Colors.separator()))
    table.insert(content, VerticalSpan:new{ height = Size.padding.large })

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
    table.insert(content, UI.buildTwoColRow(
        daysWeeksCell(self.cur_days,  self.cur_weeks),
        daysWeeksCell(self.best_days, self.best_weeks),
        layout))
    local streak_section_end_idx = #content

    self.box_content = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, self.box_content }

    -- Absolute tap zones for the ‹ / › arrows, computed from geometry (same
    -- approach as the Book progress calendar's header).
    local box_rect = self:_centeredRect(self.box_content)
    local border_w = Size.border.window
    local header_x = box_rect.x + border_w + inner_padding
    local header_y = box_rect.y + border_w + inner_padding
    local tap_pad  = Screen:scaleBySize(14)
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

    -- Tap zones for the "Current streak" / "Best streak" columns themselves
    -- - tapping either opens that streak's per-day history popup (see
    -- StreakDatePopup:onTap below). Measured from the actual laid-out
    -- widgets (streak_section_start_idx/_end_idx above) rather than a second
    -- copy of every row/spacer height, so this can't silently drift out of
    -- sync with the section it's supposed to cover.
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
    local idx = self.month_index + delta
    if idx < 1 or idx > n then return true end
    local old_rect = self:_centeredRect(self.box_content)
    self.month_index = idx
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

function StreakDatePopup:onTap(arg, ges_ev)
    if ges_ev then
        local x, y = ges_ev.pos.x, ges_ev.pos.y
        for _, zone in ipairs(self._nav_zones or {}) do
            local d = zone.dimen
            if x >= d.x and x <= d.x + d.w and y >= d.y and y <= d.y + d.h then
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
    end
    UIManager:close(self)
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
    UIManager:setDirty(self, function() return "ui", self:_centeredRect(self.box_content) end)
    return true
end

function StreakDatePopup:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self:_centeredRect(self.box_content) end)
end

-- The combined streak popup: current and best streak side by side, above a
-- calendar of your reading with the streaks marked. Opened by tapping any of
-- the streak cells on the insights page, and from the menu - always the same
-- popup. `streaks` is the table from Data.calculateStreaks().
local function showStreaksPopup(streaks)
    streaks = streaks or {}
    local fonts = getCachedFonts()
    local inner_padding = Size.padding.large
    local column_gap = Size.padding.large
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Fixed 94%-of-screen-wide box, like the book progress calendar and the
    -- reading heatmap.
    local box_width = math.floor(screen_w * 0.94)
    local layout = UI.buildLayout(box_width - 2 * inner_padding, 0, column_gap)
    local col_width = layout.col_width
    local content_width = layout.content_width

    -- Each streak's date range comes from its daily-streak span; "–" when there
    -- is no such streak yet.
    local function rangeStr(dates)
        if not dates or not dates.start then return "\xE2\x80\x93" end
        return formatDateForDisplay(dates.start, true) .. " \xE2\x80\x93 " .. formatDateForDisplay(dates.end_)
    end
    local cur_date_str  = rangeStr(streaks.current_days_dates)
    local best_date_str = rangeStr(streaks.best_days_dates)

    -- Calendar span: from the month of the very first reading record up to
    -- today, so the whole history pages through with its reading marked. The
    -- read set covers the whole shown span. Falls back to the earliest streak
    -- start (or today) if the first-reading month can't be read.
    local today     = os.date("%Y-%m-%d")
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

    local months        = streakMonthList(list_start, range_end)
    local read_set      = months and (Data.getReadingDaysInRange(list_start, range_end) or {}) or {}
    local week_start_wd = (Prefs and Prefs.weekStartWday and Prefs.weekStartWday()) or 1

    local popup = StreakDatePopup:new{
        fonts         = fonts,
        layout        = layout,
        col_width     = col_width,
        content_width = content_width,
        inner_padding = inner_padding,

        streaks       = streaks,
        cur_date_str  = cur_date_str,
        best_date_str = best_date_str,
        cur_days      = streaks.current_days  or 0,
        cur_weeks     = streaks.current_weeks or 0,
        best_days     = streaks.best_days     or 0,
        best_weeks    = streaks.best_weeks    or 0,

        read_set      = read_set,
        months        = months,
        week_start_wd = week_start_wd,
        month_index   = months and #months or 1,
    }

    -- Landscape: the calendar's day squares are exactly content_width / 7 on
    -- a side (buildStreakMonthGrid), so scaling them to a wide landscape
    -- screen's width makes the 6-week grid taller than the screen. :new()
    -- above already built it once at the normal (width-based) box size; if
    -- that actually comes out taller than 94% of the screen height, shrink
    -- just the calendar's day-cell size until the grid fits that instead,
    -- and rebuild - the box itself stays at its normal full width (so the
    -- date range and streak figures below the calendar keep all the room
    -- they had before), with the now-smaller calendar centered inside it.
    if UI.isLandscapeScreen() then
        local target_h = math.floor(screen_h * 0.94)
        local measured_h = popup.box_content:getSize().h
        if measured_h > target_h then
            -- Every element in the box other than the 6 calendar week rows
            -- has a fixed height, independent of the cell size; each week
            -- row is exactly one cell tall. So shrinking the cell size by d
            -- shrinks the total height by close to 6 * d - solve for the d
            -- that closes the gap, then rebuild once with that smaller cell
            -- size. A couple of extra pixels are shaved off on top, as a
            -- margin against the rounding math.floor() introduces along
            -- the way.
            local _week_col_w, week_prefix_w = weekColumnMetrics(showWeekNumbers(), fonts.small)
            local normal_cell = math.floor((content_width - week_prefix_w) / 7)
            local delta_cell = math.ceil((measured_h - target_h) / 6) + 2
            popup.cal_cell_override = math.max(
                normal_cell - delta_cell, Screen:scaleBySize(24))
            popup:_rebuild()
        end
    end

    UIManager:show(popup)
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
    show        = showStreaksPopup,
    showHistory = showStreakHistory,
}
