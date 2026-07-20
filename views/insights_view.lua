--[[
Reading Insights - the full-screen insights popup.

Draws the scrollable page of reading history and handles everything on it:
year navigation, the taps that open the other popups, and the layout of the
sections. The figures themselves come from lib/insights_data.lua; nothing
here reads the statistics DB.

Sections, top to bottom:
  - Last week     7-day totals and averages + daily bar chart
  - Streaks       current and best daily/weekly streaks
  - Year          time, days read or books read + pages, per year
  - Monthly chart per-month bars; the header cycles hours/days/books
  - Reading goal  finished books vs. a per-year target (can be switched off
                  in Settings > Advanced settings)
  - Total read    all-time totals

Gestures:
  - Tap "Total read" header            reading heatmap (swipe there to page
                                       through older periods)
  - Tap yearly value or monthly bar    book list for that period
  - Tap monthly chart header           cycle hours/days/books
  - Tap a streak                       that streak's dates and totals
  - Tap a Last week value              8-week trend popup
  - Tap today's bar in Last week       Today Timeline
  - Long press current month           CalendarView
  - Tap finished-book count            books finished that year
  - Long press finished-book count     checklist to correct that list
  - Long press reading goal value      set that year's goal
  - Long press title bar               force-reload everything from the DB
  - Swipe left/right                   change year
  - Swipe down / any key               close

Refresh: "ui" on open/close by default, "full" if the Tools-menu toggle for
it is on. The trend and streak popups repaint only their own box, so they
don't flash the whole screen.

Bar chart heights: by default both charts size themselves while the page is
built so it fits one screen without a scroll bar - see _buildUI's fit loop,
and Settings > Advanced settings > "Bar chart height" to turn it off.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local T = require("ffi/util").template

-- Shared translations/number-formatting, shared chart/text color settings,
-- and this view's own settings module (VS - lib/insights_settings.lua, every
-- user-settable option this popup reads or writes), all loaded once by
-- main.lua and passed in as this chunk's arguments (see main.lua's
-- loadModule() call for this file).
-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, PopupUtil, VS, Cache, UI, Trend, Heatmap, BookList, Data, Manual =
    deps.Locale, deps.Colors, deps.Fonts, deps.PopupUtil,
    deps.VS, deps.Cache, deps.UI, deps.Trend, deps.Heatmap, deps.BookList,
    deps.Data, deps.Manual

-- true: today's bar in the weekly chart is black. false: all bars gray.
local WEEKLY_CHART_HIGHLIGHT_TODAY = true

-- Value-based (not reference-based) equality for the small stat tables
-- returned by the getters below. Needed because a per-minute cache refresh
-- allocates a brand new result table every time it recomputes, even when
-- the actual numbers haven't changed (e.g. no reading happened in the last
-- minute) - a plain "==" would treat that as "changed" and force a needless
-- UI rebuild + e-ink redraw on almost every popup open.
local function valuesEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not valuesEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Localisation and number formatting now live in the shared locale.lua module
-- (required by main.lua and handed to this view as `Locale`), so both this
-- popup and the reading-stats popup translate from the same locale/<lang>.po
-- files instead of each keeping its own copy.
local _            = Locale._
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount

-- Format a YYYY-MM-DD string for display (EN: DD/MM/YYYY, HU: YYYY.MM.DD.)
-- no_trailing_dot: HU only - omit the final dot (used for the first date in a range)
local function formatDateForDisplay(date_str, no_trailing_dot)
    if not date_str then return "?" end
    local y, m, d = date_str:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return date_str end
    if getLangBase() == "hu" then
        return string.format("%s.%s.%s%s", y, m, d, no_trailing_dot and "" or ".")
    else
        return string.format("%s/%s/%s", d, m, y)
    end
end

local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}
local MONTH_NAMES_FULL = {
    _("January"), _("February"), _("March"), _("April"), _("May "), _("June"),
    _("July"), _("August"), _("September"), _("October"), _("November"), _("December"),
}

local ReadingInsightsPopup

-- Format seconds as a clock-style duration for book list display, honouring
-- KOReader's global "duration_format" setting (classic "1:30:10", modern
-- "1h30'10\"", ...) - see Locale.formatDuration() in locale.lua for details.
local function formatHHMMSS(seconds)
    return Locale.formatDuration(seconds, false)
end

-- Splits a formatted duration into a bold "value" and a plain "unit" for
-- the value/label row layout used throughout this popup (bold number +
-- plain description, e.g. "7.3" + "days reading time"). Normally the
-- number is just the clock string and unit is exactly `base_label`
-- unchanged. But when "Show long durations (24h+) as days" is on and the
-- duration crosses a day, Locale.formatDurationParts() returns a trailing
-- "day"/"nap" word that must NOT be bold - so it's merged into the plain
-- `unit` ahead of the row's usual label instead of staying glued to the
-- bold number.
local function splitDurationValueUnit(seconds, base_label)
    local parts = Locale.formatDurationParts(seconds, true)
    local unit = base_label or ""
    if parts.unit ~= "" then
        unit = (unit ~= "" and (parts.unit .. " " .. unit)) or parts.unit
    end
    return parts.value, unit
end

-- Font faces for this popup's four text roles, sourced from the shared
-- Fonts settings module (see fonts.lua) so they're user-configurable via
-- the "Fonts" Tools-menu entry, the same way Colors.* works for colors.
-- Fonts.getFace() already caches per-role, so this is cheap to call again
-- on every popup (re)build - which is what keeps a just-changed font
-- setting picked up immediately, without needing our own extra cache.
local function buildSerifFonts()
    return {
        section = Fonts.getFace("insights_section"),
        value   = Fonts.getFace("insights_value"),
        label   = Fonts.getFace("insights_label"),
        small   = Fonts.getFace("insights_small"),
    }
end

local _cached_layout = nil

-- Deliberately NOT cached at this module level (unlike getCachedLayout()
-- below): fonts are user-configurable via the Fonts menu, and
-- Fonts.getFace() already caches per-role internally, so rebuilding this
-- small table on every popup (re)build is cheap and guarantees a
-- just-changed font setting is picked up on the very next open, with no
-- stale fonts left over from before the change.
local function getCachedFonts()
    return buildSerifFonts()
end

local function getCachedLayout()
    if not _cached_layout then
        local screen_w = Screen:getWidth()
        _cached_layout = UI.buildLayout(screen_w, Size.padding.large, Screen:scaleBySize(20))
    end
    return _cached_layout
end

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

local function tappableCell(widget, col_width, callback)
    local cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = col_width, h = widget:getSize().h },
        widget,
    }
    cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } },
    }
    function cell:onTap()
        callback()
        return true
    end
    return cell
end

local function buildYearHeader(font_section, layout, year_range, selected_year)
    local prev_available = selected_year > year_range.min_year
    local next_available = selected_year < year_range.max_year

    local inner_pad = Size.padding.default
    local gap       = Size.padding.small

    local sample_arrow = TextWidget:new{ text = "\xe2\x80\xb9", face = font_section }
    local arrow_w = sample_arrow:getSize().w
    sample_arrow:free()

    local sample_yr = TextWidget:new{ text = tostring(selected_year - 1), face = font_section }
    local yr_side_w = sample_yr:getSize().w
    sample_yr:free()

    local slot_w = arrow_w + gap + yr_side_w + inner_pad

    local year_label = TextWidget:new{
        text = tostring(selected_year),
        face = font_section,
        fgcolor = Colors.section(),
    }
    -- Year navigation is done via swipe on the whole popup (see
    -- onSwipe/_goToYear); the reading heatmap now opens from the
    -- "Total read" header instead of from tapping the year (see
    -- showReadingHeatmap and buildInsightsSections).

    local function makeSlot(yr, arrow_glyph, left, visible)
        if not visible then
            return HorizontalSpan:new{ width = slot_w }, slot_w
        end

        local arrow_tw = TextWidget:new{
            text    = arrow_glyph,
            face    = font_section,
            fgcolor = Colors.section(),
        }
        local yr_tw = TextWidget:new{
            text    = tostring(yr),
            face    = font_section,
            fgcolor = Colors.section(),
        }

        local parts
        if left then
            parts = HorizontalGroup:new{
                align = "center",
                arrow_tw,
                HorizontalSpan:new{ width = gap },
                yr_tw,
                HorizontalSpan:new{ width = inner_pad },
            }
        else
            parts = HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = inner_pad },
                yr_tw,
                HorizontalSpan:new{ width = gap },
                arrow_tw,
            }
        end
        return parts, slot_w
    end

    local left_slot,  left_w  = makeSlot(selected_year - 1, "\xe2\x80\xb9", true,  prev_available)
    local right_slot, right_w = makeSlot(selected_year + 1, "\xe2\x80\xba", false, next_available)

    local year_w    = year_label:getSize().w
    local remaining = layout.content_width - left_w - right_w - year_w
    if remaining < 0 then remaining = 0 end
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l

    local header_content = HorizontalGroup:new{
        align = "center",
        left_slot,
        HorizontalSpan:new{ width = side_l },
        year_label,
        HorizontalSpan:new{ width = side_r },
        right_slot,
    }

    return FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = layout.padding_h,
        padding_right  = layout.padding_h,
        header_content,
    }
end

-- Builds the reading-goal section header text, e.g. "Reading goal"
-- (en) / "Olvasási cél" (hu). Deliberately year-agnostic: the section
-- already shows and lets you navigate the selected year via swipe (like the
-- yearly/monthly sections above it), so repeating it in the header itself
-- (e.g. "2026-os olvasási cél") was redundant and needed a
-- vowel-harmony-dependent Hungarian suffix ("-os/-es/...") that had to be
-- recomputed per year.
local function buildGoalYearLabel(year)
    return _("Reading goal")
end

-- Title for the goal-edit popup (the SpinWidget opened by long-pressing the
-- goal value - see editReadingGoal below), e.g. "2026 - reading goal" (en) /
-- "2026 - olvasási cél" (hu). Unlike buildGoalYearLabel above, this one DOES
-- include the year: the section header can stay year-agnostic because the
-- section it titles is always on screen right below it, but this dialog is
-- a separate popup on top of everything else, so the year needs to be
-- spelled out here for it to be clear which year is being edited.
local function buildGoalEditTitle(year)
    return T(_("%1 - reading goal"), tostring(year))
