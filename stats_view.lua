--[[
Reading Stats Popup (view module)
Based on: https://github.com/quanganhdo/koreader-user-patches/blob/main/2-reading-stats-popup.lua

Compact overlay displayed while reading that shows live statistics for the
current book, queried from KOReader's statistics plugin and SQLite database.
This is the plugin's second view; see main.lua for how it is wired up
(Tools menu entry, gesture/dispatcher action, and the book-view-only
restriction) and insights_view.lua for the other view (full-screen reading
history popup).

Loaded by main.lua via loadfile(...)( L10N ) -- L10N is the shared
translation/number-formatting module (l10n.lua), passed in as the sole
chunk argument, so both views translate from the same l10n/<lang>.po files
instead of each keeping a separate hard-coded translation table.

Sections shown:
  - This chapter / Next chapter   estimated time left and time to read next
                                   chapter (tap to switch to pages left /
                                   next chapter's page count; tap again to
                                   switch back)
  - This book                     progress percentage, pages read, time spent, time left
  - Chapter bar                   visual bar chart of all chapters (tappable, swipeable)
  - Pace                          today's reading time and pages-per-minute rate

Controls:
  - Tap anywhere              dismiss
  - Tap "This chapter" row    toggle between reading time left and pages left
  - Swipe left/right          navigate the chapter bar
]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Math = require("optmath")
local OverlapGroup = require("ui/widget/overlapgroup")
local SQ3 = require("lua-ljsqlite3/init")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen

-- Shared translations/number-formatting, and shared chart/text color
-- settings, both passed in as this chunk's arguments by main.lua (see the
-- header comment above).
local L10N, Colors, Fonts = ...
local _            = L10N._
local N_           = L10N.N_
local getLangBase  = L10N.getLangBase
local formatNumber = L10N.formatNumber
local formatCount  = L10N.formatCount

-- Chapter-bar height setting (Settings ▸ "Oszlopdiagram magassága" /
-- "Bar chart height" ▸ "Book progress: Fejezetek"). Same "points" value
-- previously hardcoded into Screen:scaleBySize(46) below; restoring the
-- default reproduces the exact original look.
local SETTINGS_KEY_CHAPTER_BAR_HEIGHT = "reading_insights_chapter_bar_height"
local DEFAULT_CHAPTER_BAR_HEIGHT      = 46

local function readChapterBarHeightSetting()
    if G_reader_settings and G_reader_settings.readSetting then
        local v = G_reader_settings:readSetting(SETTINGS_KEY_CHAPTER_BAR_HEIGHT)
        if v == nil then return DEFAULT_CHAPTER_BAR_HEIGHT end
        return v
    end
    return DEFAULT_CHAPTER_BAR_HEIGHT
end

local function saveChapterBarHeightSetting(value)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(SETTINGS_KEY_CHAPTER_BAR_HEIGHT, value)
    end
end

-- Book-calendar cell content setting (Settings ▸ Advanced settings ▸
-- "Book calendar cell content" / "Könyv naptár cella tartalma"). Controls
-- what the small text line under each day number in the per-book reading
-- calendar shows - see buildBookCalendarCellText below for the exact
-- formatting:
--   "percent" (default) - cumulative progress, e.g. "+13%"
--   "pages"             - that day's own page count, e.g. "+101o"
--   "time"              - that day's own time spent, honoring KOReader's
--                          global "Duration format" setting
local SETTINGS_KEY_CALENDAR_CELL_MODE = "reading_insights_calendar_cell_mode"
local DEFAULT_CALENDAR_CELL_MODE      = "percent"

local function readCalendarCellModeSetting()
    if G_reader_settings and G_reader_settings.readSetting then
        local v = G_reader_settings:readSetting(SETTINGS_KEY_CALENDAR_CELL_MODE)
        if v == nil then return DEFAULT_CALENDAR_CELL_MODE end
        return v
    end
    return DEFAULT_CALENDAR_CELL_MODE
end

local function saveCalendarCellModeSetting(mode)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(SETTINGS_KEY_CALENDAR_CELL_MODE, mode)
    end
end

local stats_db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local function emptyValue()
    return { value = "", unit = "" }
end

local function formatFraction(numerator, denominator)
    return string.format("%s / %s", formatCount(numerator), formatCount(denominator))
end
-- Format "(N days left)" suffix for the finish date (translatable).
local function formatDaysLeftSuffix(days_left)
    if not days_left or days_left < 0 then return "" end
    return " " .. string.format(
        N_("(%d day left)", "(%d days left)", days_left),
        days_left
    )
end

-- Weekday names (os.date("*t").wday: 1=Sunday .. 7=Saturday) a "kezdve" /
-- "várható befejezés" felugró dátumsorokhoz. Nem magyar nyelveknél _()-n
-- keresztül fordítva; magyarnál a lenti kisbetűs alakok kellenek, mert a
-- teljes dátum után a nap neve kisbetűvel áll ("2026.06.24. szerda").
local WEEKDAY_NAMES = {
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
}
local WEEKDAY_NAMES_HU_LC = {
    "vasárnap", "hétfő", "kedd", "szerda", "csütörtök", "péntek", "szombat",
}

-- Short weekday/month labels for the per-book reading calendar (see
-- BookCalendarPopup below). "Sun".."Sat" and "Jan".."Dec" are already
-- translated in l10n/<lang>.po (reused from elsewhere in the plugin), so
-- no new translation strings are needed for these.
local WEEKDAY_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

-- Full month names for the per-book reading calendar's header (see
-- BookCalendarPopup below). These are translated via l10n/<lang>.po like
-- everything else - note the trailing space on "May " below, which mirrors
-- the .po files and disambiguates the month name from the modal verb "May".
local MONTH_FULL = {
    "January", "February", "March", "April", "May ", "June",
    "July", "August", "September", "October", "November", "December",
}
local MONTH_FULL_HU_LC = {
    "január", "február", "március", "április", "május", "június",
    "július", "augusztus", "szeptember", "október", "november", "december",
}

-- Same settings key insights_view.lua's heatmap grid uses for its own
-- week-start-day setting, so both calendars in the plugin agree on
-- Monday- vs Sunday-first weeks without needing a second setting.
local SETTINGS_KEY_WEEK_START = "reading_insights_heatmap_week_start"

local function bookCalendarWeekStartWday()
    local start = "monday"
    if G_reader_settings and G_reader_settings.readSetting then
        start = G_reader_settings:readSetting(SETTINGS_KEY_WEEK_START) or "monday"
    end
    return start == "sunday" and 0 or 1 -- 0=Sun, 1=Mon (matches os.date("*t").wday - 1)
end

local function formatEventDateTime(timestamp)
    if not timestamp then return "" end
    local t   = os.date("*t", timestamp)
    local now = os.date("*t")

    local function midnight(tt)
        return os.time{ year = tt.year, month = tt.month, day = tt.day, hour = 0, min = 0, sec = 0 }
    end
    local day_diff = math.floor((midnight(t) - midnight(now)) / 86400 + 0.5)

    if day_diff == 0  then return _("Today") end
    if day_diff == -1 then return _("Yesterday") end
    if day_diff == 1  then return _("Tomorrow") end

    local function mondayOf(tt)
        local days_since_monday = (tt.wday + 5) % 7  -- tt.wday: 1=Sun..7=Sat
        return os.time{ year = tt.year, month = tt.month, day = tt.day - days_since_monday,
                        hour = 0, min = 0, sec = 0 }
    end
    local same_week = mondayOf(t) == mondayOf(now)
    local is_hu = (getLangBase() == "hu")

    if same_week then
        return _(WEEKDAY_NAMES[t.wday])
    end

    if is_hu then
        return os.date("%Y.%m.%d.", timestamp) .. " " .. WEEKDAY_NAMES_HU_LC[t.wday]
    end
    return _(WEEKDAY_NAMES[t.wday]) .. ", " .. os.date("%d/%m/%Y", timestamp)
end

local function tappableWrap(widget, width)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        dimen      = Geom:new{ w = width, h = widget:getSize().h },
        widget,
    }
end

