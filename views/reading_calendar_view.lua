--[[
Reading Insights - the general Reading calendar (view module).

The all-books counterpart to book_calendar_view.lua. Same month-grid look,
popup chrome, fonts and month navigation as the per-book progress calendar,
but every cell shows that day's *total* reading across every book:
  - the time read that day (in whatever clock style KOReader's global
    "Duration format" setting is on - see Locale.formatTimeHHMM), and
  - the number of pages read that day.
Tapping a day opens a book list (like the plugin's other book lists): one
row per book read that day, the book title on the left, that day's time and
pages on the right.

Unlike the per-book calendar there is no cumulative-progress bar or
start/finish flag - those only mean something for a single book. Cells are
plain white, coloured only by the day number and the two count lines.

One way in: M.show{ ui = ... } at the bottom, wired from main.lua's
ShowReadingCalendarPopup handler and the matching menu entry.

Loaded by main.lua with the usual shared modules plus CalendarData, this
popup's own queries (lib/reading_calendar_data.lua).
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, Prefs, UI, CalendarData, Cache =
    deps.Locale, deps.Colors, deps.Fonts, deps.Prefs, deps.UI, deps.CalendarData, deps.Cache
local _            = Locale._
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase
local formatCount  = Locale.formatCount

-- Weekday / month name tables for the header and weekday row. These strings
-- are already translated in locale/<lang>.po (reused from the per-book
-- calendar), so no new strings are needed here. The trailing space on
-- "May " mirrors the .po files and disambiguates the month name from the
-- modal verb "May".
local WEEKDAY_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local MONTH_FULL = {
    "January", "February", "March", "April", "May ", "June",
    "July", "August", "September", "October", "November", "December",
}
local MONTH_FULL_HU_LC = {
    "január", "február", "március", "április", "május", "június",
    "július", "augusztus", "szeptember", "október", "november", "december",
}

-- First letter of the already-translated "page(s)" word, used as a compact
-- unit abbreviation in the calendar cell - stays in the user's language for
-- free since it rides on the existing N_("page","pages",...) translation.
local function pageAbbrev(count)
    return N_("page", "pages", count):sub(1, 1)
end

-- The time line shown in a day cell: that day's total reading time in
-- whatever clock style KOReader's global "Duration format" setting is on
-- (Locale.formatTimeHHMM). Empty string for days with no reading.
local function cellTimeText(entry)
    if not entry or not entry.duration or entry.duration <= 0 then return "" end
    local td = Locale.formatTimeHHMM(entry.duration)
    local unit = td.unit ~= "" and (" " .. td.unit) or ""
    return td.value .. unit
end

-- The pages line shown in a day cell: that day's total pages, e.g. "123o".
-- Empty string for days with no reading.
local function cellPagesText(entry)
    if not entry or not entry.pages or entry.pages <= 0 then return "" end
    return formatCount(entry.pages) .. pageAbbrev(entry.pages)
end

-- ---------------------------------------------------------------------
-- Day shading setting (Settings > Advanced settings > Reading calendar >
-- "Day shading"). Tints each day cell to show whether that day was above or
-- below the month's average, using the same configurable heatmap palette as
-- the reading heatmap:
--   "off"   - no shading, cells stay white (the original look)
--   "time"  (default) - shade by that day's reading time vs the month average
--   "pages"           - shade by that day's page count vs the month average
-- The average is over the month's reading days only (days with no reading
-- don't drag it down). Exposed on the module so main.lua's Advanced settings
-- submenu can read/write it.
-- ---------------------------------------------------------------------
local SETTINGS_KEY_SHADE_METRIC = "reading_insights_reading_calendar_shade_metric"
local DEFAULT_SHADE_METRIC      = "time"

local function readShadeMetricSetting()
    local v = Prefs.read(SETTINGS_KEY_SHADE_METRIC, DEFAULT_SHADE_METRIC)
    if v == nil then return DEFAULT_SHADE_METRIC end
    return v
end

local function saveShadeMetricSetting(mode)
    Prefs.save(SETTINGS_KEY_SHADE_METRIC, mode)
end

-- Average of the chosen metric ("time"/"pages") over the month's reading
-- days (days with any reading), or 0 when there are none - which the callers
-- treat as "no shading".
local function monthReadingAverage(daily_map, metric)
    local sum, count = 0, 0
    for _day, entry in pairs(daily_map) do
        local v = (metric == "pages") and (entry.pages or 0) or (entry.duration or 0)
        if v > 0 then sum = sum + v; count = count + 1 end
    end
    if count == 0 then return 0 end
    return sum / count
end

-- Diverging shade for a day's value against the month average. Returns a
-- bucket level and the matching background colour from the (user-configurable)
-- heatmap palette:
--   0  no reading            -> heatmap_0   (white)
--   1  below average         -> heatmap_25  (light)
--   2  around the average    -> heatmap_50  (mid)   <- the average lands here
--   3  above average         -> heatmap_75  (dark)
--   4  well above average    -> heatmap_100 (darkest)
-- The level also decides the cell's text colour (dark cells flip to white so
-- the day number/counts stay readable) - see buildGrid.
local function shadeForValue(value, avg)
    if not value or value <= 0 or not avg or avg <= 0 then
        return 0, Colors.heatmap0()
    end
    local ratio = value / avg
    if ratio <= 0.66 then return 1, Colors.heatmap25() end
    if ratio <= 1.33 then return 2, Colors.heatmap50() end
    if ratio <= 2.0  then return 3, Colors.heatmap75() end
    return 4, Colors.heatmap100()
end

-- Builds the weekday header row + week rows of day cells for one month.
-- Returns the combined widget and a list of { frame, day, data } used by
-- ReadingCalendarPopup:onTap to hit-test which day (if any) was tapped.
--
-- Each cell is white, with the day number on top and, underneath, that
-- day's total time and total pages (blank lines when nothing was read, so
-- the day number sits at the same spot in every cell). Today's cell gets a
-- bold day number and a black border so "today" is unambiguous.
local function buildGrid(daily_map, year, month, day_font, small_font, content_width, shade_metric)
    local week_start_wd = Prefs.weekStartWday() -- 0=Sun, 1=Mon
    local gap    = Screen:scaleBySize(2)
    local cols   = 7
    local cell_w = math.floor((content_width - (cols - 1) * gap) / cols)
    local cell_h = math.floor(cell_w * 1.35) -- day number + time line + pages line

    local cell_radius   = Screen:scaleBySize(6)
    local day_font_bold = Fonts.getBoldFace("stats_label")

    -- Day shading: the month average of the chosen metric over its reading
    -- days, computed once here; each cell is then tinted by how it compares
    -- (see shadeForValue). "off" (or a month with no reading) means every
    -- cell stays plain white, exactly as before shading existed.
    local shading_on = (shade_metric ~= nil and shade_metric ~= "off")
    local month_avg  = shading_on and monthReadingAverage(daily_map, shade_metric) or 0

    local grid = VerticalGroup:new{ align = "center" }
    local day_cells = {}

    -- Weekday header row.
    local header_row = HorizontalGroup:new{}
    for i = 0, 6 do
        local wd = ((week_start_wd + i) % 7) + 1 -- 1=Sun..7=Sat
        local label_w = TextWidget:new{ text = _(WEEKDAY_SHORT[wd]), face = small_font, fgcolor = Colors.label() }
        table.insert(header_row, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = label_w:getSize().h }, label_w,
        })
        if i < 6 then table.insert(header_row, HorizontalSpan:new{ width = gap }) end
    end
    table.insert(grid, header_row)
    table.insert(grid, VerticalSpan:new{ height = gap * 2 })

    local first_ts = os.time{ year = year, month = month, day = 1, hour = 12 }
    local first_wd = tonumber(os.date("%w", first_ts)) -- 0=Sun..6=Sat
    local lead_blanks = (first_wd - week_start_wd + 7) % 7
    local days_in_month = tonumber(os.date("%d", os.time{ year = year, month = month + 1, day = 0, hour = 12 }))

    local today_str = os.date("%Y-%m-%d")

    local day = 1 - lead_blanks
    while day <= days_in_month do
        local row = HorizontalGroup:new{}
        for col = 1, 7 do
            local cell_day = day + col - 1
            if cell_day < 1 or cell_day > days_in_month then
                table.insert(row, LineWidget:new{
                    dimen = Geom:new{ w = cell_w, h = cell_h }, background = Blitbuffer.COLOR_WHITE,
                })
            else
                local entry    = daily_map[cell_day]
                local day_str  = string.format("%04d-%02d-%02d", year, month, cell_day)
                local is_today = (day_str == today_str)

                -- Day shading vs the month average. When shading is off (or
                -- there's no average), bg_color stays white and the text keeps
                -- its normal colour, so the cell looks exactly as before.
                local bg_color   = Blitbuffer.COLOR_WHITE
                local text_color = Colors.value()
                if shading_on then
                    local metric_value = entry and
                        ((shade_metric == "pages") and entry.pages or entry.duration)
                    local level
                    level, bg_color = shadeForValue(metric_value, month_avg)
                    -- Darker cells (around-average and up) flip the text to
                    -- white so the day number and counts stay readable.
                    if level >= 2 then text_color = Blitbuffer.COLOR_WHITE end
                end

                local day_num_w = TextWidget:new{
                    text = tostring(cell_day),
                    face = is_today and day_font_bold or day_font,
                    fgcolor = text_color,
                }
                -- Both count lines are always present (even blank), so the
                -- day number sits at the same vertical spot in every cell.
                local time_w = TextWidget:new{
                    text = cellTimeText(entry), face = small_font, fgcolor = text_color,
                }
                local pages_w = TextWidget:new{
                    text = cellPagesText(entry), face = small_font, fgcolor = text_color,
                }

                local cell_inner = VerticalGroup:new{
                    align = "center",
                    day_num_w,
                    VerticalSpan:new{ height = Screen:scaleBySize(2) },
                    time_w,
                    pages_w,
                }
                -- Same construction as the per-book progress calendar so the
                -- cells look identical: a solid fill covering the whole cell
                -- (the shading colour, or white when shading is off) inside
                -- the rounded border below, with the day's text centred on
                -- top. Without the explicit fill the rounded FrameContainer
                -- border doesn't render as a full cell.
                local cell_content = OverlapGroup:new{
                    dimen = Geom:new{ w = cell_w, h = cell_h },
                    Colors.newBar(cell_w, cell_h, bg_color),
                    CenterContainer:new{
                        dimen = Geom:new{ w = cell_w, h = cell_h }, cell_inner,
                    },
                }

                -- Border/shape depends on whether the cell is shaded:
                --   shading ON  - the colour fill *is* the cell, so no thin
                --     separator frame (its rounded corners don't line up with
                --     the square colour fill and read as a broken top/left
                --     line). Square, borderless; only today keeps a marker,
                --     a square black border (radius 0, so its corners match
                --     the square fill cleanly).
                --   shading OFF - the original book-progress-calendar look:
                --     a thin rounded separator frame around a white fill,
                --     where the fill matching the page hides the corners.
                local border, border_color, radius
                if shading_on then
                    border       = is_today and Size.line.medium or 0
                    border_color = Blitbuffer.COLOR_BLACK
                    radius       = 0
                else
                    border       = is_today and Size.line.medium or Size.line.thin
                    border_color = is_today and Blitbuffer.COLOR_BLACK or Colors.separator()
                    radius       = cell_radius
                end
                local frame = FrameContainer:new{
                    background = nil,
                    bordersize = border,
                    color      = border_color,
                    radius     = radius,
                    padding    = 0,
                    margin     = 0,
                    width      = cell_w,
                    height     = cell_h,
                    cell_content,
                }
                table.insert(day_cells, { frame = frame, day = cell_day, data = entry })
                table.insert(row, frame)
            end
            if col < 7 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        end
        table.insert(grid, row)
        table.insert(grid, VerticalSpan:new{ height = gap })
        day = day + 7
    end

    return grid, day_cells
end

-- Month header with < / > navigation arrows, styled like the per-book
-- calendar's (buildBookCalendarHeader) and KOReader's own Statistics
-- CalendarView header. Returns the header widget plus the tappable arrow
-- frames (nil when hidden), so onTap can hit-test them the same way it
-- hit-tests day cells.
local function buildHeader(title_str, content_width, section_font, prev_available, next_available)
    local arrow_pad = Size.padding.default

    -- Both arrows always occupy the same fixed-width slot, whether or not
    -- they're visible, so the title stays centred and the header doesn't
    -- jump sideways while paging.
    local left_glyph_w  = TextWidget:new{ text = "\xe2\x80\xb9", face = section_font }:getSize().w
    local right_glyph_w = TextWidget:new{ text = "\xe2\x80\xba", face = section_font }:getSize().w
    local slot_w = math.max(left_glyph_w, right_glyph_w) + 2 * arrow_pad

    local function makeArrow(glyph, visible)
        if not visible then
            return HorizontalSpan:new{ width = slot_w }, nil
        end
        local tw = TextWidget:new{ text = glyph, face = section_font, fgcolor = Colors.section() }
        local extra = slot_w - 2 * arrow_pad - tw:getSize().w
        local frame = FrameContainer:new{
            background     = nil,
            bordersize     = 0,
            padding_top    = 0,
            padding_bottom = 0,
            padding_left   = arrow_pad + math.floor(extra / 2),
            padding_right  = arrow_pad + math.ceil(extra / 2),
            margin         = 0,
            tw,
        }
        return frame, frame
    end

    local left_widget,  left_frame  = makeArrow("\xe2\x80\xb9", prev_available)
    local right_widget, right_frame = makeArrow("\xe2\x80\xba", next_available)

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

    return header_row, left_frame, right_frame, left_widget:getSize().w, right_widget:getSize().w, header_row:getSize().h
end

-- True if year/month (y1, m1) is chronologically after (y2, m2).
local function monthIsAfter(y1, m1, y2, m2)
    return (y1 > y2) or (y1 == y2 and m1 > m2)
end

-- How long after new reading is detected the background refresh waits before
-- re-querying and repainting, matching the heatmap's own revalidation delay
-- so a just-detected change lands a moment after the instant stale paint
-- rather than fighting it.
local REVALIDATE_DELAY_S = 0.88

-- Stale-while-revalidate front end for the month grid query
-- (CalendarData.getDailyStatsForMonth). Unless `force_fresh` is set, or this
-- month has never been fetched, this hands back the last-known map straight
-- from Cache._stale_reading_calendar with no DB access at all - what lets the
-- popup (re)open and page instantly. `force_fresh` is set only by the
-- background revalidation below, once it has confirmed via
-- CalendarData.getMaxStartTime that there's new reading to show; that path
-- runs the real query and refreshes both the stale mirror and the watermark.
local function getMonthData(year, month, force_fresh)
    local key = string.format("%04d-%02d", year, month)

    if Cache and Cache.ENABLE_CACHE then
        if not force_fresh then
            local stale = Cache._stale_reading_calendar[key]
            if stale then return stale end
        end
        local daily_map = CalendarData.getDailyStatsForMonth(year, month)
        Cache._stale_reading_calendar[key] = daily_map
        Cache._reading_calendar_watermark = CalendarData.getMaxStartTime()
        -- Persist the refreshed mirror + watermark so the next open after a
        -- KOReader restart still paints instantly (best-effort; a failure
        -- here never breaks the calendar - see Cache.saveDiskCache).
        if Cache.saveDiskCache then pcall(Cache.saveDiskCache) end
        return daily_map
    end

    return CalendarData.getDailyStatsForMonth(year, month)
end

local ReadingCalendarPopup = InputContainer:extend{
    modal = true,
    ui    = nil,
    year  = nil,
    month = nil,
}

function ReadingCalendarPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end

    self:_rebuild()
end

function ReadingCalendarPopup:_rebuild(force_fresh)
    local day_font   = Fonts.getFace("stats_label")
    local small_font = Fonts.getFace("insights_small")

    local box_width     = math.floor(Screen:getWidth() * 0.94)
    local inner_padding = Size.padding.large
    local content_width = box_width - 2 * inner_padding

    local is_hu = (getLangBase() == "hu")
    local title_str = is_hu
        and string.format("%04d. %s", self.year, MONTH_FULL_HU_LC[self.month])
        or  (_(MONTH_FULL[self.month]) .. " " .. tostring(self.year))

    -- Forward paging stops at the current calendar month (no reading can be
    -- recorded in the future).
    local now = os.date("*t")
    local next_available = monthIsAfter(now.year, now.month, self.year, self.month)

    -- Backward paging stops at the earliest month with any reading in it, so
    -- the calendar can't be paged back into empty months.
    local prev_month, prev_year = self.month - 1, self.year
    if prev_month < 1 then prev_month = 12; prev_year = prev_year - 1 end
    local prev_available = CalendarData.monthHasData(prev_year, prev_month)

    local title_row, left_arrow_frame, right_arrow_frame, left_w, right_w, header_h = buildHeader(
        title_str, content_width, Fonts.getFace("stats_section"), prev_available, next_available)

    local daily_map = getMonthData(self.year, self.month, force_fresh)
    local grid, day_cells = buildGrid(daily_map, self.year, self.month, day_font, small_font,
        content_width, readShadeMetricSetting())
    self._day_cells = day_cells

    local content = VerticalGroup:new{
        align = "center",
        title_row,
        VerticalSpan:new{ height = Size.padding.large },
        grid,
    }

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

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.box_content,
    }

    -- Absolute tap zones for the < / > arrows, computed from geometry (the
    -- arrow frames' own .dimen can be stale when the popup is first built).
    local box_rect = self:_centeredRect(self.box_content)
    local border_w = Size.border.window
    local header_x = box_rect.x + border_w + inner_padding
    local header_y = box_rect.y + border_w + inner_padding
    local tap_pad  = Screen:scaleBySize(14)

    self._nav_zones = {}
    if left_arrow_frame then
        table.insert(self._nav_zones, {
            dimen = Geom:new{
                x = header_x - tap_pad,
                y = header_y - tap_pad,
                w = left_w + 2 * tap_pad,
                h = header_h + 2 * tap_pad,
            },
            delta = -1,
        })
    end
    if right_arrow_frame then
        table.insert(self._nav_zones, {
            dimen = Geom:new{
                x = header_x + content_width - right_w - tap_pad,
                y = header_y - tap_pad,
                w = right_w + 2 * tap_pad,
                h = header_h + 2 * tap_pad,
            },
            delta = 1,
        })
    end
end

function ReadingCalendarPopup:_centeredRect(widget)
    local size = widget:getSize()
    local w, h = size.w, size.h
    local x = self.dimen.x + math.floor((self.dimen.w - w) / 2)
    local y = self.dimen.y + math.floor((self.dimen.h - h) / 2)
    return Geom:new{ x = x, y = y, w = w, h = h }
end

function ReadingCalendarPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self:_centeredRect(self.box_content)
    end)
    -- Instant stale paint done; now check (cheaply) whether the current
    -- month actually has new reading to fold in, and refresh behind the
    -- popup if so - see _scheduleRevalidate.
    self:_scheduleRevalidate()
    return true
