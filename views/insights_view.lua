--[[
Reading Insights - the full-screen insights popup.

Draws the scrollable page of reading history and handles everything on it:
year navigation, the taps that open the other popups, and the layout of the
sections. The figures themselves come from lib/insights_data.lua; nothing
here reads the statistics DB.

Sections, top to bottom:
  - Last 7 days   7-day totals and averages + daily bar chart (or, with the
                  "Current week" view setting, one pageable calendar week)
  - Streaks       current and best daily/weekly streaks
  - Year          time, days read or books read + pages, per year
  - Monthly chart per-month bars; the header cycles hours/days/books
  - Reading goal  finished books vs. a per-year target (can be switched off
                  in Settings > Reading insights popup)
  - All time    all-time totals

Gestures:
  - Tap "All time" header            reading heatmap (swipe there to page
                                       through older periods)
  - Tap yearly value or monthly bar/dot  book list for that period
  - Tap monthly chart header           cycle hours/days/books
  - Tap a streak                       that streak's dates and totals
  - Tap a Last 7 days value              8-week trend popup
  - Tap Time | Pages (Last 7 days)       switch the week between time and pages
  - Tap a day's bar (Last 7 days / Current week)  books read that day
  - Long press today's bar               Today Timeline
  - Long press current month           CalendarView
  - Tap finished-book count            books finished that year
  - Long press finished-book count     checklist to correct that list
  - Long press reading goal value      set that year's goal
  - Long press title bar               force-reload everything from the DB
  - Swipe left/right on monthly chart change year (elsewhere: ignored)
  - Swipe down / any key               close

Refresh: "ui" on open/close by default, "full" if the Tools-menu toggle for
it is on. The trend and streak popups repaint only their own box, so they
don't flash the whole screen.

Bar chart heights: by default both charts size themselves while the page is
built so it fits one screen; if it can't without the bars getting shorter
than VS.Opt.AUTO_MIN_SCROLL, the sections are put on pages (swipe up / down
or the arrows at the bottom; the sleep screen shrinks instead) - see
_buildUI's fit loop and _paginate, and Settings > Reading insights popup > "Bar chart height" to turn it off.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
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
local Locale, Colors, Fonts, PopupUtil, VS, Cache, UI, Trend, Heatmap, BookList, Data, Manual, Achievements, AchievementsView, Prefs, Streak, Records, YearShelf =
    deps.Locale, deps.Colors, deps.Fonts, deps.PopupUtil,
    deps.VS, deps.Cache, deps.UI, deps.Trend, deps.Heatmap, deps.BookList,
    deps.Data, deps.Manual, deps.Achievements, deps.AchievementsView, deps.Prefs, deps.Streak,
    deps.Records, deps.YearShelf

-- The charts and header rows this view lays out (views/insights_charts.lua,
-- views/insights_headers.lua - split out of this file).
local Charts, Headers, Donut = deps.Charts, deps.Headers, deps.Donut
local buildMonthlyChart, buildWeeklyChart = Charts.buildMonthlyChart, Charts.buildWeeklyChart
local buildAlignedSectionHeader, buildYearHeader, buildWeekNavHeader =
    Headers.buildAlignedSectionHeader, Headers.buildYearHeader, Headers.buildWeekNavHeader

-- Fill used behind a handful of section headers ("Last 7 days", "Current
-- streak"/"Best streak", the year header, "Achievements" when shown next
-- to "Reading goal", and "All time") to visually group them with the
-- section above rather than reading as their own separate block. Backed by
-- the user-configurable "Section header background color" (white by
-- default, i.e. no visible fill) - see colors.lua. A function rather than
-- a value computed once at load time, so it always reflects the current
-- setting even if changed after this module was first loaded.
local function HEADER_BG() return Colors.headerBg() end

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
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount

-- A YYYY-MM-DD string in the configured date format ("?" when missing).
local formatDateForDisplay = Locale.formatDateOrUnknown

local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}
local ReadingInsightsPopup

-- Format seconds as a clock-style duration for book list display, honouring
-- KOReader's global "duration_format" setting (classic "1:30:10", modern
-- "1h30'10\"", ...) - see Locale.formatDuration() in locale.lua for details.
local function formatHHMMSS(seconds)
    return Locale.formatDuration(seconds, false)
end

-- Bold value + plain unit of a duration (see Locale.splitDurationValueUnit).
local splitDurationValueUnit = Locale.splitDurationValueUnit

-- Font faces for this popup's four text roles, sourced from the shared
-- Fonts settings module (see fonts.lua) so they're user-configurable via
-- the "Fonts" Tools-menu entry, the same way Colors.* works for colors.
-- Fonts.getFace() already caches per-role, so this is cheap to call again
-- on every popup (re)build - which is what keeps a just-changed font
-- setting picked up immediately, without needing our own extra cache.
--
-- `scale` (optional, default 1) shrinks all four roles by the same factor;
-- used by _buildUI's font fit (see there) to get rid of the scroll bar.
local function buildSerifFonts(scale)
    return {
        section = Fonts.getScaledFace("insights_section", scale),
        value   = Fonts.getScaledFace("insights_value",   scale),
        label   = Fonts.getScaledFace("insights_label",   scale),
        small   = Fonts.getScaledFace("insights_small",   scale),
    }
end

local _cached_layout = nil

-- Deliberately NOT cached at this module level (unlike getCachedLayout()
-- below): fonts are user-configurable via the Fonts menu, and
-- Fonts.getFace() already caches per-role internally, so rebuilding this
-- small table on every popup (re)build is cheap and guarantees a
-- just-changed font setting is picked up on the very next open, with no
-- stale fonts left over from before the change.
local function getCachedFonts(scale)
    return buildSerifFonts(scale)
end

