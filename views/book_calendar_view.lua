--[[
Reading Insights - the Book progress calendar (view module).

Extracted from what used to be stats_view.lua (now book_stats_view.lua):
the month-grid calendar for the currently open book, colored like a heatmap
by how long *this* book was read each day, with a thin cumulative-progress
bar under each day and tap-for-detail on any day. Distinct from
insights_view.lua's all-books Statistics calendar - this one is scoped to a
single book and drawn locally, since KOReader's stock CalendarView widget
has no per-book filter.

Two ways in, both funnelled through M.show(opts) at the bottom:
  - directly from a gesture/dispatcher action (main.lua's
    ShowBookCalendarPopup -> M.show{ ui = ui }), and
  - from the compact book-stats overlay, by tapping its "Pace" section
    title (book_stats_view.lua's openBookCalendar, which passes the
    already-computed total_pages / finish / started timestamps plus an
    on_close callback so it can reopen itself afterwards).

Loaded by main.lua with the usual shared modules plus CalendarData, this
popup's own queries (lib/book_calendar_data.lua).
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
local Math            = require("optmath")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, Prefs, BookProgress, UI, CalendarData =
    deps.Locale, deps.Colors, deps.Fonts, deps.Prefs, deps.BookProgress,
    deps.UI, deps.CalendarData
local _            = Locale._
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase
local formatCount  = Locale.formatCount

-- Weekday / month name tables for the calendar header and weekday row.
-- "Sun".."Sat" and "Jan".."Dec"/full month names are already translated in
-- locale/<lang>.po (reused from elsewhere in the plugin), so no new strings
-- are needed here. The trailing space on "May " mirrors the .po files and
-- disambiguates the month name from the modal verb "May".

local WEEKDAY_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local MONTH_FULL = {
    "January", "February", "March", "April", "May ", "June",
    "July", "August", "September", "October", "November", "December",
}
local MONTH_FULL_HU_LC = {
    "január", "február", "március", "április", "május", "június",
    "július", "augusztus", "szeptember", "október", "november", "december",
}

-- ---------------------------------------------------------------------
-- Book-calendar cell content setting (Settings > Advanced settings > Book
-- progress calendar > "Book progress calendar cell content"). Controls the
-- small text line under each day number - see buildBookCalendarCellText
-- below:
--   "percent" (default) - cumulative progress, e.g. "+13%"
--   "pages"             - that day's own page count, e.g. "+101o"
--   "time"              - that day's own time spent (honors the global
--                          "Duration format" setting)
-- Exposed on the module so main.lua's Advanced settings submenu can
-- read/write it.
-- ---------------------------------------------------------------------
local SETTINGS_KEY_CALENDAR_CELL_MODE = "reading_insights_calendar_cell_mode"
local DEFAULT_CALENDAR_CELL_MODE      = "percent"

local function readCalendarCellModeSetting()
    local v = Prefs.read(SETTINGS_KEY_CALENDAR_CELL_MODE, DEFAULT_CALENDAR_CELL_MODE)
    if v == nil then return DEFAULT_CALENDAR_CELL_MODE end
    return v
end

local function saveCalendarCellModeSetting(mode)
    Prefs.save(SETTINGS_KEY_CALENDAR_CELL_MODE, mode)
end

-- First letter of the already-translated "page(s)" word, used as a
-- compact unit abbreviation in the calendar cell (see
-- buildBookCalendarCellText below) - stays in the user's language for free
-- since it rides on the existing N_("page","pages",...) translation
-- rather than a separate hardcoded letter.
local function pageAbbrev(count)
    return N_("page", "pages", count):sub(1, 1)
end

-- Small text line shown under the day number in the Book progress calendar
-- (see buildBookCalendarGrid below). Honors the "Book progress calendar
-- cell content" setting (readCalendarCellModeSetting):
--   "percent" (default) - cumulative "+13%" progress through the whole book
--   "pages"             - that day's own page count, e.g. "+101o"
--   "time"              - that day's own time spent, e.g. "+0:23" or
--                          "+23m", whichever clock style KOReader's global
--                          "Duration format" setting (Prefs ▸ Time and
--                          date) is set to - see Locale.formatTimeHHMM above.
-- Returns "" for days with no reading, in any mode.
local function buildBookCalendarCellText(entry, total_pages)
    if not entry or not entry.pages or entry.pages <= 0 then return "" end

    local mode = readCalendarCellModeSetting()

    if mode == "pages" then
        return "+" .. formatCount(entry.pages) .. pageAbbrev(entry.pages)
    end

    if mode == "time" then
        local time_td = Locale.formatTimeHHMM(entry.duration or 0)
        local unit = time_td.unit ~= "" and (" " .. time_td.unit) or ""
        return time_td.value .. unit
    end

    if not total_pages or total_pages <= 0 then return "" end
    local pct = Math.round(100 * entry.pages / total_pages)
    return "+" .. formatCount(pct) .. "%"
end

-- Builds the weekday header row + week rows of day cells for one month.
-- Returns the combined widget and a list of { frame = <tappable widget>,
-- day = N, data = daily_map[N] or nil } used by BookCalendarPopup:onTap
-- to hit-test which day (if any) was tapped.
--
-- Each day cell is white (so the day number/percent text is always
-- readable, regardless of how much was read), with a thin progress bar
-- along the bottom showing cumulative_ratios[day] - how far into the
-- book that day's reading got, out of the whole book.
--
-- Today's cell gets its day number rendered in bold (Fonts.getBoldFace)
-- plus a black border, so "where am I now" is unambiguous at a glance.
--
-- finish_day (optional): day-of-month of this book's estimated finish
-- date, IF it falls within the month currently being rendered (callers
-- pre-filter this - see BookCalendarPopup:_rebuild). That cell gets a
-- small flag glyph in its top-right corner (the day number itself is
-- untouched and stays in its normal spot) so the projected finish day
-- stands out on the calendar itself, not just in the "Expected finish"
-- tap popup.
--
-- start_day (optional): day-of-month this book's reading was actually
-- started, IF it falls within the month currently being rendered (same
-- pre-filtering as finish_day - see BookCalendarPopup:_rebuild). That cell
-- gets a matching white/hollow flag glyph, placed to the left of the day
-- number (mirrored from the black finish flag on the right) so start and
-- finish day both get an on-calendar marker without colliding if they
-- ever land on the same day.
--
-- Finished-day checkmark: any day whose cumulative_ratios entry is ≥0.99
-- (i.e. the last page reached that day already covers ≥99% of the book)
-- gets a small ✓ in the exact same spot the black finish_day flag would
-- otherwise take (right of the day number). When both would apply to the
-- same cell, the checkmark wins and the finish_day flag is suppressed for
-- that cell - see is_book_finished_day below.
local function buildBookCalendarGrid(daily_map, year, month, day_font, small_font, content_width, total_pages, cumulative_ratios, finish_day, start_day)
    local week_start_wd = Prefs.weekStartWday() -- 0=Sun, 1=Mon
    local gap    = Screen:scaleBySize(2)
    local cols   = 7
    local cell_w = math.floor((content_width - (cols - 1) * gap) / cols)
    local cell_h = math.floor(cell_w * 1.15) -- room for day number + percent line + bottom progress bar

    local bar_h   = Screen:scaleBySize(4)
    local bar_pad = Screen:scaleBySize(3)
    local bar_w   = cell_w - 2 * bar_pad
    local cell_radius = Screen:scaleBySize(6)
    local day_font_bold = Fonts.getBoldFace("stats_label")

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
                local entry     = daily_map[cell_day]
                local day_str   = string.format("%04d-%02d-%02d", year, month, cell_day)
                local is_today  = (day_str == today_str)
                local is_finish_day = (finish_day ~= nil and cell_day == finish_day)
                local is_start_day  = (start_day  ~= nil and cell_day == start_day)

                local day_num_w = TextWidget:new{
                    text = tostring(cell_day),
                    face = is_today and day_font_bold or day_font,
                    fgcolor = Colors.value(),
                }
                local pct_text = buildBookCalendarCellText(entry, total_pages)
                -- Always include the percent line (even blank) so the day
                -- number sits at the same vertical spot in every cell,
                -- whether or not that day has a "+%" underneath it.
                local pct_w = TextWidget:new{ text = pct_text, face = small_font, fgcolor = Colors.value() }

                -- Bottom progress bar: how far into the book this day's
                -- reading got (cumulative), out of the whole book. Days
                -- with no reading recorded (ratio is nil - see
                -- getBookCumulativeProgressForMonth, which only fills in
                -- days that actually have data) get a blank spacer of the
                -- same height instead of a bar, so no bar of any color
                -- shows under days with nothing read.
                local ratio = cumulative_ratios and cumulative_ratios[cell_day]
                local bar_row
                if ratio and ratio > 0 then
                    local fill_w  = math.max(1, math.floor(bar_w * ratio))
                    local empty_w = bar_w - fill_w
                    bar_row = HorizontalGroup:new{
                        Colors.newBar(fill_w, bar_h, Colors.activeBar()),
                        empty_w > 0 and Colors.newBar(empty_w, bar_h, Colors.inactiveBar())
                            or HorizontalSpan:new{ width = 0 },
                    }
                else
                    bar_row = VerticalSpan:new{ height = bar_h }
                end

                -- The book counts as *finished as of this day* when the
                -- last page reached that day already covers ≥99% of the
                -- book (reuses "ratio" above, just against a threshold
                -- instead of for bar width). Marked with a checkmark in
                -- the cell's literal top-right corner - a different spot
                -- than the finish_day black-flag glyph below (which sits
                -- just right of the day number, not the corner), so the
                -- two can never visually collide. They also shouldn't
                -- ever both apply to the same day in practice: finish_day
                -- is only ever a *projected* date drawn while the book is
                -- still unfinished, whereas the checkmark is driven purely
                -- by *actual* recorded progress.
                local is_book_finished_day = (ratio ~= nil and ratio >= 0.99)

                local cell_inner = VerticalGroup:new{
                    align = "center",
                    day_num_w,
                    pct_w,
                    VerticalSpan:new{ height = bar_pad },
                    bar_row,
                }
                local cell_content = OverlapGroup:new{
                    dimen = Geom:new{ w = cell_w, h = cell_h },
                    Colors.newBar(cell_w, cell_h, Blitbuffer.COLOR_WHITE),
                    CenterContainer:new{
                        dimen = Geom:new{ w = cell_w, h = cell_h }, cell_inner,
                    },
                }
                if is_finish_day and not is_book_finished_day then
                    -- Flag glyph placed immediately to the right of the
                    -- centered day number. The day number is centered in
                    -- cell_w, so its left edge sits at (cell_w - num_w) / 2
                    -- and its right edge at (cell_w + num_w) / 2. We push
                    -- the flag that far right plus a small gap, then overlay
                    -- it at the top of the cell (same vertical start as
                    -- cell_inner inside the CenterContainer).
                    --
                    -- Suppressed whenever is_book_finished_day is also true
                    -- for this cell - see that block below, which takes
                    -- this exact same spot instead. In practice the two
                    -- shouldn't ever both apply to the same day (finish_day
                    -- is only ever a *projected* date shown while the book
                    -- is still unfinished, the checkmark only from *actual*
                    -- recorded progress), but actual data wins if they ever
                    -- do coincide.
                    local flag_pad = Screen:scaleBySize(2)
                    local flag_glyph = TextWidget:new{
                        text = "\xe2\x9a\x91", -- ⚑ BLACK FLAG
                        face = small_font,
                        fgcolor = Colors.value(),
                    }
                    local flag_size   = flag_glyph:getSize()
                    local day_num_size = day_num_w:getSize()
                    -- x offset from cell left edge to the flag's left edge:
                    -- center of cell  +  half the day-number width  +  gap
                    local flag_x = math.floor(cell_w / 2) + math.floor(day_num_size.w / 2) + flag_pad
                    -- y offset: align flag top with the top of cell_inner
                    -- inside the CenterContainer. cell_inner top =
                    -- (cell_h - cell_inner_h) / 2; we just want it near the
                    -- top of the number so use a small fixed top margin.
                    local flag_y = Screen:scaleBySize(3)
                    table.insert(cell_content, HorizontalGroup:new{
                        HorizontalSpan:new{ width = flag_x },
                        VerticalGroup:new{
                            VerticalSpan:new{ height = flag_y },
                            flag_glyph,
                        },
                    })
                end
                if is_start_day then
                    -- Mirror image of the black finish flag above, placed
                    -- immediately to the LEFT of the centered day number
                    -- instead of to the right, using the same gap/top
                    -- offset so the two line up visually if a book ever
                    -- has both markers in view at once (they can't collide
                    -- since one is pinned right of the number and the
                    -- other left of it, even on the same day).
                    local flag_pad = Screen:scaleBySize(2)
                    local flag_glyph = TextWidget:new{
                        text = "\xe2\x9a\x90", -- ⚐ WHITE FLAG
                        face = small_font,
                        fgcolor = Colors.value(),
                    }
                    local flag_size    = flag_glyph:getSize()
                    local day_num_size = day_num_w:getSize()
                    -- x offset from cell left edge to the flag's RIGHT edge:
                    -- center of cell  -  half the day-number width  -  gap.
                    -- We then subtract the flag's own width to get its left
                    -- edge, so it sits flush against that point growing
                    -- further left, mirroring the right-side flag's layout.
                    local flag_right_x = math.floor(cell_w / 2) - math.floor(day_num_size.w / 2) - flag_pad
                    local flag_x = flag_right_x - flag_size.w
                    local flag_y = Screen:scaleBySize(3)
                    table.insert(cell_content, HorizontalGroup:new{
                        HorizontalSpan:new{ width = flag_x },
                        VerticalGroup:new{
                            VerticalSpan:new{ height = flag_y },
                            flag_glyph,
                        },
                    })
                end
                if is_book_finished_day then
                    -- Same spot the black finish flag would otherwise take
                    -- (right of the centered day number) - see is_finish_day
                    -- above, which is suppressed for this cell when this
                    -- branch fires.
                    local check_pad = Screen:scaleBySize(2)
                    local check_glyph = TextWidget:new{
                        text = "\xe2\x9c\x93", -- ✓ CHECK MARK
                        face = small_font,
                        fgcolor = Colors.value(),
                    }
                    local check_size  = check_glyph:getSize()
                    local day_num_size = day_num_w:getSize()
                    local check_x = math.floor(cell_w / 2) + math.floor(day_num_size.w / 2) + check_pad
                    local check_y = Screen:scaleBySize(3)
                    table.insert(cell_content, HorizontalGroup:new{
                        HorizontalSpan:new{ width = check_x },
                        VerticalGroup:new{
                            VerticalSpan:new{ height = check_y },
                            check_glyph,
                        },
                    })
                end
                local border = is_today and Size.line.medium or Size.line.thin
                local frame = FrameContainer:new{
                    background = nil,
                    bordersize = border,
                    color      = is_today and Blitbuffer.COLOR_BLACK or Colors.separator(),
                    radius     = cell_radius,
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

-- Month header with ‹ / › navigation arrows, styled like KOReader's own
-- Statistics CalendarView header (and matching this plugin's own
-- buildYearHeader in insights_view.lua). Returns the header widget plus
-- the tappable arrow frames (nil when hidden), so BookCalendarPopup:onTap
-- can hit-test them the same way it hit-tests day cells.
local function buildBookCalendarHeader(title_str, content_width, section_font, prev_available, next_available)
    local arrow_pad = Size.padding.default

    -- Both arrows always occupy the same fixed-width slot, whether or not
    -- they're actually visible. Without this, a hidden arrow used to
    -- collapse to zero width, which (a) threw the title off-center
    -- whenever only one side had an arrow, since the two slots then had
    -- different widths, and (b) made the whole header jump sideways while
    -- paging, whenever an arrow appeared or disappeared (e.g. hitting the
    -- earliest/latest available month).
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

local BookCalendarPopup = InputContainer:extend{
    modal     = true,
    ui        = nil,
    book_id   = nil,
    total_pages = nil,
    year      = nil,
    month     = nil,
    -- Estimated finish timestamp for this book (stats.finish_timestamp -
    -- see the pace calculation above), or nil if there isn't enough data
    -- yet. When set, forward navigation is allowed up to (and the finish
    -- day is marked within) that month - see _rebuild/_goToMonth below.
    finish_timestamp = nil,
    -- Timestamp of this book's very first recorded reading (stats.started_timestamp
    -- / getBookStartedTimestamp above), or nil if there's no reading data
    -- yet. When set and it falls in the month being rendered, that day
    -- gets marked with a white flag - see start_day/_rebuild below.
    started_timestamp = nil,
}

