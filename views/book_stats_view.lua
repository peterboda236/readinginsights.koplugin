--[[
Book Stats Popup (view module) - formerly stats_view.lua.
Based on: https://github.com/quanganhdo/koreader-user-patches/blob/main/2-reading-stats-popup.lua

Compact overlay displayed while reading that shows live statistics for the
current book, queried from KOReader's statistics plugin and SQLite database.
This is the plugin's "current book progress" view; see main.lua for how it
is wired up (Tools menu entry, gesture/dispatcher action, and the book-view-
only restriction) and insights_view.lua for the all-time reading-history
view. The per-book reading calendar that used to live here now has its own
file, book_calendar_view.lua; this popup opens it (tap the "Pace" title) via
the injected BookCalendar module.

Loaded by main.lua via loadfile(...)(Locale, Colors, Fonts, Settings, StatsDb,
BookProgress, BookCalendar) - the shared modules for translations/number
formatting (locale.lua), colors, fonts, G_reader_settings access, the
statistics DB, per-book reading position, and the calendar view.

Sections shown:
  - This chapter / Next chapter   estimated time left and time to read next
                                   chapter (tap to switch to pages left /
                                   next chapter's page count; tap again to
                                   switch back)
  - This book                     progress percentage, pages read, time spent, time left
  - Chapter bar                   visual bar chart of all chapters (tappable, swipeable)
  - Pace                          today's reading time and pages-per-minute rate
                                   (tap the title to open the reading calendar)

Controls:
  - Tap anywhere              dismiss
  - Tap "This chapter" row    toggle between reading time left and pages left
  - Swipe left/right          navigate the chapter bar
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
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
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
local Locale, Colors, Fonts, Settings, StatsDb, BookProgress, BookCalendar = ...
local _            = Locale._
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount

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
-- Locale.formatDuration() in locale.lua for details.
-- Returns { value = "<formatted>", unit = "" } so it fits the buildValueLine API.
-- When the "24h+ as days" setting is on and the duration crosses a day,
-- Locale.formatDurationParts() splits the trailing "day"/"nap" word into
-- `unit`, so buildValueLine renders it in the plain label style instead of
-- bolding it along with the number.
local function formatTimeHHMM(seconds)
    if not seconds or seconds ~= seconds then
        return emptyValue()
    end
    return Locale.formatDurationParts(seconds, true)
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

    local conn = StatsDb.open()
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
    -- "read today" / "avg time/day" can show either time (default) or page
    -- counts - toggled by tapping the pace row (see ReadingStatsPopup:onTapClose).
    -- popup._pace_view_mode is nil/"time" by default; "pages" once toggled.
    local pace_view_mode = (popup and popup._pace_view_mode) or "time"
    local today_time_data_hhmm = popup and popup.today_all_books
        and stats.today_time_all_hhmm
        or  stats.today_time_hhmm
    local today_pages_data = popup and popup.today_all_books
        and stats.today_pages_all
        or  stats.today_pages

    local zero_hhmm = { value = "00:00", unit = "" }
    local function nonEmpty(td)
        if not td or td.value == "" then return zero_hhmm end
        return td
    end
    local function nonEmptyPagesToday(pd)
        local count = 0
        if pd and pd.value ~= "" then
            count = tonumber(pd.value) or 1
        end
        local value = (pd and pd.value ~= "") and pd.value or formatCount(0)
        return { value = value, unit = "" }, N_("page read today", "pages read today", count)
    end

    local days_col2, pace_col2
    if pace_view_mode == "pages" then
        local today_pages_val, today_pages_label = nonEmptyPagesToday(today_pages_data)
        local avg_pages_data = stats.avg_pages_per_day or { value = "—", unit = "" }
        days_col2 = valueLine(today_pages_val, today_pages_label)
        pace_col2 = valueLine(avg_pages_data, _("avg pages/day"))
    else
        local avg_day_data = stats.avg_time_per_day_hhmm or { value = "—:—", unit = "" }
        days_col2 = valueLine(nonEmpty(today_time_data_hhmm), _("read today"))
        pace_col2 = valueLine(avg_day_data, _("avg time/day"))
    end

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
    local pace_row_content = buildTwoColRow(days_col2, pace_col2, layout)
    local pace_row = tappableWrap(pace_row_content, pace_row_content:getSize().w)
    if popup then
        popup._pace_row = pace_row
    end

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
    _pace_view_mode    = "time",
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

    local progress_percent = BookProgress.percent(ui)
    if progress_percent then
        stats.book_progress = { value = formatCount(progress_percent) .. "%", unit = "" }
    end
    local current_page_count, total_page_count = BookProgress.counts(ui)
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
        pages_left = BookProgress.pagesLeft(ui)
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
            local _, time_val = plugin:getPageTimeTotalStats(plugin.id_curr_book)
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
            -- current_page_count is the live reading position (set above,
            -- from BookProgress.counts) - a reliable proxy for "pages
            -- read so far", unlike statistics plugin's own page counter
            -- which can be 0/stale depending on how the book was opened.
            if current_page_count and current_page_count > 0 then
                local avg_pages = current_page_count / total_days
                stats.avg_pages_per_day = {
                    value = formatNumber(avg_pages, avg_pages >= 10 and 0 or 1),
                    unit  = "",
                }
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
-- Opens the per-book reading calendar (now in book_calendar_view.lua, via
-- BookCalendar.show) on the month of this book's most recent recorded
-- reading (falls back to today's month if the book has no reading yet).
-- Closes this popup first (KOReader only shows one modal popup cleanly at a
-- time), then reopens it once the calendar is dismissed (the on_close
-- callback) - same close/reopen pattern as insights_view.lua's
-- openCalendarForMonth, so the person lands back on "This book" instead of
-- the reader screen.
function ReadingStatsPopup:openBookCalendar()
    local saved_ui                 = self.ui
    local saved_today_all_books    = self.today_all_books
    local saved_chapter_bar_offset = self.chapter_bar_offset
    local saved_book_id            = self._stats and self._stats.book_id
    local saved_total_pages        = self._stats and self._stats.total_pages_for_calendar
    local saved_finish_timestamp   = self._stats and self._stats.finish_timestamp
    local saved_started_timestamp  = self._stats and self._stats.started_timestamp

    UIManager:close(self)

    -- Wait one frame so this popup is fully closed before opening the calendar.
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

        -- The per-book calendar now lives in book_calendar_view.lua; hand it
        -- the data we already gathered plus an on_close that reopens us, so
        -- the person lands back on "This book" instead of the reader screen.
        BookCalendar.show{
            ui                = saved_ui,
            book_id           = saved_book_id,
            total_pages       = saved_total_pages,
            finish_timestamp  = saved_finish_timestamp,
            started_timestamp = saved_started_timestamp,
            on_close          = reopen_once,
        }
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

        if hitTest(self._pace_row, x, y) then
            self._pace_view_mode = (self._pace_view_mode == "pages") and "time" or "pages"
            self:_rebuildUI()
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

return ReadingStatsPopup