-- Rebuilt whenever the screen width changes - not just on first use - so a
-- rotation between two openings of the popup (or, on devices that support
-- it, while it's open) is picked up instead of serving a stale portrait/
-- landscape layout.
local function getCachedLayout()
    local screen_w = Screen:getWidth()
    if not _cached_layout or _cached_layout.full_width ~= screen_w then
        _cached_layout = UI.buildLayout(screen_w, Size.padding.large, Size.padding.large)
    end
    return _cached_layout
end

local buildValueLine = UI.buildValueLine

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
    -- Days of the shown year so far (the whole year once it is over): what the
    -- daily averages and the "of days read" percentage divide by.
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

    local left_value = ""
    local left_unit  = ""
    local right_value, right_unit
    local mode = popup_self.mode

    if mode == VS.INSIGHTS_MODE_HOURS then
        -- Reading time | daily average time.
        local yr_secs = yearly_stats.duration or 0
        left_value, left_unit = splitDurationValueUnit(yr_secs, _("reading time"))
        local avg_secs = (days_in_year > 0) and (yr_secs / days_in_year) or 0
        right_value, right_unit = splitDurationValueUnit(avg_secs, _("daily avg time"))
    elseif mode == VS.INSIGHTS_MODE_PAGES then
        -- Pages read | daily average pages.
        local pg = yearly_stats.pages or 0
        left_value = formatCount(pg)
        left_unit  = N_("page read", "pages read", pg)
        local avg_pg = (days_in_year > 0) and (pg / days_in_year) or 0
        local avg_rounded
        if avg_pg >= 10 then
            avg_rounded = math.floor(avg_pg + 0.5)
        else
            avg_rounded = math.floor(avg_pg * 10 + 0.5) / 10
        end
        right_value = formatNumber(avg_rounded, avg_rounded ~= math.floor(avg_rounded) and 1 or 0)
        right_unit  = N_("daily avg page", "daily avg pages", avg_rounded)
    elseif mode == VS.INSIGHTS_MODE_BOOKS then
        left_value = formatCount(yearly_stats.books_started)
        left_unit  = N_("book", "books", yearly_stats.books_started)
        local avg_days = yearly_stats.avg_days_per_book or 0
        right_value = formatCount(avg_days)
        right_unit  = N_("day/book avg", "days/book avg", avg_days)
    else
        left_value = formatCount(yearly_stats.days)
        left_unit  = N_("day read", "days read", yearly_stats.days)
        local pct = (days_in_year > 0)
            and math.floor((yearly_stats.days / days_in_year) * 100 + 0.5)
            or 0
        right_value = pct .. "%"
        right_unit  = _("of days read")
    end

    -- Stacked value cells (tap: the books of that year), `layout` is the
    -- inside of the year card.
    local selected_year_for_tap = popup_self.selected_year
    local function cell(value, unit)
        local c = UI.buildStatCell(fonts, layout.col_width, value, unit, { chevron = not popup_self.readonly })
        return tappableCell(c, layout.col_width, function() popup_self:showBooksForYear(selected_year_for_tap) end)
    end
    return UI.buildTwoColRow(cell(left_value, left_unit), cell(right_value, right_unit),
        layout, false, nil, Size.line.thin)
end

-- Any tap / swipe / key dismisses; onShow/onCloseWidget mark the popup box
-- region dirty. All five come from the shared helper (see popuputil.lua).
PopupUtil.makeDismissable(Trend.Popup, function(self) return self.box_content.dimen end)
-- ...except its tap: a tap on the chart switches totals / averages, any other
-- tap closes the popup (see Trend.popupOnTap).
Trend.Popup.onTap = Trend.popupOnTap
Trend.Popup.onHold = Trend.popupOnHold

-- A year strictly before the current calendar year: its reading is history
-- and won't change, so its year-specific data can be frozen in the
-- completed-year cache and served without ever re-querying (see
-- Cache._completed_year and _fetchYearSpecific/_primeYearSpecific below).
local function isCompletedYear(year)
    return year ~= nil and year < tonumber(os.date("%Y"))
end

local function buildInsightsSections(popup_self, streaks, yearly_stats, year_range, monthly_data, all_time_stats, last_week_stats, last_week_daily, fonts, layout, goal_finished_count)
    -- Long-press targets of the chart captions (view pickers).
    popup_self._chart_hold_targets = {}
    popup_self._today_bar_widget = nil   -- set again by the weekly chart
    local sections = VerticalGroup:new{ align = "left" }
    -- Where each section starts in `sections`: a page break may only fall
    -- there (see _buildUI's pages).
    local breaks = {}
    sections._breaks = breaks
    local function newBlock() table.insert(breaks, #sections + 1) end

    -- "Daily goal | Weekly goal": time read today / this calendar week against
    -- a goal in minutes. Long press on the section edits the goals. Today's
    -- and this week's seconds come from the last-7-days data already loaded
    -- for the "Last 7 days" section (a calendar week never reaches back more
    -- than 7 days, so no extra query is needed).
    popup_self._timegoal_hold_targets = {}
    if VS.readShowTimeGoals() then

        local daily_goal_secs  = VS.readDailyGoalMinutes()  * 60
        local weekly_goal_secs = VS.readWeeklyGoalMinutes() * 60

        local today_secs, week_secs = 0, 0
        if last_week_daily then
            local week_start_wd = Data.weekStartWday()
            local wday = tonumber(os.date("%w"))
            local days_into_week = (week_start_wd == 0) and wday or ((wday + 6) % 7)
            for i = 1, math.min(days_into_week + 1, #last_week_daily) do
                local secs = (last_week_daily[i] and last_week_daily[i].seconds) or 0
                week_secs = week_secs + secs
                if i == 1 then today_secs = secs end
            end
        end

        local function addTimeGoalHold(widget, fn)
            table.insert(popup_self._timegoal_hold_targets, { w = widget, fn = fn })
        end
        local function editDaily()  popup_self:editTimeGoal("daily")  end
        local function editWeekly() popup_self:editTimeGoal("weekly") end

        -- Same duration format as the rest of the plugin (follows KOReader's
        -- "Duration format" setting): "0:23 / 0:30" classic, "23m / 30m" etc.
        local function goalText(done, goal)
            local txt = Locale.formatDuration(done, true) .. " / " .. Locale.formatDuration(goal, true)
            if goal > 0 and done >= goal then txt = txt .. "  \u{2713}" end  -- goal met
            return txt
        end

        local function showDailyStreak()  popup_self:showTimeGoalStreak("daily")  end
        local function showWeeklyStreak() popup_self:showTimeGoalStreak("weekly") end

        -- Two cards side by side (see goalCard). Tap a card for the goal
        -- streak, hold to edit the goal.
        local show_ring = VS.readShowTimeGoalBar() and Donut ~= nil
        local card_gap  = layout.column_gap
        local card_w    = math.floor((layout.content_width - card_gap) / 2)
        local pad_h     = Size.padding.default
        local inner_w   = UI.cardInnerWidth(card_w)

        local ring_d = 0
        if show_ring then
            local probe_v = TextWidget:new{ text = "0", face = fonts.value }
            local probe_l = TextWidget:new{ text = "0", face = fonts.label }
            ring_d = probe_v:getSize().h + probe_l:getSize().h
            probe_v:free()
            probe_l:free()
        end
        local text_w = show_ring and (inner_w - ring_d - pad_h) or inner_w

        -- With the ring: title on top, then the ring (percent inside, a check
        -- once the goal is met) beside the time read and "of <goal>".
        -- Without it: title over the "done / goal" line.
        local function goalCard(title, done, goal, edit_fn, tap_fn)
            local header_w = UI.cardHeader("target", title, fonts.section, inner_w, not popup_self.readonly)
            local ratio = (goal > 0) and math.min(1, done / goal) or 0
            local ring = show_ring and Donut.build{
                ratio        = ratio,
                diameter     = ring_d,
                thickness    = math.floor(ring_d * 0.11 + 0.5),
                text         = (goal > 0 and done >= goal) and "\u{2713}" or (math.floor(ratio * 100) .. "%"),
                face         = fonts.small,
                text_color   = Colors.value(),
                read_color   = Colors.activeBar(),
                unread_color = Colors.inactiveBar(),
            } or nil
            local content
            if ring then
                content = VerticalGroup:new{
                    align = "left",
                    header_w,
                    HorizontalGroup:new{
                        align = "center",
                        ring,
                        HorizontalSpan:new{ width = pad_h },
                        VerticalGroup:new{
                            align = "left",
                            TextWidget:new{ text = Locale.formatDuration(done, true), face = fonts.value, fgcolor = Colors.value(), max_width = text_w },
                            TextWidget:new{ text = T(_("of %1"), Locale.formatDuration(goal, true)), face = fonts.label, fgcolor = Colors.label(), max_width = text_w },
                        },
                    },
                }
            else
                content = VerticalGroup:new{
                    align = "left",
                    header_w,
                    TextWidget:new{ text = goalText(done, goal), face = fonts.value, fgcolor = Colors.value(), max_width = inner_w },
                }
            end
            local frame = UI.buildCard(content, card_w)
            local cell = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = card_w, h = frame:getSize().h },
                frame,
            }
            cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
            cell.onTap = function() tap_fn(); return true end
            addTimeGoalHold(cell, edit_fn)
            return cell
        end

        local goal_row = HorizontalGroup:new{
            align = "top",
            goalCard(_("Daily goal"),  today_secs, daily_goal_secs,  editDaily,  showDailyStreak),
            HorizontalSpan:new{ width = layout.content_width - 2 * card_w },
            goalCard(_("Weekly goal"), week_secs,  weekly_goal_secs, editWeekly, showWeeklyStreak),
        }
        newBlock()
        UI.addCard(sections, goal_row, layout)
    end

    do
        -- Two views of the same section (Settings > Reading insights popup >
        -- Week > View): the rolling last 7 days, or one calendar week that
        -- can be paged. Everything below - totals, averages, chart and the
        -- comparison - is worked out from whichever week is shown.
        local cal_mode = VS.readWeeklyViewIsCalendar()
        popup_self._week_swipe_targets = {}
        -- Long-press targets that flip between the two week views.
        popup_self._week_hold_targets = {}
        local cal = cal_mode and popup_self._cal_week or nil
        local lw, week_daily
        if cal_mode then
            lw = (cal and cal.stats) or { avg_seconds = 0, avg_pages = 0, total_seconds = 0,
                                          total_pages = 0, days = 7, prev_seconds = 0, prev_pages = 0 }
            week_daily = cal and cal.daily or nil
        else
            lw = last_week_stats or { avg_seconds = 0, avg_pages = 0 }
            week_daily = last_week_daily
        end
        -- The calendar view is always shown, even for a week without any
        -- reading: its header is what pages to the other weeks.
        local has_week = cal_mode or lw.avg_seconds > 0 or lw.avg_pages > 0
        if has_week then
            local days_n = lw.days or 7

            local avg_secs = lw.avg_seconds or 0
            local week_time_val, week_time_unit_full = splitDurationValueUnit(avg_secs, _("daily avg time"))

            local avg_pages_rounded
            if lw.avg_pages >= 10 then
                avg_pages_rounded = math.floor(lw.avg_pages + 0.5)
            else
                avg_pages_rounded = math.floor(lw.avg_pages * 10 + 0.5) / 10
            end
            local week_pages_val  = formatNumber(avg_pages_rounded, avg_pages_rounded ~= math.floor(avg_pages_rounded) and 1 or 0)
            local week_pages_unit = N_("daily avg page", "daily avg pages", avg_pages_rounded)

            local total_secs = lw.total_seconds or (lw.avg_seconds or 0) * 7
            local total_time_val, total_time_unit = splitDurationValueUnit(total_secs, _("reading time"))

            local total_pages_raw = math.floor((lw.total_pages or (lw.avg_pages or 0) * 7) + 0.5)
            local total_pages_val = formatCount(total_pages_raw)
            local total_pages_unit = N_("page read", "pages read", total_pages_raw)

            local weekly_chart_mode = VS.normalizeWeeklyChartMode(popup_self.weekly_chart_mode)
            local pages_mode = (weekly_chart_mode == VS.WEEKLY_CHART_MODE_PAGES)

            local time_cells  = { total_time_val, total_time_unit, "time_total",
                                  week_time_val, week_time_unit_full, "time_avg" }
            local pages_cells = { total_pages_val, total_pages_unit, "pages_total",
                                  week_pages_val, week_pages_unit, "pages_avg" }

            -- The section is a card; everything in it is built against the
            -- inside of the card.
            local ilayout = UI.cardLayout(layout)

            -- Optional change against the week before, under the values of
            -- the first row ("▲ 1:05 vs prev. 7d").
            local deltas
            if VS.readWeeklyVsPrev() then
                local vs_label = cal_mode and _("vs prev. week") or _("vs prev. 7d")
                local function deltaText(d, decimals)
                    local val, unit, zero
                    if pages_mode then
                        local a = math.abs(d)
                        a = decimals and (math.floor(a * 10 + 0.5) / 10) or math.floor(a + 0.5)
                        zero = (a == 0)
                        val = decimals and formatNumber(a, 1) or formatCount(a)
                        unit = vs_label
                    else
                        local a = math.floor(math.abs(d) / 60 + 0.5) * 60
                        zero = (a == 0)
                        val, unit = splitDurationValueUnit(a, vs_label)
                    end
                    local arrow = zero and "" or (d < 0 and "\u{25BC} " or "\u{25B2} ")
                    return { arrow .. val, unit }
                end
                local diff_total
                if pages_mode then
                    diff_total = total_pages_raw - math.floor((lw.prev_pages or 0) + 0.5)
                else
                    diff_total = math.floor(total_secs + 0.5) - math.floor((lw.prev_seconds or 0) + 0.5)
                end
                deltas = { deltaText(diff_total), deltaText(diff_total / days_n, true) }
            end

            -- One value cell (tap: 8-week trend), with its delta under it.
            local function weekCell(value, unit, metric, delta)
                local cell = UI.buildStatCell(fonts, ilayout.col_width, value, unit, {
                    chevron     = not popup_self.readonly,
                    delta_value = delta and delta[1],
                    delta_label = delta and delta[2],
                })
                return tappableCell(cell, ilayout.col_width, function() popup_self:showWeeklyTrendPopup(metric) end)
            end

            -- One 2-column row: total on the left, daily average on the right.
            local function weekRow(c, row_opts, d)
                return UI.buildTwoColRow(
                    weekCell(c[1], c[2], c[3], d and d[1]),
                    weekCell(c[4], c[5], c[6], d and d[2]),
                    ilayout, false, row_opts, Size.line.thin)
            end

            -- First row: the metric the chart shows (switched with the
            -- Time | Pages switch). With the optional second row (the other
            -- metric) the vertical divider runs unbroken between the rows.
            local two_rows = VS.readWeeklyExtraRow()
            local last_week_rows = { weekRow(pages_mode and pages_cells or time_cells,
                two_rows and { join_below = Size.padding.small } or nil, deltas) }
            if two_rows then
                table.insert(last_week_rows, weekRow(pages_mode and time_cells or pages_cells,
                    { join_above = true }))
            end

            -- Time | Pages switch: a tap flips the chart and the rows above it.
            local switch = UI.buildSegmented({ _("Time"), _("Pages") }, pages_mode and 2 or 1, fonts.small)
            local switch_cell = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = switch:getSize().w, h = switch:getSize().h },
                switch,
            }
            if not popup_self.readonly then
                switch_cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = switch_cell.dimen } } }
                switch_cell.onTap = function() popup_self:toggleWeeklyChartMode(); return true end
            end
            local switch_w = switch:getSize().w

            local header
            if cal_mode then
                -- Paging header: previous week | shown week | next week.
                header = buildWeekNavHeader(popup_self, fonts.section, fonts.label, ilayout)
            else
                local header_row = UI.cardHeader("calendar", _("Last 7 days"), fonts.section,
                    ilayout.content_width, not popup_self.readonly, switch_cell)
                header = InputContainer:new{
                    dimen = Geom:new{ x = 0, y = 0, w = ilayout.content_width, h = header_row:getSize().h },
                    header_row,
                }
                -- A long press lists the two week views (last 7 days /
                -- current week) to choose from.
                if not popup_self.readonly then
                    table.insert(popup_self._week_hold_targets, {
                        w  = header,
                        fn = function() popup_self:showWeeklyViewPicker() end,
                    })
                end
            end

            local body = VerticalGroup:new{ align = "left", header, VerticalSpan:new{ width = Size.padding.small } }
            for idx, row in ipairs(last_week_rows) do
                if idx > 1 and UI.classicLines() then
                    table.insert(body, VerticalSpan:new{ width = Size.padding.small })
                end
                table.insert(body, row)
            end
            -- The paging header has no room for the switch: it gets its own
            -- line, right-aligned, above the chart.
            if cal_mode then
                table.insert(body, VerticalSpan:new{ width = Size.padding.small })
                table.insert(body, HorizontalGroup:new{
                    HorizontalSpan:new{ width = math.max(0, ilayout.content_width - switch_w) },
                    switch_cell,
                })
            end
            local weekly_chart = buildWeeklyChart(popup_self, week_daily, ilayout, fonts, weekly_chart_mode)
            if weekly_chart then
                table.insert(body, VerticalSpan:new{ width = Size.padding.small })
                table.insert(body, weekly_chart)
            end

            local card = UI.buildCard(body, layout.content_width)

            -- Calendar view: a horizontal swipe over this card pages the week
            -- (see onSwipe); the year is paged only from the monthly chart.
            -- The wrapper only keeps track of where the card is on screen
            -- (its dimen follows the paint).
            if cal_mode and not popup_self.readonly then
                local sz = card:getSize()
                card = InputContainer:new{
                    dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h },
                    card,
                }
                table.insert(popup_self._week_swipe_targets, card)
            end

            newBlock()
            UI.addCard(sections, card, layout)
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

    -- One card: current and best streak side by side, each as days and
    -- weeks. Under the current streak a dot per day of the last 7 days
    -- (filled = read), under the best one the days left to beat it.
    -- A tap anywhere on the card opens the streak calendar.
    do
        local ilayout = UI.cardLayout(layout)
        local col_w   = ilayout.col_width

        -- "5 days · 3 weeks" on one line, or the two on separate lines
        -- when that does not fit the column.
        local function streakLine(d_val, d_unit, w_val, w_unit)
            if d_val == "" and w_val == "" then
                return buildValueLine(fonts.value, fonts.label, col_w, d_val, d_unit)
            end
            local function width(v, u)
                local tv = TextWidget:new{ text = v, face = fonts.value }
                local tu = TextWidget:new{ text = u, face = fonts.label }
                local w = tu:getSize().w + 1
                if v ~= "" then w = w + tv:getSize().w + Size.padding.large end
                tv:free()
                tu:free()
                return w
            end
            local d_w, w_w = width(d_val, d_unit), width(w_val, w_unit)
            local dot = TextWidget:new{ text = "\u{00B7}", face = fonts.label, fgcolor = Colors.label() }
            local gap = Size.padding.default
            if d_w + w_w + dot:getSize().w + 2 * gap <= col_w then
                return HorizontalGroup:new{
                    align = "center",
                    buildValueLine(fonts.value, fonts.label, d_w, d_val, d_unit),
                    HorizontalSpan:new{ width = gap },
                    dot,
                    HorizontalSpan:new{ width = gap },
                    buildValueLine(fonts.value, fonts.label, w_w, w_val, w_unit),
                }
            end
            dot:free()
            return VerticalGroup:new{
                align = "left",
                buildValueLine(fonts.value, fonts.label, col_w, d_val, d_unit),
                buildValueLine(fonts.value, fonts.label, col_w, w_val, w_unit),
            }
        end

        local probe = TextWidget:new{ text = "0", face = fonts.small }
        local dot_size = math.floor(probe:getSize().h * 0.55)
        probe:free()

        -- Last 7 days, oldest on the left (last_week_daily[1] is today).
        local read_flags = {}
        for i = 7, 1, -1 do
            local d = last_week_daily and last_week_daily[i]
            table.insert(read_flags, (d and (tonumber(d.seconds) or 0) > 0) and true or false)
        end
        -- Under the best streak: days still to read in a row to beat it.
        local record_w
        if streaks.best_days >= 2 then
            local to_go = streaks.best_days - streaks.current_days + 1
            record_w = TextWidget:new{
                text = T(N_("%1 day to beat your record", "%1 days to beat your record", to_go), formatCount(to_go)),
                face = fonts.small, fgcolor = Colors.label(), max_width = col_w,
            }
        end
        -- The dots and the record line share one row height, so both
        -- columns line up.
        local extra_h = math.max(dot_size, record_w and record_w:getSize().h or 0)

        local function column(title, line, extra)
            return VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = title, face = fonts.label, bold = true, fgcolor = Colors.section(), max_width = col_w },
                line,
                VerticalSpan:new{ width = Size.padding.small },
                UI.fixedCol(extra, col_w, extra_h),
            }
        end
        local current_col = column(_("Current"), streakLine(cd_val, cd_unit, cw_val, cw_unit),
            UI.buildDots(read_flags, dot_size))
        local best_col = column(_("Best"), streakLine(bd_val, bd_unit, bw_val, bw_unit),
            record_w or VerticalSpan:new{ width = 0 })

        local chevron = TextWidget:new{ text = "\u{203A}", face = fonts.value, fgcolor = Colors.label() }
        local body = VerticalGroup:new{
            align = "left",
            UI.cardHeader("flame", _("Streaks"), fonts.section, ilayout.content_width, false,
                (not popup_self.readonly) and chevron or nil),
            VerticalSpan:new{ width = Size.padding.small },
            UI.buildTwoColRow(current_col, best_col, ilayout, false, nil, Size.line.thin),
            VerticalSpan:new{ width = Size.padding.default },
        }
        local card = UI.buildCard(body, layout.content_width)
        local tap_card = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = card:getSize().w, h = card:getSize().h },
            card,
        }
        tap_card.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = tap_card.dimen } } }
        function tap_card:onTap() Streak.show(streaks) return true end

        newBlock()
        UI.addCard(sections, tap_card, layout)
    end

    popup_self._year_swipe_targets = {}
    -- A horizontal swipe over any widget wrapped with this pages the year
    -- (see onSwipe): the year card and the reading goal row. The wrapper
    -- only keeps track of where the widget is on screen (its dimen follows
    -- the paint).
    local function trackYearSwipe(w)
        local sz = w:getSize()
        local box = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h },
            w,
        }
        table.insert(popup_self._year_swipe_targets, box)
        return box
    end

    -- One card: year header (‹ prev · selected › · next ›), the year's
    -- stats, the chart caption as a chip (tap: the four views) and the
    -- monthly chart.
    do
        local ilayout = UI.cardLayout(layout)
        local body = VerticalGroup:new{
            align = "left",
            buildYearHeader(popup_self, fonts.section, fonts.label, fonts.value, ilayout, year_range, popup_self.selected_year),
            VerticalSpan:new{ width = Size.padding.small },
            buildYearlyRow(popup_self, yearly_stats, fonts, ilayout),
        }

        local chart = buildMonthlyChart(popup_self, monthly_data, ilayout, fonts)
        if chart then
            local caption = (popup_self.mode == VS.INSIGHTS_MODE_HOURS and _("Reading time per month"))
                or (popup_self.mode == VS.INSIGHTS_MODE_PAGES and _("Pages per month"))
                or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS and _("Books per month"))
                or _("Days read per month")
            if not popup_self.readonly then caption = caption .. " \u{25BE}" end
            local chip = UI.buildPill(caption, fonts.small, true)
            local chip_cell = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = chip:getSize().w, h = chip:getSize().h },
                chip,
            }
            if not popup_self.readonly then
                chip_cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = chip_cell.dimen } } }
                chip_cell.onTap = function() popup_self:showInsightsModePicker(); return true end
            end
            table.insert(body, VerticalSpan:new{ width = Size.padding.default })
            table.insert(body, chip_cell)
            table.insert(body, VerticalSpan:new{ width = Size.padding.small })
            table.insert(body, chart)
            -- The few pixels the auto-fit could not hand out as whole bar
            -- points (see _buildUI's fit) go under the chart, so the page
            -- ends exactly at the bottom of the screen.
            local extra_px = VS.Opt.readBarHeightAuto() and (VS.Opt.monthly_extra_px or 0) or 0
            if extra_px > 0 then
                table.insert(body, VerticalSpan:new{ width = extra_px })
            end
        end

        newBlock()
        UI.addCard(sections, trackYearSwipe(UI.buildCard(body, layout.content_width)), layout)
    end

    -- Long-press targets for the reading-goal section (its headers and
    -- cells). Reset every build so onHold never tests a hold against the
    -- coordinates a previous build's widgets occupied. Each entry is
    -- { w = widget, fn = function }.
    popup_self._goal_hold_targets = {}

    -- Reading goal and Achievements: two cards side by side (each one
    -- full width when the other is switched off in Settings > Reading
    -- insights popup).
    local show_goal = VS.Opt.readShowReadingGoal()
    local show_ach  = VS.Opt.readShowAchievements() and Achievements ~= nil

    if show_goal or show_ach then
        local goal_year      = popup_self.selected_year
        local finished_count = goal_finished_count or 0
        local goal_value     = VS.readReadingGoal(goal_year)

        local function openFinished()     popup_self:showFinishedBooksForYear(goal_year) end
        local function openFinishedMenu() popup_self:showFinishedBooksMenu(goal_year) end
        -- Shared with the hamburger menu - see
        -- ReadingInsightsPopup:openAchievementsList() above.
        local function openAchievements() popup_self:openAchievementsList() end

        local both    = show_goal and show_ach
        local card_w  = both and math.floor((layout.content_width - layout.column_gap) / 2) or layout.content_width
        local inner_w = UI.cardInnerWidth(card_w)
        local bar_h   = Screen:scaleBySize(6)
        local gap     = Size.padding.small

        -- Bold value, then the label after it on the same line, then an
        -- optional pill when it still fits.
        local function valueLine(value, label, pill)
            local v = TextWidget:new{ text = value, face = fonts.value, fgcolor = Colors.value() }
            local rest = inner_w - v:getSize().w - gap
            local pill_w = pill and (pill:getSize().w + gap) or 0
            if pill and rest - pill_w < inner_w / 4 then pill, pill_w = nil, 0 end
            local row = HorizontalGroup:new{
                align = "center",
                v,
                HorizontalSpan:new{ width = gap },
                TextWidget:new{ text = label, face = fonts.label, fgcolor = Colors.label(), max_width = math.max(1, rest - pill_w) },
            }
            if pill then
                table.insert(row, HorizontalSpan:new{ width = gap })
                table.insert(row, pill)
            end
            return row
        end

        local cards = {}

        if show_goal then
            -- "5 / 12 books finished", the progress bar, and the pace in a
            -- pill:
            --   closed year  -> "Goal reached" / "Goal not reached"
            --   current year -> "▲ 3 books ahead of pace" / "▼ 1 book behind
            --                   pace" / "On track" / "Goal reached"
            --   otherwise    -> "40% of yearly goal"
            -- Pace uses the day of the year and whole books only (floor), so
            -- "On track" covers less than a book either way.
            local ratio = (goal_value > 0) and math.min(1, finished_count / goal_value) or 0
            local pace = formatCount(math.floor(ratio * 100 + 0.5)) .. "% " .. _("of yearly goal")
            local this_year = tonumber(os.date("%Y"))
            if goal_value > 0 and goal_year < this_year then
                pace = finished_count >= goal_value and _("Goal reached") or _("Goal not reached")
            elseif goal_value > 0 and goal_year == this_year then
                local y = goal_year
                local leap = (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
                local expected = goal_value * tonumber(os.date("%j")) / (leap and 366 or 365)
                local diff = finished_count - expected
                local n = math.floor(math.abs(diff))
                if finished_count >= goal_value then
                    pace = _("Goal reached")
                elseif n == 0 then
                    pace = _("On track")
                elseif diff > 0 then
                    pace = "\u{25B2} " .. formatCount(n) .. " " .. N_("book ahead of pace", "books ahead of pace", n)
                else
                    pace = "\u{25BC} " .. formatCount(n) .. " " .. N_("book behind pace", "books behind pace", n)
                end
            end

            local body = VerticalGroup:new{
                align = "left",
                UI.cardHeader("book", _("Reading goal"), fonts.section, inner_w, not popup_self.readonly),
                VerticalSpan:new{ width = gap },
                valueLine(formatCount(finished_count),
                    "/ " .. formatCount(goal_value) .. " " .. N_("book finished", "books finished", finished_count)),
                VerticalSpan:new{ width = gap },
                UI.buildRoundBar(ratio, inner_w, bar_h),
                VerticalSpan:new{ width = gap },
                UI.buildPill(pace, fonts.small, false, inner_w),
            }
            -- Tap: the books finished that year; hold: the finished-books
            -- menu (correct the list, set the goal). Swiping it pages the
            -- year, like the year card.
            table.insert(cards, { body = body, tap = openFinished, hold = openFinishedMenu, year = true })
        end

        if show_ach then
            local earned_count = Achievements.earnedCount()
            local ach_total    = Achievements.totalCount()
            -- "★ new" = achievements earned since the list was last opened
            -- (see Achievements.newCount); opening the list clears it.
            local new_pill = (Achievements.newCount() > 0)
                and UI.buildPill("\u{2605} " .. _("new"), fonts.small) or nil
            local latest = Achievements.latest()
            local chevron = (not popup_self.readonly)
                and TextWidget:new{ text = "\u{203A}", face = fonts.value, fgcolor = Colors.label() } or nil

            local body = VerticalGroup:new{
                align = "left",
                UI.cardHeader("trophy", _("Achievements"), fonts.section, inner_w, false, chevron),
                VerticalSpan:new{ width = gap },
                valueLine(formatCount(earned_count), "/ " .. formatCount(ach_total) .. " " .. _("earned"), new_pill),
                VerticalSpan:new{ width = gap },
                UI.buildRoundBar(ach_total > 0 and earned_count / ach_total or 0, inner_w, bar_h),
                VerticalSpan:new{ width = gap },
                TextWidget:new{
                    text = _("Latest: ") .. (latest and (latest.icon .. " " .. latest.title) or "\u{2013}"),
                    face = fonts.small, fgcolor = Colors.label(), max_width = inner_w,
                },
            }
            table.insert(cards, { body = body, tap = openAchievements })
        end

        -- Both cards as tall as the taller one.
        local body_h = 0
        for _idx, c in ipairs(cards) do body_h = math.max(body_h, c.body:getSize().h) end
        local row = HorizontalGroup:new{ align = "top" }
        for idx, c in ipairs(cards) do
            local frame = UI.buildCard(UI.fixedCol(c.body, inner_w, body_h), card_w)
            local cell = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = card_w, h = frame:getSize().h },
                frame,
            }
            cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
            cell.onTap = function() c.tap(); return true end
            if c.hold then
                table.insert(popup_self._goal_hold_targets, { w = cell, fn = c.hold })
            end
            if c.year then cell = trackYearSwipe(cell) end
            if idx > 1 then
                table.insert(row, HorizontalSpan:new{ width = layout.content_width - 2 * card_w })
            end
            table.insert(row, cell)
        end
        newBlock()
        UI.addCard(sections, row, layout)
    end -- if show_goal or show_ach

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
        local header_text = _("All time")

        -- Tapping the header opens the reading heatmap popup (moved here
        -- from tapping the year, see showReadingHeatmap / buildYearHeader).
        local total_read_header = buildAlignedSectionHeader(fonts.section, header_text, layout, HEADER_BG())
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

        newBlock()
        UI.addSectionWithRow(sections,
            tappable_total_read_header,
            all_time_row, layout, { no_bottom_line = true, gap_above_row = true })
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
    --
    -- A readonly popup also loads and draws EVERYTHING inside init(), with
    -- nothing deferred (see init and _sleep_sync): it is built while the
    -- device is going to sleep, so no query or redraw may be left for a
    -- timer that would fire after it has gone.
    readonly      = false,
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