function BookCalendarPopup:init()
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

function BookCalendarPopup:_rebuild()
    local day_font   = Fonts.getFace("stats_label")
    local small_font = Fonts.getFace("insights_small")

    local box_width     = math.floor(Screen:getWidth() * 0.94)
    local inner_padding = Size.padding.large
    local content_width = box_width - 2 * inner_padding

    local is_hu = (getLangBase() == "hu")
    local title_str = is_hu
        and string.format("%04d. %s", self.year, MONTH_FULL_HU_LC[self.month])
        or  (_(MONTH_FULL[self.month]) .. " " .. tostring(self.year))

    -- Next month is hidden once we're on the current calendar month - UNLESS
    -- this book has an estimated finish date in a later month, in which case
    -- paging is allowed up to that month, so the projected finish day (see
    -- finish_day below) is actually reachable. Same bound _goToMonth
    -- enforces for swipe/key navigation.
    local now = os.date("*t")
    local max_year, max_month = now.year, now.month
    local finish_year, finish_month, finish_day_of_month
    if self.finish_timestamp then
        local ft = os.date("*t", self.finish_timestamp)
        finish_year, finish_month, finish_day_of_month = ft.year, ft.month, ft.day
        if monthIsAfter(finish_year, finish_month, max_year, max_month) then
            max_year, max_month = finish_year, finish_month
        end
    end
    local next_available = monthIsAfter(max_year, max_month, self.year, self.month)

    -- Only pass finish_day through when the finish date actually falls in
    -- the month currently being rendered.
    local finish_day = (finish_year == self.year and finish_month == self.month)
        and finish_day_of_month or nil

    -- Same filtering for the started date's day-of-month - only passed
    -- through to the grid when it falls in the month currently rendered.
    local start_year, start_month, start_day_of_month
    if self.started_timestamp then
        local st = os.date("*t", self.started_timestamp)
        start_year, start_month, start_day_of_month = st.year, st.month, st.day
    end
    local start_day = (start_year == self.year and start_month == self.month)
        and start_day_of_month or nil

    -- Previous month is hidden if this book has no reading recorded there
    -- (same bound _goToMonth enforces for swipe/key navigation), so the
    -- calendar can't be paged back into empty months.
    local prev_month, prev_year = self.month - 1, self.year
    if prev_month < 1 then prev_month = 12; prev_year = prev_year - 1 end
    local prev_available = CalendarData.bookCalendarMonthHasData(self.book_id, prev_year, prev_month)

    local title_row, left_arrow_frame, right_arrow_frame, left_w, right_w, header_h = buildBookCalendarHeader(
        title_str, content_width, Fonts.getFace("stats_section"), prev_available, next_available)

    local daily_map = CalendarData.getBookDailyStatsForMonth(self.book_id, self.year, self.month)
    local cumulative_ratios = CalendarData.getBookCumulativeProgressForMonth(
        self.book_id, self.year, self.month, self.total_pages)
    local grid, day_cells = buildBookCalendarGrid(
        daily_map, self.year, self.month, day_font, small_font, content_width, self.total_pages, cumulative_ratios,
        finish_day, start_day)
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

    -- Absolute tap zones for the ‹ / › arrows, computed from geometry
    -- rather than from left_arrow_frame.dimen/right_arrow_frame.dimen (see
    -- comment above this function for why the latter can be stale/unset
    -- when this popup is opened from inside the stats popup instead of
    -- directly from the menu/gesture).
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