end

function ReadingCalendarPopup:onCloseWidget()
    -- Guards the callbacks _scheduleRevalidate schedules: a background
    -- refresh still pending when the popup is closed must not fire afterwards
    -- and touch a box_content/dimen that's no longer shown.
    self._closed = true
    UIManager:setDirty(nil, function()
        return "ui", self:_centeredRect(self.box_content)
    end)
end

-- True when the month currently shown is the live calendar month - the only
-- month that can still gain new reading, so the only one ever revalidated.
function ReadingCalendarPopup:_showingCurrentMonth()
    local now = os.date("*t")
    return self.year == now.year and self.month == now.month
end

-- Smart-invalidation half of the stale-while-revalidate: only the current
-- month can gain new reading (older months are history, served from the
-- stale mirror forever). A single cheap CalendarData.getMaxStartTime() read
-- decides whether a refresh is worth doing: unmoved since the last fetch
-- (Cache._reading_calendar_watermark) means nothing was read since, so the
-- popup is left exactly as it opened; moved on means a real refresh is
-- scheduled after REVALIDATE_DELAY_S and its result repaints in place.
function ReadingCalendarPopup:_scheduleRevalidate()
    if not (Cache and Cache.ENABLE_CACHE) then return end
    if not self:_showingCurrentMonth() then return end
    UIManager:scheduleIn(0, function()
        if self._closed or not self:_showingCurrentMonth() then return end
        local watermark = CalendarData.getMaxStartTime()
        if not watermark or watermark <= (Cache._reading_calendar_watermark or 0) then
            return
        end
        UIManager:scheduleIn(REVALIDATE_DELAY_S, function()
            if self._closed or not self:_showingCurrentMonth() then return end
            self:_refreshInPlace()
        end)
    end)