-- Opens the "Reading heatmap" popup - tap the "All time" header (see
-- buildInsightsSections) to open it, starting on the most recent
-- half-year; swipe left/right inside the popup to page through older/
-- newer half-years as far back as there's data.
function ReadingInsightsPopup:showReadingHeatmap()
    -- Whether this open is actually going to touch the DB: mirrors the
    -- exact stale-cache check getHeatmapData (heatmap_view.lua) makes for
    -- the current (periods_back == 0) period. There's no way to measure a
    -- blocking Lua call's duration before making it, so this is the best
    -- available proxy for "this open is about to be slow" - a cache hit
    -- returns with no DB access at all and stays instant, while a miss
    -- runs the full calendar + day-part queries synchronously on the UI
    -- thread. Same "let the message actually reach the screen first"
    -- pattern as openRecordsPopup above.
    local start_t, end_t = Heatmap.getHeatmapPeriodRange(0)
    local key = os.date("%Y-%m-%d", start_t) .. ".." .. os.date("%Y-%m-%d", end_t)
    local cache_hit = Cache.ENABLE_CACHE
        and Cache._stale_daily_map[key] and Cache._stale_weekday_hour_map[key]

    if cache_hit then
        UIManager:show(Heatmap.Popup:new{ popup_self = self, periods_back = 0 })
        return
    end

    local popup_self = self
    local msg = InfoMessage:new{ text = _("Loading data…") }
    UIManager:show(msg)
    UIManager:scheduleIn(0.1, function()
        UIManager:show(Heatmap.Popup:new{ popup_self = popup_self, periods_back = 0 })
        UIManager:close(msg)
    end)
