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
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there). Same
-- Locale/Colors/Fonts/UI/Data/Prefs the insights view uses, so this popup
-- reads the same colors, fonts and reading data.
local deps = ...
local Locale, Colors, Fonts, UI, Data, Prefs =
    deps.Locale, deps.Colors, deps.Fonts, deps.UI, deps.Data, deps.Prefs

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
local function buildStreakMonthGrid(year, month, read_set, fonts, cell, week_start_wd)
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
    local grid_w  = 7 * cell
    local row_gap = Screen:scaleBySize(6)
    local grid = VerticalGroup:new{ align = "center" }

    -- Weekday header row (each label centered over its day column).
    local header_row = HorizontalGroup:new{}
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
local function buildStreakCalHeader(title_str, content_width, section_font, prev_available, next_available)
    local arrow_pad = Size.padding.default
    local left_glyph_w  = TextWidget:new{ text = "\xe2\x80\xb9", face = section_font }:getSize().w
    local right_glyph_w = TextWidget:new{ text = "\xe2\x80\xba", face = section_font }:getSize().w
    local slot_w = math.max(left_glyph_w, right_glyph_w) + 2 * arrow_pad

    local function makeArrow(glyph, visible)
        if not visible then return HorizontalSpan:new{ width = slot_w } end
        local tw = TextWidget:new{ text = glyph, face = section_font, fgcolor = Colors.section() }
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
    local title_w = TextWidget:new{ text = title_str, face = section_font, fgcolor = Colors.section() }

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
        -- exactly 7 cells wide; cell size is a seventh of the content width.
        local cell = math.floor(cont_w / 7)
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
            fonts, cell, self.week_start_wd)

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

    -- Fixed 94%-of-screen-wide box, like the book progress calendar and the
    -- reading heatmap.
    local column_gap = Size.padding.large
    local layout = UI.buildLayout(math.floor(Screen:getWidth() * 0.94) - 2 * inner_padding, 0, column_gap)
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

    UIManager:show(StreakDatePopup:new{
        fonts         = fonts,
        layout        = layout,
        col_width     = col_width,
        content_width = content_width,
        inner_padding = inner_padding,

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
    })
end

-- Module export. `show(streaks)` opens the combined streak popup for the given
-- Data.calculateStreaks() table - the one entry point, used both from the menu
-- and from the insights page's streak cells.
return {
    show = showStreaksPopup,
}
