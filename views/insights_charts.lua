--[[
Reading Insights - the insights popup's bar and line charts.

Split out of insights_view.lua: the monthly chart (bars, or a smooth line with
a dot per month), the weekly chart of "Last 7 days" / the current week, and
the shared dot-and-curve chart both use in their "Line with dots" style. Pure
widget builders - the popup hands itself in as `popup_self` for the state
and callbacks the taps use (see each function).

Loaded once by main.lua and handed to the insights view as `deps.Charts`.
]]--

local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, UI, VS, Trend, DateUtil =
    deps.Locale, deps.Colors, deps.UI, deps.VS, deps.Trend, deps.DateUtil

local formatNumber = Locale.formatNumber
local isLandscapeScreen = UI.isLandscapeScreen

-- true: today's bar in the weekly chart is black. false: all bars gray.
local WEEKLY_CHART_HIGHLIGHT_TODAY = true


-- Yearly chart as a smooth curve with a dot on it for each month and the
-- month's value above the dot (the default style; the "Months chart style"
-- setting switches back to bars). Always one row of all months, since the
-- curve needs to run unbroken. Each month column is tappable (opens that
-- month's books); the current month's dot has the active colour, like the
-- current bar in the bar style. Neighbouring values only move (one up a
-- row, alternating) when they would overlap, so compact values like "0:04"
-- never move.
-- Number of days in the month of a "YYYY-MM" string (28-31).
local function daysInMonthOf(month_str)
    local y, mo = tostring(month_str or ""):match("^(%d+)%-(%d+)$")
    y, mo = tonumber(y), tonumber(mo)
    if not y or not mo then return 31 end
    return DateUtil.daysInMonth(y, mo)
end

-- True for a month that hasn't happened yet in the year being shown: later
-- than the current month this year (every month of a future year). The
-- yearly chart leaves these out - no dot / value in the line style, no value
-- or tap in the bar style - instead of showing a made-up "00:00".
local function isFutureMonth(popup_self, m)
    local sel_year     = tonumber(popup_self.selected_year)
    local current_year = tonumber(os.date("%Y"))
    if not sel_year then return false end
    if sel_year > current_year then return true end
    return sel_year == current_year and tostring(m.month) > os.date("%Y-%m")
end

-- True for a month before the very first month with reading data (and with
-- nothing in the shown view either - a manually added book can be older than
-- the first reading record). The yearly chart leaves these empty, like the
-- months still to come, instead of showing "00:00".
local function isBeforeFirstData(popup_self, m)
    local yr = popup_self._year_range
    if not yr or not yr.min_year then return false end
    local first = string.format("%04d-%02d", yr.min_year, yr.min_month or 1)
    if not (tostring(m.month) < first) then return false end
    local has_value = (tonumber(m.seconds) or 0) > 0 or (tonumber(m.hours) or 0) > 0
        or (tonumber(m.book_count) or 0) > 0 or (tonumber(m.days) or 0) > 0
        or (tonumber(m.pages) or 0) > 0
    return not has_value
end

-- Horizontal gap between bars, shared by the weekly and monthly charts so
-- the two read with the same rhythm (bar widths differ with the bar count).
local function CHART_BAR_GAP()
    return tonumber(Screen:scaleBySize(8))
end

-- What the yearly chart plots for a month. In the "days read" view it is the
-- share of the month read (days / days in that month), so a month read
-- through every day stands as high as any other fully read month - 30, 31
-- or 28 days alike - instead of the longer month looking better. The label
-- still shows the real day count. Hours and books are plotted as they are.
local function monthlyPlotValue(m, value_key)
    local v = tonumber(m[value_key]) or 0
    if value_key == "days" then
        return v / daysInMonthOf(m.month)
    end
    return v
end

-- Shared line chart: a smooth curve with a dot on it for each entry, the
-- entry's value above the dot and its name (month / day) in a row below.
-- Used for the yearly chart and for "Last 7 days" when their style setting is
-- "Line with dots".
--
--   o.ratios[i]       height of entry i, 0..1 of the plot
--   o.value_strs[i]   text above the dot
--   o.axis_strs[i]    text under the chart
--   o.highlight[i]    true -> dot in the active colour
--   o.on_tap[i]       optional function, called when column i is tapped
--   o.on_widget(i, w) optional, handed the tappable column widget of entry i
--   o.slots           how many columns the full width is divided into
--                     (12 months / 7 days), so a short row stays left-aligned
--                     in the same scale
--   o.first           optional: entries before `first` are left empty too (no
--                     dot, value or curve point) - months before the first
--                     reading data. Default: 1.
--   o.visible         optional: only the first `visible` entries get a dot,
--                     a value and a place on the curve (the rest keep their
--                     axis label and baseline) - used to leave out months
--                     that haven't happened yet. Default: all.
--   o.chart_width, o.plot_height, o.fonts
--
-- Every value stands above its dot, and moves up just as far as it takes for
-- the curve not to run through it (Trend.clearLabelTops); neighbouring
-- values only move (one more row up) when they would overlap each other, so
-- compact values like "0:04" never do. The curve, the dots and the values
-- are all placed from the same coordinates, so they line up.
local function buildDotLineChart(o)
    local n_cols     = #o.ratios
    local n_vis      = math.max(0, math.min(o.visible or n_cols, n_cols))
    local first_vis  = math.max(1, o.first or 1)
    local col_width  = math.floor(o.chart_width / o.slots)
    local plot_height = o.plot_height
    local font_small = o.fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    -- The empty strip under the digits' baseline inside a value's box.
    local label_descent = math.max(0, label_height - sample_label:getBaseline())
    sample_label:free()

    local dot_size   = tonumber(Screen:scaleBySize(8))
    local baseline_h = Size.line.medium
    local label_gap  = tonumber(Screen:scaleBySize(4))
    -- Air between the digits' baseline and the curve. The box is taller than
    -- the digits: digits and colons leave the whole strip under their
    -- baseline empty, so the curve may run through all of it; a value with a
    -- hanging letter ("12 p") only gets half of it.
    local label_air  = tonumber(Screen:scaleBySize(1)) + 2
    local margins    = {}

    local label_ws = {}
    for i = first_vis, n_vis do
        local tw = TextWidget:new{ text = o.value_strs[i], face = font_small }
        label_ws[i] = tw:getSize().w
        tw:free()
    end

    -- Labels share one row above the dots; one that would run into an
    -- earlier label on the same row goes up a row instead.
    local levels, any_raised = {}, false
    for i = first_vis, n_vis do
        levels[i] = 0
        for j = i - 1, math.max(first_vis, i - 3), -1 do
            if levels[j] == levels[i]
               and (label_ws[j] + label_ws[i]) / 2 + label_gap > (i - j) * col_width then
                levels[i] = 1
                break
            end
        end
        if levels[i] == 1 then any_raised = true end
    end

    -- Where every value goes, measured from the top of the plot (the room
    -- above the highest one is added afterwards): above its dot, higher
    -- where the curve would cut through it.
    local pre_pts, widths, vis_index = {}, {}, {}
    for i = first_vis, n_vis do
        local dot_y_from_bottom = math.floor(o.ratios[i] * (plot_height - dot_size))
        local space_above = math.max(0, plot_height - dot_size - dot_y_from_bottom)
        pre_pts[#pre_pts + 1] = {
            x = (i - 1) * col_width + math.floor(col_width / 2),
            y = space_above + math.floor(dot_size / 2),
        }
        widths[#widths + 1] = label_ws[i]
        vis_index[i] = #pre_pts
        margins[#pre_pts] = label_air - (Trend.hasDescender(o.value_strs[i])
            and math.floor(label_descent / 2) or label_descent)
    end
    local pre_tops = Trend.clearLabelTops(pre_pts, widths, label_height, dot_size, margins,
        tonumber(Screen:scaleBySize(2)))
    local min_top = 0
    for i = first_vis, n_vis do
        local t = pre_tops[vis_index[i]] - levels[i] * label_height
        if t < min_top then min_top = t end
    end
    local label_area_h = -min_top + Size.padding.tiny
    local total_col_h  = plot_height + label_area_h + baseline_h

    local columns_row     = HorizontalGroup:new{ align = "bottom" }
    local axis_labels_row = HorizontalGroup:new{ align = "top" }
    local points, dots, value_labels = {}, {}, {}

    for i = 1, n_cols do
        -- The column only carries the baseline and the tap area; the dot and
        -- the value are placed explicitly on the chart area below, from the
        -- same coordinates as the curve.
        local col_group = VerticalGroup:new{ align = "center" }
        table.insert(col_group, Colors.newBar(col_width, baseline_h, Colors.inactiveBar()))

        -- Entries past `visible` (months still to come) have no dot, value
        -- or curve point; only their column and axis label remain.
        if i >= first_vis and i <= n_vis then
            local ratio = o.ratios[i]
            local dot_color = o.highlight[i] and Colors.activeBar() or Colors.inactiveBar()
            local dot_y_from_bottom = math.floor(ratio * (plot_height - dot_size))
            local space_above = plot_height - dot_size - dot_y_from_bottom
            if space_above < 0 then space_above = 0 end

            -- points/dots are kept as gap-free lists (the curve and the dots
            -- are drawn from them in order).
            local pt = {
                x = (i - 1) * col_width + math.floor(col_width / 2),
                y = label_area_h + space_above + math.floor(dot_size / 2),
            }
            points[#points + 1] = pt
            dots[#dots + 1] = { x = pt.x, y = pt.y, size = dot_size, color = dot_color }

            local value_label = TextWidget:new{ text = o.value_strs[i], face = font_small, fgcolor = Colors.small() }
            value_label.overlap_offset = {
                pt.x - math.floor(label_ws[i] / 2),
                label_area_h + pre_tops[vis_index[i]] - levels[i] * label_height,
            }
            value_labels[#value_labels + 1] = value_label
        end

        local tappable_col = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = col_width, h = total_col_h },
            BottomContainer:new{
                dimen = Geom:new{ w = col_width, h = total_col_h },
                col_group,
            },
        }
        local on_tap = o.on_tap and o.on_tap[i]
        if on_tap then
            tappable_col.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = tappable_col.dimen } },
            }
            function tappable_col:onTap()
                on_tap()
                return true
            end
        end
        if o.on_widget then o.on_widget(i, tappable_col) end
        table.insert(columns_row, tappable_col)

        -- The highlighted entry (today / the current month) has its label in
        -- bold as well.
        local axis_widget = TextWidget:new{
            text = o.axis_strs[i], face = font_small, fgcolor = Colors.small(),
            bold = (o.highlight and o.highlight[i]) and true or false,
        }
        table.insert(axis_labels_row, CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = axis_widget:getSize().h },
            axis_widget,
        })
    end

    local line_widget = Trend.LineChartWidget:new{
        width      = n_cols * col_width,
        height     = total_col_h,
        points     = points,
        dots       = dots,
        line_color = Colors.trendLine(),
        thickness  = 2,
        smooth     = true,
    }

    -- Columns (baseline) first, the curve and its dots over them, and the
    -- values over everything.
    local chart_area = OverlapGroup:new{
        dimen = Geom:new{ w = n_cols * col_width, h = total_col_h },
        columns_row,
        line_widget,
    }
    for _, vl in ipairs(value_labels) do
        table.insert(chart_area, vl)
    end

    return VerticalGroup:new{
        align = "center",
        chart_area,
        VerticalSpan:new{ width = Size.padding.small },
        axis_labels_row,
    }