end

local function buildYearlyRow(popup_self, yearly_stats, fonts, layout)
    local left_value = ""
    local left_unit  = ""
    if popup_self.mode == VS.INSIGHTS_MODE_HOURS then
        local yr_secs = yearly_stats.duration or 0
        left_value, left_unit = splitDurationValueUnit(yr_secs, _("reading time"))
    elseif popup_self.mode == VS.INSIGHTS_MODE_BOOKS then
        left_value = formatCount(yearly_stats.books_started)
        left_unit  = N_("book read", "books read", yearly_stats.books_started)
    else
        left_value = formatCount(yearly_stats.days)
        left_unit  = N_("day read", "days read", yearly_stats.days)
    end
    local left_line = buildValueLine(
        fonts.value, fonts.label, layout.col_width, left_value, left_unit)
    local right_value, right_unit
    if popup_self.mode == VS.INSIGHTS_MODE_DAYS then
        local selected_year = popup_self.selected_year or tonumber(os.date("%Y"))
        local current_year  = tonumber(os.date("%Y"))
        local days_in_year
        if selected_year == current_year then
            days_in_year = tonumber(os.date("%j"))
        else
            local is_leap = (selected_year % 4 == 0 and selected_year % 100 ~= 0)
                         or (selected_year % 400 == 0)
            days_in_year = is_leap and 366 or 365
        end
        local pct = (days_in_year > 0)
            and math.floor((yearly_stats.days / days_in_year) * 100 + 0.5)
            or 0
        right_value = pct .. "%"
        right_unit  = _("of days read")
    elseif popup_self.mode == VS.INSIGHTS_MODE_BOOKS then
        local avg_days = yearly_stats.avg_days_per_book or 0
        right_value = formatCount(avg_days)
        right_unit  = N_("day/book avg", "days/book avg", avg_days)
    else
        right_value = formatCount(yearly_stats.pages)
        right_unit  = N_("page read", "pages read", yearly_stats.pages)
    end
    local pages_val = buildValueLine(
        fonts.value, fonts.label, layout.col_width, right_value, right_unit)

    local selected_year_for_tap = popup_self.selected_year

    local left_cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = left_line:getSize().h },
        left_line,
    }
    left_cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = left_cell.dimen } },
    }
    function left_cell:onTap()
        popup_self:showBooksForYear(selected_year_for_tap)
        return true
    end

    local right_cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = pages_val:getSize().h },
        pages_val,
    }
    right_cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = right_cell.dimen } },
    }
    function right_cell:onTap()
        popup_self:showBooksForYear(selected_year_for_tap)
        return true
    end

    local yearly_row = UI.buildTwoColRow(left_cell, right_cell, layout)

    return VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            UI.padded(layout.padding_h, yearly_row),
        },
    }
end

local function buildMonthlyChart(popup_self, monthly_data, layout, fonts)
    if #monthly_data == 0 then return nil end

    local value_key = (popup_self.mode == VS.INSIGHTS_MODE_HOURS and "hours")
        or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS and "book_count")
        or "days"
    local max_value = 1
    for _, m in ipairs(monthly_data) do
        local v = tonumber(m[value_key]) or 0
        if v > max_value then max_value = v end
    end

    local chart_width  = layout.content_width
    VS.Opt.built_monthly = true
    local bar_height   = tonumber(Screen:scaleBySize(VS.Opt.monthlyBarHeight()))
    local bar_width    = math.floor(chart_width / 6) - tonumber(Screen:scaleBySize(8))
    local bar_gap      = math.floor((chart_width - bar_width * 6) / 5)
    local font_small   = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local current_year  = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")

    local function createBarRow(data_slice)
        local bars_row        = HorizontalGroup:new{ align = "bottom" }
        local month_labels_row = HorizontalGroup:new{ align = "top" }
        local baseline_h      = Size.line.medium
        local total_bar_height = bar_height + label_height

        for i, m in ipairs(data_slice) do
            local value = tonumber(m[value_key]) or 0
            local ratio = max_value > 0 and (value / max_value) or 0
            local bar_h = math.floor(ratio * bar_height + 0.5)
            if bar_h == 0 and value > 0 then bar_h = 1 end

            local is_current = (popup_self.selected_year == current_year) and (m.month == current_month)
            local bar_color  = is_current and Colors.activeBar() or Colors.inactiveBar()

            local bar_label_str
            if popup_self.mode == VS.INSIGHTS_MODE_HOURS then
                local mo_secs = tonumber(m.seconds) or math.floor((tonumber(m.hours) or 0) * 3600 + 0.5)
                bar_label_str = Locale.formatDuration(mo_secs, true)
            else
                bar_label_str = formatNumber(value)
            end            local value_label   = TextWidget:new{ text = bar_label_str, face = font_small, fgcolor = Colors.small() }
            local centered_label = CenterContainer:new{
                dimen  = Geom:new{ w = bar_width, h = label_height },
                value_label,
            }

            local bar_column = VerticalGroup:new{ align = "center" }
            table.insert(bar_column, centered_label)
            if bar_h > 0 then
                table.insert(bar_column, Colors.newBar(bar_width, bar_h, bar_color))
            end
            table.insert(bar_column, Colors.newBar(bar_width, baseline_h, bar_color))

            local bar_container = BottomContainer:new{
                dimen = Geom:new{ w = bar_width, h = total_bar_height },
                bar_column,
            }

            local tappable_bar = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = bar_width, h = total_bar_height },
                bar_container,
            }
            local month_data       = m
            local month_year_label = m.label_full .. " " .. popup_self.selected_year
            tappable_bar.ges_events = {
                Tap  = { GestureRange:new{ ges = "tap",  range = tappable_bar.dimen } },
            }
            function tappable_bar:onTap()
                popup_self:showBooksForMonth(month_data.month, month_year_label)
                return true
            end
            if is_current then
                popup_self._current_month_bar_widget = tappable_bar
            end

            table.insert(bars_row, tappable_bar)

            local month_label_widget = TextWidget:new{ text = m.label, face = font_small, fgcolor = Colors.small() }
            table.insert(month_labels_row, CenterContainer:new{
                dimen = Geom:new{ w = bar_width, h = month_label_widget:getSize().h },
                month_label_widget,
            })

            if i < #data_slice then
                table.insert(bars_row,         HorizontalSpan:new{ width = bar_gap })
                table.insert(month_labels_row, HorizontalSpan:new{ width = bar_gap })
            end
        end

        return VerticalGroup:new{
            align = "center",
            bars_row,
            VerticalSpan:new{ height = Size.padding.small },
            month_labels_row,
        }
    end

    local chart     = VerticalGroup:new{ align = "center" }
    local row_index = 0
    for i = 1, #monthly_data, 6 do
        local row_data = {}
        for j = i, math.min(i + 5, #monthly_data) do
            table.insert(row_data, monthly_data[j])
        end
        if #row_data > 0 then
            if row_index > 0 then
                table.insert(chart, VerticalSpan:new{ height = Size.padding.default })
            end
            table.insert(chart, createBarRow(row_data))
            row_index = row_index + 1
        end
    end

    return chart
end

-- Any tap / swipe / key dismisses; onShow/onCloseWidget mark the popup box
-- region dirty. All five come from the shared helper (see popuputil.lua).
PopupUtil.makeDismissable(Trend.Popup, function(self) return self.box_content.dimen end)

-- Weekly bar chart: 7 bars, index 1 = today (leftmost), index 7 = 6 days ago.
-- Labels: "Today", "Yesterday", then weekday abbreviations.
local function buildWeeklyChart(popup_self, daily_data, layout, fonts, mode)
    if not daily_data or #daily_data == 0 then return nil end
    mode = VS.normalizeWeeklyChartMode(mode)
    local show_pages = (mode == VS.WEEKLY_CHART_MODE_PAGES)

    -- Pad to exactly 7 entries.
    while #daily_data < 7 do
        table.insert(daily_data, { hours = 0, seconds = 0, pages = 0, label = "" })
    end

    local chart_width  = layout.content_width

    VS.Opt.built_weekly = true
    local bar_height   = tonumber(Screen:scaleBySize(VS.Opt.weeklyBarHeight()))
    local num_bars     = 7
    local bar_width    = math.floor(chart_width / num_bars) - tonumber(Screen:scaleBySize(6))
    local bar_gap      = math.floor((chart_width - bar_width * num_bars) / (num_bars - 1))
    local font_small   = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local max_value = 0
    for _, d in ipairs(daily_data) do
        local v = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
        if v > max_value then max_value = v end
    end
    if max_value < 0.1 then max_value = 1 end  -- avoid division by zero

    local bars_row        = HorizontalGroup:new{ align = "bottom" }
    local day_labels_row  = HorizontalGroup:new{ align = "top" }
    local baseline_h      = Size.line.medium
    local total_bar_height = bar_height + label_height

    for i = 1, num_bars do
        local d = daily_data[i]
        local value = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
        local ratio = value / max_value
        local bar_h = math.floor(ratio * bar_height + 0.5)
        if bar_h == 0 and value > 0 then bar_h = 1 end

        local bar_color = (WEEKLY_CHART_HIGHLIGHT_TODAY and i == 1) and Colors.activeBar() or Colors.inactiveBar()

        local val_str
        if show_pages then
            local pages = math.floor((tonumber(d.pages) or 0) + 0.5)
            val_str = string.format(_("%d p"), pages)
        else
            local secs = tonumber(d.seconds) or 0
            val_str = Locale.formatDuration(secs, true)
        end
        local value_label   = TextWidget:new{ text = val_str, face = font_small, fgcolor = Colors.small() }
        local centered_label = CenterContainer:new{
            dimen  = Geom:new{ w = bar_width, h = label_height },
            value_label,
        }

        local bar_column = VerticalGroup:new{ align = "center" }
        table.insert(bar_column, centered_label)
        if bar_h > 0 then
            table.insert(bar_column, Colors.newBar(bar_width, bar_h, bar_color))
        end
        table.insert(bar_column, Colors.newBar(bar_width, baseline_h, bar_color))

        local bar_container = BottomContainer:new{
            dimen = Geom:new{ w = bar_width, h = total_bar_height },
            bar_column,
        }

        if i == 1 then
            local tappable_bar = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = bar_width, h = total_bar_height },
                bar_container,
            }
            tappable_bar.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = tappable_bar.dimen } },
            }
            function tappable_bar:onTap()
                popup_self:openTodayTimeline()
                return true
            end
            table.insert(bars_row, tappable_bar)
        else
            table.insert(bars_row, bar_container)
        end

        local day_label_widget = TextWidget:new{ text = d.label, face = font_small, fgcolor = Colors.small() }
        table.insert(day_labels_row, CenterContainer:new{
            dimen = Geom:new{ w = bar_width, h = day_label_widget:getSize().h },
            day_label_widget,
        })

        if i < num_bars then
            table.insert(bars_row,       HorizontalSpan:new{ width = bar_gap })
            table.insert(day_labels_row, HorizontalSpan:new{ width = bar_gap })
        end
    end

    return VerticalGroup:new{
        align = "center",
        bars_row,
        VerticalSpan:new{ height = Size.padding.small },
        day_labels_row,
    }
