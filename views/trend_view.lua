--[[
Reading Insights - the 8-week trend popup.

The chart behind the "Last 7 days" section, opened by tapping one of the
last-week values in the insights popup: eight weeks of reading time (when a
time value was tapped) or of pages (when a pages value was tapped). Each chart
draws one line of the weekly totals, with the daily average printed under each dot.

Split out of insights_view.lua, which was carrying three self-contained
popups (this one, the heatmap and the book lists) inside its own 5000-line
file. Nothing here is used by the rest of the view except the popup class
itself, which the view opens and hands a week series to.

Also home to LineChartWidget, the small line/point/axis renderer this is the
only user of.

  Trend.Popup:new{ weeks = ..., metric = "time" | "pages", ... }
  Trend.buildContent(weeks, metric, width, fonts)
                                title, line, total | daily avg row and chart
  Trend.buildTrendChart(weeks, "time" | "pages", width, fonts)
                                the chart on its own
]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
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
local UIManager = require("ui/uimanager")

-- Shared modules, passed in as one table by main.lua (see the deps table
-- there): Colors and Locale for appearance and text, VS for the reader's
-- "8-week chart order" setting.
local deps = ...
local Colors, Locale, VS = deps.Colors, deps.Locale, deps.VS
local _            = Locale._
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase

-- Same short month names the insights view uses for its own axis labels.
local MONTH_NAMES_SHORT = Locale.shortMonthNames

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

-- Same rounding rule used for the "daily avg pages" cell in the main popup:
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
        if metric == "time_avg" then secs = secs / (week_entry.days or 7) end
        return Locale.formatDuration(secs, true), secs
    else
        local pages = week_entry.pages or 0
        if metric == "pages_avg" then
            pages = roundAvgPages(pages / (week_entry.days or 7))
            return formatNumber(pages, pages ~= math.floor(pages) and 1 or 0), pages
        end
        return formatCount(pages), pages
    end
end

-- The popup shows one chart for time and one for pages. Whichever of the four
-- old metric names the insights page hands over ("time_total", "time_avg",
-- "pages_total", "pages_avg") opens the chart of its own kind, so a time cell
-- opens the time chart and a pages cell the pages chart.
function M.kindOf(metric)
    if type(metric) == "string" and metric:sub(1, 5) == "pages" then
        return "pages"
    end
    return "time"
end

function M.trendTitle(_metric)
    return _("8-week reading trend")
end

-- Week start date without the year, in the configured date format (the
-- plugin's "Date format" setting): 09.30. | 30/09 | 9/30 (and 09-30 for the
-- ISO style).
local function formatShortDate(date_str)
    local y, m, d = date_str:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return date_str end
    m, d = tonumber(m), tonumber(d)
    local fmt = Locale.readDateFormatSetting and Locale.readDateFormatSetting()
    if fmt == "ymd_dot" then
        return string.format("%02d.%02d.", m, d)
    elseif fmt == "ymd_dash" then
        return string.format("%02d-%02d", m, d)
    elseif fmt == "mdy_slash" then
        return string.format("%d/%d", m, d)
    end
    return string.format("%02d/%02d", d, m)
end

-- Bold value + plain unit, like the value/label cells of the insights page.
-- With "long durations as days" on, a trailing day word is merged into the
-- plain unit instead of staying glued to the bold number.
local function splitDurationValueUnit(seconds, base_label)
    local parts = Locale.formatDurationParts(seconds, true)
    local unit = base_label or ""
    if parts.unit ~= "" then
        unit = (unit ~= "" and (parts.unit .. " " .. unit)) or parts.unit
    end
    return parts.value, unit
end

local function buildValueLine(fonts, col_width, value, unit)
    local value_widget = TextWidget:new{ text = value, face = fonts.value, fgcolor = Colors.value() }
    local text_w = col_width - value_widget:getSize().w - Size.padding.large
    return HorizontalGroup:new{
        align = "center",
        value_widget,
        HorizontalSpan:new{ width = Size.padding.large },
        TextBoxWidget:new{
            text      = unit,
            face      = fonts.label,
            fgcolor   = Colors.label(),
            width     = text_w,
            alignment = "left",
        },
    }
end

-- The row under the title: total of the 8 weeks on the left, daily average
-- over the same 8 weeks on the right ("07:00 reading time | 01:00 daily avg
-- time" or the pages equivalent).
function M.buildSummaryRow(weeks, kind, width, fonts)
    local total_secs, total_pages = 0, 0
    for _i, w in ipairs(weeks) do
        total_secs  = total_secs  + (w.seconds or 0)
        total_pages = total_pages + (w.pages or 0)
    end
    local days = 0
    for _i, w in ipairs(weeks) do days = days + (w.days or 7) end
    if days <= 0 then days = 1 end

    local left_val, left_unit, right_val, right_unit
    if kind == "pages" then
        left_val  = formatCount(total_pages)
        left_unit = N_("page read", "pages read", total_pages)
        local avg = roundAvgPages(total_pages / days)
        right_val  = formatNumber(avg, avg ~= math.floor(avg) and 1 or 0)
        right_unit = N_("daily avg page", "daily avg pages", avg)
    else
        left_val,  left_unit  = splitDurationValueUnit(total_secs, _("reading time"))
        right_val, right_unit = splitDurationValueUnit(total_secs / days, _("daily avg time"))
    end

    local gap     = Size.padding.large * 2
    local col_w   = math.floor((width - gap - Size.line.thin) / 2)
    local left    = buildValueLine(fonts, col_w, left_val,  left_unit)
    local right   = buildValueLine(fonts, col_w, right_val, right_unit)
    local row_h   = math.max(left:getSize().h, right:getSize().h)

    local function cell(widget)
        return LeftContainer:new{ dimen = Geom:new{ w = col_w, h = row_h }, widget }
    end
    return HorizontalGroup:new{
        align = "center",
        cell(left),
        HorizontalSpan:new{ width = math.floor(gap / 2) },
        Colors.newBar(Size.line.thin, row_h, Colors.separator()),
        HorizontalSpan:new{ width = gap - math.floor(gap / 2) },
        cell(right),
    }
end

-- Whether the chart shows the daily averages instead of the weekly totals
-- above its dots. The last choice is remembered (shared by the time and the
-- pages chart) in KOReader's global settings.
local SHOW_AVG_KEY = "reading_insights_trend_show_avg"

local function readShowAvg()
    if G_reader_settings and G_reader_settings.isTrue then
        return G_reader_settings:isTrue(SHOW_AVG_KEY)
    end
    return false
end

local function saveShowAvg(value)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(SHOW_AVG_KEY, value and true or false)
    end
end

-- The chart: one line through the weekly totals. The daily average of a week
-- is always 1/7 of its total, so it follows the very same curve - it gets no
-- line of its own, only its value. Above every dot stands one value: the
-- week's total, or - after a tap on the chart - its daily average ("Ø 1:12");
-- the choice is saved. The dots are painted by the line widget itself, from
-- the same coordinates as the line, so they sit exactly on it. The weeks'
-- start dates are under the baseline.
function M.buildTrendChart(weeks, kind, chart_width, fonts)
    if not weeks or #weeks == 0 then return nil end

    local total_metric = kind .. "_total"
    local avg_metric   = kind .. "_avg"

    local num_points  = #weeks
    local col_width   = math.floor(chart_width / num_points)
    local plot_height = tonumber(Screen:scaleBySize(150))
    local dot_size    = tonumber(Screen:scaleBySize(8))
    local baseline_h  = Size.line.medium
    local font_small  = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local total_vals, total_strs, avg_strs = {}, {}, {}
    local max_value = 0
    for i, w in ipairs(weeks) do
        local s1, v1 = formatWeekValue(total_metric, w)
        local s2 = formatWeekValue(avg_metric, w)
        total_strs[i], total_vals[i], avg_strs[i] = s1, v1, s2
        if v1 > max_value then max_value = v1 end
    end
    if max_value <= 0 then max_value = 1 end

    local half    = math.floor(dot_size / 2)
    -- Room above the highest dot for its value.
    local top_pad = label_height
    local total_h = top_pad + plot_height + baseline_h
    local usable  = plot_height - dot_size
    local area_w  = num_points * col_width

    -- Ascending = oldest week leftmost; descending = newest leftmost.
    local ascending = VS.readAscendingSetting()

    local points, dots = {}, {}
    local total_layer = OverlapGroup:new{ dimen = Geom:new{ w = area_w, h = total_h } }
    local avg_layer   = OverlapGroup:new{ dimen = Geom:new{ w = area_w, h = total_h } }

    local function addLabel(layer, text, cx, top_y)
        local tw = TextWidget:new{ text = text, face = font_small, fgcolor = Colors.small() }
        local w  = tw:getSize().w
        tw.overlap_offset = {
            math.max(0, math.min(area_w - w, cx - math.floor(w / 2))),
            math.max(0, top_y),
        }
        table.insert(layer, tw)
    end

    local date_labels_row = HorizontalGroup:new{ align = "top" }
    for col = 1, num_points do
        local i  = ascending and col or (num_points - col + 1)
        local cx = (col - 1) * col_width + math.floor(col_width / 2)
        local dy = math.floor((total_vals[i] / max_value) * usable)
        local cy = top_pad + (plot_height - dot_size - dy) + half  -- dot centre

        points[col] = { x = cx, y = cy }
        -- The current week (the last one in time) has the active colour, the
        -- earlier weeks the inactive one.
        dots[col]   = { x = cx, y = cy, size = dot_size,
                        color = (i == num_points) and Colors.activeBar() or Colors.inactiveBar() }

        local top_y = cy - half - label_height
        addLabel(total_layer, total_strs[i], cx, top_y)

        -- Daily average with a "Ø" prefix, dropped when the column is too
        -- narrow for it.
        local avg_text = "Ø " .. avg_strs[i]
        local probe = TextWidget:new{ text = avg_text, face = font_small }
        if probe:getSize().w > col_width then avg_text = avg_strs[i] end
        probe:free()
        addLabel(avg_layer, avg_text, cx, top_y)

        local date_lbl = TextWidget:new{ text = formatShortDate(weeks[i].start_date), face = font_small, fgcolor = Colors.small() }
        table.insert(date_labels_row, CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = date_lbl:getSize().h },
            date_lbl,
        })
    end

    local baseline = Colors.newBar(area_w, baseline_h, Colors.inactiveBar())
    baseline.overlap_offset = { 0, total_h - baseline_h }

    local showing_avg = readShowAvg()
    local chart_area = OverlapGroup:new{
        dimen = Geom:new{ w = area_w, h = total_h },
        baseline,
        LineChartWidget:new{
            width = area_w, height = total_h,
            points = points, dots = dots,
            line_color = Colors.activeBar(), thickness = 2,
        },
        showing_avg and avg_layer or total_layer,
    }

    -- The popup (see M.popupOnTap) calls toggle() for a tap on the chart
    -- itself; a tap anywhere else closes the popup.
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = area_w, h = total_h },
        chart_area,
    }
    local handle = { widget = tappable }
    function handle.toggle()
        showing_avg = not showing_avg
        saveShowAvg(showing_avg)
        chart_area[3] = showing_avg and avg_layer or total_layer
        UIManager:setDirty("all", function() return "ui", tappable.dimen end)
    end

    return VerticalGroup:new{
        align = "center",
        tappable,
        VerticalSpan:new{ width = Size.padding.small },
        date_labels_row,
    }, handle