-- Format seconds as a clock-style duration honouring KOReader's global
-- "duration_format" setting (classic "1:30", modern "1h30'", ...) - see
-- L10N.formatDuration() in l10n.lua for details.
-- Returns { value = "<formatted>", unit = "" } so it fits the buildValueLine API.
-- When the "24h+ as days" setting is on and the duration crosses a day,
-- L10N.formatDurationParts() splits the trailing "day"/"nap" word into
-- `unit`, so buildValueLine renders it in the plain label style instead of
-- bolding it along with the number.
local function formatTimeHHMM(seconds)
    if not seconds or seconds ~= seconds then
        return emptyValue()
    end
    return L10N.formatDurationParts(seconds, true)
end

local function dayCountLabel(kind, unit, count)
    if kind == "reading" then
        if unit == "week"  then return N_("week reading",  "weeks reading",  count) end
        if unit == "month" then return N_("month reading", "months reading", count) end
        return N_("day reading", "days reading", count)
    elseif kind == "to_go" then
        if unit == "week"  then return N_("week to go",  "weeks to go",  count) end
        if unit == "month" then return N_("month to go", "months to go", count) end
        return N_("day to go", "days to go", count)
    end
    return ""
end

local function humanizeDayCount(days, kind)
    local count = tonumber(days) or 0
    local unit = "day"
    if count >= 60 then
        unit = "month"
        count = math.floor((count + 15) / 30)
    elseif count >= 14 then
        unit = "week"
        count = math.floor((count + 3) / 7)
    end
    if count < 0 then count = 0 end
    return { value = formatCount(count), unit = dayCountLabel(kind, unit, count) }
end

-- Single DB connection, all stats fetched at once.
local function getBookAndTodayStats(book_id)
    if not book_id then return nil, nil, nil, nil, nil, nil, nil end

    local conn = SQ3.open(stats_db_path)
    if not conn then return nil, nil, nil, nil, nil, nil, nil end

    local days_sql = string.format([[
        SELECT count(*)
        FROM (
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates
            FROM   page_stat
            WHERE  id_book = %d
            GROUP  BY dates
        );
    ]], book_id)
    local total_days = conn:rowexec(days_sql)
    total_days = total_days and tonumber(total_days) or nil

    local today_book_sql = string.format([[
        SELECT count(*), sum(duration)
        FROM (
            SELECT page, sum(duration) AS duration
            FROM   page_stat
            WHERE  strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime')
                   = strftime('%%Y-%%m-%%d', 'now', 'localtime')
            AND    id_book = %d
            GROUP  BY page
        );
    ]], book_id)
    local today_pages, today_time = conn:rowexec(today_book_sql)
    today_pages = tonumber(today_pages)
    today_time  = tonumber(today_time)

    local today_all_sql = [[
        SELECT count(*), sum(duration)
        FROM (
            SELECT page, sum(duration) AS duration
            FROM   page_stat
            WHERE  strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')
                   = strftime('%Y-%m-%d', 'now', 'localtime')
            GROUP  BY id_book, page
        );
    ]]
    local today_pages_all, today_time_all = conn:rowexec(today_all_sql)
    today_pages_all = tonumber(today_pages_all)
    today_time_all  = tonumber(today_time_all)

    -- Days elapsed since this book's very first page_stat entry (i.e. since
    -- reading it was started). Used for the "N days since started" cell.
    local first_read_sql = string.format([[
        SELECT start_time,
               CAST(julianday('now', 'localtime')
                    - julianday(date(start_time, 'unixepoch', 'localtime')) AS INTEGER)
        FROM   page_stat
        WHERE  id_book = %d
        ORDER  BY start_time ASC
        LIMIT  1
    ]], book_id)
    local started_timestamp, days_since_start = conn:rowexec(first_read_sql)
    started_timestamp = started_timestamp and tonumber(started_timestamp) or nil
    days_since_start  = days_since_start  and tonumber(days_since_start)  or nil

    conn:close()
    return total_days, today_pages, today_time, today_pages_all, today_time_all, days_since_start, started_timestamp
end

-- Per-day reading data for one book, for one calendar month (year/month
-- as numbers, e.g. 2026, 7). Returns:
--   daily_map    { [day_of_month] = { pages = N, duration = seconds } }
--   max_duration the largest single day's duration in the month (for
--                scaling the heatmap cell colors - 0 if no reading at all)
-- "pages" is the count of distinct pages of *this* book turned that day
-- (same definition as the "This book" / "Pace" sections above), so it
-- matches what the rest of the popup already calls a book's page count.
local function getBookDailyStatsForMonth(book_id, year, month)
    local daily_map = {}
    if not book_id then return daily_map, 0 end

    local conn = SQ3.open(stats_db_path)
    if not conn then return daily_map, 0 end

    local year_month = string.format("%04d-%02d", year, month)
    local sql = string.format([[
        SELECT day, count(*), sum(duration)
        FROM (
            SELECT strftime('%%d', start_time, 'unixepoch', 'localtime') AS day,
                   page,
                   sum(duration) AS duration
            FROM   page_stat
            WHERE  id_book = %d
            AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
            GROUP  BY day, page
        )
        GROUP BY day
        ORDER BY day;
    ]], book_id, year_month)

    local max_duration = 0
    local ok, stmt = pcall(function() return conn:prepare(sql) end)
    if ok and stmt then
        for row in stmt:rows() do
            local day      = tonumber(row[1])
            local pages    = tonumber(row[2]) or 0
            local duration = tonumber(row[3]) or 0
            if day then
                daily_map[day] = { pages = pages, duration = duration }
                if duration > max_duration then max_duration = duration end
            end
        end
        stmt:close()
    end

    conn:close()
    return daily_map, max_duration
end

-- Year/month of this book's most recent page_stat entry - used so the
-- reading calendar (see BookCalendarPopup) opens on the month the person
-- actually last read in, instead of always today's month. Falls back to
-- nil, nil (caller uses today) if the book has no recorded reading yet.
local function getBookLastReadYearMonth(book_id)
    if not book_id then return nil, nil end
    local conn = SQ3.open(stats_db_path)
    if not conn then return nil, nil end

    local sql = string.format([[
        SELECT strftime('%%Y', start_time, 'unixepoch', 'localtime'),
               strftime('%%m', start_time, 'unixepoch', 'localtime')
        FROM   page_stat
        WHERE  id_book = %d
        ORDER  BY start_time DESC
        LIMIT  1
    ]], book_id)
    local y, m = conn:rowexec(sql)
    conn:close()
    if not y or not m then return nil, nil end
    return tonumber(y), tonumber(m)
end