function BookCalendarPopup:_centeredRect(widget)
    local size = widget:getSize()
    local w, h = size.w, size.h
    local x = self.dimen.x + math.floor((self.dimen.w - w) / 2)
    local y = self.dimen.y + math.floor((self.dimen.h - h) / 2)
    return Geom:new{ x = x, y = y, w = w, h = h }
end

function BookCalendarPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self:_centeredRect(self.box_content)
    end)
    return true
end

function BookCalendarPopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self:_centeredRect(self.box_content)
    end)
end

function BookCalendarPopup:_showDayDetail(day, data)
    local t = os.time{ year = self.year, month = self.month, day = day, hour = 12 }
    local date_str = Locale.formatDateFromTS(t)

    if not data or (not data.pages or data.pages == 0) then
        UIManager:show(InfoMessage:new{ text = date_str .. "\n" .. _("No reading on this day.") })
        return
    end

    local pages_line = "+" .. formatCount(data.pages) .. " " .. N_("page", "pages", data.pages)
    local time_td     = Locale.formatTimeHHMM(data.duration)
    local time_line   = time_td.value .. (time_td.unit ~= "" and (" " .. time_td.unit) or "")
    local percent_line = ""
    if self.total_pages and self.total_pages > 0 then
        local percent = Math.round(100 * data.pages / self.total_pages)
        percent_line = "+" .. formatCount(percent) .. "%"
    end

    UIManager:show(InfoMessage:new{
        text = date_str .. "\n" .. pages_line .. " · " .. percent_line .. " · " .. time_line,
    })