end

-- Kept for callers that still hand over one of the four metric names.
function M.buildLine8WeekChart(weeks, metric, chart_width, fonts)
    return M.buildTrendChart(weeks, M.kindOf(metric), chart_width, fonts)
end

-- Everything inside the popup box: title, thin line, the total / daily
-- average row, then the chart with the week dates at its bottom.
function M.buildContent(weeks, metric, width, fonts)
    local kind = M.kindOf(metric)

    local title_w = TextWidget:new{ text = M.trendTitle(kind), face = fonts.section, fgcolor = Colors.section() }
    local title = LeftContainer:new{
        dimen = Geom:new{ w = width, h = title_w:getSize().h },
        title_w,
    }

    -- Same small gaps as the "Last 7 days" section of the insights page:
    -- header, thin line, row, thin line, chart.
    local gap = Size.padding.small
    local chart, handle = M.buildTrendChart(weeks, kind, width, fonts)
    return VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{ width = gap },
        Colors.newBar(width, Size.line.thin, Colors.separator()),
        VerticalSpan:new{ width = gap },
        M.buildSummaryRow(weeks, kind, width, fonts),
        VerticalSpan:new{ width = gap },
        Colors.newBar(width, Size.line.thin, Colors.separator()),
        VerticalSpan:new{ width = gap },
        chart,
    }, handle
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