-- Whether this book has any page_stat entry in the given year/month - used
-- to stop the reading calendar from paging back into months with nothing
-- to show (see BookCalendarPopup:_goToMonth and the header's left arrow).
local function bookCalendarMonthHasData(book_id, year, month)
    if not book_id then return false end
    local conn = SQ3.open(stats_db_path)
    if not conn then return false end

    local year_month = string.format("%04d-%02d", year, month)
    local sql = string.format([[
        SELECT EXISTS(
            SELECT 1 FROM page_stat
            WHERE  id_book = %d
            AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
            LIMIT  1
        );
    ]], book_id, year_month)
    local exists = conn:rowexec(sql)
    conn:close()
    return tonumber(exists) == 1
end

-- TOC cache: single entry keyed by book_id, validated against total page count.
local _toc_cache     = {}   -- [book_id] = entry table, or false on parse failure
local _toc_cache_key = nil  -- book_id of the single cached entry

-- Shared helper: current chapter index + progress ratio from a resolved TOC entry.
local function computeChapterResult(toc_items, items_are_tables, total_chapters, page_counts, pageno)
    local current_chapter = 0
    if items_are_tables then
        for i = total_chapters, 1, -1 do
            if toc_items[i].page <= pageno then
                current_chapter = i
                break
            end
        end
    else
        for i = total_chapters, 1, -1 do
            if toc_items[i] <= pageno then
                current_chapter = i
                break
            end
        end
    end
    if current_chapter == 0 then current_chapter = 1 end

    local chapter_progress_ratio = 0.0
    local cur_pc = (page_counts or {})[current_chapter] or 1
    if cur_pc > 0 then
        local cur_start = items_are_tables
            and toc_items[current_chapter].page
            or  toc_items[current_chapter]
        local pages_read_in_chapter = math.max(0, pageno - cur_start) + 0.5
        chapter_progress_ratio = math.min(0.95, pages_read_in_chapter / cur_pc)
    end

    return {
        current                = current_chapter,
        total                  = total_chapters,
        page_counts            = page_counts,
        chapter_progress_ratio = chapter_progress_ratio,
    }
end

local function getCachedChapterInfo(book_id, toc, pages, pageno)
    if not book_id then return nil end

    -- explicit cache-hit / miss / invalidate branches
    local cached = _toc_cache[book_id]
    if cached == false then
        return nil
    elseif cached ~= nil then
        if cached._pages ~= pages then
            _toc_cache[book_id] = nil
            _toc_cache_key      = nil
        else
            return computeChapterResult(
                cached._toc_items,
                cached._items_are_tables,
                cached._total,
                cached._page_counts,
                pageno
            )
        end
    end

    -- Cache miss: parse TOC and store (at most 1 entry).
    local chapter_info = nil
    local ok = pcall(function()
        local toc_items = nil

        if toc.getToc and type(toc.getToc) == "function" then
            local raw = toc:getToc()
            if raw and #raw > 0 then
                local chapter_entries = {}
                local has_depth = raw[1] and raw[1].depth ~= nil
                for _, entry in ipairs(raw) do
                    if not has_depth or (entry.depth or 1) == 1 then
                        table.insert(chapter_entries, entry)
                    end
                end
                if #chapter_entries == 0 then chapter_entries = raw end
                toc_items = chapter_entries
            end
        end

        if not toc_items and toc.toc_ticks and #toc.toc_ticks > 0 then
            toc_items = toc.toc_ticks
        end
        if not toc_items and toc.toc and type(toc.toc) == "table" and #toc.toc > 0 then
            toc_items = toc.toc
        end

        if not toc_items or #toc_items == 0 then return end

        local total_chapters   = #toc_items
        local page_counts      = {}
        local items_are_tables = type(toc_items[1]) == "table" and toc_items[1].page ~= nil

        if items_are_tables then
            for i = 1, total_chapters do
                local start_p = toc_items[i].page
                local end_p   = (i < total_chapters) and (toc_items[i + 1].page - 1) or pages
                page_counts[i] = math.max(1, end_p - start_p + 1)
            end
        elseif type(toc_items[1]) == "number" then
            for i = 1, total_chapters do
                local start_p = toc_items[i]
                local end_p   = (i < total_chapters) and (toc_items[i + 1] - 1) or pages
                page_counts[i] = math.max(1, end_p - start_p + 1)
            end
        else
            return  -- unknown TOC format
        end

        -- evict previous entry before storing the new one
        if _toc_cache_key and _toc_cache_key ~= book_id then
            _toc_cache[_toc_cache_key] = nil
        end
        _toc_cache[book_id] = {
            _toc_items        = toc_items,
            _items_are_tables = items_are_tables,
            _page_counts      = page_counts,
            _total            = total_chapters,
            _pages            = pages,
        }
        _toc_cache_key = book_id

        chapter_info = computeChapterResult(
            toc_items, items_are_tables, total_chapters, page_counts, pageno
        )
    end)

    if not ok or not chapter_info then
        _toc_cache[book_id] = false
        return nil
    end

    return chapter_info
end

local function getChapterPagesLeft(ui, pageno)
    if not ui or not ui.toc then return end
    local pages_left = ui.toc:getChapterPagesLeft(pageno, true)
    if pages_left == nil and ui.document then
        pages_left = ui.document:getTotalPagesLeft(pageno)
    end
    return pages_left
end

local function getBookProgressData(ui)
    if not ui or not ui.document then return end
    local current_page = ui:getCurrentPage()
    local total_pages  = ui.document:getPageCount()
    if not current_page or not total_pages or total_pages == 0 then return end

    local pagemap = ui.pagemap and ui.pagemap:wantsPageLabels()
    local current_page_idx
    local total_pages_idx
    if pagemap then
        local _, page_idx, pages_idx = ui.pagemap:getCurrentPageLabel()
        current_page_idx = page_idx
        total_pages_idx  = pages_idx
    elseif ui.document:hasHiddenFlows() then
        local flow = ui.document:getPageFlow(current_page)
        current_page = ui.document:getPageNumberInFlow(current_page)
        total_pages  = ui.document:getTotalPagesInFlow(flow)
    end

    return {
        current_page     = current_page,
        total_pages      = total_pages,
        current_page_idx = current_page_idx,
        total_pages_idx  = total_pages_idx,
        pagemap          = pagemap,
    }
end

local function getBookPagesLeft(ui)
    local progress = getBookProgressData(ui)
    if not progress then return end
    return progress.total_pages - progress.current_page
end

local function getBookProgressPercent(ui)
    local progress = getBookProgressData(ui)
    if not progress then return end
    if progress.pagemap and progress.current_page_idx and progress.total_pages_idx and progress.total_pages_idx > 0 then
        return Math.round(100 * progress.current_page_idx / progress.total_pages_idx)
    end
    return Math.round(100 * progress.current_page / progress.total_pages)
end

local function getBookProgressCounts(ui)
    local progress = getBookProgressData(ui)
    if not progress then return end
    if progress.pagemap and progress.current_page_idx and progress.total_pages_idx and progress.total_pages_idx > 0 then
        return progress.current_page_idx, progress.total_pages_idx
    end
    return progress.current_page, progress.total_pages
end

-- Font faces for this popup's three text roles, sourced from the shared
-- Fonts settings module (see fonts.lua) so they're user-configurable via
-- the "Fonts" Tools-menu entry, the same way Colors.* works for colors.
-- Rebuilt fresh on every popup init (like before), so a just-changed font
-- setting is always picked up on the next open.
local function buildSerifFonts()
    return {
        section = Fonts.getFace("stats_section"),
        value   = Fonts.getFace("stats_value"),
        label   = Fonts.getFace("stats_label"),
    }
end

local function buildLayout(screen_w, padding_h, column_gap)
    local separator_width = 2 * column_gap + Size.line.medium
    local col_width = math.floor((screen_w - 2 * padding_h - separator_width) / 2)
    return {
        full_width    = screen_w,
        padding_h     = padding_h,
        column_gap    = column_gap,
        separator_width = separator_width,
        col_width     = col_width,
    }
end

local function buildColumnSeparator(column_gap, height)
    local v_padding = Size.padding.default
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = column_gap },
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ height = v_padding },
            Colors.newBar(Size.line.medium, height - 2 * v_padding, Colors.separator()),
            VerticalSpan:new{ height = v_padding },
        },
        HorizontalSpan:new{ width = column_gap },
    }
end

-- No radius, left-aligned text with padding_left; width comes from parent.
local function buildSectionHeader(font_section, text, width, left_padding)
    left_padding = left_padding or Size.padding.large
    local text_widget = TextWidget:new{ text = text, face = font_section, fgcolor = Colors.section() }
    return FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = left_padding,
        padding_right  = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = width - left_padding, h = text_widget:getSize().h },
            text_widget,
        },
    }
end

local function buildValueLine(font_value, font_label, col_width, time_data, label)
    if time_data.value == "" then
        return TextBoxWidget:new{
            text      = time_data.unit,
            face      = font_label,
            fgcolor   = Colors.label(),
            width     = col_width,
            alignment = "left",
        }
    end

    local desc = time_data.unit
    if label and label ~= "" then
        if desc ~= "" then
            desc = desc .. " " .. label
        else
            desc = label
        end
    end
    local value_widget    = TextWidget:new{ text = time_data.value, face = font_value, fgcolor = Colors.value() }
    local value_width     = value_widget:getSize().w
    local text_desc_width = col_width - value_width - Size.padding.large
    if text_desc_width <= 0 then
        return VerticalGroup:new{
            align = "left",
            value_widget,
            TextBoxWidget:new{
                text      = desc,
                face      = font_label,
                fgcolor   = Colors.label(),
                width     = col_width,
                alignment = "left",
            },
        }
    end
    return HorizontalGroup:new{
        align = "center",
        value_widget,
        HorizontalSpan:new{ width = Size.padding.large },
        TextBoxWidget:new{
            text      = desc,
            face      = font_label,
            fgcolor   = Colors.label(),
            width     = text_desc_width,
            alignment = "left",
        },
    }
end

local function fixedCol(widget, width, height)
    height = height or widget:getSize().h
    return LeftContainer:new{
        dimen  = Geom:new{ w = width, h = height },
        widget,
    }