end

function BookCalendarPopup:_goToMonth(delta)
    local m = self.month + delta
    local y = self.year
    while m < 1 do m = m + 12; y = y - 1 end
    while m > 12 do m = m - 12; y = y + 1 end
    -- Don't navigate past the current calendar month - unless this book's
    -- estimated finish date falls in a later month, matching the arrow
    -- availability computed in _rebuild.
    local now = os.date("*t")
    local max_year, max_month = now.year, now.month
    if self.finish_timestamp then
        local ft = os.date("*t", self.finish_timestamp)
        if monthIsAfter(ft.year, ft.month, max_year, max_month) then
            max_year, max_month = ft.year, ft.month
        end
    end
    if monthIsAfter(y, m, max_year, max_month) then return true end
    -- Don't navigate back into a month with no reading recorded for this book.
    if delta < 0 and not CalendarData.bookCalendarMonthHasData(self.book_id, y, m) then return true end

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
    return true
end

function BookCalendarPopup:onTap(arg, ges_ev)
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
                self:_showDayDetail(cell.day, cell.data)
                return true
            end
        end
    end
    UIManager:close(self)
    return true
end

function BookCalendarPopup:onSwipe(arg, ges_ev)
    if not ges_ev then UIManager:close(self) return true end
    local dir = ges_ev.direction
    if dir == "west" or dir == "left"  then return self:_goToMonth(1)  end
    if dir == "east" or dir == "right" then return self:_goToMonth(-1) end
    UIManager:close(self)
    return true