-- Tap handling of the popup: a tap on the chart switches the values above its
-- dots (totals / daily averages); a tap anywhere else closes the popup.
-- Installed over the generic "any tap closes" handler by the insights view.
function M.popupOnTap(self, _arg, ges)
    local h = self.chart_handle
    local d = h and h.widget and h.widget.dimen
    local pos = ges and ges.pos
    if d and pos and pos.x >= d.x and pos.x < d.x + d.w
       and pos.y >= d.y and pos.y < d.y + d.h then
        h.toggle()
        return true
    end
    UIManager:close(self)
    return true
end

-- Smooth curve through `pts` ({x, y}, x strictly increasing): monotone cubic
-- (Fritsch-Carlson) interpolation, so the curve passes exactly through every
-- point and never overshoots between them (no dips below the baseline or
-- above the highest value). Returns a denser point list, a sample every
-- couple of pixels, that the widget joins with short straight segments.
function M.smoothCurve(pts)
    local n = #pts
    local h, d, m = {}, {}, {}
    for k = 1, n - 1 do
        h[k] = pts[k + 1].x - pts[k].x
        d[k] = (pts[k + 1].y - pts[k].y) / h[k]
    end
    m[1] = d[1]
    m[n] = d[n - 1]
    for k = 2, n - 1 do
        if d[k - 1] * d[k] <= 0 then
            m[k] = 0
        else
            m[k] = (d[k - 1] + d[k]) / 2
        end
    end
    for k = 1, n - 1 do
        if d[k] == 0 then
            m[k], m[k + 1] = 0, 0
        else
            local a, b = m[k] / d[k], m[k + 1] / d[k]
            local r = a * a + b * b
            if r > 9 then
                local tau = 3 / math.sqrt(r)
                m[k], m[k + 1] = tau * a * d[k], tau * b * d[k]
            end
        end
    end
    local out = {}
    for k = 1, n - 1 do
        local x0, y0, y1 = pts[k].x, pts[k].y, pts[k + 1].y
        local samples = math.max(2, math.ceil(h[k] / 2))
        for s = 0, samples - 1 do
            local t   = s / samples
            local t2, t3 = t * t, t * t * t
            local yv = (2 * t3 - 3 * t2 + 1) * y0
                     + (t3 - 2 * t2 + t) * h[k] * m[k]
                     + (-2 * t3 + 3 * t2) * y1
                     + (t3 - t2) * h[k] * m[k + 1]
            out[#out + 1] = { x = x0 + t * h[k], y = yv }
        end
    end
    out[#out + 1] = { x = pts[n].x, y = pts[n].y }
    return out
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

    local pts = self.points
    if self.smooth and #pts > 2 then
        pts = M.smoothCurve(pts)
    end

    if #pts > 1 then
        for i = 1, #pts - 1 do
            local p1, p2 = pts[i], pts[i + 1]
            local dx, dy = p2.x - p1.x, p2.y - p1.y
            local steps  = math.max(math.abs(dx), math.abs(dy), 1)
            for s = 0, steps do
                local t  = s / steps
                local px = math.floor(p1.x + dx * t + 0.5)
                local py = math.floor(p1.y + dy * t + 0.5)
                local th = self.thickness or 2
                paint(bb, x + px - math.floor(th / 2), y + py - math.floor(th / 2), th, th, color)
            end
        end
    end

    -- Optional dots ({x, y, size, color}), painted by this same widget with
    -- the same coordinates as the curve so they sit exactly on it. Corners
    -- are cut a little so they read as round rather than square.
    if self.dots then
        for _, dt in ipairs(self.dots) do
            local sz  = dt.size
            local half = math.floor(sz / 2)
            local c   = dt.color
            local pnt = Blitbuffer.isColor8(c) and bb.paintRect or bb.paintRectRGB32
            local cut = math.max(1, math.floor(sz / 4))
            local left, top = x + dt.x - half, y + dt.y - half
            pnt(bb, left + cut, top, sz - 2 * cut, sz, c)
            pnt(bb, left, top + cut, sz, sz - 2 * cut, c)
        end
    end
end

-- Exported so the insights view can draw the yearly line chart with it too.
M.LineChartWidget = LineChartWidget

return M