end

local function padded(padding_h, widget)
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = padding_h },
        widget,
    }
end

local function buildTwoColRow(left_widget, right_widget, layout, hide_separator)
    local left_h   = left_widget:getSize().h
    local right_h  = right_widget:getSize().h
    local row_height = math.max(left_h, right_h)
    local separator = hide_separator
        and HorizontalSpan:new{ width = layout.separator_width }
        or  buildColumnSeparator(layout.column_gap, row_height)
    return HorizontalGroup:new{
        align = "center",
        fixedCol(left_widget,  layout.col_width, row_height),
        separator,
        fixedCol(right_widget, layout.col_width, row_height),
    }
end

-- Two buildSectionHeader widgets in a HorizontalGroup.
-- When show_next is false (no next chapter), the "Next chapter" label is
-- omitted, leaving that side blank instead of showing a misleading header.
local function buildChapterHeaders(font_section, layout, show_next)
    local left_width          = layout.padding_h + layout.col_width + math.floor(layout.separator_width / 2)
    local right_width         = layout.full_width - left_width
    local next_chapter_padding = math.ceil(layout.separator_width / 2)
    local next_chapter_text = show_next and _("Next chapter") or ""
    return HorizontalGroup:new{
        align = "center",
        buildSectionHeader(font_section, _("This chapter"), left_width),
        buildSectionHeader(font_section, next_chapter_text, right_width, next_chapter_padding),
    }
end

-- header → span → line → row → span.
local function addSectionWithRow(sections, header_widget, row, layout)
    table.insert(sections, header_widget)
    table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
    table.insert(sections, padded(layout.padding_h,
        Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thin, Colors.separator())))
    table.insert(sections, padded(layout.padding_h, row))
    table.insert(sections, VerticalSpan:new{ height = Size.padding.large })
end

-- Chapter progress bar.
-- Always shows exactly PAGE_SIZE columns per page; empty slots on the last page.
-- Arrows always visible: black = can navigate, gray = cannot.
local CHAPTER_BAR_PAGE_SIZE = 25

local function buildChapterBar(chapter_info, full_width, padding_h, offset_override, on_prev, on_next)
    if not chapter_info or not chapter_info.total or chapter_info.total == 0 then
        return nil
    end

    local total                  = chapter_info.total
    local current                = chapter_info.current or 0
    local page_counts            = chapter_info.page_counts
    local chapter_progress_ratio = chapter_info.chapter_progress_ratio or 0.0

    local col_h_max = Screen:scaleBySize(readChapterBarHeightSetting())

    local max_pages = 0
    if page_counts then
        for i = 1, total do
            local pc = page_counts[i] or 0
            if pc > max_pages then max_pages = pc end
        end
    end

    local function barHeight(ch_idx)
        if page_counts and max_pages > 0 then
            local pc = page_counts[ch_idx] or 0
            return math.max(1, math.floor(1 + (pc / max_pages) * (col_h_max - 1)))
        end
        return col_h_max
    end

    local v_pad      = Size.padding.large
    local arrow_face = Fonts.getFace("stats_arrow")
    local inner_pad  = Size.padding.default

    -- Measure arrow glyph width once; both arrows use the same face so width is identical.
    local arrow_glyph_w = TextWidget:new{ text = "\xe2\x80\xb9", face = arrow_face }:getSize().w
    local slot_w        = arrow_glyph_w + 2 * inner_pad

    -- Available width for exactly PAGE_SIZE columns, after symmetric padding and both arrow slots.
    local avail_w   = full_width - 2 * padding_h - 2 * slot_w
    local col_w     = math.floor(avail_w / CHAPTER_BAR_PAGE_SIZE)
    local remainder = avail_w - col_w * CHAPTER_BAR_PAGE_SIZE  -- extra pixels, absorbed into right padding
    local gap       = math.max(1, math.floor(col_w * 0.15))
    local bar_w     = col_w - gap

    -- offset snaps to PAGE_SIZE pages: 1, 26, 51, …
    local offset = math.max(1, math.min(offset_override or 1, total))

    local can_go_left  = (offset > 1)
    local can_go_right = (offset + CHAPTER_BAR_PAGE_SIZE - 1 < total)
    local left_arrow_color  = can_go_left  and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_E
    local right_arrow_color = can_go_right and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_E

    -- Build exactly PAGE_SIZE slots; slots beyond total are white (empty).
    local bar_row = HorizontalGroup:new{ align = "bottom" }
    for i = 1, CHAPTER_BAR_PAGE_SIZE do
        local ch_idx = offset + i - 1
        if ch_idx <= total then
            local bh = barHeight(ch_idx)
            if ch_idx == current then
                local read_h   = math.max(1, math.floor(bh * chapter_progress_ratio))
                local unread_h = bh - read_h
                table.insert(bar_row, VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ height = col_h_max - bh },
                    unread_h > 0 and Colors.newBar(bar_w, unread_h, Colors.inactiveBar())
                        or VerticalSpan:new{ height = 0 },
                    read_h > 0 and Colors.newBar(bar_w, read_h, Colors.activeBar())
                        or VerticalSpan:new{ height = 0 },
                })
            else
                table.insert(bar_row, VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ height = col_h_max - bh },
                    Colors.newBar(bar_w, bh, ch_idx < current and Colors.activeBar() or Colors.inactiveBar()),
                })
            end
        else
            -- empty slot: same width as a real bar so the total row width stays fixed
            table.insert(bar_row, LineWidget:new{
                dimen      = Geom:new{ w = bar_w, h = col_h_max },
                background = Blitbuffer.COLOR_WHITE,
            })
        end
        if i < CHAPTER_BAR_PAGE_SIZE then
            table.insert(bar_row, LineWidget:new{
                dimen      = Geom:new{ w = gap, h = col_h_max },
                background = Blitbuffer.COLOR_WHITE,
            })
        end
    end

    local function makeArrowSpan(symbol, fgcolor)
        local tw      = TextWidget:new{ text = symbol, face = arrow_face, fgcolor = fgcolor }
        local gh      = tw:getSize().h
        local top_pad = math.floor((col_h_max - gh) / 2)
        return FrameContainer:new{
            background     = nil,
            bordersize     = 0,
            padding_top    = 0,
            padding_bottom = 0,
            padding_left   = 0,
            padding_right  = 0,
            margin         = 0,
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ height = top_pad },
                HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = inner_pad },
                    tw,
                    HorizontalSpan:new{ width = inner_pad },
                },
                VerticalSpan:new{ height = col_h_max - gh - top_pad },
            },
        }
    end

    -- Layout: (padding_h + remainder/2) | left_arrow | [PAGE_SIZE slots] | right_arrow | (padding_h + remainder/2)
    -- The leftover rounding pixels from col_w's floor() are split evenly between
    -- both sides (any odd extra pixel goes to the right) so the empty space
    -- around the two arrows stays visually symmetric.
    local remainder_left  = math.floor(remainder / 2)
    local remainder_right = remainder - remainder_left
    
    local left_arrow_widget  = makeArrowSpan("\xe2\x80\xb9", left_arrow_color)
    local right_arrow_widget = makeArrowSpan("\xe2\x80\xba", right_arrow_color)
    
    local flat_row = HorizontalGroup:new{ align = "center" }
    table.insert(flat_row, HorizontalSpan:new{ width = padding_h + remainder_left })
    table.insert(flat_row, left_arrow_widget)
    table.insert(flat_row, bar_row)
    table.insert(flat_row, right_arrow_widget)
    table.insert(flat_row, HorizontalSpan:new{ width = padding_h + remainder_right })

    local bar_h = col_h_max + 2 * Size.padding.default

    local fixed_bar_row = FrameContainer:new{
        bordersize     = 0,
        padding_top    = Size.padding.default,
        padding_bottom = Size.padding.default,
        padding_left   = 0,
        padding_right  = 0,
        background     = Blitbuffer.COLOR_WHITE,
        dimen          = Geom:new{ w = full_width, h = bar_h },
        flat_row,
    }

    local result = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ height = v_pad },
        fixed_bar_row,
        VerticalSpan:new{ height = v_pad },
    }
    result._on_swipe_left  = can_go_right and on_next or nil
    result._on_swipe_right = can_go_left  and on_prev or nil
    return result, left_arrow_widget, right_arrow_widget, can_go_left, can_go_right