end

-- Yearly chart as a line (the "Months chart style" setting switches back to
-- bars). Always one row of all months, since the curve needs to run
-- unbroken. Tapping a month opens its books; the current month's dot has the
-- active colour, like the current bar in the bar style.
local function buildMonthlyLineChart(popup_self, monthly_data, layout, fonts)
    local value_key = (popup_self.mode == VS.INSIGHTS_MODE_HOURS and "hours")
        or (popup_self.mode == VS.INSIGHTS_MODE_PAGES and "pages")
        or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS and "book_count")
        or "days"
    local max_value = 0
    for _, m in ipairs(monthly_data) do
        local v = monthlyPlotValue(m, value_key)
        if v > max_value then max_value = v end
    end
    if max_value <= 0 then max_value = 1 end

    VS.Opt.built_monthly = true

    local current_year  = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")

    local ratios, value_strs, axis_strs, highlight, on_tap = {}, {}, {}, {}, {}
    local current_idx
    for i, m in ipairs(monthly_data) do
        local value = tonumber(m[value_key]) or 0
        ratios[i] = monthlyPlotValue(m, value_key) / max_value
        if popup_self.mode == VS.INSIGHTS_MODE_HOURS then
            local mo_secs = tonumber(m.seconds) or math.floor((tonumber(m.hours) or 0) * 3600 + 0.5)
            value_strs[i] = Locale.formatDurationChart(mo_secs)
        elseif popup_self.mode == VS.INSIGHTS_MODE_PAGES then
            value_strs[i] = tostring(formatNumber(value))
        else
            value_strs[i] = formatNumber(value)
        end
        highlight[i] = (popup_self.selected_year == current_year) and (m.month == current_month)
        if highlight[i] then current_idx = i end

        local mn = tonumber(tostring(m.month):match("%-(%d%d)$"))
        axis_strs[i] = Locale.shortMonthName(mn) or m.label

        local month_year_label = Locale.formatMonthYear(popup_self.selected_year, mn)
        local month = m.month
        on_tap[i] = function() popup_self:showBooksForMonth(month, month_year_label) end
    end

    -- Months that haven't happened yet are cut off: the curve ends at the
    -- current month, they get no dot, value or tap (their names stay on the
    -- axis). Past years show all months.
    local visible = 0
    for i, m in ipairs(monthly_data) do
        if not isFutureMonth(popup_self, m) then visible = i end
    end
    -- Months before the first reading data are left empty as well.
    local first = 1
    while first <= visible and isBeforeFirstData(popup_self, monthly_data[first]) do
        first = first + 1
    end
    for i = visible + 1, #monthly_data do on_tap[i] = nil end
    for i = 1, first - 1 do on_tap[i] = nil end

    return buildDotLineChart{
        ratios = ratios, value_strs = value_strs, axis_strs = axis_strs,
        highlight = highlight, on_tap = on_tap,
        visible = visible, first = first,
        on_widget = function(i, w)
            if i == current_idx then popup_self._current_month_bar_widget = w end
        end,
        slots = 12,
        chart_width = layout.content_width,
        plot_height = tonumber(Screen:scaleBySize(VS.Opt.monthlyBarHeight())),
        fonts = fonts,
    }