end

function BookCalendarPopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:_goToMonth(1)  end
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:_goToMonth(-1) end
    UIManager:close(self)
    return true
end

-- ---------------------------------------------------------------------
-- Module entry point + exports.
-- ---------------------------------------------------------------------
local M = {}

M.Popup = BookCalendarPopup

-- Book-calendar cell content setting, reached from main.lua's Advanced
-- settings submenu.
M.readCalendarCellModeSetting  = readCalendarCellModeSetting
M.saveCalendarCellModeSetting  = saveCalendarCellModeSetting
M.DEFAULT_CALENDAR_CELL_MODE   = DEFAULT_CALENDAR_CELL_MODE

--[[
Open the Book progress calendar. Single funnel for both entry paths.

opts:
  ui                (required) the ReaderUI
  book_id           optional; defaults to ui.statistics.id_curr_book
  total_pages       optional; computed from the live book position if absent
  year, month       optional; defaults to the book's last-read month, else now
  started_timestamp optional; looked up from the DB if absent
  finish_timestamp  optional; enables forward paging up to the finish month
  on_close          optional; called after the calendar is dismissed (used
                    by the stats popup to reopen itself)

Returns the popup, or nil if there's no usable book/reading data (in which
case an InfoMessage is shown).
]]--
function M.show(opts)
    opts = opts or {}
    local ui = opts.ui
    if not ui then return end

    local stats_plugin = ui.statistics
    local book_id = opts.book_id or (stats_plugin and stats_plugin.id_curr_book)
    if not book_id then
        UIManager:show(InfoMessage:new{ text = _("No reading data for this book yet.") })
        return
    end

    local total_pages = opts.total_pages
    if not total_pages then
        local _current, total = BookProgress.counts(ui)
        total_pages = total
    end
    if not total_pages or total_pages <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No reading data for this book yet.") })
        return
    end

    local open_year, open_month = opts.year, opts.month
    if not open_year or not open_month then
        open_year, open_month = CalendarData.getBookLastReadYearMonth(book_id)
        if not open_year or not open_month then
            local now = os.date("*t")
            open_year, open_month = now.year, now.month
        end
    end

    local started_timestamp = opts.started_timestamp
    if started_timestamp == nil then
        started_timestamp = CalendarData.getBookStartedTimestamp(book_id)
    end

    local popup = BookCalendarPopup:new{
        ui                = ui,
        book_id           = book_id,
        total_pages       = total_pages,
        year              = open_year,
        month             = open_month,
        finish_timestamp  = opts.finish_timestamp,
        started_timestamp = started_timestamp,
    }

    if opts.on_close then
        local orig_onCloseWidget = popup.onCloseWidget
        popup.onCloseWidget = function(self_popup, ...)
            if orig_onCloseWidget then orig_onCloseWidget(self_popup, ...) end
            opts.on_close()
        end
    end

    UIManager:show(popup)
    return popup
end

return M