end

-- Main section builder.
local function buildSections(stats, fonts, layout, popup)
    local function valueLine(time_data, label)
        return buildValueLine(fonts.value, fonts.label, layout.col_width, time_data, label)
    end

    -- "This chapter" / "Next chapter" can show either an estimated reading
    -- time (default) or a page count - toggled by tapping the header/value
    -- row (see ReadingStatsPopup:onTapClose). popup._chapter_view_mode is
    -- nil/"time" by default; "pages" once toggled. Tapping again switches
    -- back (see onTapClose).
    local chapter_view_mode = (popup and popup._chapter_view_mode) or "time"
    local chapter_val1, chapter_val2
    if chapter_view_mode == "pages" then
        local na_pages   = { value = "—", unit = "" }
        local left_count = stats.chapter_pages_left_count
        local left_data  = left_count and { value = formatCount(left_count), unit = "" } or na_pages
        local left_label = N_("page left", "pages left", left_count or 0)
        chapter_val1 = valueLine(left_data, left_label)

        local next_count = stats.next_chapter_pages_count
        local next_data  = next_count and { value = formatCount(next_count), unit = "" } or emptyValue()
        local next_label = next_count and N_("page", "pages", next_count) or ""
        chapter_val2 = valueLine(next_data, next_label)
    else
        chapter_val1 = valueLine(stats.chapter_time_left_hhmm, _("reading time left"))
        chapter_val2 = valueLine(stats.next_chapter_time_hhmm, _("reading time"))
    end
    local progress_label  = stats.book_progress.value ~= "" and _("read") or ""
    local book_progress   = valueLine(stats.book_progress, progress_label)
    local book_pages_read = valueLine(stats.book_pages_read, "")
    local book_col1       = valueLine(stats.book_time_spent_hhmm, _("read so far"))
    local book_col2       = valueLine(stats.book_time_left_hhmm, _("reading time left"))
    local avg_day_data    = stats.avg_time_per_day_hhmm or { value = "—:—", unit = "" }
    local pace_col2       = valueLine(avg_day_data, _("avg time/day"))
    local today_time_data_hhmm = popup and popup.today_all_books
        and stats.today_time_all_hhmm
        or  stats.today_time_hhmm

    local zero_hhmm = { value = "00:00", unit = "" }
    local function nonEmpty(td)
        if not td or td.value == "" then return zero_hhmm end
        return td
    end
    local days_col2 = valueLine(nonEmpty(today_time_data_hhmm), _("read today"))

    local chapter_headers_content = buildChapterHeaders(fonts.section, layout, stats.has_next_chapter)
    local chapter_values_content  = buildTwoColRow(chapter_val1, chapter_val2, layout, not stats.has_next_chapter)
    -- Wrapped in tappableWrap (fixed dimen) rather than used raw, so tapping
    -- either row reliably hits (same reasoning as started_tap/finish_tap
    -- below: a bare HorizontalGroup isn't guaranteed a usable .dimen for
    -- hitTest the way a FrameContainer with an explicit dimen is).
    local chapter_headers = tappableWrap(chapter_headers_content, chapter_headers_content:getSize().w)
    local chapter_values  = tappableWrap(chapter_values_content, chapter_values_content:getSize().w)
    if popup then
        popup._chapter_headers = chapter_headers
        popup._chapter_values  = chapter_values
    end
    local book_progress_row = buildTwoColRow(book_progress, book_pages_read, layout)
    local book_progress_tap = book_progress_row
    local book_row          = buildTwoColRow(book_col1, book_col2, layout)
    local pace_row = buildTwoColRow(days_col2, pace_col2, layout)

    local sections = VerticalGroup:new{
        align = "left",
    }

    addSectionWithRow(sections, chapter_headers, chapter_values, layout, true)

    local chapter_on_prev = popup and function()
        popup.chapter_bar_offset = math.max(1, (popup.chapter_bar_offset or 1) - CHAPTER_BAR_PAGE_SIZE)
        popup:_rebuildUI()
    end or nil
    local chapter_on_next = popup and function()
        popup.chapter_bar_offset = math.max(1, (popup.chapter_bar_offset or 1) + CHAPTER_BAR_PAGE_SIZE)
        popup:_rebuildUI()
    end or nil

    local chapter_bar, chapter_left_arrow, chapter_right_arrow, chapter_can_go_left, chapter_can_go_right =
        buildChapterBar(
            stats.chapter_info,
            layout.full_width,
            layout.padding_h,
            popup and popup.chapter_bar_offset or nil,
            chapter_on_prev,
            chapter_on_next
        )
    table.insert(sections, padded(layout.padding_h,
        Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thick, Colors.separator())))
    local this_book_header = buildSectionHeader(fonts.section, _("This book"), layout.full_width)
    if popup then
        popup._this_book_header = this_book_header
    end
    addSectionWithRow(
        sections,
        this_book_header,
        VerticalGroup:new{
            align = "center",
            book_progress_tap,
            VerticalSpan:new{ height = Size.padding.default },
            book_row,
        },
        layout,
        false
    )

    if chapter_bar then
        if popup then
            popup._chapter_bar = chapter_bar
            popup._chapter_bar_prev_arrow = chapter_can_go_left  and chapter_left_arrow  or nil
            popup._chapter_bar_next_arrow = chapter_can_go_right and chapter_right_arrow or nil
            popup._chapter_bar_on_prev    = chapter_on_prev
            popup._chapter_bar_on_next    = chapter_on_next
        end
            table.insert(sections, padded(layout.padding_h,
                Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thin, Colors.separator())))
        table.insert(sections, chapter_bar)
    end
    table.insert(sections, padded(layout.padding_h,
        Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thick, Colors.separator())))
    local pace_header = buildSectionHeader(fonts.section, _("Pace"), layout.full_width)
    if popup then popup._pace_header = pace_header end
    table.insert(sections, pace_header)
    table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
    table.insert(sections, padded(layout.padding_h,
        Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thin, Colors.separator())))
    table.insert(sections, padded(layout.padding_h, pace_row))

    -- Last row: "started N days ago" | "N days of reading left".
    -- The right cell (and the separator to its left) only appears once
    -- there's enough page_stat data to estimate a finish date; the left
    -- cell alone still appears as soon as the book has been opened at all.
    if stats.started_days_ago or stats.finish_days_left then
        local started_widget = stats.started_days_ago
            and valueLine(stats.started_days_ago, "")
            or nil

        if started_widget and stats.finish_days_left then
            local finish_widget = valueLine(
                { value = formatCount(stats.finish_days_left),
                  unit  = N_("day of reading left", "days of reading left", stats.finish_days_left) },
                ""
            )
            local started_tap = tappableWrap(started_widget, layout.col_width)
            local finish_tap  = tappableWrap(finish_widget, layout.col_width)
            if popup then
                popup._started_widget = started_tap
                popup._finish_widget  = finish_tap
            end
            table.insert(sections, VerticalSpan:new{ height = Size.padding.small })
            table.insert(sections, padded(layout.padding_h, buildTwoColRow(started_tap, finish_tap, layout)))
            table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
        elseif started_widget then
            local started_full_widget = buildValueLine(
                fonts.value, fonts.label, layout.full_width - 2 * layout.padding_h,
                stats.started_days_ago, ""
            )
            local started_tap = tappableWrap(started_full_widget, layout.full_width - 2 * layout.padding_h)
            if popup then popup._started_widget = started_tap end
            table.insert(sections, VerticalSpan:new{ height = Size.padding.small })
            table.insert(sections, padded(layout.padding_h, started_tap))
            table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
        elseif stats.finish_days_left then
            local finish_widget = buildValueLine(
                fonts.value, fonts.label, layout.full_width - 2 * layout.padding_h,
                { value = formatCount(stats.finish_days_left),
                  unit  = N_("day of reading left", "days of reading left", stats.finish_days_left) },
                ""
            )
            local finish_tap = tappableWrap(finish_widget, layout.full_width - 2 * layout.padding_h)
            if popup then popup._finish_widget = finish_tap end
            table.insert(sections, VerticalSpan:new{ height = Size.padding.small })
            table.insert(sections, padded(layout.padding_h, finish_tap))
            table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
        end
    end

    table.insert(sections, LineWidget:new{
        dimen      = Geom:new{ w = layout.full_width, h = Size.line.thick },
        background = Blitbuffer.COLOR_BLACK,
    })
    return sections
