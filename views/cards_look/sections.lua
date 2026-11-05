--[[
Reading Insights - the "Cards" look of the insights popup (Settings >
Reading insights popup > Look).

Builds the same sections as insights_view.lua's buildInsightsSections (the
Classic look), each one as a card with an icon in its header; _buildUI in
insights_view.lua picks one of the two. The sections are put on pages when
they don't fit one screen (see views/cards_look/pages.lua), so each one records
where it starts (sections._breaks).

Loaded once by main.lua and handed to the insights view as `deps.Cards`.
]]--

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local T = require("ffi/util").template

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, VS, UI, Data, Achievements, Streak, YearShelf, Charts, Headers, Donut =
    deps.Locale, deps.Colors, deps.VS, deps.UI, deps.Data, deps.Achievements,
    deps.Streak, deps.YearShelf, deps.Charts, deps.Headers, deps.Donut

local buildMonthlyChart, buildWeeklyChart = Charts.buildMonthlyChart, Charts.buildWeeklyChart
local buildWeekNavHeader = Headers.buildWeekNavHeader

local _            = Locale._
local N_           = Locale.N_
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount
local splitDurationValueUnit = Locale.splitDurationValueUnit
local buildValueLine = UI.buildValueLine

local M = {}

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

local function buildYearHeader(popup_self, font_section, font_label, font_value, layout, year_range, selected_year)
    local prev_available = selected_year > year_range.min_year
    local next_available = selected_year < year_range.max_year

    local inner_pad = Size.padding.default
    local gap       = Size.padding.small

    -- The previous/next year on either side use the plain "label" face
    -- (like the "pages read" text below), so only the centre year - in the
    -- bold "section" face - stands out as the selected one.
    local sample_arrow = TextWidget:new{ text = "\xe2\x80\xb9", face = font_label }
    local arrow_w = sample_arrow:getSize().w
    sample_arrow:free()

    local sample_yr = TextWidget:new{ text = tostring(selected_year - 1), face = font_label }
    local yr_side_w = sample_yr:getSize().w
    sample_yr:free()

    local slot_w = arrow_w + gap + yr_side_w + inner_pad

    local year_label = TextWidget:new{
        text = tostring(selected_year),
        face = font_section,
        fgcolor = Colors.section(),
    }
    -- Year navigation is done via swipe on the whole popup (see
    -- onSwipe/_goToYear) and by tapping the previous/next year slot on either
    -- side of the centre year (the InputContainer wrappers below). The reading
    -- heatmap opens from the "All time" header instead of from tapping the
    -- year (see showReadingHeatmap and buildInsightsSections). Tapping the
    -- centre year itself opens the year shelf: the covers of the books read
    -- that year, month by month (see showYearShelf). Not on the sleep screen
    -- (readonly), where a tap must not navigate anywhere.
    local tappable_year = YearShelf and not popup_self.readonly
    local year_h  = year_label:getSize().h
    local icon_sz = math.floor(year_h * 0.7)
    local year_group = HorizontalGroup:new{
        align = "center",
        UI.icon("chart", icon_sz),
        HorizontalSpan:new{ width = inner_pad },
        year_label,
    }
    local year_group_w = icon_sz + inner_pad + year_label:getSize().w
    if tappable_year then
        local chevron = UI.chevron(font_section)
        table.insert(year_group, HorizontalSpan:new{ width = inner_pad })
        table.insert(year_group, chevron)
        year_group_w = year_group_w + inner_pad + chevron:getSize().w
    end
    local year_widget = year_group
    local year_tap_pad = 0
    if tappable_year then
        year_tap_pad = Screen:scaleBySize(16)
        local year_inner = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = year_tap_pad },
            year_group,
            HorizontalSpan:new{ width = year_tap_pad },
        }
        local year_tappable = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0,
                w = year_group_w + 2 * year_tap_pad, h = year_inner:getSize().h },
            year_inner,
        }
        year_tappable.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = year_tappable.dimen } },
        }
        function year_tappable:onTap()
            popup_self:showYearShelf()
            return true
        end
        year_widget = year_tappable
    end

    local function makeSlot(yr, arrow_glyph, left, visible, on_tap)
        if not visible then
            return HorizontalSpan:new{ width = slot_w }, slot_w
        end

        local arrow_tw = TextWidget:new{
            text    = arrow_glyph,
            face    = font_label,
            fgcolor = Colors.label(),
        }
        local yr_tw = TextWidget:new{
            text    = tostring(yr),
            face    = font_label,
            fgcolor = Colors.label(),
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

        -- Tapping the slot navigates to that year, same as the swipe.
        local tappable = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = parts:getSize().w, h = parts:getSize().h },
            parts,
        }
        tappable.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = tappable.dimen } },
        }
        function tappable:onTap()
            on_tap()
            return true
        end
        return tappable, slot_w
    end

    local left_slot,  left_w  = makeSlot(selected_year - 1, "\xe2\x80\xb9", true,  prev_available,
        function() popup_self:onGoToPrevYear() end)
    local right_slot, right_w = makeSlot(selected_year + 1, "\xe2\x80\xba", false, next_available,
        function() popup_self:onGoToNextYear() end)

    local year_w    = year_group_w + 2 * year_tap_pad
    local remaining = layout.content_width - left_w - right_w - year_w
    if remaining < 0 then remaining = 0 end
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l

    return HorizontalGroup:new{
        align = "center",
        left_slot,
        HorizontalSpan:new{ width = side_l },
        year_widget,
        HorizontalSpan:new{ width = side_r },
        right_slot,
    }
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

function M.buildSections(popup_self, streaks, yearly_stats, year_range, monthly_data, all_time_stats, last_week_stats, last_week_daily, fonts, layout, goal_finished_count)
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
                read_color   = Colors.cardsColor("active_bar"),
                unread_color = Colors.cardsColor("inactive_bar"),
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
            local weekly_chart = buildWeeklyChart(popup_self, week_daily, ilayout, fonts, weekly_chart_mode, true)
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

        local chevron = UI.chevron(fonts.section)
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

        local chart = buildMonthlyChart(popup_self, monthly_data, ilayout, fonts, true)
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
                VerticalSpan:new{ width = Size.padding.default },
                UI.buildPill(pace, fonts.small, false, inner_w),
                VerticalSpan:new{ width = Size.padding.default },
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
                and UI.chevron(fonts.section) or nil

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

        -- One card: header (tap: the reading heatmap, moved here from
        -- tapping the year, see showReadingHeatmap / buildYearHeader) and
        -- the two totals (tap: all books).
        local ilayout = UI.cardLayout(layout)
        local function cell(value, unit)
            return tappableCell(UI.buildStatCell(fonts, ilayout.col_width, value, unit),
                ilayout.col_width, function() popup_self:showAllBooks() end)
        end
        local chevron = (not popup_self.readonly)
            and UI.chevron(fonts.section) or nil
        local header = tappableCell(
            UI.cardHeader("clock", _("All time"), fonts.section, ilayout.content_width, false, chevron),
            ilayout.content_width, function() popup_self:showReadingHeatmap() end)

        local body = VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = Size.padding.small },
            UI.buildTwoColRow(cell(all_time_val, all_time_unit), cell(all_pages_val, all_pages_unit),
                ilayout, false, nil, Size.line.thin),
            VerticalSpan:new{ width = Size.padding.default },
        }
        newBlock()
        UI.addCard(sections, UI.buildCard(body, layout.content_width), layout)
    end

    return sections
end

return M