end

-- Show a popup (styled like the main insights popup) with the period start/end
-- dates for a streak, plus total reading time, average time/day, and book count.
-- dates table: { start = "YYYY-MM-DD" or "YYYY-WW", end_ = same }, is_weekly = bool
-- is_current: true = current streak, false = best streak. When given, a label
-- naming which streak's period is shown is prepended above the date range.
local function showStreakDatePopup(dates, is_weekly, is_current)
    if not dates then
        UIManager:show(InfoMessage:new{ text = _("No streak dates") })
        return
    end
    local start_str, end_str, range_start, range_end
    if is_weekly then
        local mon_from = Data.weekStrToMondayDate(dates.start)
        local mon_to   = Data.weekStrToMondayDate(dates.end_)
        local sun_to
        if mon_to then
            sun_to = os.date("%Y-%m-%d", os.time({ year = tonumber(mon_to:sub(1,4)),
                month = tonumber(mon_to:sub(6,7)), day = tonumber(mon_to:sub(9,10)) }) + 6 * 86400)
        end
        range_start = mon_from
        range_end   = sun_to or mon_to
        start_str = formatDateForDisplay(mon_from, true)
        end_str   = formatDateForDisplay(sun_to or mon_to)
    else
        range_start = dates.start
        range_end   = dates.end_
        start_str = formatDateForDisplay(dates.start, true)
        end_str   = formatDateForDisplay(dates.end_)
    end

    local period = Data.getStreakPeriodStats(range_start, range_end)
    local num_days = Data.daysBetweenInclusive(range_start, range_end)
    local avg_seconds = num_days > 0 and (period.duration / num_days) or 0

    -- Two columns, time on the left and pages on the right, mirroring how
    -- the insights page itself pairs those two numbers. The book count sits
    -- on its own below, since it has no counterpart.
    local total_time_val, total_time_unit = splitDurationValueUnit(period.duration, _("reading time"))
    local avg_time_val,   avg_time_unit   = splitDurationValueUnit(avg_seconds, _("avg time/day"))

    local total_pages     = period.pages or 0
    local total_pages_val = formatCount(total_pages)
    -- Same label the last-week section uses for its page total, so the two
    -- read the same way and share one translation.
    local total_pages_unit = N_("page read", "pages read", total_pages)

    local avg_pages = num_days > 0 and (total_pages / num_days) or 0
    local avg_pages_rounded
    if avg_pages >= 10 then
        avg_pages_rounded = math.floor(avg_pages + 0.5)
    else
        avg_pages_rounded = math.floor(avg_pages * 10 + 0.5) / 10
    end
    local avg_pages_val  = formatNumber(avg_pages_rounded,
        avg_pages_rounded ~= math.floor(avg_pages_rounded) and 1 or 0)
    local avg_pages_unit = _("avg pages/day")

    local book_count = period.books
    local book_label = N_("book read in this streak", "books read in this streak", book_count)

    local fonts = getCachedFonts()
    local inner_padding = Size.padding.large
    local max_width = math.floor(Screen:getWidth() * 0.9) - 2 * inner_padding

    -- Heading: the streak name in the section face (bold), the date range
    -- beside it in the plain label face.
    local title_w
    if is_current ~= nil then
        local label = is_current and _("Current streak") or _("Best streak")
        title_w = TextWidget:new{ text = label, face = fonts.section, fgcolor = Colors.section() }
    end
    local date_w = TextWidget:new{ text = start_str .. " – " .. end_str, face = fonts.label, fgcolor = Colors.label() }

    -- Measure every cell at its natural (unwrapped) width, then give both
    -- columns the widest of them, so the two line up and the box hugs its
    -- content instead of being a fixed fraction of the screen.
    local function naturalRowWidth(value, unit)
        local value_w = TextWidget:new{ text = value, face = fonts.value }:getSize().w
        local label_w = TextWidget:new{ text = unit,  face = fonts.label }:getSize().w
        return value_w + Size.padding.large + label_w
    end

    local col_width = math.max(
        naturalRowWidth(total_time_val, total_time_unit),
        naturalRowWidth(total_pages_val, total_pages_unit),
        naturalRowWidth(avg_time_val, avg_time_unit),
        naturalRowWidth(avg_pages_val, avg_pages_unit),
        naturalRowWidth(tostring(book_count), book_label),
        date_w:getSize().w,
        title_w and title_w:getSize().w or 0
    )

    local column_gap = Size.padding.large
    local layout = UI.buildLayout(math.min(2 * col_width + 2 * column_gap + Size.line.medium,
                                           max_width), 0, column_gap)
    col_width = layout.col_width
    local content_width = layout.content_width

    local content = VerticalGroup:new{ align = "left" }

    -- Heading row: no column separator, so the name and the date read as
    -- one line rather than as two cells.
    if title_w then
        table.insert(content, UI.buildTwoColRow(title_w, date_w, layout, true))
    else
        table.insert(content, UI.fixedCol(date_w, content_width))
    end
    table.insert(content, VerticalSpan:new{ height = Size.padding.default })
    table.insert(content, Colors.newBar(content_width, Size.line.thin, Colors.separator()))
    table.insert(content, VerticalSpan:new{ height = Size.padding.large })

    table.insert(content, UI.buildTwoColRow(
        buildValueLine(fonts.value, fonts.label, col_width, total_time_val,  total_time_unit),
        buildValueLine(fonts.value, fonts.label, col_width, total_pages_val, total_pages_unit),
        layout))
    table.insert(content, VerticalSpan:new{ height = Size.padding.default })
    table.insert(content, UI.buildTwoColRow(
        buildValueLine(fonts.value, fonts.label, col_width, avg_time_val,  avg_time_unit),
        buildValueLine(fonts.value, fonts.label, col_width, avg_pages_val, avg_pages_unit),
        layout))
    table.insert(content, VerticalSpan:new{ height = Size.padding.default })
    table.insert(content, UI.fixedCol(
        buildValueLine(fonts.value, fonts.label, content_width, tostring(book_count), book_label),
        content_width))

    local box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }

    UIManager:show(Trend.Popup:new{ box_content = box })
end