end

local function hitTest(widget, x, y)
    local d = widget and widget.dimen
    if not d then return false end
    return x >= d.x and x <= d.x + d.w and y >= d.y and y <= d.y + d.h
end

-- Same as hitTest, but grows the widget's box by `pad` on every side before
-- testing. Used for small tap targets - like the ‹ / › paging arrows - where
-- the visible glyph is much smaller than a comfortable finger-sized tap
-- area, without having to make the arrow itself visually bigger.
local function hitTestPadded(widget, x, y, pad)
    local d = widget and widget.dimen
    if not d then return false end
    return x >= d.x - pad and x <= d.x + d.w + pad and y >= d.y - pad and y <= d.y + d.h + pad
end

-- ---------------------------------------------------------------------
-- Reading calendar (per book): tap the "Pace" section title to
-- open a month grid, colored like a heatmap by how long *this* book was
-- read each day; tap a day to see its exact pages/time/percent. Distinct
-- from insights_view.lua's CalendarView integration (openCalendarForMonth
-- there opens KOReader's own, all-books Statistics calendar) - this one
-- is scoped to a single book and built locally, since the stock
-- CalendarView widget has no per-book filter.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------

-- "How far into the book had I gotten, as of the last page I reached on
-- this day" ratio (0..1) - the page from that day's chronologically LAST
-- page_stat entry (i.e. wherever reading actually stopped that day),
-- divided by total_pages. Deliberately NOT the day's highest page
-- reached: some books have an explanatory note/glossary at the very end
-- that readers jump to mid-chapter and then jump back from, which would
-- otherwise make MAX(page) spike to ~100% on a day where the actual
-- reading position was still early in the book. It's also NOT a
-- running/ratchet carried over from other days or earlier months: an
-- earlier attempt at this used a monotonic "highest page ever reached"
-- that never decreased, which meant any day (or whole later month) after
-- the book's highest-ever point stayed pinned there regardless of where
-- that day's reading actually left off (e.g. rereading an earlier
-- chapter, or continuing a book that was skimmed to the end once
-- before) - not what the bar is meant to show.
-- Only returns an entry for days that actually have reading recorded
-- (days with nothing read are left blank).
local function getBookCumulativeProgressForMonth(book_id, year, month, total_pages)
    local ratios = {}
    if not book_id or not total_pages or total_pages <= 0 then return ratios end

    local conn = SQ3.open(stats_db_path)
    if not conn then return ratios end

    local year_month = string.format("%04d-%02d", year, month)

    -- Ordered by start_time ASC so that, as we walk the rows in the loop
    -- below, each day's entry in day_last_page keeps getting overwritten
    -- by later and later entries - the value left after the loop is each
    -- day's chronologically last page, with no separate MAX/window-
    -- function query needed.
    local day_rows_sql = string.format([[
        SELECT strftime('%%d', start_time, 'unixepoch', 'localtime') AS day, page
        FROM   page_stat
        WHERE  id_book = %d
        AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
        ORDER  BY start_time ASC
    ]], book_id, year_month)

    local day_last_page = {}
    local ok, stmt = pcall(function() return conn:prepare(day_rows_sql) end)
    if ok and stmt then
        for row in stmt:rows() do
            local day  = tonumber(row[1])
            local page = tonumber(row[2])
            if day and page then day_last_page[day] = page end
        end
        stmt:close()
    end
    conn:close()

    for day, page in pairs(day_last_page) do
        local ratio = page / total_pages
        if ratio > 1 then ratio = 1 end
        if ratio < 0 then ratio = 0 end
        ratios[day] = ratio
    end

    return ratios
end

-- First letter of the already-translated "page(s)" word, used as a
-- compact unit abbreviation in the calendar cell (see
-- buildBookCalendarCellText below) - stays in the user's language for free
-- since it rides on the existing N_("page","pages",...) translation
-- rather than a separate hardcoded letter.
local function pageAbbrev(count)
    return N_("page", "pages", count):sub(1, 1)
end

-- Small text line shown under the day number in the per-book calendar
-- (see buildBookCalendarGrid below). Honors the "Book calendar cell
-- content" setting (readCalendarCellModeSetting):
--   "percent" (default) - cumulative "+13%" progress through the whole book
--   "pages"             - that day's own page count, e.g. "+101o"
--   "time"              - that day's own time spent, e.g. "+0:23" or
--                          "+23m", whichever clock style KOReader's global
--                          "Duration format" setting (Settings ▸ Time and
--                          date) is set to - see formatTimeHHMM above.
-- Returns "" for days with no reading, in any mode.
local function buildBookCalendarCellText(entry, total_pages)
    if not entry or not entry.pages or entry.pages <= 0 then return "" end

    local mode = readCalendarCellModeSetting()

    if mode == "pages" then
        return "+" .. formatCount(entry.pages) .. pageAbbrev(entry.pages)
    end

    if mode == "time" then
        local time_td = formatTimeHHMM(entry.duration or 0)
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
local function buildBookCalendarGrid(daily_map, year, month, day_font, small_font, content_width, total_pages, cumulative_ratios, finish_day)
    local week_start_wd = bookCalendarWeekStartWday() -- 0=Sun, 1=Mon
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
                if is_finish_day then
                    -- Flag glyph placed immediately to the right of the
                    -- centered day number. The day number is centered in
                    -- cell_w, so its left edge sits at (cell_w - num_w) / 2
                    -- and its right edge at (cell_w + num_w) / 2. We push
                    -- the flag that far right plus a small gap, then overlay
                    -- it at the top of the cell (same vertical start as
                    -- cell_inner inside the CenterContainer).
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

    -- Previous month is hidden if this book has no reading recorded there
    -- (same bound _goToMonth enforces for swipe/key navigation), so the
    -- calendar can't be paged back into empty months.
    local prev_month, prev_year = self.month - 1, self.year
    if prev_month < 1 then prev_month = 12; prev_year = prev_year - 1 end
    local prev_available = bookCalendarMonthHasData(self.book_id, prev_year, prev_month)

    local title_row, left_arrow_frame, right_arrow_frame, left_w, right_w, header_h = buildBookCalendarHeader(
        title_str, content_width, Fonts.getFace("stats_section"), prev_available, next_available)

    local daily_map = getBookDailyStatsForMonth(self.book_id, self.year, self.month)
    local cumulative_ratios = getBookCumulativeProgressForMonth(
        self.book_id, self.year, self.month, self.total_pages)
    local grid, day_cells = buildBookCalendarGrid(
        daily_map, self.year, self.month, day_font, small_font, content_width, self.total_pages, cumulative_ratios,
        finish_day)
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
    local is_hu = (getLangBase() == "hu")
    local date_str = is_hu and os.date("%Y.%m.%d.", t) or os.date("%d/%m/%Y", t)

    if not data or (not data.pages or data.pages == 0) then
        UIManager:show(InfoMessage:new{ text = date_str .. "\n" .. _("No reading on this day.") })
        return
    end

    local pages_line = "+" .. formatCount(data.pages) .. " " .. N_("page", "pages", data.pages)
    local time_td     = formatTimeHHMM(data.duration)
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
    if delta < 0 and not bookCalendarMonthHasData(self.book_id, y, m) then return true end

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
            if hitTest(cell.frame, x, y) then
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

-- Dispatcher action registration for this view lives in main.lua (alongside
-- the "reading_insights_popup" action), so both gesture-assignable actions
-- are declared in one place.

local ReadingStatsPopup = InputContainer:extend{
    modal              = true,
    ui                 = nil,
    width              = nil,
    height             = nil,
    chapter_bar_offset = nil,
    today_all_books    = false,
    _has_book_id       = false,
    _chapter_view_mode = "time",
}

function ReadingStatsPopup:init()
    self.today_all_books = self.today_all_books or false
    self._stats  = self:gatherStats()
    self._fonts  = buildSerifFonts()
    if not self.chapter_bar_offset and self._stats.chapter_info then
        local info = self._stats.chapter_info
        -- Start on the page that contains the current chapter.
        -- Pages are 1, 1+PAGE_SIZE, 1+2*PAGE_SIZE, …
        local page_start = math.floor((info.current - 1) / CHAPTER_BAR_PAGE_SIZE) * CHAPTER_BAR_PAGE_SIZE + 1
        self.chapter_bar_offset = math.max(1, page_start)
    end
    self:_buildUI()