end

-- Opens the achievements list. Shared by the reading-goal section's
-- "Achievements" title/cell (see buildInsightsSections) and the hamburger
-- menu (see onShowHamburgerMenu). Refreshes this popup's own build when the
-- list closes, so the "new" star badge next to the earned count clears at
-- once (opening the list marks everything seen).
function ReadingInsightsPopup:openAchievementsList()
    if not AchievementsView then return end
    local popup_self = self
    AchievementsView.show(function()
        if popup_self._closed then return end
        popup_self:_buildUI()
        UIManager:setDirty(popup_self, function()
            return "ui", popup_self.popup_frame.dimen
        end)
    end)
end

-- Opens the Records popup (all-time reading records) - same popup the
-- Tools-menu "Show Records" entry opens (see main.lua's
-- onShowReadingRecordsPopup), reachable here from the hamburger menu.
function ReadingInsightsPopup:openRecordsPopup()
    if not Records then return end
    local popup_self = self
    -- A first-ever open (no records cache yet) recomputes every record from
    -- the full statistics history in one blocking scan - the plugin's own
    -- slowest thing, and it runs on the UI thread (see records_view.lua's
    -- onHold, which shows this same message before its own forced recount
    -- for exactly that reason). Shown here too, so a big history doesn't
    -- read as "nothing happened" while it's still counting - the message is
    -- given a moment to actually reach the screen before the blocking call.
    local msg = InfoMessage:new{ text = _("Loading data…") }
    UIManager:show(msg)
    UIManager:scheduleIn(0.1, function()
        -- Wrapped in pcall: this is the one popup among the four
        -- hamburger-menu entries that also touches the statistics database
        -- on the way up (RecordsData.load()), so an InfoMessage here beats
        -- a tap that silently does nothing if that ever throws instead of
        -- returning its documented zero-value fallback.
        local ok, err = pcall(function()
            UIManager:show(Records.Popup:new{ ui = popup_self.ui })
        end)
        UIManager:close(msg)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Couldn't open Records: ") .. tostring(err),
            })
        end
    end)
end

-- Opens the combined current/best streak popup - same popup the streak
-- header cells open (see buildInsightsSections) and the Tools-menu
-- "Show Reading streak" entry (Insights.showStreaks below), reachable here
-- from the hamburger menu. Uses whatever streak data this popup already
-- has loaded rather than re-querying the DB.
function ReadingInsightsPopup:openStreakPopup()
    Streak.show(self._streaks or Data.calculateStreaks())
end