local function buildInsightsSections(popup_self, streaks, yearly_stats, year_range, monthly_data, all_time_stats, last_week_stats, last_week_daily, fonts, layout, goal_finished_count)
    local sections = VerticalGroup:new{ align = "left" }

    do
        local lw = last_week_stats or { avg_seconds = 0, avg_pages = 0 }
        local has_week = lw.avg_seconds > 0 or lw.avg_pages > 0
        if has_week then

            local avg_secs = lw.avg_seconds or 0
            local week_time_val, week_time_unit_full = splitDurationValueUnit(avg_secs, _("read time avg/day"))

            local avg_pages_rounded
            if lw.avg_pages >= 10 then
                avg_pages_rounded = math.floor(lw.avg_pages + 0.5)
            else
                avg_pages_rounded = math.floor(lw.avg_pages * 10 + 0.5) / 10
            end
            local week_pages_val  = formatNumber(avg_pages_rounded, avg_pages_rounded ~= math.floor(avg_pages_rounded) and 1 or 0)
            local pages_unit_base = N_("page read", "pages read", avg_pages_rounded)
            local avg_day_str = _("avg/day")
            local week_pages_unit
            if getLangBase() == "hu" then
                week_pages_unit = avg_day_str
            else
                week_pages_unit = pages_unit_base .. " " .. avg_day_str
            end

            local week_row = UI.buildTwoColRow(
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, week_time_val,   week_time_unit_full),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("time_avg") end),
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, week_pages_val,  week_pages_unit),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("pages_avg") end),
                layout)

            local total_secs = (lw.avg_seconds or 0) * 7
            local total_time_val, total_time_unit = splitDurationValueUnit(total_secs, _("reading time"))

            local total_pages_raw = math.floor((lw.avg_pages or 0) * 7 + 0.5)
            local total_pages_val = formatCount(total_pages_raw)
            local total_pages_unit = N_("page read", "pages read", total_pages_raw)

            local total_row = UI.buildTwoColRow(
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, total_time_val, total_time_unit),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("time_total") end),
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, total_pages_val, total_pages_unit),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("pages_total") end),
                layout)

            local weekly_chart_mode = VS.normalizeWeeklyChartMode(popup_self.weekly_chart_mode)
            local weekly_chart = buildWeeklyChart(popup_self, last_week_daily, layout, fonts, weekly_chart_mode)
            local last_week_content = VerticalGroup:new{
                align = "left",
                UI.padded(layout.padding_h, total_row),
                VerticalSpan:new{ height = Size.padding.default },
                UI.padded(layout.padding_h, week_row),
            }
            if weekly_chart then
                table.insert(last_week_content, VerticalSpan:new{ height = Size.padding.default })
                table.insert(last_week_content, UI.padded(layout.padding_h, weekly_chart))
            end

            -- Tapping the header toggles the chart above between reading
            -- time and pages read per day (see toggleWeeklyChartMode()).
            local last_week_header = UI.buildSectionHeader(fonts.section, _("Last week"), layout.full_width)
            local tappable_last_week_header = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = last_week_header:getSize().w, h = last_week_header:getSize().h },
                last_week_header,
            }
            tappable_last_week_header.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = tappable_last_week_header.dimen } },
            }
            function tappable_last_week_header:onTap()
                popup_self:toggleWeeklyChartMode()
                return true
            end

            UI.addSectionWithRow(sections,
                tappable_last_week_header,
                last_week_content, layout, { pad_row = false })
        end
    end

    local function streakDisplay(n, unit_label, empty_label)
        if n < 2 then return "", empty_label end
        return formatCount(n), unit_label(n)
    end

    -- Compact unit labels ("days"/"weeks" instead of "days in a row") so that
    -- the days/weeks values fit side by side within a single Current/Best column.
    local cd_val, cd_unit = streakDisplay(streaks.current_days,
        function(n) return N_("day",  "days",  n) end, _("No streak"))
    local cw_val, cw_unit = streakDisplay(streaks.current_weeks,
        function(n) return N_("week", "weeks", n) end, _("No streak"))
    local bd_val, bd_unit = streakDisplay(streaks.best_days,
        function(n) return N_("day",  "days",  n) end, _("No streak"))
    local bw_val, bw_unit = streakDisplay(streaks.best_weeks,
        function(n) return N_("week", "weeks", n) end, _("No streak"))

    -- Two-column streak header (tappable: shows date range for that streak).
    local streak_header_left  = UI.buildSectionHeader(fonts.section, _("Current streak"), layout.col_width, 0)
    local streak_header_right = UI.buildSectionHeader(fonts.section, _("Best streak"),    layout.col_width, 0)
    local sep_h = streak_header_left:getSize().h

    local tap_current_header = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=streak_header_left:getSize().h },
        streak_header_left,
    }
    tap_current_header.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_current_header.dimen } } }
    function tap_current_header:onTap()
        showStreakDatePopup(streaks.current_days_dates, false, true)
        return true
    end

    local tap_best_header = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=streak_header_right:getSize().h },
        streak_header_right,
    }
    tap_best_header.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_best_header.dimen } } }
    function tap_best_header:onTap()
        showStreakDatePopup(streaks.best_days_dates, false, false)
        return true
    end

    local streak_combined_header = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = layout.padding_h },
            UI.fixedCol(tap_current_header, layout.col_width),
            UI.buildColumnSeparator(layout.column_gap, sep_h),
            UI.fixedCol(tap_best_header,    layout.col_width),
        },
    }

    -- Single data row: each Current/Best column is split into a days sub-cell
    -- and a weeks sub-cell (tappable, each shows its own date range), giving
    -- a 2x2 grid overall: [Current | Best] header, [days|weeks  days|weeks] data.
    local inner_gap        = math.floor(layout.column_gap / 2)
    local half_col_width   = math.floor((layout.col_width - inner_gap) / 2)

    local cd_line = buildValueLine(fonts.value, fonts.label, half_col_width, cd_val, cd_unit)
    local cw_line = buildValueLine(fonts.value, fonts.label, half_col_width, cw_val, cw_unit)
    local bd_line = buildValueLine(fonts.value, fonts.label, half_col_width, bd_val, bd_unit)
    local bw_line = buildValueLine(fonts.value, fonts.label, half_col_width, bw_val, bw_unit)

    local tap_cd = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=cd_line:getSize().h }, cd_line,
    }
    tap_cd.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_cd.dimen } } }
    function tap_cd:onTap() showStreakDatePopup(streaks.current_days_dates, false, true) return true end

    local tap_cw = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=cw_line:getSize().h }, cw_line,
    }
    tap_cw.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_cw.dimen } } }
    function tap_cw:onTap() showStreakDatePopup(streaks.current_weeks_dates, true, true) return true end

    local tap_bd = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=bd_line:getSize().h }, bd_line,
    }
    tap_bd.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_bd.dimen } } }
    function tap_bd:onTap() showStreakDatePopup(streaks.best_days_dates, false, false) return true end

    local tap_bw = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=bw_line:getSize().h }, bw_line,
    }
    tap_bw.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_bw.dimen } } }
    function tap_bw:onTap() showStreakDatePopup(streaks.best_weeks_dates, true, false) return true end

    local current_cell = HorizontalGroup:new{
        align = "center",
        UI.fixedCol(tap_cd, half_col_width),
        UI.buildColumnSeparator(inner_gap, tap_cd:getSize().h),
        UI.fixedCol(tap_cw, half_col_width),
    }
    local best_cell = HorizontalGroup:new{
        align = "center",
        UI.fixedCol(tap_bd, half_col_width),
        UI.buildColumnSeparator(inner_gap, tap_bd:getSize().h),
        UI.fixedCol(tap_bw, half_col_width),
    }

    local streak_data_row = UI.buildTwoColRow(current_cell, best_cell, layout)

    local streak_rows = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            UI.padded(layout.padding_h, streak_data_row),
        },
    }

    UI.addSectionWithRow(sections,
        streak_combined_header,
        streak_rows, layout, { pad_row = false })

    local year_header = buildYearHeader(fonts.section, layout, year_range, popup_self.selected_year)
    local yearly_row  = buildYearlyRow(popup_self, yearly_stats, fonts, layout)

    local chart = buildMonthlyChart(popup_self, monthly_data, layout, fonts)

    UI.addSectionWithRow(sections, year_header, yearly_row, layout, { pad_row = false, no_bottom_line = not chart })

    if chart then
        local chart_header_text = (popup_self.mode == VS.INSIGHTS_MODE_HOURS
            and _("Time read per month"))
            or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS
            and _("Books read per month"))
            or _("Days read per month")
        chart_header_text = chart_header_text
        --.. " \xe2\x80\xba"
        local chart_header = UI.buildSectionHeader(fonts.section, chart_header_text, layout.full_width)
        local tappable_chart_header = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = chart_header:getSize().w, h = chart_header:getSize().h },
            chart_header,
        }
        tappable_chart_header.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = tappable_chart_header.dimen } },
        }
        function tappable_chart_header:onTap()
            popup_self:cycleInsightsMode()
            return true
        end
        UI.addSectionWithRow(sections, tappable_chart_header, chart, layout, { add_divider = true, no_bottom_line = false })
    end

    -- Stale widget references from a previous build must be dropped even
    -- when the section is off, or onHold would still test taps against the
    -- coordinates the goal cells occupied back when it was on.
    popup_self._goal_cell_widget          = nil
    popup_self._goal_finished_cell_widget = nil

    if VS.Opt.readShowReadingGoal() then
        local goal_year      = popup_self.selected_year
        local finished_count = goal_finished_count or 0
        local goal_value     = VS.readReadingGoal(goal_year)

        local left_value = formatCount(finished_count)
        local left_unit  = N_("book finished", "books finished", finished_count)
        local left_line  = buildValueLine(fonts.value, fonts.label, layout.col_width, left_value, left_unit)

        local right_value = formatCount(goal_value)
        -- Reads as one sentence with the value above it: "30 books to read".
        local right_unit  = N_("book to read", "books to read", goal_value)
        local right_line  = buildValueLine(fonts.value, fonts.label, layout.col_width, right_value, right_unit)

        local left_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = left_line:getSize().h },
            left_line,
        }
        left_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = left_cell.dimen } },
        }
        function left_cell:onTap()
            popup_self:showFinishedBooksForYear(goal_year)
            return true
        end
        -- Also long-pressable (see ReadingInsightsPopup:onHold): opens the
        -- finished-books checklist to manually correct which books count.
        popup_self._goal_finished_cell_widget = left_cell

        -- No tap handler: the goal value is edited via long press (see
        -- ReadingInsightsPopup:onHold), which needs this widget's laid-out
        -- dimen to know where the goal cell ended up on screen.
        local right_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = right_line:getSize().h },
            right_line,
        }
        popup_self._goal_cell_widget = right_cell

        local goal_data_row = UI.buildTwoColRow(left_cell, right_cell, layout)
        local goal_row = VerticalGroup:new{
            align = "left",
            FrameContainer:new{
                bordersize = 0,
                padding    = 0,
                UI.padded(layout.padding_h, goal_data_row),
            },
        }

        local goal_header = UI.buildSectionHeader(fonts.section, buildGoalYearLabel(goal_year), layout.full_width)

        UI.addSectionWithRow(sections, goal_header, goal_row, layout, { pad_row = false })
    end -- if VS.Opt.readShowReadingGoal()

    do
        local all_hours = all_time_stats and all_time_stats.hours or 0
        local all_pages = all_time_stats and all_time_stats.pages or 0

        local all_secs_approx = (all_time_stats and all_time_stats.duration) or (all_hours * 3600)
        local all_time_val, all_time_unit = splitDurationValueUnit(all_secs_approx, _("reading time"))
        local all_pages_val  = formatCount(all_pages)
        local all_pages_unit = N_("page read", "pages read", all_pages)

        local left_line  = buildValueLine(fonts.value, fonts.label, layout.col_width, all_time_val,  all_time_unit)
        local right_line = buildValueLine(fonts.value, fonts.label, layout.col_width, all_pages_val, all_pages_unit)

        local left_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = left_line:getSize().h },
            left_line,
        }
        left_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = left_cell.dimen } },
        }
        function left_cell:onTap()
            popup_self:showAllBooks()
            return true
        end

        local right_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = right_line:getSize().h },
            right_line,
        }
        right_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = right_cell.dimen } },
        }
        function right_cell:onTap()
            popup_self:showAllBooks()
            return true
        end

        local all_time_row = UI.buildTwoColRow(left_cell, right_cell, layout)

        local all_book_count = all_time_stats and all_time_stats.book_count or 0
        local header_text = _("Total read")

        -- Tapping the header opens the reading heatmap popup (moved here
        -- from tapping the year, see showReadingHeatmap / buildYearHeader).
        local total_read_header = UI.buildSectionHeader(fonts.section, header_text, layout.full_width)
        local tappable_total_read_header = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = total_read_header:getSize().w, h = total_read_header:getSize().h },
            total_read_header,
        }
        tappable_total_read_header.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = tappable_total_read_header.dimen } },
        }
        function tappable_total_read_header:onTap()
            popup_self:showReadingHeatmap()
            return true
        end

        UI.addSectionWithRow(sections,
            tappable_total_read_header,
            all_time_row, layout, { no_bottom_line = true })
    end

    return sections