end

local function buildMonthlyChart(popup_self, monthly_data, layout, fonts)
    if #monthly_data == 0 then return nil end

    if VS.readMonthlyStyleSetting() == VS.MONTHLY_STYLE_LINE then
        return buildMonthlyLineChart(popup_self, monthly_data, layout, fonts)
    end

    local value_key = (popup_self.mode == VS.INSIGHTS_MODE_HOURS and "hours")
        or (popup_self.mode == VS.INSIGHTS_MODE_PAGES and "pages")
        or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS and "book_count")
        or "days"
    -- Days view plots fractions of a month (0..1), so its scale starts from
    -- nothing; hours and books keep their old minimum scale of 1.
    local max_value = (value_key == "days") and 0 or 1
    for _, m in ipairs(monthly_data) do
        local v = monthlyPlotValue(m, value_key)
        if v > max_value then max_value = v end
    end
    if max_value <= 0 then max_value = 1 end

    local chart_width  = layout.content_width
    VS.Opt.built_monthly = true
    local bar_height   = tonumber(Screen:scaleBySize(VS.Opt.monthlyBarHeight()))
    -- Default (and landscape): all 12 months on one row, so the year reads
    -- as a single strip. The "Months chart layout" setting can switch
    -- portrait back to two rows of 6 months.
    local months_per_row = (isLandscapeScreen()
        or VS.readMonthlyLayoutSetting() ~= VS.MONTHLY_LAYOUT_TWO_ROWS) and 12 or 6
    -- Same fixed gap as the weekly chart (CHART_BAR_GAP); the bar width
    -- follows from it.
    local bar_width    = math.floor((chart_width - CHART_BAR_GAP() * (months_per_row - 1)) / months_per_row)
    local bar_gap      = CHART_BAR_GAP()
    -- Pixels left over after the integer bar width: split evenly on the two
    -- sides so the gap stays exactly CHART_BAR_GAP and the chart stays centred.
    local lead_pad     = math.floor((chart_width - bar_width * months_per_row
                                     - bar_gap * (months_per_row - 1)) / 2)
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
            local ratio = max_value > 0 and (monthlyPlotValue(m, value_key) / max_value) or 0
            local bar_h = math.floor(ratio * bar_height + 0.5)
            if bar_h == 0 and value > 0 then bar_h = 1 end

            local is_current = (popup_self.selected_year == current_year) and (m.month == current_month)
            local bar_color  = is_current and Colors.activeBar() or Colors.inactiveBar()

            -- A month still to come, or from before the first reading data,
            -- has no value to show: no "00:00" above it and no tap (its bar
            -- is empty and its name stays below).
            local future = isFutureMonth(popup_self, m) or isBeforeFirstData(popup_self, m)

            local bar_label_str
            if popup_self.mode == VS.INSIGHTS_MODE_HOURS then
                local mo_secs = tonumber(m.seconds) or math.floor((tonumber(m.hours) or 0) * 3600 + 0.5)
                -- The compact label (letters format: "1.9h" / "45m") is for the
                -- tight 12-in-a-row strip; with two rows of 6 months there is
                -- room for the full duration.
                bar_label_str = (months_per_row == 6)
                    and Locale.formatDuration(mo_secs, true)
                    or Locale.formatDurationChart(mo_secs)
            elseif popup_self.mode == VS.INSIGHTS_MODE_PAGES then
                bar_label_str = tostring(formatNumber(value))
            else
                bar_label_str = formatNumber(value)
            end
            local value_label   = TextWidget:new{ text = bar_label_str, face = font_small, fgcolor = Colors.small() }
            local centered_label = CenterContainer:new{
                dimen  = Geom:new{ w = bar_width, h = label_height },
                value_label,
            }

            local bar_column = VerticalGroup:new{ align = "center" }
            if not future then
                table.insert(bar_column, centered_label)
            else
                value_label:free()
            end
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
            local month_num        = tonumber(tostring(m.month):match("%-(%d%d)$"))
            -- Same heading as the calendars ("2026. január" with a year-first
            -- date format, "January 2026" otherwise).
            local month_year_label = Locale.formatMonthYear(popup_self.selected_year, month_num)
            if not future then
                tappable_bar.ges_events = {
                    Tap  = { GestureRange:new{ ges = "tap",  range = tappable_bar.dimen } },
                }
                function tappable_bar:onTap()
                    popup_self:showBooksForMonth(month_data.month, month_year_label)
                    return true
                end
            end
            if is_current then
                popup_self._current_month_bar_widget = tappable_bar
            end

            table.insert(bars_row, tappable_bar)

            local month_label_text = Locale.shortMonthName(month_num) or m.label
            local month_label_widget = TextWidget:new{ text = month_label_text, face = font_small, fgcolor = Colors.small(), bold = is_current and true or false }
            table.insert(month_labels_row, CenterContainer:new{
                dimen = Geom:new{ w = bar_width, h = month_label_widget:getSize().h },
                month_label_widget,
            })

            if i < #data_slice then
                table.insert(bars_row,         HorizontalSpan:new{ width = bar_gap })
                table.insert(month_labels_row, HorizontalSpan:new{ width = bar_gap })
            end
        end

        if lead_pad > 0 then
            table.insert(bars_row,         1, HorizontalSpan:new{ width = lead_pad })
            table.insert(month_labels_row, 1, HorizontalSpan:new{ width = lead_pad })
        end

        return VerticalGroup:new{
            align = "center",
            bars_row,
            VerticalSpan:new{ width = Size.padding.small },
            month_labels_row,
        }
    end

    local chart     = VerticalGroup:new{ align = "center" }
    local row_index = 0
    for i = 1, #monthly_data, months_per_row do
        local row_data = {}
        for j = i, math.min(i + months_per_row - 1, #monthly_data) do
            table.insert(row_data, monthly_data[j])
        end
        if #row_data > 0 then
            if row_index > 0 then
                table.insert(chart, VerticalSpan:new{ width = Size.padding.small })
            end
            table.insert(chart, createBarRow(row_data))
            row_index = row_index + 1
        end
    end

    return chart
end

-- Weekly bar chart: 7 bars, index 1 = the newest day, index 7 = the oldest.
-- Last-7-days view: index 1 = today, index 7 = 6 days ago, labels "Today",
-- "Yesterday", then weekday abbreviations. Current-week view: index 1 = the
-- week's last day, index 7 = its first, labels are weekday abbreviations
-- only, today carries is_today and the days after it (current week only)
-- carry future (drawn empty). Which end of the row the newest day is drawn
-- at follows the "Bar order" setting (rightmost by default, so time runs
-- left to right); the data index stays the same either way.
local function buildWeeklyChart(popup_self, daily_data, layout, fonts, mode)
    if not daily_data or #daily_data == 0 then return nil end
    mode = VS.normalizeWeeklyChartMode(mode)
    local show_pages = (mode == VS.WEEKLY_CHART_MODE_PAGES)
    popup_self._today_bar_widget = nil

    -- Entries without an is_today flag (the last-7-days series) have today
    -- at index 1.
    local function isTodayEntry(d, i)
        if d.is_today ~= nil then return d.is_today end
        return i == 1
    end

    -- "YYYY-MM-DD" of a day entry (the calendar-week series carries it, the
    -- last-7-days series only its local midnight), nil for padding entries.
    local function entryDate(d)
        if d.date_str then return d.date_str end
        if d.midnight_ts then return os.date("%Y-%m-%d", d.midnight_ts) end
        return nil
    end

    -- Text under a day's column: in the calendar-week view (its entries
    -- carry date_str) the date without the year, in the configured date
    -- format ("10. 20." / "10/20" ...) - the columns always run in week
    -- order, so the weekday adds little there. The last-7-days entries keep
    -- "Today" / "Yesterday" / weekday.
    local function dayAxisText(d)
        if d.date_str then return Locale.formatShortNumericDate(d.date_str) end
        return d.label or ""
    end

    -- What a tap on a day's column does: opens the list of the books read on
    -- that day (today included) - the same list the streak calendar shows
    -- for a tapped day. Days still to come do nothing.
    local function entryTapAction(d, i)
        if d.future then return nil end
        local ds = entryDate(d)
        if not ds and isTodayEntry(d, i) then ds = os.date("%Y-%m-%d") end
        if not ds then return nil end
        return function() popup_self:showBooksForDay(ds, d.midnight_ts) end
    end

    -- Pad to exactly 7 entries.
    while #daily_data < 7 do
        table.insert(daily_data, { hours = 0, seconds = 0, pages = 0, label = "" })
    end

    if VS.readWeeklyStyleSetting() == VS.WEEKLY_STYLE_LINE then
        -- Same smooth line with dots as the yearly chart. Order follows the
        -- "today on the left/right" setting; today is highlighted and, as
        -- in the bar style, opens the timeline when tapped.
        VS.Opt.built_weekly = true
        local num = 7
        local max_v = 0
        for _, d in ipairs(daily_data) do
            local v = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
            if v > max_v then max_v = v end
        end
        if max_v < 0.1 then max_v = 1 end
        local today_last_l = (VS.readWeeklyBarOrderSetting() == VS.WEEKLY_BAR_ORDER_TODAY_LAST)
        local ratios, value_strs, axis_strs, highlight, on_tap = {}, {}, {}, {}, {}
        local n_future = 0
        local today_pos
        for pos = 1, num do
            local i = today_last_l and (num + 1 - pos) or pos
            local d = daily_data[i]
            local v = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
            ratios[pos] = v / max_v
            if d.future then
                n_future = n_future + 1
                value_strs[pos] = ""
            elseif show_pages then
                value_strs[pos] = string.format("%d", math.floor((tonumber(d.pages) or 0) + 0.5))
            else
                value_strs[pos] = Locale.formatDuration(tonumber(d.seconds) or 0, true)
            end
            axis_strs[pos] = dayAxisText(d)
            highlight[pos] = (WEEKLY_CHART_HIGHLIGHT_TODAY and isTodayEntry(d, i))
            on_tap[pos] = entryTapAction(d, i)
            if isTodayEntry(d, i) and not d.future then today_pos = pos end
        end
        -- Days still to come in the current week get no dot: they sit at
        -- the end of the row (newest on the right) or at its start (newest
        -- on the left), so the visible dots are one contiguous run.
        local visible, first
        if n_future > 0 then
            if today_last_l then visible = num - n_future else first = n_future + 1 end
        end
        return buildDotLineChart{
            ratios = ratios, value_strs = value_strs, axis_strs = axis_strs,
            highlight = highlight, on_tap = on_tap,
            on_widget = function(col, w)
                if col == today_pos then popup_self._today_bar_widget = w end
            end,
            slots = num,
            visible = visible, first = first,
            chart_width = layout.content_width,
            plot_height = tonumber(Screen:scaleBySize(VS.Opt.weeklyBarHeight())),
            fonts = fonts,
        }
    end

    local chart_width  = layout.content_width

    VS.Opt.built_weekly = true
    local bar_height   = tonumber(Screen:scaleBySize(VS.Opt.weeklyBarHeight()))
    local num_bars     = 7
    -- Same fixed gap as the monthly chart (CHART_BAR_GAP); the bar width
    -- follows from it.
    local bar_width    = math.floor((chart_width - CHART_BAR_GAP() * (num_bars - 1)) / num_bars)
    local bar_gap      = CHART_BAR_GAP()
    -- Leftover pixels split on both sides (see the monthly chart).
    local lead_pad     = math.floor((chart_width - bar_width * num_bars
                                     - bar_gap * (num_bars - 1)) / 2)
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

    -- pos = where the bar is drawn (1 = leftmost), i = which day it holds
    -- (1 = today). They are the same unless today is drawn on the right.
    local today_last = (VS.readWeeklyBarOrderSetting() == VS.WEEKLY_BAR_ORDER_TODAY_LAST)

    for pos = 1, num_bars do
        local i = today_last and (num_bars + 1 - pos) or pos
        local d = daily_data[i]
        local value = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
        local ratio = value / max_value
        local bar_h = math.floor(ratio * bar_height + 0.5)
        if bar_h == 0 and value > 0 then bar_h = 1 end

        local is_today_bar = isTodayEntry(d, i)
        local bar_color = (WEEKLY_CHART_HIGHLIGHT_TODAY and is_today_bar) and Colors.activeBar() or Colors.inactiveBar()

        local val_str
        if d.future then
            val_str = ""
        elseif show_pages then
            local pages = math.floor((tonumber(d.pages) or 0) + 0.5)
            val_str = string.format("%d", pages)
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

        local tap_action = entryTapAction(d, i)
        if tap_action then
            local tappable_bar = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = bar_width, h = total_bar_height },
                bar_container,
            }
            tappable_bar.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = tappable_bar.dimen } },
            }
            function tappable_bar:onTap()
                tap_action()
                return true
            end
            -- Long press on today's column is dispatched by the popup's
            -- onHold by position (a Hold handler on the widget itself would
            -- also fire for holds elsewhere on the page).
            if isTodayEntry(d, i) and not d.future then
                popup_self._today_bar_widget = tappable_bar
            end
            table.insert(bars_row, tappable_bar)
        else
            table.insert(bars_row, bar_container)
        end

        local day_label_widget = TextWidget:new{
            text = dayAxisText(d), face = font_small, fgcolor = Colors.small(),
            bold = (WEEKLY_CHART_HIGHLIGHT_TODAY and is_today_bar) and true or false,
        }
        table.insert(day_labels_row, CenterContainer:new{
            dimen = Geom:new{ w = bar_width, h = day_label_widget:getSize().h },
            day_label_widget,
        })

        if pos < num_bars then
            table.insert(bars_row,       HorizontalSpan:new{ width = bar_gap })
            table.insert(day_labels_row, HorizontalSpan:new{ width = bar_gap })
        end
    end

    if lead_pad > 0 then
        table.insert(bars_row,       1, HorizontalSpan:new{ width = lead_pad })
        table.insert(day_labels_row, 1, HorizontalSpan:new{ width = lead_pad })
    end

    return VerticalGroup:new{
        align = "center",
        bars_row,
        VerticalSpan:new{ width = Size.padding.small },
        day_labels_row,
    }
end

return {
    buildMonthlyChart = buildMonthlyChart,
    buildWeeklyChart  = buildWeeklyChart,
}