-- Hamburger menu (title bar, top left): quick access to the other reading-
-- insights popups without paging/tapping through this one. Mirrors the
-- sort-menu pattern used by the book-list popups (see
-- widgets/booklistwidget.lua's onShowWidgetMenu / M.showSortMenu) - a
-- ButtonDialog anchored under the title bar's left icon button.
function ReadingInsightsPopup:onShowHamburgerMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local popup_self = self
    local dialog
    local title_bar = self.title_bar
    dialog = ButtonDialog:new{
        -- This popup is itself modal, and UIManager stacks a non-modal
        -- window shown over it underneath it - see showFinishedBooksMenu
        -- above for the same reasoning.
        modal                  = true,
        shrink_unneeded_width  = true,
        buttons = {
            {{
                text  = _("Show Reading calendar"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:openStreakPopup()
                end,
            }},
            {{
                text  = _("Show Reading habits"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:showReadingHeatmap()
                end,
            }},
            {{
                text  = _("Show Reading shelf"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:showYearShelf()
                end,
            }},
            {{
                text  = _("Show Records"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:openRecordsPopup()
                end,
            }},
            {{
                text  = _("Show Achievements"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:openAchievementsList()
                end,
            }},
        },
        -- Anchored under the title bar's hamburger icon, like the book
        -- lists' sort menu - falls back to centred if that button isn't
        -- there for some reason.
        anchor = title_bar and title_bar.left_button and function()
            return title_bar.left_button.image.dimen
        end or nil,
    }
    UIManager:show(dialog)
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

-- The hand-added books of a year (lib/manual_books.lua) as book-shaped
-- records, no reading time and no pages. Only the finished-books list
-- shows them.
local function manualBooksForYear(year)
    local out = {}
    for _idx, e in ipairs(Manual.list(year)) do
        local date = e.date or ""
        do
            table.insert(out, {
                title     = e.title,
                -- No author and no reading time in these lists: the row is
                -- shown as a bare title (see BookList.showBookList's
                -- `manual` branch).
                authors   = e.authors or "",
                series       = e.series or "",
                series_index = e.series_index or "",
                date_known   = date ~= "",
                duration  = 0,
                pages     = 0,
                rating    = e.rating or 0,
                manual_id   = e.id,
                manual_year = year,
                last_read = e.read_ts or e.ts or 0,
                manual    = true,
            })
        end
    end
    return out
end

local function getFinishedBooksForYearCombined(popup_self, year)
    local base_books = Data.getFinishedBooksForYear(year)
    local overrides = VS.readFinishedOverrides(year)

    -- The books the reader added by hand (lib/manual_books.lua) have no
    -- rows in the statistics DB at all, so no query can find them - they
    -- are appended here, as book-shaped entries with no reading time, so
    -- this list matches the goal count (which adds them the same way, see
    -- Data.applyFinishedOverrides).
    local manual_books = manualBooksForYear(year)

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

    -- Books ticked by hand that the query missed: look up just those, not
    -- the whole year (see Data.getBooksForYearByIds).
    local missing_ids = {}
    for id_str, val in pairs(overrides) do
        if val == true and not by_id[id_str] then
            missing_ids[#missing_ids + 1] = id_str
        end
    end
    if #missing_ids > 0 then
        local candidates = Data.getBooksForYearByIds(year, missing_ids)
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

-- Build and show the 8-week trend popup. Any of "time_total" | "time_avg"
-- opens the time chart (total + daily average), any of "pages_total" |
-- "pages_avg" the pages chart - so it follows what the tapped value showed.
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
    local box_width   = math.floor(Screen:getWidth() * 0.94)
    local chart_width = box_width - 2 * inner_padding

    local function buildBox(mode)
        local content, chart_handle = Trend.buildContent(weeks, mode, chart_width, fonts)
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
        return box, chart_handle
    end

    local mode = Trend.modeOf(metric)
    local box, chart_handle = buildBox(mode)
    UIManager:show(Trend.Popup:new{
        box_content = box, chart_handle = chart_handle,
        mode = mode, build_box = buildBox,
    })
end

function ReadingInsightsPopup:getBooksForMonth(year_month)
    return Data.getBooksForPeriod("%Y-%m", year_month)
end

function ReadingInsightsPopup:showBooksForMonth(year_month, month_label_full)
    local books = self:getBooksForMonth(year_month)
    local total_secs = Data.sumDuration(books)
    local title = T(N_("%1 - %2 book", "%1 - %2 books", #books), month_label_full, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")"
    BookList.showBooksForPeriod(
        self, books,
        T(_("No books in %1"), month_label_full),
        title)
end

-- Tap on a day's column of the weekly chart ("Last 7 days" / "Current week"):
-- the books read on that day with the time spent on each, in the same list
-- the streak calendar opens for a tapped day. A day without reading gets a
-- notice instead.
function ReadingInsightsPopup:showBooksForDay(date_str, midnight_ts)
    local y, m, d = tostring(date_str):match("^(%d+)-(%d+)-(%d+)$")
    if not y then return end
    local ts = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    -- No trailing dot, so the title reads "2026. 03. 12 - 2 books ...".
    local date_label = Locale.formatDateFromTS(ts, true)
    local books = Data.getBooksForPeriod("%Y-%m-%d", date_str) or {}
    local total_secs = Data.sumDuration(books)
    local title = T(N_("%1 - %2 book", "%1 - %2 books", #books), date_label, formatCount(#books))
        .. " (" .. formatHHMMSS(total_secs) .. ")"
    BookList.showBooksForPeriod(
        self, books,
        T(_("No reading on %1"), date_label),
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
    local saved_cal_week         = self._cal_week
    local saved_week_offset      = self.week_offset

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
                _cal_week        = saved_cal_week,
                week_offset      = saved_week_offset,
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
    local saved_cal_week         = self._cal_week
    local saved_week_offset      = self.week_offset

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
                _cal_week        = saved_cal_week,
                week_offset      = saved_week_offset,
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
        _("No books"),
        T(_("All books %1"), formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
end

function ReadingInsightsPopup:showBooksForYear(year)
    local books = self:getBooksForYear(year)
    local total_secs = Data.sumDuration(books)
    BookList.showBooksForPeriod(
        self, books,
        T(_("No books in %1"), tostring(year)),
        T(N_("%1 - %2 book", "%1 - %2 books", #books), year, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
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

-- Opens the year shelf (views/year_shelf_view.lua) on the year shown here: the
-- covers of the books read in it, month by month. It stacks on top of this
-- popup, like the heatmap and the streak calendar, so closing it brings this
-- one back as it was. The books come from the same lists the tap on the yearly
-- figures and on the reading goal open - "all books read" or, with the shelf's
-- "only finished" switch, the finished ones (manual ticks and hand-added books
-- included).
function ReadingInsightsPopup:showYearShelf()
    if not YearShelf then return end
    local popup_self = self
    YearShelf.show{
        ui         = self.ui,
        year       = self.selected_year or tonumber(os.date("%Y")),
        year_range = self._year_range or self.year_range,
        getBooks   = function(year, finished_only)
            if finished_only then
                return getFinishedBooksForYearCombined(popup_self, year)
            end
            return popup_self:getBooksForYear(year)
        end,
    }
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
        -- Only as wide as its texts need, not the dialog's default width.
        shrink_unneeded_width = true,
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
            -- The yearly goal used to be edited by long-pressing the goal
            -- value cell; that cell was merged into the "N/M books finished"
            -- figure, so goal editing moved here.
            {{
                text = _("Set reading goal"),
                callback = function()
                    UIManager:close(dialog)
                    self:editReadingGoal(year)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- The popup's header text.
function ReadingInsightsPopup:_titleBarText()
    -- Popup header has its own translation key, so the Tools menu entry can
    -- stay "Reading insights" while the popup shows the localised title.
    -- Falls back to "Reading insights" if a language lacks the key.
    return Locale.insightsTitle()
end

-- A string that changes whenever any of this plugin's settings (or the UI
-- language) changes, whichever module saved it - read straight from the
-- settings store, so enabling/disabling a section, switching a layout, a
-- font or a bar height all show up. _buildUI compares it with the one the
-- remembered landscape font scale was computed under: a different one means
-- the page's content changed, so the old scale is no longer a valid guess
-- and the fit starts over from the configured font sizes.
local function settingsSignature()
    local data = G_reader_settings and G_reader_settings.data
    if type(data) ~= "table" then return "" end
    local keys = {}
    for k in pairs(data) do
        if type(k) == "string"
           and (k:find("^reading_insights_") or k:find("^readinginsights_") or k == "language") then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. "=" .. tostring(data[k]) end
    return table.concat(parts, "|")
end

function ReadingInsightsPopup:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local fonts    = getCachedFonts()
    local layout   = getCachedLayout()
    -- Text scale (1 = the configured sizes). Lowered by the
    -- fit step below when the page is taller than the screen even after the
    -- bar charts have been sized; everything in the popup that is text goes
    -- through `fonts`, so changing it and rebuilding scales all of it.
    local font_scale = 1

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
            -- Hamburger menu, top left: quick access to the streak/heatmap/
            -- records/achievements popups - see onShowHamburgerMenu below.
            -- Hidden in readonly (sleep-screen) mode, same as close_callback,
            -- so a stray touch there can't navigate away from the wake screen.
            left_icon              = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and "appbar.menu" or nil,
            left_icon_tap_callback = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and function() self:onShowHamburgerMenu() end or nil,
            close_callback = (not self.readonly) and function() UIManager:close(self) end or nil,
            show_parent    = self,
            top_v_padding    = Size.padding.default,
            bottom_v_padding = Size.padding.default,
        }
        self._title_bar_height = title_bar_inner:getSize().h
        self.title_bar = title_bar_inner

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
    -- Auto mode: what is left under the last row is the same as under the
    -- Reading calendar's streak section (Size.padding.default in total; the
    -- section already ends with a Size.padding.small gap of its own).
    local bottom_span = auto_fit and math.max(0, Size.padding.default - Size.padding.small) or nil
    -- Extra pixels in force during the latest buildContent() (see the fit).
    local built_extra = 0

    -- Width the page is laid out for: the screen, or less the scroll bar
    -- once the page turns out taller than the screen (see below).
    local content_w = screen_w

    -- `paginate`: show only the current page of the sections (see
    -- _paginate) instead of all of them.
    local function buildContent(paginate)
        VS.Opt.built_weekly  = false
        VS.Opt.built_monthly = false
        if not auto_fit then VS.Opt.monthly_extra_px = 0 end
        built_extra = VS.Opt.monthly_extra_px or 0

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
            width          = content_w,
            align          = "left",
            title          = self:_titleBarText(),
            -- Same scale as the rest of the text (nil = TitleBar's own
            -- default face while nothing is scaled).
            title_face     = font_scale < 0.999 and Font:getFace("smalltfont",
                math.max(8, math.floor(((Font.sizemap and Font.sizemap.smalltfont) or 24) * font_scale + 0.5))) or nil,
            -- Hamburger menu, top left: quick access to the streak/heatmap/
            -- records/achievements popups - see onShowHamburgerMenu below.
            -- Hidden in readonly (sleep-screen) mode, same as close_callback,
            -- so a stray touch there can't navigate away from the wake screen.
            left_icon              = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and "appbar.menu" or nil,
            left_icon_tap_callback = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and function() self:onShowHamburgerMenu() end or nil,
            close_callback = (not self.readonly) and function() UIManager:close(self) end or nil,
            show_parent    = self,
            top_v_padding    = Size.padding.default,
            -- The line under the title is the title bar's own (like the book
            -- list's), so it sits the same distance below the text.
            with_bottom_line      = true,
            bottom_line_color     = Colors.separator(),
            bottom_line_h_padding = layout.padding_h,
            bottom_v_padding      = 0,
        }

        local title_bar_h = title_bar_inner:getSize().h
        self._title_bar_height = title_bar_h
        self.title_bar = title_bar_inner

        if paginate then
            local group = VerticalGroup:new{
                align = "left",
                title_bar_inner,
                self:_paginate(sections, screen_h - title_bar_h, fonts, content_w),
            }
            return group, group:getSize().h
        end

        -- Manual mode keeps the generous title-bar-tall bottom spacer it
        -- always had (the page is expected to scroll there anyway); auto
        -- mode uses a small one, so the space it would have eaten goes to
        -- the charts instead.
        local group = VerticalGroup:new{
            align = "left",
            title_bar_inner,
            sections,
            -- VerticalSpan reads `width` (a `height` field is ignored, which
            -- left this spacer at 0 px). Without a monthly chart to take
            -- the extra pixels they end up here.
            VerticalSpan:new{ width = (bottom_span or title_bar_h)
                + (VS.Opt.built_monthly and 0 or built_extra) },
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

        local function rebuild()
            local discarded = content
            content, content_h = buildContent()
            -- Free the measured-then-thrown-away build; failure here is
            -- harmless (worst case it's collected later), so it must never
            -- take the popup down with it.
            pcall(function() if discarded.free then discarded:free() end end)
        end

        for _ = 1, 4 do
            local n_charts = (VS.Opt.built_weekly and 1 or 0) + (VS.Opt.built_monthly and 1 or 0)
            if n_charts == 0 then break end -- nothing adjustable on this page

            -- Room the page has with the extra pixels taken back out: the
            -- bar points are fitted first, the extra pixels only take up
            -- what a whole point (per chart) cannot.
            local slack_px = screen_h - content_h + built_extra
            if slack_px >= 0 and slack_px < px_per_point * n_charts then break end

            local delta_points = math.floor(slack_px / (px_per_point * n_charts))
            if delta_points == 0 then
                -- Overflowing by less than one point per chart: still has
                -- to come off, or the scroll bar stays.
                delta_points = (slack_px < 0) and -1 or 0
            end
            if delta_points == 0 then break end

            local current = VS.Opt.auto_height or VS.DEFAULT_MONTHLY_BAR_HEIGHT
            -- The open popup goes on pages rather than flatten the charts;
            -- the sleep screen has one screen only, so it may shrink them
            -- all the way.
            local min_height = self.readonly and VS.Opt.AUTO_MIN or VS.Opt.AUTO_MIN_SCROLL
            local new_height = math.max(min_height,
                math.min(VS.Opt.AUTO_MAX, current + delta_points))

            -- Clamped, so another build would produce the exact same page:
            -- give up and let it scroll (tiny screen, huge fonts) or stay
            -- slightly short (huge screen, few sections).
            if new_height == current then break end

            VS.Opt.auto_height = new_height
            VS.Opt.monthly_extra_px = 0
            adjusted = true
            rebuild()
        end

        -- Whole pixels that did not make a bar point: hand them to the
        -- monthly chart (under it) so the page is exactly one screen tall
        -- and its last row lands where the Reading calendar's does. Only a
        -- small remainder is handed out - if the heights are clamped and
        -- much room is left, the page stays short as before.
        local n_charts = (VS.Opt.built_weekly and 1 or 0) + (VS.Opt.built_monthly and 1 or 0)
        local slack_px = screen_h - content_h + built_extra
        local want_extra = 0
        if n_charts > 0 and slack_px >= 0 and slack_px <= px_per_point * n_charts * 2 then
            want_extra = slack_px
        end
        if want_extra ~= built_extra then
            VS.Opt.monthly_extra_px = want_extra
            rebuild()
            -- The extra is plain pixels, so this should fit exactly; if it
            -- somehow overflows, take it back rather than show a scroll bar.
            if content_h > screen_h and want_extra > 0 then
                VS.Opt.monthly_extra_px = 0
                rebuild()
            end
        end
    end

    -- Landscape and portrait: if the page is still taller than the screen here (the
    -- bar charts are at their smallest, or auto height is off and the fixed
    -- heights are too big) the scroll bar would show up. Shrink every font
    -- by the same percentage until the content fits and the scroll bar is
    -- gone. If everything fits, the configured font sizes stay untouched.
    --
    -- Like the bar fit above, each step is measured, not predicted: text
    -- height shrinks roughly in proportion to the scale while the bars and
    -- spacing don't, so the next scale is the current one times
    -- screen/content (a little under, to land on the fitting side), which
    -- usually settles in one or two extra builds. The result is remembered
    -- in VS.Opt.font_scale as the first guess for the next open.
    -- FONT_SCALE_MIN stops it from shrinking text into unreadability; below
    -- that the page just scrolls.
    -- A settings change since the remembered scale was computed (a section
    -- switched on/off, a layout, font or height changed...) discards it, so
    -- the fit is recalculated from scratch instead of reusing a scale that
    -- belonged to a different page.
    local sig = settingsSignature()
    if VS.Opt.settings_sig ~= sig then
        VS.Opt.font_scale   = nil
        VS.Opt.settings_sig = sig
    end

    -- Only the sleep screen shrinks its text: the open popup goes on pages.
    if content_h > screen_h and self.readonly then
        local FONT_SCALE_MIN = 0.5
        local remembered     = VS.Opt.font_scale
        local scale          = 1
        local best           = nil   -- smallest-change scale that fitted
        for attempt = 1, 6 do
            local candidate
            if attempt == 1 and remembered and remembered < 1 and remembered >= FONT_SCALE_MIN then
                candidate = remembered
            else
                candidate = scale * (screen_h / content_h) * 0.98
                -- Always make progress, even if the measurement says the
                -- estimate is the same as before.
                if candidate > scale - 0.02 then candidate = scale - 0.02 end
            end
            candidate = math.max(FONT_SCALE_MIN, math.floor(candidate * 100) / 100)
            if candidate >= scale then break end

            scale      = candidate
            font_scale = scale
            fonts      = getCachedFonts(scale)

            local discarded = content
            content, content_h = buildContent()
            pcall(function() if discarded.free then discarded:free() end end)

            if content_h <= screen_h then best = scale; break end
            if scale <= FONT_SCALE_MIN then break end
        end
        VS.Opt.font_scale = best  -- nil when it never fitted: don't pin a bad guess
    elseif self.readonly then
        VS.Opt.font_scale = nil
    end

    -- Still taller than the screen: the open popup shows the sections on
    -- pages (see _paginate); the sleep screen has shrunk its text instead.
    self._page_count = 1
    if content_h > screen_h and not self.readonly then
        local discarded = content
        content, content_h = buildContent(true)
        pcall(function() if discarded.free then discarded:free() end end)
    end
    if self._page_count <= 1 then self._page = 1 end

    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")

    -- A page taller than the screen (a single section taller than the
    -- screen, or the sleep screen at its smallest text) gets a scroll bar on
    -- the right, which takes width from the page: lay it out again that much
    -- narrower, or its right edge would be cut off. Making it narrower can
    -- only make it taller, so it still scrolls afterwards.
    if content_h > screen_h then
        content_w = screen_w - ScrollableContainer:getScrollbarWidth()
        layout = UI.buildLayout(content_w, Size.padding.large, Size.padding.large)
        local discarded = content
        content, content_h = buildContent(self._page_count > 1)
        pcall(function() if discarded.free then discarded:free() end end)
    end

    -- A scrolling page would otherwise keep the popup's own gestures: long
    -- press (the container scrolls with press-and-drag; it still scrolls
    -- with a drag or an up/down swipe), sideways swipes (year / week) and a
    -- swipe down at the top of the page (close).
    self.scroll_container = ScrollableContainer:new{
        dimen               = Geom:new{ w = screen_w, h = screen_h },
        show_parent         = self,
        scroll_bar_position = "right",
        ignore_events       = { "hold", "hold_pan", "hold_release" },
        content,
    }
    local onScrollableSwipe = self.scroll_container.onScrollableSwipe
    self.scroll_container.onScrollableSwipe = function(sc, arg, ges)
        local dir = ges and ges.direction
        if dir == "east" or dir == "west" then return false end
        if dir == "south" and (sc._scroll_offset_y or 0) <= 0 then return false end
        return onScrollableSwipe(sc, arg, ges)
    end

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

-- Runs the DB getter for one insights mode's monthly chart. Shared by
-- _fetchYearSpecific (current mode, on the popup's own load path) and
-- _prefetchOtherModes (the other two modes, in the background) so both stay
-- in sync with which getter belongs to which mode.
local function queryMonthlyForMode(year, mode, conn)
    if mode == VS.INSIGHTS_MODE_HOURS then
        return Data.getMonthlyReadingHours(year, conn)
    elseif mode == VS.INSIGHTS_MODE_PAGES then
        return Data.getMonthlyReadingPages(year, conn)
    elseif mode == VS.INSIGHTS_MODE_BOOKS then
        return Data.getMonthlyBookCounts(year, conn)
    end
    return Data.getMonthlyReadingDays(year, conn)
end

-- Fetches (and, for a completed year, freezes) one mode's monthly chart for
-- `year`. This is the completed-year-aware wrapper around
-- queryMonthlyForMode: a past year is read from the frozen completed-year
-- cache and only ever queried the first time it's needed for that mode, the
-- current year always queries live (which itself is cheap after the first
-- call today - see the base-cache comments on the getters in
-- lib/insights_data.lua). Used for the popup's own mode as well as for
-- warming the modes it isn't currently showing.
local function fetchMonthlyForYearMode(year, mode, conn)
    if not isCompletedYear(year) then
        return queryMonthlyForMode(year, mode, conn)
    end
    local monthly = Cache.getCompletedMonthly(year, mode)
    if monthly == nil then
        monthly = queryMonthlyForMode(year, mode, conn)
        Cache.setCompletedYearData(year, nil, mode, monthly)
    end
    return monthly
end

-- The two year-specific slices (yearly totals + the monthly chart for the
-- current mode), fetched the way the selected year wants them. A completed
-- (past) year is read from the frozen completed-year cache and only queried
-- the first time it's ever needed - then written back so it's never queried
-- again; the current year always queries live. `conn` is the shared batch
-- connection (may be nil, in which case each getter opens its own).
function ReadingInsightsPopup:_fetchYearSpecific(conn)
    local year = self.selected_year
    local mode = self.mode or VS.INSIGHTS_MODE_HOURS

    if not isCompletedYear(year) then
        return Data.getYearlyStats(year, conn), queryMonthlyForMode(year, mode, conn)
    end

    local yearly  = Cache.getCompletedYearly(year)
    local monthly = Cache.getCompletedMonthly(year, mode)
    if yearly == nil then yearly = Data.getYearlyStats(year, conn) end
    if monthly == nil then monthly = queryMonthlyForMode(year, mode, conn) end
    -- Freeze whatever we had to compute (a no-op re-store for cache hits).
    Cache.setCompletedYearData(year, yearly, mode, monthly)
    return yearly, monthly
end

-- Warms the monthly chart cache for the insights modes the popup ISN'T
-- currently showing, so switching to "days" or "books" later this session
-- lands on the same warm cache as the mode the popup opened with, instead of
-- doing the once-a-day full-year scan right when the user taps to switch.
--
-- Scheduled from _loadAndRebuild, after that call's own data has already
-- loaded and painted (see _scheduleAchievementsRefresh right above it for
-- the same reasoning), so this never delays what's on screen for the
-- current mode. For a mode whose base cache was already computed today -
-- an earlier popup open, or an earlier switch this session - the getter
-- call below is effectively free (same per-day base cache the visible mode
-- itself relies on), so this is a real DB scan at most once per mode per
-- day, same cost the visible mode already pays for itself.
function ReadingInsightsPopup:_schedulePrefetchOtherModes()
    if self._sleep_sync then return end
    if self._prefetch_scheduled then return end
    self._prefetch_scheduled = true
    UIManager:scheduleIn(0.3, function()
        self._prefetch_scheduled = false
        if self._closed then return end
        local year         = self.selected_year
        local current_mode = self.mode or VS.INSIGHTS_MODE_HOURS
        local other_modes = {}
        for _, m in ipairs({ VS.INSIGHTS_MODE_HOURS, VS.INSIGHTS_MODE_PAGES, VS.INSIGHTS_MODE_DAYS, VS.INSIGHTS_MODE_BOOKS }) do
            if m ~= current_mode then table.insert(other_modes, m) end
        end
        Data.withBatchConnection(function(conn)
            for _, m in ipairs(other_modes) do
                if self._closed then break end
                pcall(fetchMonthlyForYearMode, year, m, conn)
            end
        end)
        if self._closed then return end
        Cache.saveDiskCache()
    end)
end

-- Set self._yearly/_monthly for the current selected_year+mode ahead of a
-- _buildUI, so that first build already has the right data - and therefore
-- the bar-chart auto-fit sizes correctly on the first pass, with no
-- stale-then-real reflow. reset_yearly is false on a mode switch (same year,
-- only the monthly chart changes) so the mode-independent yearly numbers on
-- screen don't flicker.
--
-- Fast path first: a past year from its frozen cache, the current year from
-- its last stale values - both instant. Whatever the fast path can't supply
-- (a year/mode not seen yet today) is then fetched synchronously, so the
-- monthly chart is on the page for that very first build instead of appearing
-- a beat later and reflowing the charts. That synchronous fill is the fix for
-- "it still jumps once, only when not cached yet": the first switch into
-- days- or books-per-month, or paging to a year not opened yet today.
function ReadingInsightsPopup:_primeYearSpecific(reset_yearly)
    local year = self.selected_year
    local mode = self.mode or VS.INSIGHTS_MODE_HOURS

    local fast_yearly, fast_monthly
    if isCompletedYear(year) then
        fast_yearly  = Cache.getCompletedYearly(year)
        fast_monthly = Cache.getCompletedMonthly(year, mode)
    else
        fast_yearly  = Cache.findStaleByPrefix(Cache._stale_yearly, year .. ":v3:")
        fast_monthly = Cache.findStaleByPrefix(Cache._stale_monthly,
            VS.monthKeyPrefixForMode(mode) .. year .. ":")
    end

    if reset_yearly then
        -- Year changed (paging or a direct open): take the fast values, but
        -- don't null out anything already served (e.g. init's stale) just
        -- because the fast source has a gap - the sync fill below covers it.
        self._yearly  = fast_yearly  or self._yearly
        self._monthly = fast_monthly or self._monthly
    else
        -- Only the mode changed: replace the monthly chart outright (the
        -- prior value is a *different* mode's chart, so it must not be kept);
        -- yearly is mode-independent and stays as it is.
        self._monthly = fast_monthly
    end

    -- Fetch any genuine gap synchronously. _fetchYearSpecific also freezes a
    -- past year's result; for the current year it's a one-off bootstrap that
    -- _loadAndRebuild refreshes right after. Only assign what actually came
    -- back, so a failed one-off (e.g. a locked DB) keeps whatever was served
    -- rather than nulling a section into a reflow.
    local need_yearly  = (reset_yearly and self._yearly == nil)
    local need_monthly = (self._monthly == nil)
    if need_yearly or need_monthly then
        local got = Data.withBatchConnection(function(conn)
            local y, m = self:_fetchYearSpecific(conn)
            return { yearly = y, monthly = m }
        end) or {}
        if need_yearly  and got.yearly  ~= nil then self._yearly  = got.yearly  end
        if need_monthly and got.monthly ~= nil then self._monthly = got.monthly end
    end
end

function ReadingInsightsPopup:_loadAndRebuild()
    -- Re-fetch everything over one shared DB connection (seven open/close
    -- cycles become one). Each getter still manages its own cache and works
    -- without a connection, so this only saves the redundant opens; the
    -- connection is opened and closed by the data module (see
    -- Data.withBatchConnection), leaving this file with no DB knowledge.
    local batch = Data.withBatchConnection(function(conn)
        -- Year-specific parts; a cache hit (no DB) for an already-frozen
        -- past year, so paging back to it never re-queries.
        local yearly, monthly = self:_fetchYearSpecific(conn)
        local last_week, last_week_daily = Data.getLastWeekAll(conn)
        local cal_week
        if VS.readWeeklyViewIsCalendar() then
            cal_week = Data.getCalendarWeek(self.week_offset or 0, conn)
        end
        return {
            streaks    = Data.calculateStreaks(conn),
            year_range = Data.getYearRange(conn),
            yearly     = yearly,
            all_time   = Data.getAllTimeStats(conn),
            -- Only worth querying when the section that displays it is on.
            goal_finished = VS.Opt.readShowReadingGoal()
                and Data.getFinishedBookCountForYear(self.selected_year, conn)
                or nil,
            last_week       = last_week,
            last_week_daily = last_week_daily,
            cal_week        = cal_week,
            monthly         = monthly,
        }
    end) or {}

    -- Achievements are re-evaluated *after* this rebuild has painted, not
    -- here, so the day's fresh reading numbers appear first and aren't held
    -- back by the (occasionally expensive) achievement recompute - see
    -- _scheduleAchievementsRefresh(), scheduled at the end of this function.
    -- For now we reuse whatever count is already known, so the goal/
    -- achievements cell keeps its current value until that deferred pass
    -- (a beat later) updates it if anything was unlocked.
    local new_ach_count = Achievements and Achievements.earnedCount() or 0

    local new_streaks         = batch.streaks
    local new_year_range      = batch.year_range
    local new_yearly          = batch.yearly
    local new_all_time        = batch.all_time
    local new_goal_finished   = batch.goal_finished
    local new_last_week       = batch.last_week
    local new_last_week_daily = batch.last_week_daily
    local new_cal_week        = batch.cal_week
    local new_monthly         = batch.monthly

    -- Skip rebuild if nothing actually displayed would change - compared by
    -- value, not by table reference (see valuesEqual() for why reference
    -- equality isn't enough now that all_time/yearly refresh every minute).
    -- Exception: coming out of the cold-start "Loading data..." placeholder
    -- always needs a rebuild, even if the freshly-loaded values happen to
    -- be all-zero (e.g. a brand new, still-empty statistics.sqlite3).
    local was_initial_loading = self._initial_loading
    if not was_initial_loading and
       new_ach_count == self._ach_count                        and
       valuesEqual(new_streaks,         self._streaks)         and
       valuesEqual(new_year_range,      self._year_range)      and
       valuesEqual(new_yearly,          self._yearly)          and
       valuesEqual(new_all_time,        self._all_time)        and
       valuesEqual(new_goal_finished,   self._goal_finished)   and
       valuesEqual(new_last_week,       self._last_week)       and
       valuesEqual(new_last_week_daily, self._last_week_daily) and
       valuesEqual(new_cal_week,        self._cal_week)        and
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
        self._cal_week        = new_cal_week
        self._monthly         = new_monthly
        self._ach_count       = new_ach_count
        Cache.saveDiskCache()
        self:_scheduleAchievementsRefresh()
        self:_schedulePrefetchOtherModes()
        return
    end

    self._streaks          = new_streaks
    self._year_range       = new_year_range
    self._yearly           = new_yearly
    self._all_time         = new_all_time
    self._goal_finished    = new_goal_finished
    self._last_week        = new_last_week
    self._last_week_daily = new_last_week_daily
    self._cal_week        = new_cal_week
    self._monthly         = new_monthly
    self._ach_count       = new_ach_count
    self._initial_loading = false

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    Cache.saveDiskCache()
    self:_scheduleAchievementsRefresh()
    self:_schedulePrefetchOtherModes()
end

-- Deferred, one-shot achievement re-evaluation. Scheduled at the end of
-- _loadAndRebuild(), i.e. only once the reading data has been loaded and
-- painted, so opening the popup shows the day's fresh numbers straight away
-- and the (sometimes costly) achievement recompute runs a beat later. If it
-- unlocks anything, the goal/achievements cell is repainted then; otherwise
-- nothing visible changes. refreshIfChanged() is cheap when nothing changed -
-- one fingerprint query, or nothing at all more than once a day - so it is
-- fine to schedule this on every rebuild; the flag only stops overlapping
-- passes from stacking up, and the pass never reschedules itself, so it can't
-- loop.
function ReadingInsightsPopup:_scheduleAchievementsRefresh()
    if self._sleep_sync then return end
    if not Achievements then return end
    -- Only worth doing when the popup actually shows the achievements
    -- section. When it's switched off the count isn't drawn, so skip even
    -- the cheap fingerprint query here - the list
    -- (reachable via "Show Achievements") recomputes on its own force-reload,
    -- and a full popup title-bar reload still re-scans regardless (see the
    -- Achievements.recompute call in the reload path).
    if not VS.Opt.readShowAchievements() then return end
    if self._ach_refresh_scheduled then return end
    self._ach_refresh_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._ach_refresh_scheduled = false
        if self._closed then return end
        local before = self._ach_count or 0
        pcall(Achievements.refreshIfChanged, VS.Opt.readAchievementRefresh())
        local after = Achievements and Achievements.earnedCount() or 0
        if after == before then return end
        self._ach_count = after
        if self._closed then return end
        self:_buildUI()
        UIManager:setDirty(self, function()
            return "ui", self.popup_frame.dimen
        end)
    end)
end

-- init() shows cached/stale data immediately, then _loadAndRebuild() refreshes in the background.
function ReadingInsightsPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Write the current (in-memory, not yet saved) reading session into
    -- statistics.sqlite3, then invalidate the "Last 7 days" cache so it is
    -- always re-queried from the DB on every open of this popup - not just
    -- once per minute. Older cached/stale values are still shown instantly
    -- below (stale-while-revalidate); _loadAndRebuild() then replaces them
    -- with the freshly-flushed numbers a moment later.
    Data.flushStatsToDB(self.ui)
    Cache._cache.last_week              = nil
    Cache._cache.last_week_minute       = nil
    Cache._cache.last_week_daily        = nil
    Cache._cache.last_week_daily_minute = nil
    Data.clearCalendarWeekCache()

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

    -- selected_year needs a value before we can prime year-specific data or
    -- run _loadAndRebuild.
    if not self.selected_year then
        self.selected_year = tonumber(os.date("%Y"))
    end

    -- "Current week" view of the weekly section: it opens on the current
    -- week (week_offset 0) unless a reopen hands one over, and is loaded
    -- before the first build, so the section is on the page at once rather
    -- than appearing a beat later. The sleep screen skips this:
    -- _sleep_load() fetches it together with the rest.
    self.week_offset = self.week_offset or 0
    if not self.readonly then
        -- Paint from the previous numbers when there are some from today and
        -- let _loadAndRebuild() refresh them together with the rest over one
        -- shared query; only a cold start queries here, before the first paint.
        local stale = VS.readWeeklyViewIsCalendar() and Data.getCalendarWeekStale(self.week_offset) or nil
        if stale then
            self._cal_week = stale
        else
            self:_primeCalendarWeek()
        end
    end

    -- Direct-open on a past year (a caller passing selected_year, rather than
    -- the usual open-on-the-current-year then page): serve that year's
    -- immutable year-specific data straight from the completed-year cache
    -- before the first build - fetched synchronously once if it isn't frozen
    -- yet - exactly as _goToYear does, so the bar-chart auto-fit lands right
    -- the first time instead of reflowing when the async refresh arrives. The
    -- current year keeps the stale-then-refresh path handled above.
    if isCompletedYear(self.selected_year) then
        self:_primeYearSpecific(true)
    end

    -- True only on a genuine cold start (e.g. right after a KOReader restart):
    -- no fresh cache and no stale fallback for any of the core stats. In that
    -- case _buildUI() shows a "Loading data..." placeholder instead of a
    -- flash of zeroed-out sections; cleared as soon as _loadAndRebuild()
    -- brings in real data.
    self._initial_loading = not (self._streaks or self._yearly or self._monthly
        or self._all_time or self._last_week or self._goal_finished)

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
    if self.readonly then
        -- Sleep screen: no stale-then-refresh. Every query runs and the page
        -- is built once, right here, before the Suspend handler returns -
        -- otherwise the numbers would be refreshed by a timer after the
        -- device has already started to sleep (or never, if it is quicker).
        self:_sleep_load()
    else
        self:_buildUI()
        UIManager:scheduleIn(0.1, function()
            if self._closed then return end
            self:_loadAndRebuild()
        end)
    end
end

-- Readonly (sleep screen) loading: the whole of _loadAndRebuild() plus the
-- achievements count, run now and in order, with the deferred passes
-- (_scheduleAchievementsRefresh / _schedulePrefetchOtherModes) switched off.
function ReadingInsightsPopup:_sleep_load()
    self._sleep_sync = true
    -- Forces _loadAndRebuild() to build the page even when the fresh numbers
    -- equal the cached ones - this is the first (and only) build.
    self._initial_loading = true
    local ok, err = pcall(self._loadAndRebuild, self)
    if not ok then
        logger.warn("ReadingInsights sleep screen: load failed:", tostring(err))
        self._initial_loading = false
        if not self[1] then self:_buildUI() end
        return
    end

    -- The achievements count: normally refreshed a beat after the open;
    -- here it is done now, and the page rebuilt only if it changed.
    if Achievements and VS.Opt.readShowAchievements() then
        local before = self._ach_count or 0
        pcall(Achievements.refreshIfChanged, VS.Opt.readAchievementRefresh())
        local after = Achievements.earnedCount() or 0
        if after ~= before then
            self._ach_count = after
            self:_buildUI()
        end
    end
end

function ReadingInsightsPopup:onSwipe(arg, ges_ev)
    if not ges_ev then return false end
    local dir = ges_ev.direction
    local west  = (dir == "west" or dir == "left")
    local east  = (dir == "east" or dir == "right")
    local function inside(list)
        local pos = ges_ev.pos
        if not pos then return false end
        for _idx, w in ipairs(list or {}) do
            local d = w.dimen
            if d and pos.x >= d.x and pos.x <= d.x + d.w
                  and pos.y >= d.y and pos.y <= d.y + d.h then
                return true
            end
        end
        return false
    end
    -- Sideways swipes only act where they start:
    --   - on the weekly card (calendar-week view)    -> page the week
    --   - on the year card or the reading goal card  -> page the year
    -- A sideways swipe anywhere else is ignored.
    if west or east then
        if VS.readWeeklyViewIsCalendar() and inside(self._week_swipe_targets) then
            if west then return self:onGoToNextWeek() end
            return self:onGoToPrevWeek()
        end
        if inside(self._year_swipe_targets) then
            if west then return self:onGoToNextYear() end
            return self:onGoToPrevYear()
        end
        return true
    end
    -- Up / down: next / previous page; down on the first page closes.
    if dir == "north" or dir == "up" then
        if (self._page or 1) < (self._page_count or 1) then
            return self:_goToPage((self._page or 1) + 1)
        end
        return true
    end
    if dir == "south" or dir == "down" then
        if self.readonly then return true end
        if (self._page or 1) > 1 then
            return self:_goToPage(self._page - 1)
        end
        UIManager:close(self)
        return true
    end
    return false
end

-- Splits `sections` into pages at the section starts it recorded
-- (sections._breaks), filling each page with as many whole sections as fit
-- above the page footer, and returns the current page (self._page) with the
-- footer at the bottom of `avail_h`. Sets self._page / self._page_count.
function ReadingInsightsPopup:_paginate(sections, avail_h, fonts, width)
    local probe = TextWidget:new{ text = "0", face = fonts.label }
    local footer_h = probe:getSize().h + 2 * Size.padding.small
    probe:free()
    local room = avail_h - footer_h
    local top_gap = Size.padding.small  -- above the first section of pages 2+

    local n = #sections
    local starts, prev = { 1 }, 1
    for _idx, b in ipairs(sections._breaks or {}) do
        if b > prev and b <= n then
            table.insert(starts, b)
            prev = b
        end
    end

    local pages, cur, cur_h = {}, nil, 0
    for k, first in ipairs(starts) do
        local last = (starts[k + 1] or (n + 1)) - 1
        local h = 0
        for i = first, last do h = h + sections[i]:getSize().h end
        if cur and cur_h + h > room then
            table.insert(pages, cur)
            cur = nil
        end
        if cur then
            cur.last = last
            cur_h = cur_h + h
        else
            cur = { first = first, last = last }
            cur_h = h + ((#pages > 0) and top_gap or 0)
        end
    end
    if cur then table.insert(pages, cur) end

    local count = #pages
    local page = math.max(1, math.min(self._page or 1, count))
    self._page, self._page_count = page, count

    local group = VerticalGroup:new{ align = "left" }
    if page > 1 then table.insert(group, VerticalSpan:new{ width = top_gap }) end
    for i = pages[page].first, pages[page].last do
        table.insert(group, sections[i])
    end
    self:_dropHiddenTargets(group)

    return VerticalGroup:new{
        align = "left",
        group,
        VerticalSpan:new{ width = math.max(0, room - group:getSize().h) },
        self:_buildPageFooter(fonts, width, footer_h, page, count),
    }
end

-- "‹  1 / 2  ›" under the page; the arrows turn the page.
function ReadingInsightsPopup:_buildPageFooter(fonts, width, height, page, count)
    local IconWidget = require("ui/widget/iconwidget")
    local label = TextWidget:new{ text = page .. " / " .. count, face = fonts.label, fgcolor = Colors.label() }
    local icon_sz = label:getSize().h
    local tap_w = 3 * icon_sz
    local popup_self = self
    local function arrow(icon, target)
        if target < 1 or target > count then
            return HorizontalSpan:new{ width = tap_w }
        end
        local cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = tap_w, h = height },
            CenterContainer:new{
                dimen = Geom:new{ w = tap_w, h = height },
                IconWidget:new{ icon = icon, width = icon_sz, height = icon_sz },
            },
        }
        cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
        cell.onTap = function() popup_self:_goToPage(target); return true end
        return cell
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalGroup:new{
            align = "center",
            arrow("chevron.left", page - 1),
            label,
            arrow("chevron.right", page + 1),
        },
    }
end

-- Forgets the hold / swipe targets that are not on the shown page: they are
-- never painted, so their positions would still be the zeros they were
-- built with and would catch gestures at the top left of the screen.
function ReadingInsightsPopup:_dropHiddenTargets(page_group)
    local shown = {}
    local function walk(w)
        shown[w] = true
        for _idx, child in ipairs(w) do
            if type(child) == "table" then walk(child) end
        end
    end
    walk(page_group)
    local function keepShown(list, key)
        if not list then return end
        for i = #list, 1, -1 do
            local w = key and list[i][key] or list[i]
            if not shown[w] then table.remove(list, i) end
        end
    end
    keepShown(self._chart_hold_targets, "w")
    keepShown(self._timegoal_hold_targets, "w")
    keepShown(self._week_hold_targets, "w")
    keepShown(self._goal_hold_targets, "w")
    keepShown(self._week_swipe_targets)
    keepShown(self._year_swipe_targets)
    if self._today_bar_widget and not shown[self._today_bar_widget] then
        self._today_bar_widget = nil
    end
    if self._current_month_bar_widget and not shown[self._current_month_bar_widget] then
        self._current_month_bar_widget = nil
    end
end

function ReadingInsightsPopup:_goToPage(page)
    self._page = page
    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
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
        -- The "Reloading data..." message stays up for the whole reload (the
        -- UI is busy while the database is re-scanned and the achievements
        -- are re-dated), and a short result message follows it.
        local msg = InfoMessage:new{ text = _("Reloading data...") }
        UIManager:show(msg)
        UIManager:scheduleIn(0.5, function()
            local before = Achievements and Achievements.earnedCount() or 0
            Cache.clearAllCache()
            Data.clearCalendarWeekCache(true)
            Data.clearTimeGoalCache()
            -- ratings changed outside the plugin (file manager, status page)
            if BookList and BookList.refreshRatings then pcall(BookList.refreshRatings, true) end
            -- A full reload is the one place achievements are re-evaluated
            -- against the (now uncached) database - see lib/achievements.lua.
            -- Newly earned ones get persisted; the rebuilt goal section then
            -- reads the updated count from the file.
            if Achievements then pcall(Achievements.recompute) end
            local gained = (Achievements and Achievements.earnedCount() or 0) - before
            self._streaks         = nil
            self._yearly          = nil
            self._monthly         = nil
            self._all_time        = nil
            self._last_week       = nil
            self._last_week_daily = nil
            UIManager:close(msg)
            self:_loadAndRebuild()
            local text = _("Data reloaded")
            if gained > 0 then
                text = T(_("Data reloaded. New achievements: %1"), tostring(gained))
            end
            UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
        end)
        return true
    end

    -- Long press on today's column of the weekly chart: today's timeline
    -- (the day calendar view). Tap opens that day's book list instead.
    if self._today_bar_widget then
        local d = self._today_bar_widget.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            self:openTodayTimeline()
            return true
        end
    end

    if self._current_month_bar_widget then
        local d = self._current_month_bar_widget.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            self:openCalendarForCurrentMonth()
            return true
        end
    end

    -- Chart captions: hold opens a list of their views.
    for _idx, t in ipairs(self._chart_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    -- Weekly section header: hold flips between "Last 7 days" and the
    -- current-week view.
    for _idx, t in ipairs(self._week_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    -- Daily/Weekly time goal section: a hold edits that goal.
    for _idx, t in ipairs(self._timegoal_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    -- Reading-goal section: a hold on any of its headers/cells runs that
    -- widget's registered action (see buildInsightsSections' addHold).
    for _idx, t in ipairs(self._goal_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    return true
end

-- Tapping the number in a SpinWidget / DoubleSpinWidget opens KOReader's own
-- numeric InputDialog, which is *not* modal - and UIManager stacks a non-modal
-- window shown over a modal one (ReadingInsightsPopup) *underneath* it, so the
-- entry field ended up hidden behind the popup. This makes that dialog modal:
-- the number picker's value button gets wrapped so that, while its tap action
-- runs (it shows the InputDialog synchronously), InputDialog is flagged modal.
-- NumberPickerWidget rebuilds its value button on every update, and the
-- spin widgets rebuild their pickers on every change, so the hook is
-- re-applied after each rebuild.
local function hookValueTapModal(picker)
    if not picker then return end
    local InputDialog = require("ui/widget/inputdialog")
    local function wrap()
        local btn = picker.text_value
        local cb  = btn and btn.callback
        if not cb then return end
        btn.callback = function(...)
            local prev = rawget(InputDialog, "modal")
            InputDialog.modal = true
            local ok, err = pcall(cb, ...)
            InputDialog.modal = prev
            if not ok then error(err, 0) end
        end
    end
    local orig_update = picker.update
    picker.update = function(p_self, ...)
        local r = orig_update(p_self, ...)
        wrap()
        return r
    end
    wrap()
end

-- Applies hookValueTapModal to the pickers of a spin widget (SpinWidget:
-- value_widget, DoubleSpinWidget: left_widget / right_widget), now and after
-- each of the widget's own rebuilds.
local function hookSpinWidgetModal(widget)
    local function hookAll(w)
        hookValueTapModal(w.value_widget)
        hookValueTapModal(w.left_widget)
        hookValueTapModal(w.right_widget)
    end
    local orig_update = widget.update
    widget.update = function(w_self, ...)
        local r = orig_update(w_self, ...)
        hookAll(w_self)
        return r
    end
    hookAll(widget)
end

-- Opens a numeric picker (long press on the goal value in the reading-goal
-- section) to set/change that year's target in books. Same look as the
-- daily/weekly goal picker (editTimeGoal), just with one number. Saved
-- immediately on OK; the popup is
-- rebuilt in place so the new value shows without a full close/reopen.
function ReadingInsightsPopup:editReadingGoal(year)
    local SpinWidget = require("ui/widget/spinwidget")
    local popup_self = self
    local current = math.floor(VS.readReadingGoal(year))
    if current < 1 then current = 1 elseif current > 999 then current = 999 end
    local widget
    widget = SpinWidget:new{
        -- ReadingInsightsPopup is modal, and UIManager stacks a *non*-modal
        -- window shown over it *underneath* it, so the picker must be modal
        -- too (same reason as editTimeGoal). Tapping the number opens the
        -- keyboard entry, made modal as well - see hookSpinWidgetModal.
        modal         = true,
        title_text    = buildGoalEditTitle(year),
        value         = current,
        value_min     = 1,
        value_max     = 999,
        value_step    = 1,
        value_hold_step = 5,
        ok_always_enabled = true,
        callback = function(spin)
            local n = tonumber(spin and spin.value)
            if n then
                n = math.floor(n)
                if n < 1 then n = 1 elseif n > 999 then n = 999 end
                VS.saveReadingGoal(year, n)
            end
            popup_self:_buildUI()
            UIManager:setDirty(popup_self, function()
                return "ui", popup_self.popup_frame.dimen
            end)
        end,
    }
    widget.modal = true
    hookSpinWidgetModal(widget)
    UIManager:show(widget)
end

-- Tap on the Daily/Weekly goal section: how many days / weeks in a row the
-- goal has been met. Runs one grouped query only now, so opening the popup
-- itself costs nothing extra.
function ReadingInsightsPopup:showTimeGoalStreak(kind)
    local is_daily = (kind == "daily")
    Data.flushStatsToDB(self.ui)
    local goal_secs = (is_daily and VS.readDailyGoalMinutes() or VS.readWeeklyGoalMinutes()) * 60
    local n = Data.getTimeGoalStreak(kind, goal_secs) or 0
    local text
    if n <= 0 then
        text = is_daily and _("You haven't met your daily goal yet.")
                         or _("You haven't met your weekly goal yet.")
    elseif is_daily then
        text = T(N_("You've met your daily goal %1 day in a row.",
                    "You've met your daily goal %1 days in a row.", n), formatCount(n))
    else
        text = T(N_("You've met your weekly goal %1 week in a row.",
                    "You've met your weekly goal %1 weeks in a row.", n), formatCount(n))
    end
    UIManager:show(InfoMessage:new{ text = text, modal = true, timeout = 5 })
end

-- Long press on the Daily/Weekly goal section: hours/minutes spinner for the
-- goal (stored as total minutes). Marked modal so it opens above this popup,
-- same reason as editReadingGoal's modal InputDialog.
function ReadingInsightsPopup:editTimeGoal(kind)
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")

    -- Label for the "default" button, e.g. "Default: 30m" / "Default: 5h"
    -- (depends on KOReader's duration format setting), instead of KOReader's
    -- raw "Default values: 0 : 30". Seconds are dropped.
    local function formatDefaultGoal(total_min)
        return T(_("Default: %1"), Locale.formatDuration(total_min * 60, true))
    end
    local popup_self = self
    local is_daily = (kind == "daily")
    local current  = is_daily and VS.readDailyGoalMinutes() or VS.readWeeklyGoalMinutes()
    local default  = is_daily and VS.DEFAULT_DAILY_GOAL_MIN or VS.DEFAULT_WEEKLY_GOAL_MIN
    local max_hours = is_daily and 23 or 99
    local widget
    widget = DoubleSpinWidget:new{
        modal        = true,
        title_text   = is_daily and _("Daily goal") or _("Weekly goal"),
        left_text    = _("Hours"),
        left_value   = math.floor(current / 60),
        left_min     = 0,
        left_max     = max_hours,
        left_step    = 1,
        left_hold_step = 5,
        right_text   = _("Minutes"),
        right_value  = current % 60,
        right_min    = 0,
        right_max    = 59,
        right_step   = 1,
        right_hold_step = 5,
        default_values = true,
        left_default   = math.floor(default / 60),
        right_default  = default % 60,
        default_text   = formatDefaultGoal(default),
        ok_always_enabled = true,
        callback = function(hours, minutes)
            local total = (tonumber(hours) or 0) * 60 + (tonumber(minutes) or 0)
            if total < 1 then total = 1 end
            if is_daily then VS.saveDailyGoalMinutes(total) else VS.saveWeeklyGoalMinutes(total) end
            popup_self:_buildUI()
            UIManager:setDirty(popup_self, function()
                return "ui", popup_self.popup_frame.dimen
            end)
        end,
    }
    widget.modal = true

    hookSpinWidgetModal(widget)

    UIManager:show(widget)
end

-- Cycles the insights mode (hours -> days -> books -> hours) and reloads
-- the monthly chart for it. Bound to both the "Press" key handler
-- (toggleInsightsMode) and tapping the monthly chart header
-- (cycleInsightsMode) - kept as two names since that's what the gesture/key
-- wiring elsewhere calls, but there's only one implementation.
function ReadingInsightsPopup:cycleInsightsMode()
    local new_mode
    -- time -> pages -> days -> books -> time
    if self.mode == VS.INSIGHTS_MODE_HOURS then
        new_mode = VS.INSIGHTS_MODE_PAGES
    elseif self.mode == VS.INSIGHTS_MODE_PAGES then
        new_mode = VS.INSIGHTS_MODE_DAYS
    elseif self.mode == VS.INSIGHTS_MODE_DAYS then
        new_mode = VS.INSIGHTS_MODE_BOOKS
    else
        new_mode = VS.INSIGHTS_MODE_HOURS
    end

    return self:setInsightsMode(new_mode)
end

-- Applies an insights mode (hours / pages / days / books): persists it and
-- reloads the monthly chart for it.
function ReadingInsightsPopup:setInsightsMode(new_mode)
    if self.mode == new_mode then return true end
    VS.saveInsightsMode(new_mode)
    self.mode = new_mode

    -- Only the monthly chart changes with the mode; a past year serves it
    -- from the frozen cache, the current year from stale + background
    -- refresh. reset_yearly = false so the (mode-independent) yearly numbers
    -- on screen don't flicker.
    self:_primeYearSpecific(false)

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

-- Shows a list dialog with one row per choice, the active one marked with a
-- check mark (same look as the other pickers of the plugin).
--   choices = { { value = ..., text = ... }, ... }
function ReadingInsightsPopup:_showChoiceDialog(choices, current, on_pick)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _idx, c in ipairs(choices) do
        local value = c.value
        table.insert(buttons, {{
            -- U+2713 CHECK MARK in front of the view currently in use.
            text  = (current == value and "\xe2\x9c\x93 " or "    ") .. c.text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                on_pick(value)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        modal                 = true,
        shrink_unneeded_width = true,
        buttons               = buttons,
    }
    -- ButtonDialog repaints its area with a flashing "flashui" refresh when
    -- it closes; use a plain "ui" refresh instead so choosing an item does
    -- not flash the screen. The popup is redrawn right after by the callback.
    dialog.onCloseWidget = function(this)
        UIManager:setDirty(nil, function()
            return "ui", this.movable and this.movable.dimen
        end)
    end
    UIManager:show(dialog)
end

-- Long press on the monthly chart caption: choose the monthly view.
function ReadingInsightsPopup:showInsightsModePicker()
    local popup_self = self
    self:_showChoiceDialog({
        { value = VS.INSIGHTS_MODE_HOURS, text = _("Reading time per month") },
        { value = VS.INSIGHTS_MODE_PAGES, text = _("Pages per month") },
        { value = VS.INSIGHTS_MODE_DAYS,  text = _("Days read per month") },
        { value = VS.INSIGHTS_MODE_BOOKS, text = _("Books per month") },
    }, self.mode, function(mode) popup_self:setInsightsMode(mode) end)
    return true
end

function ReadingInsightsPopup:toggleInsightsMode()
    return self:cycleInsightsMode()
end

-- Toggles the "Last 7 days" bar chart between reading time and pages read per
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
    -- Serve the target year's year-specific data before building: a past
    -- year exactly, from its frozen cache (so the auto-fit is right on the
    -- first pass, no reflow); the current year from stale, refreshed by the
    -- background _loadAndRebuild below.
    self:_primeYearSpecific(true)

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

-- Whether the calendar week `offset` weeks from the current one (0 = this
-- week, -1 = last week, ...) may be shown: never a future week, and not a
-- week that ends before the first year with reading data.
function ReadingInsightsPopup:_weekInRange(offset)
    if offset > 0 then return false end
    local yr = self._year_range or self.year_range
    local min_year = (yr and yr.min_year) or tonumber(os.date("%Y"))
    local _start, week_end = Data.calendarWeekBounds(offset)
    return (tonumber(week_end:sub(1, 4)) or 0) >= min_year
end

-- Loads the shown calendar week (self.week_offset) into self._cal_week.
-- Used where the week must be on the page at once - the first build, and
-- paging - since it is one small query (cached per minute). Anything that
-- comes back empty (a locked DB) keeps whatever was shown before.
function ReadingInsightsPopup:_primeCalendarWeek()
    if not VS.readWeeklyViewIsCalendar() then
        self._cal_week = nil
        return
    end
    local ok, res = pcall(Data.getCalendarWeek, self.week_offset or 0)
    if ok and res then self._cal_week = res end
end

-- Pages the calendar week by `delta` (-1 = the week before, +1 = the next),
-- the same way _goToYear pages the year. The data of one week is fetched
-- right away, so there is no stale flash and no second redraw.
function ReadingInsightsPopup:_goToWeek(delta)
    if not VS.readWeeklyViewIsCalendar() then return true end
    local new_offset = (self.week_offset or 0) + delta
    if not self:_weekInRange(new_offset) then return true end

    self.week_offset = new_offset
    self._cal_week = nil
    self:_primeCalendarWeek()

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Tap on the shown week's label: jump straight back to the current week.
function ReadingInsightsPopup:onGoToCurrentWeek()
    if not VS.readWeeklyViewIsCalendar() then return true end
    if (self.week_offset or 0) == 0 then return true end
    self.week_offset = 0
    self._cal_week = nil
    self:_primeCalendarWeek()

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Switches the weekly section between the rolling last 7 days and the
-- current calendar week (the same setting as Settings > Week > View).
function ReadingInsightsPopup:setWeeklyView(value)
    if self.readonly then return true end
    if VS.readWeeklyViewSetting() == value then return true end
    VS.saveWeeklyViewSetting(value)
    self.week_offset = 0
    self._cal_week = nil
    self:_primeCalendarWeek()

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Long press on the "Last 7 days" header: choose the week view from a list.
function ReadingInsightsPopup:showWeeklyViewPicker()
    local popup_self = self
    self:_showChoiceDialog({
        { value = VS.WEEKLY_VIEW_LAST7,    text = _("Last 7 days") },
        { value = VS.WEEKLY_VIEW_CALENDAR, text = _("Current week") },
    }, VS.readWeeklyViewSetting(), function(view) popup_self:setWeeklyView(view) end)
    return true
end

function ReadingInsightsPopup:onGoToPrevWeek()
    return self:_goToWeek(-1)
end

function ReadingInsightsPopup:onGoToNextWeek()
    return self:_goToWeek(1)
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
-- The year shelf without an insights window under it - the sleep screen shows
-- it on its own (lib/sleepscreen.lua). opts: ui, year (default: this year),
-- readonly. Returns the shelf window, nil when there is no shelf module.
local function openYearShelf(opts)
    if not YearShelf then return nil end
    opts = opts or {}
    local year_range
    pcall(function() year_range = Data.getYearRange() end)
    local year = tonumber(opts.year) or tonumber(os.date("%Y"))
    if year_range and year_range.min_year and year_range.max_year then
        year = math.max(year_range.min_year, math.min(year_range.max_year, year))
    end
    return YearShelf.show{
        ui         = opts.ui,
        year       = year,
        year_range = year_range,
        readonly   = opts.readonly,
        getBooks   = function(y, finished_only)
            if finished_only then
                return getFinishedBooksForYearCombined(nil, y)
            end
            return Data.getBooksForPeriod("%Y", tostring(y))
        end,
    }
end

return {
    showYearShelf = openYearShelf,
    Popup = ReadingInsightsPopup,
    -- Open the combined current/best streak popup straight from the menu.
    showStreaks = function()
        Streak.show(Data.calculateStreaks())
    end,
}
