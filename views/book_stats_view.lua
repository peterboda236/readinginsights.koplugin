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

Loaded by main.lua with one named table of dependencies: the shared modules
for translations/number formatting (locale.lua), colors, fonts,
G_reader_settings access, per-book reading position, the calendar view, the
chapter maths and chapter bar, the layout helpers - and BookStatsData, which
holds this popup's own queries (lib/book_stats_data.lua).

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
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
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
-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, Prefs, BookProgress, BookCalendar, ChapterInfo, ChapterBar, UI, BookStatsData =
    deps.Locale, deps.Colors, deps.Fonts, deps.Prefs, deps.BookProgress,
    deps.BookCalendar, deps.ChapterInfo, deps.ChapterBar, deps.UI,
    deps.BookStatsData
local _            = Locale._
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount

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

    -- The date itself follows the configured date format (Settings ▸
    -- Advanced settings ▸ "Date format"); only where the weekday goes
    -- stays language-bound, since Hungarian wants it after the date and in
    -- lower case ("2026.06.24. szerda").
    local date_str = Locale.formatDateFromTS(timestamp)
    if is_hu then
        return date_str .. " " .. WEEKDAY_NAMES_HU_LC[t.wday]
    end
    return _(WEEKDAY_NAMES[t.wday]) .. ", " .. date_str
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

-- Two UI.buildSectionHeader widgets in a HorizontalGroup.
-- When show_next is false (no next chapter), the "Next chapter" label is
-- omitted, leaving that side blank instead of showing a misleading header.
local function buildChapterHeaders(font_section, layout, show_next)
    local left_width          = layout.padding_h + layout.col_width + math.floor(layout.separator_width / 2)
    local right_width         = layout.full_width - left_width
    local next_chapter_padding = math.ceil(layout.separator_width / 2)
    local next_chapter_text = show_next and _("Next chapter") or ""
    return HorizontalGroup:new{
        align = "center",
        UI.buildSectionHeader(font_section, _("This chapter"), left_width),
        UI.buildSectionHeader(font_section, next_chapter_text, right_width, next_chapter_padding),
    }
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
        local next_data  = next_count and { value = formatCount(next_count), unit = "" } or UI.emptyValue()
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
    local chapter_values_content  = UI.buildTwoColRow(chapter_val1, chapter_val2, layout, not stats.has_next_chapter)
    -- Wrapped in tappableWrap (fixed dimen) rather than used raw, so tapping
    -- either row reliably hits (same reasoning as started_tap/finish_tap
    -- below: a bare HorizontalGroup isn't guaranteed a usable .dimen for
    -- UI.hitTest the way a FrameContainer with an explicit dimen is).
    local chapter_headers = tappableWrap(chapter_headers_content, chapter_headers_content:getSize().w)
    local chapter_values  = tappableWrap(chapter_values_content, chapter_values_content:getSize().w)
    if popup then
        popup._chapter_headers = chapter_headers
        popup._chapter_values  = chapter_values
    end
    local book_progress_row = UI.buildTwoColRow(book_progress, book_pages_read, layout)
    local book_progress_tap = book_progress_row
    local book_row          = UI.buildTwoColRow(book_col1, book_col2, layout)
    local pace_row_content = UI.buildTwoColRow(days_col2, pace_col2, layout)
    local pace_row = tappableWrap(pace_row_content, pace_row_content:getSize().w)
    if popup then
        popup._pace_row = pace_row
    end

    local sections = VerticalGroup:new{
        align = "left",
    }

    UI.addSectionWithRow(sections, chapter_headers, chapter_values, layout, { no_bottom_line = true })

    local chapter_on_prev = popup and function()
        popup.chapter_bar_offset = math.max(1, (popup.chapter_bar_offset or 1) - ChapterBar.PAGE_SIZE)
        popup:_rebuildUI()
    end or nil
    local chapter_on_next = popup and function()
        popup.chapter_bar_offset = math.max(1, (popup.chapter_bar_offset or 1) + ChapterBar.PAGE_SIZE)
        popup:_rebuildUI()
    end or nil

    local chapter_bar, chapter_left_arrow, chapter_right_arrow, chapter_can_go_left, chapter_can_go_right =
        ChapterBar.build(
            stats.chapter_info,
            layout.full_width,
            layout.padding_h,
            popup and popup.chapter_bar_offset or nil,
            chapter_on_prev,
            chapter_on_next
        )
    table.insert(sections, UI.padded(layout.padding_h,
        Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thick, Colors.separator())))
    local this_book_header = UI.buildSectionHeader(fonts.section, _("This book"), layout.full_width)
    if popup then
        popup._this_book_header = this_book_header
    end
    UI.addSectionWithRow(
        sections,
        this_book_header,
        VerticalGroup:new{
            align = "center",
            book_progress_tap,
            VerticalSpan:new{ height = Size.padding.default },
            book_row,
        },
        layout,
        -- Same look as before the shared uikit: header, thin divider, row,
        -- and no closing line (the chapter bar follows right below).
        { no_bottom_line = true }
    )

    if chapter_bar then
        if popup then
            popup._chapter_bar = chapter_bar
            popup._chapter_bar_prev_arrow = chapter_can_go_left  and chapter_left_arrow  or nil
            popup._chapter_bar_next_arrow = chapter_can_go_right and chapter_right_arrow or nil
            popup._chapter_bar_on_prev    = chapter_on_prev
            popup._chapter_bar_on_next    = chapter_on_next
        end
            table.insert(sections, UI.padded(layout.padding_h,
                Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thin, Colors.separator())))
        table.insert(sections, chapter_bar)
    end
    table.insert(sections, UI.padded(layout.padding_h,
        Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thick, Colors.separator())))
    local pace_header = UI.buildSectionHeader(fonts.section, _("Pace"), layout.full_width)
    if popup then popup._pace_header = pace_header end
    table.insert(sections, pace_header)
    table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
    table.insert(sections, UI.padded(layout.padding_h,
        Colors.newBar(layout.full_width - 2 * layout.padding_h, Size.line.thin, Colors.separator())))
    table.insert(sections, UI.padded(layout.padding_h, pace_row))

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
            table.insert(sections, UI.padded(layout.padding_h, UI.buildTwoColRow(started_tap, finish_tap, layout)))
            table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
        elseif started_widget then
            local started_full_widget = buildValueLine(
                fonts.value, fonts.label, layout.full_width - 2 * layout.padding_h,
                stats.started_days_ago, ""
            )
            local started_tap = tappableWrap(started_full_widget, layout.full_width - 2 * layout.padding_h)
            if popup then popup._started_widget = started_tap end
            table.insert(sections, VerticalSpan:new{ height = Size.padding.small })
            table.insert(sections, UI.padded(layout.padding_h, started_tap))
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
            table.insert(sections, UI.padded(layout.padding_h, finish_tap))
            table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
        end
    end

    table.insert(sections, LineWidget:new{
        dimen      = Geom:new{ w = layout.full_width, h = Size.line.thick },
        background = Blitbuffer.COLOR_BLACK,
    })
    return sections
