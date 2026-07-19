--[[
Reading Insights - the 8-week trend popup.

The line chart behind the "Last week" section: eight weeks of reading time
or pages, with the current week highlighted, opened by tapping one of the
last-week values in the insights popup.

Split out of insights_view.lua, which was carrying three self-contained
popups (this one, the heatmap and the book lists) inside its own 5000-line
file. Nothing here is used by the rest of the view except the popup class
itself, which the view opens and hands a week series to.

Also home to LineChartWidget, the small line/point/axis renderer this is the
only user of.

  Trend.Popup:new{ weeks = ..., metric = "time" | "pages", ... }
  Trend.buildLine8WeekChart(weeks, metric, width, fonts)
                                the chart on its own, for the insights page
  Trend.trendTitle(metric) / Trend.totalForMetric(metric, weeks)
                                its heading and summary value
]]--

local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local GestureRange = require("ui/gesturerange")
local Screen = Device.screen

-- Shared modules, passed in as one table by main.lua (see the deps table
-- there): Colors and Locale for appearance and text, VS for the reader's
-- "8-week chart order" setting.
local deps = ...
local Colors, Locale, VS = deps.Colors, deps.Locale, deps.VS
local _            = Locale._
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount
local getLangBase  = Locale.getLangBase

-- Same short month names the insights view uses for its own axis labels.
local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}

local M = {}