end

-- Full-width popup, bordersize=0, radius=0, VerticalGroup wrapper.
function ReadingStatsPopup:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self._layout   = buildLayout(screen_w, Size.padding.large, Screen:scaleBySize(20))
    local sections = buildSections(self._stats, self._fonts, self._layout, self)

    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        radius     = 0,
        padding    = 0,
        width      = screen_w,
        sections,
    }

    self[1] = VerticalGroup:new{
        self.popup_frame,
    }

    self.dimen = Geom:new{ w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges   = "tap",
                range = self.dimen,
            }
        }
        self.ges_events.Swipe = {
            GestureRange:new{
                ges   = "swipe",
                range = self.dimen,
            }
        }
    end
end

function ReadingStatsPopup:_rebuildUI()
    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
end

function ReadingStatsPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

function ReadingStatsPopup:gatherStats()
    local zero_pages_per_minute = { value = formatCount(0), unit = N_("page per minute", "pages per minute", 0) }
    local zero_days_reading     = humanizeDayCount(0, "reading")
    local zero_days_to_go       = humanizeDayCount(0, "to_go")
    local zero_progress         = { value = formatCount(0) .. "%", unit = "" }
    local zero_pages_read       = { value = formatCount(0), unit = N_("page", "pages", 0) }

    local zero_hhmm = { value = "00:00", unit = "" }
    -- No page_stat/pace data yet to estimate a time value from - shown as
    -- "—:—" rather than the misleading "00:00".
    local na_hhmm = { value = "—:—", unit = "" }
    local stats = {
        chapter_time_left_hhmm = na_hhmm,
        next_chapter_time_hhmm = emptyValue(),
        book_time_left_hhmm    = na_hhmm,
        book_time_spent_hhmm   = zero_hhmm,
        book_progress          = zero_progress,
        book_pages_read        = zero_pages_read,
        avg_time_per_day_hhmm  = na_hhmm,
        pages_per_minute       = zero_pages_per_minute,
        days_reading           = zero_days_reading,
        days_to_go             = zero_days_to_go,
        today_pages            = emptyValue(),
        today_time_hhmm        = zero_hhmm,
        today_pages_all        = emptyValue(),
        today_time_all_hhmm    = zero_hhmm,
        chapter_info           = nil,
        has_next_chapter       = false,
        chapter_pages_left_count = nil,
        next_chapter_pages_count = nil,
    }

    local ui = self.ui
    if not ui then return stats end

    local stats_plugin = ui.statistics
    local toc          = ui.toc
    local doc          = ui.document
    local footer       = ui.view and ui.view.footer

    if stats_plugin then
        stats_plugin:insertDB()
    end

    local pageno = footer and footer.pageno or 1
    local pages  = footer and footer.pages  or 1

    local progress_percent = getBookProgressPercent(ui)
    if progress_percent then
        stats.book_progress = { value = formatCount(progress_percent) .. "%", unit = "" }
    end
    local current_page_count, total_page_count = getBookProgressCounts(ui)
    if current_page_count and total_page_count and total_page_count > 0 then
        stats.book_pages_read = {
            value = formatFraction(current_page_count, total_page_count),
            unit  = N_("page", "pages", current_page_count),
        }
        -- Kept separately (not just parsed back out of book_pages_read)
        -- for the reading calendar (see openBookCalendar below), which
        -- needs the raw total to turn a day's page count into a percent.
        stats.total_pages_for_calendar = total_page_count
    end

    local avg_time  = stats_plugin and stats_plugin.avg_time
    local has_stats = avg_time and avg_time == avg_time

    local pages_left = nil

    -- Whether a next chapter exists is independent of has_stats (pace data).
    -- If it exists but we can't compute its time yet, show "—:—" instead of
    -- leaving it blank (blank is reserved for "no next chapter at all", and
    -- drives hiding the "Next chapter" header/separator in buildSections).
    local next_chapter_start = toc and toc:getNextChapter(pageno)
    if next_chapter_start then
        stats.has_next_chapter        = true
        stats.next_chapter_time_hhmm  = na_hhmm
    end

    -- Page counts (chapter_pages_left_count / next_chapter_pages_count) are
    -- computed independently of has_stats (pace data isn't needed to know
    -- how many pages are left) so the tap-to-toggle "pages" view in
    -- buildSections works even before the reader has enough history for a
    -- time estimate. The *_hhmm time estimates still need avg_time.
    if toc then
        local chapter_pages_left = getChapterPagesLeft(ui, pageno)
        if chapter_pages_left and chapter_pages_left >= 0 then
            stats.chapter_pages_left_count = chapter_pages_left
            if has_stats then
                local ch_secs = chapter_pages_left * avg_time
                stats.chapter_time_left_hhmm = formatTimeHHMM(ch_secs)
            end
        end

        if next_chapter_start then
            local chapter_after_next = toc:getNextChapter(next_chapter_start)
            local next_chapter_pages
            if chapter_after_next then
                next_chapter_pages = chapter_after_next - next_chapter_start
            else
                next_chapter_pages = pages - next_chapter_start + 1
            end
            next_chapter_pages = next_chapter_pages - 1
            if next_chapter_pages < 0 then next_chapter_pages = 0 end
            stats.next_chapter_pages_count = next_chapter_pages
            if has_stats then
                local nc_secs = next_chapter_pages * avg_time
                stats.next_chapter_time_hhmm = formatTimeHHMM(nc_secs)
            end
        end
    end

    if has_stats and doc then
        pages_left = getBookPagesLeft(ui)
        if pages_left and pages_left > 0 then
            local bl_secs = (pages_left + 1) * avg_time
            stats.book_time_left_hhmm = formatTimeHHMM(bl_secs)
            stats.book_time_left_raw  = bl_secs
        elseif pages_left then
            -- Pace data exists and the book is genuinely finished (no pages
            -- left) - 00:00 is correct here, unlike the "no data" case above.
            stats.book_time_left_hhmm = zero_hhmm
            stats.book_time_left_raw  = 0
        end
    end

    if has_stats and avg_time > 0 then
        local ppm = 60 / avg_time
        local ppm_str
        if ppm >= 1 then
            ppm_str = formatNumber(ppm, 1)
        else
            ppm_str = formatNumber(ppm, 2)
        end
        stats.pages_per_minute = {
            value = ppm_str,
            unit  = N_("page per minute", "pages per minute", ppm),
        }
    end

    -- single DB connection for all book stats
    if stats_plugin and stats_plugin.id_curr_book then
        local plugin = stats_plugin
        stats.book_id = plugin.id_curr_book
        local total_time = 0
        if plugin.getPageTimeTotalStats then
            local read_pages, time_val = plugin:getPageTimeTotalStats(plugin.id_curr_book)
            total_time = tonumber(time_val) or 0
        end
        if total_time and total_time > 0 then
            stats.book_time_spent_hhmm = formatTimeHHMM(total_time)
        end

        local total_days, today_p, today_t, all_p, all_t, days_since_start, started_timestamp =
            getBookAndTodayStats(plugin.id_curr_book)

        -- "Started N days ago": only shown when there is at least one
        -- page_stat entry for this book (i.e. reading has actually begun).
        if days_since_start ~= nil and days_since_start >= 0 then
            stats.started_days_ago = {
                value = formatCount(days_since_start),
                unit  = N_("day since started", "days since started", days_since_start),
            }
            stats.started_timestamp = started_timestamp
        end

        if total_days ~= nil then
            if total_time and total_time > 0 then
                local avg_secs = total_time / total_days
                stats.avg_time_per_day_hhmm = formatTimeHHMM(avg_secs)
            end
            stats.days_reading = humanizeDayCount(total_days, "reading")

            -- Estimated days of reading left, based on time left / avg time per day
            local bl_secs = stats.book_time_left_raw
            if bl_secs and bl_secs > 0 and total_time and total_time > 0 then
                local avg_secs_per_day = total_time / total_days
                local days_left_fraction = bl_secs / avg_secs_per_day
                stats.finish_days_left = math.ceil(days_left_fraction)
                stats.finish_timestamp = os.time() + math.floor(days_left_fraction * 86400 + 0.5)
            end
        end

        if today_p and today_p > 0 then
            stats.today_pages = {
                value = formatCount(today_p),
                unit  = N_("page", "pages", today_p),
            }
        end
        if today_t and today_t > 0 then
            stats.today_time_hhmm = formatTimeHHMM(today_t)
        end

        if all_p and all_p > 0 then
            stats.today_pages_all = {
                value = formatCount(all_p),
                unit  = N_("page", "pages", all_p),
            }
        end
        if all_t and all_t > 0 then
            stats.today_time_all_hhmm = formatTimeHHMM(all_t)
        end

        self._has_book_id = true
    end -- stats_plugin

    -- TOC cache
    if toc then
        local book_id = stats_plugin and stats_plugin.id_curr_book
        stats.chapter_info = getCachedChapterInfo(book_id, toc, pages, pageno)
    end

    return stats
