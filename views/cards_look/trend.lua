--[[
Reading Insights - the "Cards" look of the 8-week trend popup
(Settings > Appearance > Look).

The popup (views/trend_view.lua, its window built in views/insights_view.lua)
keeps its centred window and taps; in the Cards look its content is two
cards: "8-week reading trend" with the total | daily average of the 8 weeks,
and the chart under a header with the view's name and "▾" (tap = the list
of the four views).

Loaded once by main.lua and handed to the trend view as `deps.Cards`.
]]--

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors, UI = deps.Colors, deps.UI

local M = {}

-- Same return values as Trend.buildContent: the content, `width` wide, and
-- the chart handle (its `caption` is the chart card's header).
function M.buildContent(Trend, weeks, mode, width, fonts)
    local kind = Trend.kindOf(mode)
    local inner_w = UI.cardInnerWidth(width)
    local gap = Size.padding.default

    local left_val, left_unit, right_val, right_unit = Trend.summaryValues(weeks, kind)
    local col_gap = Size.padding.large * 2
    local col_w = math.floor((inner_w - col_gap - Size.line.thin) / 2)
    local left  = UI.buildStatCell(fonts, col_w, left_val, left_unit)
    local right = UI.buildStatCell(fonts, col_w, right_val, right_unit)
    local row_h = math.max(left:getSize().h, right:getSize().h)
    local totals = UI.buildCard(VerticalGroup:new{
        align = "left",
        UI.cardHeader("clock", Trend.trendTitle(kind), fonts.section, inner_w),
        VerticalSpan:new{ width = gap },
        HorizontalGroup:new{
            align = "center",
            UI.fixedCol(left, col_w, row_h),
            HorizontalSpan:new{ width = math.floor(col_gap / 2) },
            Colors.vLine(Size.line.thin, row_h, Colors.cardsColor("divider")),
            HorizontalSpan:new{ width = col_gap - math.floor(col_gap / 2) },
            UI.fixedCol(right, col_w, row_h),
        },
        VerticalSpan:new{ width = Size.padding.small },
    }, width)

    local chart, handle = Trend.buildTrendChart(weeks, kind, inner_w, fonts, mode:sub(-4) == "_avg", true)
    local header = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        UI.cardHeader("chart", Trend.captionText(mode), fonts.section, inner_w, "menu"),
    }
    local chart_body = VerticalGroup:new{ align = "left", header, VerticalSpan:new{ width = gap } }
    if chart then table.insert(chart_body, chart) end
    table.insert(chart_body, VerticalSpan:new{ width = Size.padding.small })

    handle = handle or {}
    handle.caption = header

    return VerticalGroup:new{
        align = "left",
        totals,
        VerticalSpan:new{ width = gap },
        UI.buildCard(chart_body, width),
    }, handle
end

return M
