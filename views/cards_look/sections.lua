--[[
Reading Insights - the "Cards" look of the insights popup (Settings >
Appearance > Look).

Builds the same sections as insights_view.lua's buildInsightsSections (the
Classic look), each one as a card with an icon in its header; _buildUI in
insights_view.lua picks one of the two. The sections are put on pages when
they don't fit one screen (see views/cards_look/pages.lua), so each one records
where it starts (sections._breaks).

Loaded once by main.lua and handed to the insights view as `deps.InsightsCards`.
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
local Locale, Colors, VS, UI, Data, Achievements, Streak, Charts, Headers, Donut =
    deps.Locale, deps.Colors, deps.VS, deps.UI, deps.Data, deps.Achievements,
    deps.Streak, deps.Charts, deps.Headers, deps.Donut
local Values = deps.Values

local buildMonthlyChart, buildWeeklyChart = Charts.buildMonthlyChart, Charts.buildWeeklyChart
local buildWeekNavHeader = Headers.buildWeekNavHeader

local _            = Locale._
local N_           = Locale.N_
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount
local splitDurationValueUnit = Locale.splitDurationValueUnit

local M = {}

local tappableCell = UI.tappableCell

-- The year row of the Reading insights page (views/insights_headers.lua),
-- with the chart icon before the year and a "›" after it when a tap opens the
-- year shelf; no background fill.
local function buildYearHeader(popup_self, font_section, font_label, layout, year_range, selected_year)
    return Headers.buildYearRow(popup_self, font_section, font_label, layout, year_range, selected_year,
        function(year_label, tappable)
            local inner_pad = Size.padding.default
            local icon_sz = math.floor(year_label:getSize().h * 0.7)
            local group = HorizontalGroup:new{
                align = "center",
                UI.icon("chart", icon_sz),
                HorizontalSpan:new{ width = inner_pad },
                year_label,
            }
            if tappable then
                table.insert(group, HorizontalSpan:new{ width = inner_pad })
                table.insert(group, UI.chevron(font_section))
            end
            return group
        end)
end

local function buildYearlyRow(popup_self, yearly_stats, fonts, layout)
    local left_value, left_unit, right_value, right_unit =
        Values.yearlyValues(popup_self.selected_year, popup_self.mode, yearly_stats)

    -- Stacked value cells (tap: the books of that year), `layout` is the
    -- inside of the year card.
    local selected_year_for_tap = popup_self.selected_year
    local function cell(value, unit)
        local c = UI.buildStatCell(fonts, layout.col_width, value, unit, { chevron = not popup_self.readonly })
        return tappableCell(c, layout.col_width, function() popup_self:showBooksForYear(selected_year_for_tap) end)
    end
    return UI.buildTwoColRow(cell(left_value, left_unit), cell(right_value, right_unit),
        layout, false, nil, Size.line.thin, Colors.cardsColor("divider"))
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
    -- Also kept for the section order (Settings > Reading insights popup >
    -- Section order): the sections are built in a fixed order below and
    -- rearranged at the end (VS.Order.reorderGroup). `lead`: the gap
    -- UI.addCard puts above the very first card, which moves with the
    -- section that is first.
    local marks = {}
    local function newBlock(id)
        table.insert(breaks, #sections + 1)
        table.insert(marks, { id = id, first = #sections + 1, lead = (#sections == 0) or nil })
    end

    -- "Daily goal | Weekly goal": time read today / this calendar week against
    -- a goal in minutes. Long press on the section edits the goals. Today's
    -- and this week's seconds come from the last-7-days data already loaded
    -- for the "Last 7 days" section (a calendar week never reaches back more
    -- than 7 days, so no extra query is needed).
    popup_self._timegoal_hold_targets = {}
    if VS.readShowTimeGoals() then

        local today_secs, week_secs, daily_goal_secs, weekly_goal_secs =
            Values.timeGoalValues(last_week_daily, last_week_daily and Data.weekStartWday())

        local function addTimeGoalHold(widget, fn)
            table.insert(popup_self._timegoal_hold_targets, { w = widget, fn = fn })
        end
        local function editDaily()  popup_self:editTimeGoal("daily")  end
        local function editWeekly() popup_self:editTimeGoal("weekly") end

        local goalText = Values.timeGoalText

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
        newBlock("time_goals")
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
        local lw, week_daily, has_week = Values.weekData(cal_mode,
            cal_mode and popup_self._cal_week or nil, last_week_stats, last_week_daily)
        if has_week and VS.Opt.readShowSection("week") then
            local days_n = lw.days or 7
            local total_secs, total_pages_raw, time_cells, pages_cells = Values.weekValues(lw)

            local weekly_chart_mode = VS.normalizeWeeklyChartMode(popup_self.weekly_chart_mode)
            local pages_mode = (weekly_chart_mode == VS.WEEKLY_CHART_MODE_PAGES)

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
                local diff_total, diff_avg =
                    Values.weekDiff(lw, pages_mode, total_secs, total_pages_raw, days_n)
                deltas = { deltaText(diff_total), deltaText(diff_avg, true) }
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
                    ilayout, false, row_opts, Size.line.thin, Colors.cardsColor("divider"))
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
                -- Without the header fill, which the card does not use.
                header = buildWeekNavHeader(popup_self, fonts.section, fonts.label, ilayout)
                header.background = nil
            else
                local header_row = UI.cardHeader("calendar", _("Last 7 days"), fonts.section,
                    ilayout.content_width, (not popup_self.readonly) and "menu" or false, switch_cell)
                header = InputContainer:new{
                    dimen = Geom:new{ x = 0, y = 0, w = ilayout.content_width, h = header_row:getSize().h },
                    header_row,
                }
                -- A tap (the "▾") or a long press lists the two week views
                -- (last 7 days / current week) to choose from.
                if not popup_self.readonly then
                    header.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = header.dimen } } }
                    header.onTap = function() popup_self:showWeeklyViewPicker(); return true end
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

            newBlock("week")
            UI.addCard(sections, card, layout)
        end
    end

    local cd_val, cd_unit, cw_val, cw_unit, bd_val, bd_unit, bw_val, bw_unit =
        Values.streakValues(streaks)

    -- One card: current and best streak side by side, each as days and
    -- weeks. Under the current streak a dot per day of the last 7 days
    -- (filled = read), under the best one the days left to beat it.
    -- A tap anywhere on the card opens the streak calendar.
    -- (Settings > Reading insights popup > Sections can switch it off.)
    if VS.Opt.readShowSection("streaks") then
        local ilayout = UI.cardLayout(layout)
        local col_w   = ilayout.col_width

        local function streakLine(d_val, d_unit, w_val, w_unit)
            return UI.buildDaysWeeksLine(fonts, col_w, d_val, d_unit, w_val, w_unit)
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
            UI.buildTwoColRow(current_col, best_col, ilayout, false, nil, Size.line.thin, Colors.cardsColor("divider")),
            VerticalSpan:new{ width = Size.padding.default },
        }
        local card = UI.buildCard(body, layout.content_width)
        local tap_card = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = card:getSize().w, h = card:getSize().h },
            card,
        }
        tap_card.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = tap_card.dimen } } }
        function tap_card:onTap() Streak.show(streaks) return true end

        newBlock("streaks")
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
    -- monthly chart. (Sections > Yearly & monthly / Monthly chart can switch
    -- the card, or just its chart, off.)
    if VS.Opt.readShowSection("year") then
        local ilayout = UI.cardLayout(layout)
        local body = VerticalGroup:new{
            align = "left",
            buildYearHeader(popup_self, fonts.section, fonts.label, ilayout, year_range, popup_self.selected_year),
            VerticalSpan:new{ width = Size.padding.small },
            buildYearlyRow(popup_self, yearly_stats, fonts, ilayout),
        }

        local chart = VS.Opt.readShowSection("monthly")
            and buildMonthlyChart(popup_self, monthly_data, ilayout, fonts, true) or nil
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

        newBlock("year")
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
            local pace
            local state, n = Values.goalPace(finished_count, goal_value, goal_year)
            if state == "reached" then
                pace = _("Goal reached")
            elseif state == "not_reached" then
                pace = _("Goal not reached")
            elseif state == "on_track" then
                pace = _("On track")
            elseif state == "ahead" then
                pace = "\u{25B2} " .. formatCount(n) .. " " .. N_("book ahead of pace", "books ahead of pace", n)
            elseif state == "behind" then
                pace = "\u{25BC} " .. formatCount(n) .. " " .. N_("book behind pace", "books behind pace", n)
            else
                pace = formatCount(Values.goalPercent(finished_count, goal_value)) .. "% " .. _("of yearly goal")
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
        newBlock("goal_ach")
        UI.addCard(sections, row, layout)
    end -- if show_goal or show_ach

    if VS.Opt.readShowSection("all_time") then
        local all_time_val, all_time_unit, all_pages_val, all_pages_unit = Values.allTimeValues(all_time_stats)

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
                ilayout, false, nil, Size.line.thin, Colors.cardsColor("divider")),
            VerticalSpan:new{ width = Size.padding.default },
        }
        newBlock("all_time")
        UI.addCard(sections, UI.buildCard(body, layout.content_width), layout)
    end

    VS.Order.reorderGroup(sections, marks, "insights", {
        makeLead = function() return VerticalSpan:new{ width = Size.padding.small } end,
    })
    return sections
end

return M
