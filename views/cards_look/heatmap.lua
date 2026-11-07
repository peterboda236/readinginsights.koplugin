--[[
Reading Insights - the "Cards" look of the Reading habits (heatmap) popup
(Settings > Appearance > Look).

Builds the same box as heatmap_view.lua's buildBox (the Classic look): the
period header with its ‹ / › arrows, then one card each for the day heatmap,
the weekday chart and the time-of-day chart. It returns the same values as
buildBox, so the popup's fit loop, tap zones and paging serve both looks.

Loaded once by main.lua and handed to the heatmap view as `deps.HeatmapCards`. The
view passes its own helpers (`H`) on each build.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local T = require("ffi/util").template

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, VS, UI, Data = deps.Locale, deps.VS, deps.UI, deps.Data

local _ = Locale._

local M = {}

local function rightAlign(widget, width)
    return RightContainer:new{ dimen = Geom:new{ w = width, h = widget:getSize().h }, widget }
end

local function leftAlign(widget, width)
    return LeftContainer:new{ dimen = Geom:new{ w = width, h = widget:getSize().h }, widget }
end

-- H: helpers from heatmap_view.lua (Heatmap = its module, getHeatmapData,
-- getCachedFonts, barCaption, peakHourText, periodTitle). The other
-- arguments and the return values are buildBox's.
function M.buildBox(H, popup_self, periods_back, force_fresh, width_override, data)
    local Heatmap = H.Heatmap
    Heatmap._bars_built = 0
    local start_t, end_t, daily_map, weekday_hour_map
    if data then
        start_t, end_t, daily_map, weekday_hour_map = data[1], data[2], data[3], data[4]
    else
        start_t, end_t = Heatmap.getHeatmapPeriodRange(periods_back)
        daily_map, weekday_hour_map = H.getHeatmapData(popup_self, start_t, end_t, force_fresh)
    end

    local fonts = H.getCachedFonts()
    local inner_padding = Size.padding.large
    local box_width     = width_override or math.floor(Screen:getWidth() * 0.94)
    local content_width = box_width - 2 * inner_padding
    local card_w        = UI.cardInnerWidth(content_width)

    local year_range      = Data.getYearRange()
    local older_available = periods_back < Heatmap.heatmapMaxPeriodsBack(year_range.min_year, year_range.min_month)
    local newer_available = periods_back > 0

    local header, left_frame, right_frame, left_w, right_w, header_h = UI.buildNavHeader(
        H.periodTitle(start_t, end_t), content_width, fonts.section, older_available, newer_available)

    local function card(card_header, rows)
        local body = VerticalGroup:new{
            align = "left",
            card_header,
            VerticalSpan:new{ width = Size.padding.small },
        }
        for _idx, w in ipairs(rows) do table.insert(body, w) end
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        return UI.buildCard(body, content_width)
    end
    local function legend()
        return rightAlign(Heatmap.buildHeatmapLegendWidget(fonts, 0), card_w)
    end

    -- Reading by day
    local calendar_widget, calendar_cell =
        Heatmap.buildRangeHeatmapWidget(daily_map, start_t, end_t, fonts, card_w)
    local day_card = card(UI.cardHeader("calendar", _("Reading by day"), fonts.section, card_w, false), {
        leftAlign(calendar_widget, card_w),
        VerticalSpan:new{ width = Size.padding.small },
        legend(),
    })

    -- Reading time by weekday (title tap: the view picker)
    local week_mode = Heatmap._week_mode or "time"
    local week_header = UI.cardHeader("chart", H.barCaption("week", week_mode), fonts.section, card_w, "menu")
    local week_card = card(week_header, {
        leftAlign(Heatmap.buildWeekdayChartWidget(weekday_hour_map, fonts, card_w, week_mode, true), card_w),
    })

    -- Reading time by time of day: four day-part bars, twelve two-hour bars
    -- or the weekday x hour grid (Settings > Reading habits > Time of day).
    local timeofday_view = VS.readTimeOfDayViewSetting()
    local is_chart = timeofday_view ~= "heatmap"
    local when_mode = Heatmap._when_mode or "time"
    local when_widget
    if timeofday_view == "hourly" then
        when_widget = Heatmap.buildHourlyChartWidget(weekday_hour_map, fonts, card_w, when_mode, true)
    elseif is_chart then
        when_widget = Heatmap.buildDayPartChartWidget(weekday_hour_map, fonts, card_w, when_mode, true)
    else
        when_widget = Heatmap.buildDayPartHeatmapWidget(weekday_hour_map, fonts, card_w)
    end
    local when_rows = { leftAlign(when_widget, card_w) }
    local peak_text = timeofday_view ~= "hourly" and H.peakHourText(weekday_hour_map) or nil
    if peak_text then
        table.insert(when_rows, VerticalSpan:new{ width = Size.padding.default })
        table.insert(when_rows, UI.buildPill(T(_("You read most around %1"), peak_text), fonts.small, false, card_w))
    end
    if not is_chart then
        table.insert(when_rows, VerticalSpan:new{ width = Size.padding.small })
        table.insert(when_rows, legend())
    end
    local when_header = UI.cardHeader("clock", H.barCaption("when", is_chart and when_mode or "time"),
        fonts.section, card_w, is_chart and "menu" or false)
    local when_card = card(when_header, when_rows)

    local gap = Size.padding.default
    local content = VerticalGroup:new{
        align = "left",
        header,
        VerticalSpan:new{ width = Size.padding.small },
        day_card,
        VerticalSpan:new{ width = gap },
        week_card,
        VerticalSpan:new{ width = gap },
        when_card,
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

    -- Tap zones of the two chart titles, relative to the top of `content`.
    local function titleZone(target_card, title)
        local y = 0
        for _i, child in ipairs(content) do
            if child == target_card then break end
            y = y + child:getSize().h
        end
        return { y = y + UI.cardBorder() + Size.padding.small, h = title:getSize().h }
    end
    local week_zone = titleZone(week_card, week_header)
    local when_zone = is_chart and titleZone(when_card, when_header) or nil

    local rows_per_px = 7 / Heatmap.heatmapFixedNumCols()
    if not is_chart then rows_per_px = rows_per_px + 7 / 24 end
    return box, older_available, newer_available,
        left_frame, right_frame, left_w, right_w, header_h, when_zone, week_zone,
        calendar_cell, rows_per_px, box_width, { start_t, end_t, daily_map, weekday_hour_map }
end

return M