end

local ReadingInsightsPopup = InputContainer:extend{
    modal         = true,
    ui            = nil,
    width         = nil,
    height        = nil,
    selected_year = nil,
    mode          = nil,
    -- When true, the popup is being used as sleep-screen content: swipe-down,
    -- "any key", and the title bar's close tap are ignored so a stray touch
    -- or the wake key itself doesn't dismiss it early. Year navigation
    -- (left/right swipe or key) still works. Actually closing this instance
    -- is then the caller's responsibility (see main.lua's onResume).
    readonly      = false,
    -- Optional text shown in place of the (hidden, since readonly) close
    -- button, e.g. "sleeping…" / nil/"" shows nothing there.
    screensaver_label = nil,
}

-- Returns a { ["YYYY-MM-DD"] = seconds_read } map for the inclusive date
-- range [start_t, end_t] (timestamps at hour=12), by fetching every
-- calendar year the range touches via getDailyReadingData (1 or 2 years
-- for a half-year heatmap period) and filtering each down to just the
-- days inside the range.
function ReadingInsightsPopup:getDailyReadingDataForRange(start_t, end_t, shared_conn)
    local year_start = tonumber(os.date("%Y", start_t))
    local year_end   = tonumber(os.date("%Y", end_t))
    local start_str  = os.date("%Y-%m-%d", start_t)
    local end_str    = os.date("%Y-%m-%d", end_t)

    local merged = {}
    for year = year_start, year_end do
        local year_map = Data.getDailyReadingData(year, shared_conn)
        for dstr, seconds in pairs(year_map) do
            if dstr >= start_str and dstr <= end_str then
                merged[dstr] = seconds
            end
        end
    end
    return merged
end

-- Opens the "Reading heatmap" popup - tap the "Total read" header (see
-- buildInsightsSections) to open it, starting on the most recent
-- half-year; swipe left/right inside the popup to page through older/
-- newer half-years as far back as there's data.
function ReadingInsightsPopup:showReadingHeatmap()
    UIManager:show(Heatmap.Popup:new{ popup_self = self, periods_back = 0 })
end

-- Combines getFinishedBooksForYear's query-based list with the user's
-- manual overrides (see VS.readFinishedOverrides above) for that year: drops
-- any book explicitly overridden to "not finished", and adds any book
-- explicitly overridden to "finished" that the query didn't already
-- include (looked up from popup_self:getBooksForYear, the same candidate
-- pool the checklist itself is built from - see
-- ReadingInsightsPopup:showFinishedBooksChecklist below). This is what
-- both the goal section's tap-to-list (showFinishedBooksForYear) and the
-- checklist's own checkbox state are based on, so all three stay in sync.
-- The list is shown in the order the query returns it (last reading entry
-- first), and the two kinds of book added to it afterwards - the ones the
-- reader ticked by hand, and the hand-added ones - have to be merged into
-- that order rather than dropped at the end, or a book finished today
-- shows up below one finished in January.
local function sortByLastRead(books)
    table.sort(books, function(a, b)
        local ta, tb = a.last_read or 0, b.last_read or 0
        if ta == tb then return (a.title or "") < (b.title or "") end
        return ta > tb
    end)
    return books
end

local function getFinishedBooksForYearCombined(popup_self, year)
    local base_books = Data.getFinishedBooksForYear(year)
    local overrides = VS.readFinishedOverrides(year)

    -- The books the reader added by hand (lib/manual_books.lua) have no
    -- rows in the statistics DB at all, so no query can find them - they
    -- are appended here, as book-shaped entries with no reading time, so
    -- this list matches the goal count (which adds them the same way, see
    -- Data.applyFinishedOverrides).
    local manual_books = {}
    for _idx, e in ipairs(Manual.list(year)) do
        table.insert(manual_books, {
            title     = e.title,
            -- No author and no reading time in this list: the row is shown
            -- as a bare title (see BookList.showBookList's `manual` branch).
            authors   = "",
            duration  = 0,
            last_read = e.read_ts or e.ts or 0,
            manual    = true,
        })
    end

    if not next(overrides) then
        if #manual_books == 0 then return base_books end
        local out = {}
        for _idx, b in ipairs(base_books) do table.insert(out, b) end
        for _idx, b in ipairs(manual_books) do table.insert(out, b) end
        return sortByLastRead(out)
    end

    local by_id = {}
    for _, b in ipairs(base_books) do
        by_id[tostring(b.id_book)] = b
    end

    local result = {}
    for _, b in ipairs(base_books) do
        if overrides[tostring(b.id_book)] ~= false then
            table.insert(result, b)
        end
    end

    local missing = false
    for id_str, val in pairs(overrides) do
        if val == true and not by_id[id_str] then
            missing = true
            break
        end
    end
    if missing then
        local candidates = popup_self:getBooksForYear(year)
        for _, b in ipairs(candidates) do
            local id_str = tostring(b.id_book)
            if overrides[id_str] == true and not by_id[id_str] then
                table.insert(result, b)
            end
        end
    end

    for _idx, b in ipairs(manual_books) do
        table.insert(result, b)
    end

    return sortByLastRead(result)
end

-- Build and show the 8-week trend popup for the given metric:
-- "time_total" | "pages_total" | "time_avg" | "pages_avg".
function ReadingInsightsPopup:showWeeklyTrendPopup(metric)
    local weeks = Data.getLast8WeeksData()
    if not weeks or #weeks == 0 then
        UIManager:show(InfoMessage:new{ text = _("No streak dates") })
        return
    end

    local has_data = false
    for _, w in ipairs(weeks) do
        if (w.seconds or 0) > 0 or (w.pages or 0) > 0 then
            has_data = true
            break
        end
    end
    if not has_data then
        UIManager:show(InfoMessage:new{ text = _("No reading data in the last 8 weeks") })
        return
    end

    local fonts  = getCachedFonts()
    local inner_padding = Size.padding.large
    local box_width   = math.floor(Screen:getWidth() * 0.86)
    local chart_width = box_width - 2 * inner_padding

    local title_w = TextWidget:new{ text = Trend.trendTitle(metric), face = fonts.section, fgcolor = Colors.section() }
    local title_centered = CenterContainer:new{
        dimen = Geom:new{ w = chart_width, h = title_w:getSize().h }, title_w,
    }

    local value_w = TextWidget:new{ text = Trend.totalForMetric(metric, weeks), face = fonts.value, fgcolor = Colors.value() }
    local value_centered = CenterContainer:new{
        dimen = Geom:new{ w = chart_width, h = value_w:getSize().h }, value_w,
    }

    local chart_widget = Trend.buildLine8WeekChart(weeks, metric, chart_width, fonts)

    local content = VerticalGroup:new{
        align = "center",
        title_centered,
        VerticalSpan:new{ height = Size.padding.default },
        value_centered,
        VerticalSpan:new{ height = Size.padding.large },
        chart_widget,
    }

    local box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }

    UIManager:show(Trend.Popup:new{ box_content = box })
end

function ReadingInsightsPopup:getBooksForMonth(year_month)
    return Data.getBooksForPeriod("%Y-%m", year_month)
end