end

-- Same as UI.hitTest, but grows the widget's box by `pad` on every side before
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
        local page_start = math.floor((info.current - 1) / ChapterBar.PAGE_SIZE) * ChapterBar.PAGE_SIZE + 1
        self.chapter_bar_offset = math.max(1, page_start)
    end
    self:_buildUI()
end

-- Full-width popup, bordersize=0, radius=0, VerticalGroup wrapper.
function ReadingStatsPopup:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self._layout   = UI.buildLayout(screen_w, Size.padding.large, Screen:scaleBySize(20))
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
        next_chapter_time_hhmm = UI.emptyValue(),
        book_time_left_hhmm    = na_hhmm,
        book_time_spent_hhmm   = zero_hhmm,
        book_progress          = zero_progress,
        book_pages_read        = zero_pages_read,
        avg_time_per_day_hhmm  = na_hhmm,
        pages_per_minute       = zero_pages_per_minute,
        days_reading           = zero_days_reading,
        days_to_go             = zero_days_to_go,
        today_pages            = UI.emptyValue(),
        today_time_hhmm        = zero_hhmm,
        today_pages_all        = UI.emptyValue(),
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
        local chapter_pages_left = ChapterInfo.getChapterPagesLeft(ui, pageno)
        if chapter_pages_left and chapter_pages_left >= 0 then
            stats.chapter_pages_left_count = chapter_pages_left
            if has_stats then
                local ch_secs = chapter_pages_left * avg_time
                stats.chapter_time_left_hhmm = Locale.formatTimeHHMM(ch_secs)
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
                stats.next_chapter_time_hhmm = Locale.formatTimeHHMM(nc_secs)
            end
        end
    end

    if has_stats and doc then
        pages_left = BookProgress.pagesLeft(ui)
        if pages_left and pages_left > 0 then
            local bl_secs = (pages_left + 1) * avg_time
            stats.book_time_left_hhmm = Locale.formatTimeHHMM(bl_secs)
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
            stats.book_time_spent_hhmm = Locale.formatTimeHHMM(total_time)
        end

        local total_days, today_p, today_t, all_p, all_t, days_since_start, started_timestamp =
            BookStatsData.getBookAndTodayStats(plugin.id_curr_book)

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
                stats.avg_time_per_day_hhmm = Locale.formatTimeHHMM(avg_secs)
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
            stats.today_time_hhmm = Locale.formatTimeHHMM(today_t)
        end

        if all_p and all_p > 0 then
            stats.today_pages_all = {
                value = formatCount(all_p),
                unit  = N_("page", "pages", all_p),
            }
        end
        if all_t and all_t > 0 then
            stats.today_time_all_hhmm = Locale.formatTimeHHMM(all_t)
        end

        self._has_book_id = true
    end -- stats_plugin

    -- TOC cache
    if toc then
        local book_id = stats_plugin and stats_plugin.id_curr_book
        stats.chapter_info = ChapterInfo.getCachedChapterInfo(book_id, toc, pages, pageno)
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

        if UI.hitTest(self._chapter_headers, x, y) or UI.hitTest(self._chapter_values, x, y) then
            self._chapter_view_mode = (self._chapter_view_mode == "pages") and "time" or "pages"
            self:_rebuildUI()
            return true
        end

        if UI.hitTest(self._this_book_header, x, y) then
            UIManager:close(self)
            if self.ui then
                self.ui:handleEvent(require("ui/event"):new("ShowBookStats"))
            end
            return true
        end

        if UI.hitTest(self._pace_header, x, y) and self._stats and self._stats.book_id then
            self:openBookCalendar()
            return true
        end

        if UI.hitTest(self._pace_row, x, y) then
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

        if UI.hitTest(self._started_widget, x, y) and self._stats and self._stats.started_timestamp then
            UIManager:show(InfoMessage:new{
                text = _("Started:") .. " " .. formatEventDateTime(self._stats.started_timestamp),
            })
            return true
        end

        if UI.hitTest(self._finish_widget, x, y) and self._stats and self._stats.finish_timestamp then
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

return ReadingStatsPopup