-- Minimal line-chart widget: draws straight segments between `points`
-- ({x, y} pixel pairs, relative to the widget's own top-left corner)
-- using only bb:paintRect, so it doesn't depend on any diagonal-line
-- drawing primitive that may or may not exist in a given KOReader build.
local LineChartWidget = Widget:extend{
    width      = nil,
    height     = nil,
    points     = nil,
    line_color = nil,
}

-- Same rounding rule used for the "avg/day" pages cell in the main popup:
-- integer above 10, 1 decimal place below.
local function roundAvgPages(value)
    if value >= 10 then
        return math.floor(value + 0.5)
    else
        return math.floor(value * 10 + 0.5) / 10
    end
end

-- Format a single week's bucket value for the given metric.
-- Returns (display_string, raw_numeric_value).
local function formatWeekValue(metric, week_entry)
    if metric == "time_total" or metric == "time_avg" then
        local secs = week_entry.seconds or 0
        if metric == "time_avg" then secs = secs / 7 end
        return Locale.formatDuration(secs, true), secs
    else
        local pages = week_entry.pages or 0
        if metric == "pages_avg" then
            pages = roundAvgPages(pages / 7)
            return formatNumber(pages, pages ~= math.floor(pages) and 1 or 0), pages
        end
        return formatCount(pages), pages
    end
end

local TREND_TITLE_KEYS = {
    time_total  = "Reading time over the last 8 weeks",
    pages_total = "Pages read over the last 8 weeks",
    time_avg    = "Average daily reading time, last 8 weeks",
    pages_avg   = "Average daily pages, last 8 weeks",
}

function M.trendTitle(metric)
    local key = TREND_TITLE_KEYS[metric]
    return key and _(key) or ""
end

function M.totalForMetric(metric, weeks)
    local total_secs, total_pages = 0, 0
    for _, w in ipairs(weeks) do
        total_secs  = total_secs  + (w.seconds or 0)
        total_pages = total_pages + (w.pages or 0)
    end
    if metric == "time_total" then
        return Locale.formatDuration(total_secs, true)
    elseif metric == "time_avg" then
        local avg_secs = total_secs / (7 * #weeks)
        return Locale.formatDuration(avg_secs, true)
    elseif metric == "pages_total" then
        return formatCount(total_pages)
    else -- pages_avg
        local avg = roundAvgPages(total_pages / (7 * #weeks))
        return formatNumber(avg, avg ~= math.floor(avg) and 1 or 0)
    end
end

-- Builds the chart: one dot per week, connected by straight segments,
-- with the per-week value printed above each dot and a baseline below.
-- "Máj 6" / "May 6" style label using the same month names as the monthly chart.
local function formatShortDate(date_str)
    local y, m, d = date_str:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return date_str end
    local month_name = MONTH_NAMES_SHORT[tonumber(m)] or m
    if getLangBase() == "hu" then
        return month_name .. " " .. tostring(tonumber(d)) .. "."
    else
        return month_name .. " " .. tostring(tonumber(d))
    end
end

function M.buildLine8WeekChart(weeks, metric, chart_width, fonts)
    if not weeks or #weeks == 0 then return nil end

    local bar_height  = tonumber(Screen:scaleBySize(120))
    local num_points  = #weeks
    local col_width   = math.floor(chart_width / num_points)
    local font_small  = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local values = {}
    local max_value = 0
    for i, w in ipairs(weeks) do
        local _unused, raw = formatWeekValue(metric, w)
        values[i] = raw
        if raw > max_value then max_value = raw end
    end
    if max_value <= 0 then max_value = 1 end

    local dot_size    = tonumber(Screen:scaleBySize(6))
    local baseline_h  = Size.line.medium
    local total_col_h = bar_height + label_height

    -- Ascending = weeks[1] (oldest) leftmost; descending = weeks[num_points] (newest) leftmost.
    local ascending = VS.readAscendingSetting()

    local bars_row = HorizontalGroup:new{ align = "bottom" }
    local points   = {}

    for col = 1, num_points do
        local i = ascending and col or (num_points - col + 1)
        local ratio = values[i] / max_value
        local dot_y_from_bottom = math.floor(ratio * (bar_height - dot_size))
        local val_str = formatWeekValue(metric, weeks[i])

        local value_label    = TextWidget:new{ text = val_str, face = font_small, fgcolor = Colors.small() }
        local centered_label = CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = label_height },
            value_label,
        }

        local col_group = VerticalGroup:new{ align = "center" }
        table.insert(col_group, centered_label)
        local space_above = bar_height - dot_size - dot_y_from_bottom
        if space_above > 0 then
            table.insert(col_group, VerticalSpan:new{ height = space_above })
        end
        table.insert(col_group, CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = dot_size },
            Colors.newBar(dot_size, dot_size, Colors.activeBar()),
        })
        if dot_y_from_bottom > 0 then
            table.insert(col_group, VerticalSpan:new{ height = dot_y_from_bottom })
        end
        table.insert(col_group, Colors.newBar(col_width, baseline_h, Colors.inactiveBar()))

        table.insert(bars_row, BottomContainer:new{
            dimen = Geom:new{ w = col_width, h = total_col_h },
            col_group,
        })

        points[col] = {
            x = (col - 1) * col_width + math.floor(col_width / 2),
            y = label_height + space_above + math.floor(dot_size / 2),
        }
    end

    local line_widget = LineChartWidget:new{
        width      = num_points * col_width,
        height     = total_col_h,
        points     = points,
        line_color = Colors.trendLine(),
    }

    local chart_area = OverlapGroup:new{
        dimen = Geom:new{ w = num_points * col_width, h = total_col_h },
        bars_row,
        line_widget,
    }

    -- Per-week start/end date, same font size as the value labels above the dots.
    -- Order follows the same ascending/descending setting as the columns above.
    local date_labels_row = HorizontalGroup:new{ align = "top" }
    for col = 1, num_points do
        local i = ascending and col or (num_points - col + 1)
        local start_lbl = TextWidget:new{ text = formatShortDate(weeks[i].start_date), face = font_small, fgcolor = Colors.small() }
        local col_dates  = CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = start_lbl:getSize().h },
            start_lbl,
        }
        table.insert(date_labels_row, col_dates)
    end

    return VerticalGroup:new{
        align = "center",
        chart_area,
        VerticalSpan:new{ height = Size.padding.small },
        date_labels_row,
    }
end

-- Full-screen tap-anywhere-to-close popup that hosts the trend chart.
M.Popup = InputContainer:extend{
    modal       = true,
    box_content = nil,
}

function M.Popup:init()
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

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.box_content,
    }
end

function LineChartWidget:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function LineChartWidget:paintTo(bb, x, y)
    if not self.points or #self.points == 0 then return end
    local color = self.line_color or Colors.trendLine()
    -- See colors.lua's LineWidget patch: bb:paintRect only renders native
    -- 8bit grayscale colors correctly; arbitrary hex colors need
    -- bb:paintRectRGB32 or they silently misrender (usually as black).
    local paint = Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32

    if #self.points > 1 then
        for i = 1, #self.points - 1 do
            local p1, p2 = self.points[i], self.points[i + 1]
            local dx, dy = p2.x - p1.x, p2.y - p1.y
            local steps  = math.max(math.abs(dx), math.abs(dy), 1)
            for s = 0, steps do
                local t  = s / steps
                local px = math.floor(p1.x + dx * t + 0.5)
                local py = math.floor(p1.y + dy * t + 0.5)
                paint(bb, x + px, y + py, 2, 2, color)
            end
        end
    end
end

return M