end

function ReadingStatsPopup:onSwipe(arg, ges_ev)
    local dir = ges_ev and ges_ev.direction
    if dir == "south" or dir == "down" then
        UIManager:close(self)
        return true
    end

    local cb = self._chapter_bar
    if cb and ges_ev then
        if (dir == "west" or dir == "left") and cb._on_swipe_left then
            cb._on_swipe_left()
            return true
        elseif (dir == "east" or dir == "right") and cb._on_swipe_right then
            cb._on_swipe_right()
            return true
        end
    end
    return false
end

-- Standalone opener: shows the per-book reading calendar directly from the
-- Tools menu or its gesture/dispatcher action, without going through "This
-- book" first (unlike ReadingStatsPopup:openBookCalendar below, which is
-- only reachable by tapping the progress row inside an already-open Book
-- progress popup). Book-view only - callers (main.lua) are expected to
-- have already checked a document is open, but this also silently no-ops
-- if there's no book_id (e.g. statistics plugin not tracking this book) or
-- no page-count data yet, same as the tap-through path would.
function ReadingStatsPopup.openBookCalendarForUI(ui)
    if not ui then return end
    local stats_plugin = ui.statistics
    local book_id = stats_plugin and stats_plugin.id_curr_book
    if not book_id then
        UIManager:show(InfoMessage:new{ text = _("No reading data for this book yet.") })
        return
    end

    local _current_page_count, total_page_count = getBookProgressCounts(ui)
    if not total_page_count or total_page_count <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No reading data for this book yet.") })
        return
    end

    local open_year, open_month = getBookLastReadYearMonth(book_id)
    if not open_year or not open_month then
        local now = os.date("*t")
        open_year, open_month = now.year, now.month
    end

    UIManager:show(BookCalendarPopup:new{
        ui          = ui,
        book_id     = book_id,
        total_pages = total_page_count,
        year        = open_year,
        month       = open_month,
    })
end

-- Opens the per-book reading calendar (see BookCalendarPopup above) on the
-- month of this book's most recent recorded reading (falls back to
-- today's month if the book has no reading yet). Closes this popup first
-- (KOReader only shows one modal popup cleanly at a time), then reopens
-- it once the calendar is dismissed - same close/reopen pattern as
-- insights_view.lua's openCalendarForMonth, so the person lands back on
-- "This book" instead of the reader screen.
function ReadingStatsPopup:openBookCalendar()
    local saved_ui                 = self.ui
    local saved_today_all_books    = self.today_all_books
    local saved_chapter_bar_offset = self.chapter_bar_offset
    local saved_book_id            = self._stats and self._stats.book_id
    local saved_total_pages        = self._stats and self._stats.total_pages_for_calendar
    local saved_finish_timestamp   = self._stats and self._stats.finish_timestamp

    local open_year, open_month = getBookLastReadYearMonth(saved_book_id)
    if not open_year or not open_month then
        local now = os.date("*t")
        open_year, open_month = now.year, now.month
    end

    UIManager:close(self)

    -- Wait one frame so the popup is fully closed before opening the calendar.
    UIManager:scheduleIn(0, function()
        local function reopen_popup()
            UIManager:show(ReadingStatsPopup:new{
                ui                 = saved_ui,
                today_all_books    = saved_today_all_books,
                chapter_bar_offset = saved_chapter_bar_offset,
            })
        end

        local reopened = false
        local function reopen_once()
            if reopened then return end
            reopened = true
            UIManager:scheduleIn(0, reopen_popup)
        end

        local popup = BookCalendarPopup:new{
            ui               = saved_ui,
            book_id          = saved_book_id,
            total_pages      = saved_total_pages,
            year             = open_year,
            month            = open_month,
            finish_timestamp = saved_finish_timestamp,
        }
        -- onCloseWidget fires on all dismiss paths (tap, swipe-close, key);
        -- the flag above prevents double-open.
        local orig_onCloseWidget = popup.onCloseWidget
        popup.onCloseWidget = function(self_popup, ...)
            if orig_onCloseWidget then orig_onCloseWidget(self_popup, ...) end
            reopen_once()
        end
        UIManager:show(popup)
    end)
end

function ReadingStatsPopup:onTapClose(arg, ges_ev)
    if ges_ev then
        local x, y = ges_ev.pos.x, ges_ev.pos.y

        if hitTest(self._chapter_headers, x, y) or hitTest(self._chapter_values, x, y) then
            self._chapter_view_mode = (self._chapter_view_mode == "pages") and "time" or "pages"
            self:_rebuildUI()
            return true
        end

        if hitTest(self._this_book_header, x, y) then
            UIManager:close(self)
            if self.ui then
                self.ui:handleEvent(require("ui/event"):new("ShowBookStats"))
            end
            return true
        end

        if hitTest(self._pace_header, x, y) and self._stats and self._stats.book_id then
            self:openBookCalendar()
            return true
        end

        if self._chapter_bar_prev_arrow and hitTestPadded(self._chapter_bar_prev_arrow, x, y, Screen:scaleBySize(14)) then
            self._chapter_bar_on_prev()
            return true
        end

        if self._chapter_bar_next_arrow and hitTestPadded(self._chapter_bar_next_arrow, x, y, Screen:scaleBySize(14)) then
            self._chapter_bar_on_next()
            return true
        end

        if hitTest(self._started_widget, x, y) and self._stats and self._stats.started_timestamp then
            UIManager:show(InfoMessage:new{
                text = _("Started:") .. " " .. formatEventDateTime(self._stats.started_timestamp),
            })
            return true
        end

        if hitTest(self._finish_widget, x, y) and self._stats and self._stats.finish_timestamp then
            UIManager:show(InfoMessage:new{
                text = _("Expected finish:") .. " " .. formatEventDateTime(self._stats.finish_timestamp),
            })
            return true
        end
    end
    UIManager:close(self)
    return true
end

function ReadingStatsPopup:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

-- Module export. main.lua instantiates this on demand (from the Tools
-- menu entry, or from the "reading_stats_popup" dispatcher/gesture action)
-- and always passes the current ReaderUI as `ui`. Unlike the original
-- standalone user-patch version, this no longer monkey-patches
-- ReaderUI.registerKeyEvents: as a proper plugin event handler,
-- main.lua's onShowReadingStatsPopup() is enough to reach this popup
-- from both the menu and the gesture/dispatcher system.
--
-- The chapter-bar height setting helpers are attached as static fields so
-- main.lua can reach them as StatsPopup.readChapterBarHeightSetting() etc,
-- the same way Insights.readFullRefreshSetting() works for the other view.
ReadingStatsPopup.readChapterBarHeightSetting = readChapterBarHeightSetting
ReadingStatsPopup.saveChapterBarHeightSetting = saveChapterBarHeightSetting
ReadingStatsPopup.DEFAULT_CHAPTER_BAR_HEIGHT  = DEFAULT_CHAPTER_BAR_HEIGHT

-- Same idea for the book-calendar cell content setting ("percent" vs
-- "pages_minutes" - see readCalendarCellModeSetting above), reached from
-- main.lua's Advanced settings submenu.
ReadingStatsPopup.readCalendarCellModeSetting = readCalendarCellModeSetting
ReadingStatsPopup.saveCalendarCellModeSetting = saveCalendarCellModeSetting

return ReadingStatsPopup