function ReadingInsightsPopup:showBooksForMonth(year_month, month_label_full)
    local books = self:getBooksForMonth(year_month)
    local total_secs = Data.sumDuration(books)
    local title = T(N_("%1 - book read %2", "%1 - books read %2", #books), month_label_full, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")"
    BookList.showBooksForPeriod(
        self, books,
        T(_("No books read in %1"), month_label_full),
        title)
end

-- Open CalendarView for the given "YYYY-MM" string.
-- Closes this popup first; reopens it when CalendarView is dismissed.
function ReadingInsightsPopup:openCalendarForMonth(year_month)
    local year  = tonumber(year_month:sub(1, 4))
    local month = tonumber(year_month:sub(6, 7))
    if not year or not month then return end

    local ok, CalendarView = pcall(require, "ui/widget/calendarview")
    if not ok or not CalendarView then
        ok, CalendarView = pcall(require, "calendarview")
    end
    if not ok or not CalendarView then
        UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
        return
    end

    -- Save state so the popup can be recreated after CalendarView closes.
    local saved_year             = self.selected_year
    local saved_mode             = self.mode
    local saved_ui               = self.ui
    local saved_streaks          = self._streaks
    local saved_yr               = self._year_range
    local saved_yearly           = self._yearly
    local saved_monthly          = self._monthly
    local saved_all_time         = self._all_time
    local saved_goal_finished    = self._goal_finished
    local saved_last_week        = self._last_week
    local saved_last_week_daily  = self._last_week_daily

    self._closed = true
    UIManager:close(self)

    -- Wait one frame so the popup is fully closed before opening CalendarView.
    UIManager:scheduleIn(0, function()
        local stats_plugin = saved_ui and saved_ui.statistics or nil

        local function reopen_popup()
            local p = ReadingInsightsPopup:new{
                ui               = saved_ui,
                selected_year    = saved_year,
                mode             = saved_mode,
                _streaks         = saved_streaks,
                _year_range      = saved_yr,
                _yearly          = saved_yearly,
                _monthly         = saved_monthly,
                _all_time        = saved_all_time,
                _goal_finished   = saved_goal_finished,
                _last_week       = saved_last_week,
                _last_week_daily = saved_last_week_daily,
            }
            UIManager:show(p)
        end

        local reopened = false
        local function reopen_once()
            if reopened then return end
            reopened = true
            UIManager:scheduleIn(0, reopen_popup)
        end

        local cv
        cv = CalendarView:new{
            reader_statistics = stats_plugin,
            shown_year        = year,
            shown_month       = month,
            close_callback    = function()

                reopen_once()
            end,
        }
        -- onCloseWidget fires on all dismiss paths; the flag prevents double-open.
        local orig_onCloseWidget = cv.onCloseWidget
        cv.onCloseWidget = function(self_cv, ...)
            if orig_onCloseWidget then orig_onCloseWidget(self_cv, ...) end
            reopen_once()
        end
        UIManager:show(cv)
    end)
end

-- Open today's reading timeline (CalendarDayView) for the current day.
-- Closes this popup first; reopens it when the timeline is dismissed.
function ReadingInsightsPopup:openTodayTimeline()
    local ok, CalendarView = pcall(require, "ui/widget/calendarview")
    if not ok or not CalendarView then
        ok, CalendarView = pcall(require, "calendarview")
    end
    if not ok or not CalendarView then
        UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
        return
    end

    -- Save state so the popup can be recreated after the timeline closes.
    local saved_year             = self.selected_year
    local saved_mode             = self.mode
    local saved_ui               = self.ui
    local saved_streaks          = self._streaks
    local saved_yr               = self._year_range
    local saved_yearly           = self._yearly
    local saved_monthly          = self._monthly
    local saved_all_time         = self._all_time
    local saved_goal_finished    = self._goal_finished
    local saved_last_week        = self._last_week
    local saved_last_week_daily  = self._last_week_daily

    self._closed = true
    UIManager:close(self)

    -- Wait one frame so the popup is fully closed before opening the timeline.
    UIManager:scheduleIn(0, function()
        local stats_plugin = saved_ui and saved_ui.statistics or nil
        if not stats_plugin then
            UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
            return
        end

        local function reopen_popup()
            local p = ReadingInsightsPopup:new{
                ui               = saved_ui,
                selected_year    = saved_year,
                mode             = saved_mode,
                _streaks         = saved_streaks,
                _year_range      = saved_yr,
                _yearly          = saved_yearly,
                _monthly         = saved_monthly,
                _all_time        = saved_all_time,
                _goal_finished   = saved_goal_finished,
                _last_week       = saved_last_week,
                _last_week_daily = saved_last_week_daily,
            }
            UIManager:show(p)
        end

        local reopened = false
        local function reopen_once()
            if reopened then return end
            reopened = true
            UIManager:scheduleIn(0, reopen_popup)
        end

        -- CalendarView:showCalendarDayView() builds and shows the day's
        -- CalendarDayView for us (its day_ts logic respects the user's
        -- configured calendar_day_start_hour/minute), but it doesn't expose
        -- a close_callback hook. We build a CalendarView purely to call
        -- that helper (it's never itself shown), and intercept the single
        -- UIManager:show() call it makes so we can attach our own
        -- close_callback / onCloseWidget before the widget is painted.
        local cv = CalendarView:new{ reader_statistics = stats_plugin }

        local orig_show = UIManager.show
        UIManager.show = function(mgr, widget, ...)
            UIManager.show = orig_show -- one-shot: restore immediately
            widget.close_callback = reopen_once
            local orig_onCloseWidget = widget.onCloseWidget
            widget.onCloseWidget = function(self_w, ...)
                if orig_onCloseWidget then orig_onCloseWidget(self_w, ...) end
                reopen_once()
            end
            return orig_show(mgr, widget, ...)
        end

        cv:showCalendarDayView(stats_plugin)
    end)
end

-- Open CalendarView for today's month.
function ReadingInsightsPopup:openCalendarForCurrentMonth()
    local year_month = os.date("%Y-%m")
    self:openCalendarForMonth(year_month)
end

function ReadingInsightsPopup:getBooksForYear(year)
    return Data.getBooksForPeriod("%Y", tostring(year))
end

function ReadingInsightsPopup:showAllBooks()
    local books = Data.getAllBooks()
    local total_secs = Data.sumDuration(books)
    BookList.showBooksForPeriod(
        self, books,
        _("No books read"),
        T(_("All books read %1"), formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
end

function ReadingInsightsPopup:showBooksForYear(year)
    local books = self:getBooksForYear(year)
    local total_secs = Data.sumDuration(books)
    BookList.showBooksForPeriod(
        self, books,
        _("No books read in ") .. year,
        T(N_("%1 - book read %2", "%1 - books read %2", #books), year, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
end

-- Tap target for the reading-goal section's left cell ("N book(s)
-- finished"). Uses the same "last entry >= 99% progress" definition as
-- getFinishedBookCountForYear.
function ReadingInsightsPopup:showFinishedBooksForYear(year)
    local books = getFinishedBooksForYearCombined(self, year)
    local total_secs = Data.sumDuration(books)
    BookList.showBooksForPeriod(
        self, books,
        T(_("No books finished in %1"), tostring(year)),
        T(N_("%1 - book finished %2", "%1 - books finished %2", #books), tostring(year), formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")",
        -- This list is about *when* each book was finished (it's ordered by
        -- that), so its value column shows the date rather than the time
        -- spent - see BookList.showBookList's opts.show_dates.
        { show_dates = true })
end

function ReadingInsightsPopup:showFinishedBooksChecklist(year)
    BookList.showFinishedChecklist(self, year)
end

-- The other half of the long-press menu on the same cell: the reader's own
-- list of books the statistics DB knows nothing about (see
-- lib/manual_books.lua), kept per year - the year currently shown by the
-- popup is the one entries are added to.
function ReadingInsightsPopup:showManualBooksList(year)
    BookList.showManualBooks(self, year)
end

-- Long press on the reading goal's "N book(s) finished" cell. Two ways to
-- correct that count, so the press opens a chooser rather than one of them
-- directly: the checklist for books the statistics DB does know about, and
-- the hand-kept list for the ones it doesn't.
function ReadingInsightsPopup:showFinishedBooksMenu(year)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        -- The insights popup itself is modal, and UIManager puts non-modal
        -- windows below the topmost modal one - without this the chooser
        -- would open behind the popup that spawned it.
        modal       = true,
        title       = T(_("Books finished in %1"), tostring(year)),
        title_align = "center",
        buttons = {
            {{
                text = _("Mark books finished"),
                callback = function()
                    UIManager:close(dialog)
                    self:showFinishedBooksChecklist(year)
                end,
            }},
            {{
                text = _("Add books manually"),
                callback = function()
                    UIManager:close(dialog)
                    self:showManualBooksList(year)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Normally just "Reading insights"; when shown as a sleep-screen (readonly)

-- with a text indicator configured, appends it, e.g. "Reading insights
-- (sleeping…)".
function ReadingInsightsPopup:_titleBarText()
    local title = _("Reading insights")
    if self.readonly and self.screensaver_label and self.screensaver_label ~= "" then
        title = title .. " (" .. self.screensaver_label .. ")"
    end
    return title
end

function ReadingInsightsPopup:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local fonts    = getCachedFonts()
    local layout   = getCachedLayout()

    -- Cold start (e.g. right after a KOReader restart): no cache, no stale
    -- data, nothing to show yet. Rather than flashing zeroed-out sections
    -- for a moment, show a plain loading message; _loadAndRebuild() will
    -- call _buildUI() again as soon as real data is available.
    if self._initial_loading then
        local title_bar_inner = TitleBar:new{
            fullscreen     = true,
            width          = screen_w,
            align          = "left",
            title          = self:_titleBarText(),
            close_callback = (not self.readonly) and function() UIManager:close(self) end or nil,
            show_parent    = self,
            top_v_padding    = Size.padding.default,
            bottom_v_padding = Size.padding.default,
        }
        self._title_bar_height = title_bar_inner:getSize().h

        self.popup_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            radius     = 0,
            padding    = 0,
            width      = screen_w,
            height     = screen_h,
            VerticalGroup:new{
                align = "left",
                title_bar_inner,
                CenterContainer:new{
                    dimen = Geom:new{ w = screen_w, h = screen_h - title_bar_inner:getSize().h },
                    TextWidget:new{
                        text = _("Loading data…"),
                        face = fonts.label,
                        fgcolor = Colors.label(),
                    },
                },
            },
        }
        self.popup_frame.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self[1] = VerticalGroup:new{ self.popup_frame }
        return
    end

    -- One full pass: build the sections with whatever bar heights are
    -- currently in force (VS.Opt.auto_height in auto mode, see
    -- VS.Opt.weeklyBarHeight/monthlyBarHeight) and wrap them in the
    -- scrollable content group.
    -- Returns the group plus its total height, which is what the auto-fit
    -- loop below compares against the screen height.
    local auto_fit    = VS.Opt.readBarHeightAuto()
    local bottom_span = auto_fit and Size.padding.large or nil

    local function buildContent()
        VS.Opt.built_weekly  = false
        VS.Opt.built_monthly = false

        local sections = buildInsightsSections(
            self,
            self._streaks    or { current_days=0, best_days=0, current_weeks=0, best_weeks=0 },
            self._yearly     or { days=0, pages=0, duration=0 },
            self._year_range or { min_year=self.selected_year, max_year=self.selected_year },
            self._monthly    or {},
            self._all_time   or { hours=0, pages=0 },
            self._last_week  or { avg_seconds=0, avg_pages=0 },
            self._last_week_daily or nil,
            fonts, layout,
            self._goal_finished)

        local title_bar_inner = TitleBar:new{
            fullscreen     = true,
            width          = screen_w,
            align          = "left",
            title          = self:_titleBarText(),
            close_callback = (not self.readonly) and function() UIManager:close(self) end or nil,
            show_parent    = self,
            top_v_padding    = Size.padding.default,
            bottom_v_padding = Size.padding.default,
        }

        local title_bar_h = title_bar_inner:getSize().h
        self._title_bar_height = title_bar_h

        -- Manual mode keeps the generous title-bar-tall bottom spacer it
        -- always had (the page is expected to scroll there anyway); auto
        -- mode uses a small one, so the space it would have eaten goes to
        -- the charts instead.
        local group = VerticalGroup:new{
            align = "left",
            title_bar_inner,
            UI.padded(layout.padding_h, Colors.newBar(layout.content_width, Size.line.thick, Colors.separator())),
            sections,
            VerticalSpan:new{ height = bottom_span or title_bar_h },
        }
        return group, group:getSize().h
    end

    -- Auto-fit: grow/shrink the two adjustable charts until the page is as
    -- close to exactly one screen tall as it can get without going over
    -- (which is what makes the scroll bar appear).
    --
    -- Each build is measured rather than predicted, because a lot of what
    -- surrounds the charts has data- and font-dependent height (year
    -- header, streak rows, wrapped labels...). The per-point pixel cost of
    -- a bar is known though (Screen:scaleBySize is linear), so one
    -- measurement is enough to compute the next candidate directly instead
    -- of stepping towards it - in practice this settles in one or two extra
    -- builds on the very first open, and in zero afterwards, since the
    -- heights that fit last time are kept as the next starting guess.
    local content, content_h = buildContent()

    local adjusted = false
    if auto_fit then
        local px_per_point = Screen:scaleBySize(1000) / 1000
        if px_per_point <= 0 then px_per_point = 1 end

        for _ = 1, 4 do
            local n_charts = (VS.Opt.built_weekly and 1 or 0) + (VS.Opt.built_monthly and 1 or 0)
            if n_charts == 0 then break end -- nothing adjustable on this page

            local slack_px = screen_h - content_h
            -- Good enough: it fits, with less than two points of growth
            -- left over - one for the granularity of a single point of bar
            -- height, one for the safety point taken off below. Without
            -- that second point every reopen would see the safety point as
            -- room to grow, hand it back, take it off again, and pay for
            -- two extra builds to end up exactly where it started.
            if slack_px >= 0 and slack_px < px_per_point * n_charts * 2 then break end

            local delta_points = math.floor(slack_px / (px_per_point * n_charts))
            if delta_points == 0 then
                -- Overflowing by less than one point per chart: still has
                -- to come off, or the scroll bar stays.
                delta_points = (slack_px < 0) and -1 or 0
            end
            if delta_points == 0 then break end

            local current = VS.Opt.auto_height or VS.DEFAULT_MONTHLY_BAR_HEIGHT
            local new_height = math.max(VS.Opt.AUTO_MIN,
                math.min(VS.Opt.AUTO_MAX, current + delta_points))

            -- Clamped, so another build would produce the exact same page:
            -- give up and let it scroll (tiny screen, huge fonts) or stay
            -- slightly short (huge screen, few sections).
            if new_height == current then break end

            VS.Opt.auto_height = new_height
            adjusted = true

            local discarded = content
            content, content_h = buildContent()
            -- Free the measured-then-thrown-away build; failure here is
            -- harmless (worst case it's collected later), so it must never
            -- take the popup down with it.
            pcall(function() if discarded.free then discarded:free() end end)
        end

        -- One point of headroom on top of the fit. The loop stops at the
        -- largest height that still measured as fitting, which leaves the
        -- page exactly as tall as the screen - close enough to the edge
        -- that a font or spacing that rounds differently on some other
        -- device would tip it into showing a scroll bar. Giving the bars a
        -- point back costs a few pixels of chart and removes that risk.
        --
        -- Only when this build actually adjusted something: on later opens
        -- the loop breaks immediately with the remembered height, and
        -- subtracting again each time would shrink the charts away.
        if adjusted and (VS.Opt.auto_height or 0) > VS.Opt.AUTO_MIN then
            VS.Opt.auto_height = VS.Opt.auto_height - 1
            local discarded = content
            content, content_h = buildContent()
            pcall(function() if discarded.free then discarded:free() end end)
        end
    end

    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")

    self.scroll_container = ScrollableContainer:new{
        dimen               = Geom:new{ w = screen_w, h = screen_h },
        show_parent         = self,
        scroll_bar_position = "right",
        content,
    }

    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        radius     = 0,
        padding    = 0,
        width      = screen_w,
        VerticalGroup:new{
            align = "left",
            self.scroll_container,
        },
    }

    self.popup_frame.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    self[1] = VerticalGroup:new{ self.popup_frame }
end

function ReadingInsightsPopup:_loadAndRebuild()
    -- Re-fetch everything over one shared DB connection (seven open/close
    -- cycles become one). Each getter still manages its own cache and works
    -- without a connection, so this only saves the redundant opens; the
    -- connection is opened and closed by the data module (see
    -- Data.withBatchConnection), leaving this file with no DB knowledge.
    local batch = Data.withBatchConnection(function(conn)
        local monthly
        if self.mode == VS.INSIGHTS_MODE_HOURS then
            monthly = Data.getMonthlyReadingHours(self.selected_year, conn)
        elseif self.mode == VS.INSIGHTS_MODE_BOOKS then
            monthly = Data.getMonthlyBookCounts(self.selected_year, conn)
        else
            monthly = Data.getMonthlyReadingDays(self.selected_year, conn)
        end
        local last_week, last_week_daily = Data.getLastWeekAll(conn)
        return {
            streaks    = Data.calculateStreaks(conn),
            year_range = Data.getYearRange(conn),
            yearly     = Data.getYearlyStats(self.selected_year, conn),
            all_time   = Data.getAllTimeStats(conn),
            -- Only worth querying when the section that displays it is on.
            goal_finished = VS.Opt.readShowReadingGoal()
                and Data.getFinishedBookCountForYear(self.selected_year, conn)
                or nil,
            last_week       = last_week,
            last_week_daily = last_week_daily,
            monthly         = monthly,
        }
    end) or {}

    local new_streaks         = batch.streaks
    local new_year_range      = batch.year_range
    local new_yearly          = batch.yearly
    local new_all_time        = batch.all_time
    local new_goal_finished   = batch.goal_finished
    local new_last_week       = batch.last_week
    local new_last_week_daily = batch.last_week_daily
    local new_monthly         = batch.monthly

    -- Skip rebuild if nothing actually displayed would change - compared by
    -- value, not by table reference (see valuesEqual() for why reference
    -- equality isn't enough now that all_time/yearly refresh every minute).
    -- Exception: coming out of the cold-start "Loading data..." placeholder
    -- always needs a rebuild, even if the freshly-loaded values happen to
    -- be all-zero (e.g. a brand new, still-empty statistics.sqlite3).
    local was_initial_loading = self._initial_loading
    if not was_initial_loading and
       valuesEqual(new_streaks,         self._streaks)         and
       valuesEqual(new_year_range,      self._year_range)      and
       valuesEqual(new_yearly,          self._yearly)          and
       valuesEqual(new_all_time,        self._all_time)        and
       valuesEqual(new_goal_finished,   self._goal_finished)   and
       valuesEqual(new_last_week,       self._last_week)       and
       valuesEqual(new_last_week_daily, self._last_week_daily) and
       valuesEqual(new_monthly,         self._monthly)         then
        -- Still adopt the new table references so future comparisons are
        -- against the freshest cache entries, but skip the rebuild/redraw.
        self._streaks         = new_streaks
        self._year_range      = new_year_range
        self._yearly          = new_yearly
        self._all_time        = new_all_time
        self._goal_finished   = new_goal_finished
        self._last_week       = new_last_week
        self._last_week_daily = new_last_week_daily
        self._monthly         = new_monthly
        Cache.saveDiskCache()
        return
    end

    self._streaks          = new_streaks
    self._year_range       = new_year_range
    self._yearly           = new_yearly
    self._all_time         = new_all_time
    self._goal_finished    = new_goal_finished
    self._last_week        = new_last_week
    self._last_week_daily = new_last_week_daily
    self._monthly         = new_monthly
    self._initial_loading = false

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    Cache.saveDiskCache()
end

-- init() shows cached/stale data immediately, then _loadAndRebuild() refreshes in the background.
function ReadingInsightsPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Write the current (in-memory, not yet saved) reading session into
    -- statistics.sqlite3, then invalidate the "Last week" cache so it is
    -- always re-queried from the DB on every open of this popup - not just
    -- once per minute. Older cached/stale values are still shown instantly
    -- below (stale-while-revalidate); _loadAndRebuild() then replaces them
    -- with the freshly-flushed numbers a moment later.
    Data.flushStatsToDB(self.ui)
    Cache._cache.last_week              = nil
    Cache._cache.last_week_minute       = nil
    Cache._cache.last_week_daily        = nil
    Cache._cache.last_week_daily_minute = nil

    -- Use fresh cache if available.
    if Cache.ENABLE_CACHE then
        self._streaks    = self._streaks    or Cache._cache.streaks
        local minute = Cache.currentMinute()
        self._year_range = self._year_range or Cache._cache.year_range
        self._all_time   = self._all_time   or Cache._cache.all_time
        local year_key = (self.selected_year or tonumber(os.date("%Y"))) .. ":v3:" .. Cache.todayDateStr()
        self._yearly  = self._yearly  or Cache._yearly_cache[year_key]
        local mode = VS.normalizeInsightsMode(self.mode or VS.readInsightsMode())
        local month_key = VS.monthKeyPrefixForMode(mode) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":" .. Cache.todayDateStr()
        self._monthly = self._monthly or Cache._monthly_cache[month_key]
        if not self._last_week or not self._last_week_daily then
            local lw_cached    = Cache.getMinuteCache(Cache._cache, "last_week", "last_week_minute", minute)
            local daily_cached = Cache.getMinuteCache(Cache._cache, "last_week_daily", "last_week_daily_minute", minute)
            self._last_week       = self._last_week       or lw_cached
            self._last_week_daily = self._last_week_daily or daily_cached
        end
    end

    -- Fall back to stale cache for anything still missing (e.g. after a restart or day rollover).
    if Cache.ENABLE_CACHE then
        local year_key_any   = (self.selected_year or tonumber(os.date("%Y"))) .. ":v3:"
        local mode_fb = VS.normalizeInsightsMode(self.mode or VS.readInsightsMode())
        local month_key_fb = VS.monthKeyPrefixForMode(mode_fb) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":"

        if not self._streaks then
            self._streaks = Cache._stale_cache.streaks
        end

        if not self._year_range then
            self._year_range = Cache._stale_cache.year_range
            -- Ensure selected_year stays within the stale range if we got one.
            if self._year_range and self.selected_year then
                if self.selected_year < self._year_range.min_year then
                    self.selected_year = self._year_range.min_year
                elseif self.selected_year > self._year_range.max_year then
                    self.selected_year = self._year_range.max_year
                end
            end
        end

        if not self._all_time then
            self._all_time = Cache._stale_cache.all_time
        end

        if not self._last_week then
            self._last_week = Cache._stale_cache.last_week
        end

        if not self._last_week_daily then
            self._last_week_daily = Cache._stale_cache.last_week_daily
        end
        -- Find any stale yearly entry for the current year.
        if not self._yearly then
            self._yearly = Cache.findStaleByPrefix(Cache._stale_yearly, year_key_any)
        end
        -- Find any stale monthly entry for the current year + mode.
        if not self._monthly then
            self._monthly = Cache.findStaleByPrefix(Cache._stale_monthly, month_key_fb)
        end
        -- The finished-book count for the reading-goal section: seeded
        -- straight from the persisted, disk-backed finished-books list
        -- (see getFinishedBookCountForYear) rather than left nil, so the
        -- popup doesn't open showing "0 books finished" for a moment
        -- before _loadAndRebuild() replaces it with the real count a beat
        -- later.
        if not self._goal_finished then
            local goal_year_key = tostring(self.selected_year or tonumber(os.date("%Y")))
            local known = Cache._goal_finished_books[goal_year_key]
            if type(known) == "table" then
                local c = 0
                for _ in pairs(known) do c = c + 1 end
                self._goal_finished = Data.applyFinishedOverrides(goal_year_key, c)
            end
        end
    end

    self.mode = VS.normalizeInsightsMode(self.mode or VS.readInsightsMode())
    self.weekly_chart_mode = VS.normalizeWeeklyChartMode(self.weekly_chart_mode or VS.readWeeklyChartMode())

    -- True only on a genuine cold start (e.g. right after a KOReader restart):
    -- no fresh cache and no stale fallback for any of the core stats. In that
    -- case _buildUI() shows a "Loading data..." placeholder instead of a
    -- flash of zeroed-out sections; cleared as soon as _loadAndRebuild()
    -- brings in real data.
    self._initial_loading = not (self._streaks or self._yearly or self._monthly
        or self._all_time or self._last_week or self._goal_finished)

    -- selected_year needs an initial value before _loadAndRebuild runs.
    if not self.selected_year then
        self.selected_year = tonumber(os.date("%Y"))
    end

    self.dimen = Geom:new{ w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        -- Hold handled at popup level to avoid ScrollableContainer eating inner Hold events.
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
        self.ges_events.Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end

    -- Build UI immediately with available data; refresh in background.
    -- Small delay (not 0) so the initial paint actually lands on screen
    -- before _loadAndRebuild() (which now recomputes all_time/yearly on
    -- almost every open, not just once a day) can trigger a second redraw.
    self:_buildUI()
    UIManager:scheduleIn(0.1, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
end

function ReadingInsightsPopup:onSwipe(arg, ges_ev)
    if not ges_ev then return false end
    local dir = ges_ev.direction
    if dir == "west" or dir == "left"  then return self:onGoToNextYear() end
    if dir == "east" or dir == "right" then return self:onGoToPrevYear() end
    if dir == "south" or dir == "down" then
        if self.readonly then return true end
        UIManager:close(self)
        return true
    end
    return false
end

-- Hold dispatch by touch position:
--   title bar      → cache reload
--   chart header   → CalendarView for current month
--   goal value     → edit the reading goal for the currently shown year
function ReadingInsightsPopup:onHold(arg, ges_ev)
    if not ges_ev or not ges_ev.pos then return true end
    local pos = ges_ev.pos

    local title_h = self._title_bar_height
    if title_h and pos.y <= title_h then
        local msg = InfoMessage:new{ text = _("Reloading data...") }
        UIManager:show(msg)
        UIManager:scheduleIn(0.5, function()
            UIManager:close(msg)
            Cache.clearAllCache()
            self._streaks         = nil
            self._yearly          = nil
            self._monthly         = nil
            self._all_time        = nil
            self._last_week       = nil
            self._last_week_daily = nil
            self:_loadAndRebuild()
        end)
        return true
    end

    if self._current_month_bar_widget then
        local d = self._current_month_bar_widget.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            self:openCalendarForCurrentMonth()
            return true
        end
    end

    if self._goal_cell_widget then
        local d = self._goal_cell_widget.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            self:editReadingGoal(self.selected_year)
            return true
        end
    end

    if self._goal_finished_cell_widget then
        local d = self._goal_finished_cell_widget.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            self:showFinishedBooksMenu(self.selected_year)
            return true
        end
    end

    return true
end

-- Opens a numeric picker (long press on the goal value in the reading-goal
-- section) to set/change that year's target. Saved immediately on "Save";
-- the popup is rebuilt in place so the new value shows without a full
-- close/reopen.
function ReadingInsightsPopup:editReadingGoal(year)
    local SpinWidget = require("ui/widget/spinwidget")
    local popup_self = self
    local widget
    widget = SpinWidget:new{
        -- ReadingInsightsPopup itself is modal = true (see its class
        -- definition above). UIManager stacks a *non*-modal widget shown
        -- while a modal one is already on top *underneath* that modal
        -- widget, not above it (see UIManager:show()'s window-stack
        -- ordering) - so without this, the goal-edit dialog would be
        -- pushed behind the popup and effectively invisible/untappable,
        -- rather than appearing on top of it as intended.
        modal           = true,
        title_text      = buildGoalEditTitle(year),
        value           = VS.readReadingGoal(year),
        value_min       = 1,
        value_max       = 999,
        value_step      = 1,
        value_hold_step = 5,
        default_value   = VS.DEFAULT_READING_GOAL,
        ok_text         = _("Save"),
        callback        = function(spin)
            VS.saveReadingGoal(year, spin.value)
            popup_self:_buildUI()
            UIManager:setDirty(popup_self, function()
                return "ui", popup_self.popup_frame.dimen
            end)
        end,
    }
    UIManager:show(widget)
end

-- Cycles the insights mode (hours -> days -> books -> hours) and reloads
-- the monthly chart for it. Bound to both the "Press" key handler
-- (toggleInsightsMode) and tapping the monthly chart header
-- (cycleInsightsMode) - kept as two names since that's what the gesture/key
-- wiring elsewhere calls, but there's only one implementation.
function ReadingInsightsPopup:cycleInsightsMode()
    local new_mode
    if self.mode == VS.INSIGHTS_MODE_HOURS then
        new_mode = VS.INSIGHTS_MODE_DAYS
    elseif self.mode == VS.INSIGHTS_MODE_DAYS then
        new_mode = VS.INSIGHTS_MODE_BOOKS
    else
        new_mode = VS.INSIGHTS_MODE_HOURS
    end

    VS.saveInsightsMode(new_mode)
    self.mode = new_mode

    local month_key_fb = VS.monthKeyPrefixForMode(new_mode) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":"
    self._monthly = Cache.findStaleByPrefix(Cache._stale_monthly, month_key_fb)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    UIManager:scheduleIn(0, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
    return true
end

function ReadingInsightsPopup:toggleInsightsMode()
    return self:cycleInsightsMode()
end

-- Toggles the "Last week" bar chart between reading time and pages read per
-- day. No DB re-query is needed: both values are already fetched together
-- by getLastWeekAll(), so this just flips the persisted display mode and
-- rebuilds the UI.
function ReadingInsightsPopup:toggleWeeklyChartMode()
    local new_mode = (self.weekly_chart_mode == VS.WEEKLY_CHART_MODE_PAGES)
        and VS.WEEKLY_CHART_MODE_TIME or VS.WEEKLY_CHART_MODE_PAGES

    self.weekly_chart_mode = new_mode
    VS.saveWeeklyChartMode(new_mode)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Shared implementation for year navigation: moves selected_year by `delta`
-- (-1 or +1), staying within the known year range, serves stale yearly/
-- monthly data for the new year immediately, then reloads for real.
function ReadingInsightsPopup:_goToYear(delta)
    local yr = self._year_range or self.year_range
    if not yr then return true end
    local new_year = self.selected_year + delta
    if new_year < yr.min_year or new_year > yr.max_year then return true end

    self.selected_year = new_year
    self._monthly = nil
    self._yearly  = nil
    -- Serve stale data for the target year immediately.
    local year_key_any = self.selected_year .. ":v3:"
    local mode_fb       = self.mode or VS.INSIGHTS_MODE_HOURS
    local month_key_fb  = VS.monthKeyPrefixForMode(mode_fb) .. self.selected_year .. ":"
    self._yearly  = Cache.findStaleByPrefix(Cache._stale_yearly, year_key_any)
    self._monthly = Cache.findStaleByPrefix(Cache._stale_monthly, month_key_fb)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    UIManager:scheduleIn(0, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
    return true
end

function ReadingInsightsPopup:onGoToPrevYear()
    return self:_goToYear(-1)
end

function ReadingInsightsPopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:onGoToPrevYear() end
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:onGoToNextYear() end
    if key and key:match({ { "Press" } }) then return self:toggleInsightsMode() end
    if self.readonly then return true end
    UIManager:close(self)
    return true
end

function ReadingInsightsPopup:onGoToNextYear()
    return self:_goToYear(1)
end

function ReadingInsightsPopup:onShow()
    if VS.readFullRefreshSetting() then
        UIManager:setDirty(self, function()
            return "full", self.popup_frame.dimen
        end)
    else
        UIManager:setDirty(self, function()
            return "ui", self.popup_frame.dimen
        end)
    end
    return true
end

function ReadingInsightsPopup:onTapClose()
    if self.readonly then return true end
    UIManager:close(self)
    return true
end

function ReadingInsightsPopup:onCloseWidget()
    self._closed = true
    if self.scroll_container then
        self.scroll_container:free()
    end
    if VS.readFullRefreshSetting() then
        UIManager:setDirty(nil, "full")
    else
        UIManager:setDirty(nil, "ui")
    end
end

-- The book-list popups replace this popup and reopen it when they close, so
-- they need the class and a few of the helpers defined above. Registering
-- them here (rather than having booklist_view.lua require this file back)
-- keeps the dependency one-way.
Heatmap.bind{
    getCachedFonts = getCachedFonts,
    parseDateYMD   = Data.parseDateYMD,
}

BookList.bind{
    popup_class             = ReadingInsightsPopup,
    getFinishedBooksForYear = Data.getFinishedBooksForYear,
    formatHHMMSS            = formatHHMMSS,
}

-- Module export.
--
-- Just the Popup class main.lua instantiates on demand. The setting
-- accessors that used to be re-exported from here now live in
-- lib/insights_settings.lua, which main.lua loads itself and hands to this
-- file - so the Tools-menu entries read and write exactly the same
-- functions this view does, without the view having to pass them through.
return {
    Popup = ReadingInsightsPopup,
}