end

-- Re-runs _rebuild with force_fresh so it re-queries the DB (rather than
-- serving the stale mirror), then repaints exactly the screen area the box
-- occupies - both its old and new position/size, in case the fresh data
-- changed its height - the same union-of-rects approach _goToMonth uses.
function ReadingCalendarPopup:_refreshInPlace()
    local old_rect = self:_centeredRect(self.box_content)
    self:_rebuild(true)
    local new_rect = self:_centeredRect(self.box_content)

    local x1 = math.min(old_rect.x, new_rect.x)
    local y1 = math.min(old_rect.y, new_rect.y)
    local x2 = math.max(old_rect.x + old_rect.w, new_rect.x + new_rect.w)
    local y2 = math.max(old_rect.y + old_rect.h, new_rect.y + new_rect.h)
    UIManager:setDirty("all", function()
        return "ui", Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
    end)
end

-- The book list behind a tapped day: one row per book read that day, the
-- book title on the left and that day's time + pages on the right (the same
-- KeyValuePage look the plugin's read-only book lists have). Drawn on top of
-- the calendar; closing it returns to the calendar.
function ReadingCalendarPopup:_showDayDetail(day)
    local t = os.time{ year = self.year, month = self.month, day = day, hour = 12 }
    local date_str = Locale.formatDateFromTS(t)

    local books = CalendarData.getBooksForDay(self.year, self.month, day)
    if not books or #books == 0 then
        UIManager:show(InfoMessage:new{ text = date_str .. "\n" .. _("No reading on this day.") })
        return
    end

    local KeyValuePage = require("ui/widget/keyvaluepage")

    -- KOReader's statistics plugin, whose getBookStat(id) backs the same
    -- per-book detail page the plugin's other book lists open on a row tap.
    -- nil in the rare case there's no statistics plugin (then rows are inert).
    local stats_plugin = self.ui and self.ui.statistics or nil

    local kv_pairs = {}
    for _idx, book in ipairs(books) do
        local time_td   = Locale.formatTimeHHMM(book.duration)
        local time_str  = time_td.value .. (time_td.unit ~= "" and (" " .. time_td.unit) or "")
        local pages_str = formatCount(book.pages) .. " " .. N_("page", "pages", book.pages)

        -- Tapping a row opens that book's statistics, exactly like the
        -- plugin's read-only book lists (see booklist_view's showBookList).
        local book_id    = book.id_book
        local book_title = book.title or _("Unknown")
        local cb = nil
        if book_id and stats_plugin then
            cb = function()
                local kv2
                kv2 = KeyValuePage:new{
                    modal           = true,
                    title           = book_title,
                    kv_pairs        = stats_plugin:getBookStat(book_id),
                    value_align     = "right",
                    single_page     = true,
                    callback_return = function() UIManager:close(kv2) end,
                    close_callback  = function() kv2 = nil end,
                }
                UIManager:show(kv2)
            end
        end

        table.insert(kv_pairs, {
            book_title,
            time_str .. "  \xc2\xb7  " .. pages_str, -- U+00B7 MIDDLE DOT
            callback = cb,
        })
    end

    -- modal = true so UIManager stacks it ON TOP of this calendar popup (and
    -- of the insights popup underneath, when the calendar was opened from a
    -- month's long press). A non-modal window is inserted *below* the topmost
    -- modal one, which is what put the list behind the insights window.
    local kv
    kv = KeyValuePage:new{
        modal          = true,
        title          = date_str,
        kv_pairs       = kv_pairs,
        value_align    = "right",
        close_callback = function() kv = nil end,
    }
    UIManager:show(kv)
end

function ReadingCalendarPopup:_goToMonth(delta)
    local m = self.month + delta
    local y = self.year
    while m < 1 do m = m + 12; y = y - 1 end
    while m > 12 do m = m - 12; y = y + 1 end
    -- Don't navigate past the current calendar month.
    local now = os.date("*t")
    if monthIsAfter(y, m, now.year, now.month) then return true end
    -- Don't navigate back into a month with no reading recorded at all.
    if delta < 0 and not CalendarData.monthHasData(y, m) then return true end

    local old_rect = self:_centeredRect(self.box_content)
    self.year, self.month = y, m
    self:_rebuild()
    local new_rect = self:_centeredRect(self.box_content)

    local x1 = math.min(old_rect.x, new_rect.x)
    local y1 = math.min(old_rect.y, new_rect.y)
    local x2 = math.max(old_rect.x + old_rect.w, new_rect.x + new_rect.w)
    local y2 = math.max(old_rect.y + old_rect.h, new_rect.y + new_rect.h)
    UIManager:setDirty("all", function()
        return "ui", Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
    end)
    -- Landed on the live month (e.g. paged back to it): give it the same
    -- background freshness check the first open gets.
    self:_scheduleRevalidate()
    return true
end

function ReadingCalendarPopup:onTap(arg, ges_ev)
    if ges_ev then
        local x, y = ges_ev.pos.x, ges_ev.pos.y
        for _, zone in ipairs(self._nav_zones or {}) do
            if zone.dimen and x >= zone.dimen.x and x <= zone.dimen.x + zone.dimen.w
               and y >= zone.dimen.y and y <= zone.dimen.y + zone.dimen.h then
                return self:_goToMonth(zone.delta)
            end
        end
        for _, cell in ipairs(self._day_cells or {}) do
            if UI.hitTest(cell.frame, x, y) then
                self:_showDayDetail(cell.day)
                return true
            end
        end
    end
    UIManager:close(self)
    return true
end

function ReadingCalendarPopup:onSwipe(arg, ges_ev)
    if not ges_ev then UIManager:close(self) return true end
    local dir = ges_ev.direction
    if dir == "west" or dir == "left"  then return self:_goToMonth(1)  end
    if dir == "east" or dir == "right" then return self:_goToMonth(-1) end
    UIManager:close(self)
    return true
end

function ReadingCalendarPopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:_goToMonth(1)  end
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:_goToMonth(-1) end
    UIManager:close(self)
    return true
end

-- ---------------------------------------------------------------------
-- Module entry point + exports.
-- ---------------------------------------------------------------------
local M = {}

M.Popup = ReadingCalendarPopup

-- Day shading setting, reached from main.lua's Advanced settings submenu.
M.readShadeMetricSetting = readShadeMetricSetting
M.saveShadeMetricSetting = saveShadeMetricSetting
M.DEFAULT_SHADE_METRIC   = DEFAULT_SHADE_METRIC

--[[
Open the general Reading calendar.

opts:
  ui           optional; the ReaderUI/FileManager (kept for symmetry, not
               required - this calendar isn't scoped to any open book)
  year, month  optional; defaults to the month last read in, else now

Returns the popup, or nil (with an InfoMessage) if there's no reading data.
]]--
function M.show(opts)
    opts = opts or {}

    -- The month last read in doubles as the "is there any reading at all?"
    -- check: nil, nil means the statistics DB has nothing to show.
    local open_year, open_month = opts.year, opts.month
    if not open_year or not open_month then
        open_year, open_month = CalendarData.getLastReadYearMonth()
        if not open_year or not open_month then
            UIManager:show(InfoMessage:new{ text = _("No reading data yet.") })
            return
        end
    end

    local popup = ReadingCalendarPopup:new{
        ui    = opts.ui,
        year  = open_year,
        month = open_month,
    }
    UIManager:show(popup)
    return popup
end

return M
