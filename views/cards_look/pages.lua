--[[
Reading Insights - pages for the "Cards" look of the insights popup.

When the sections don't fit one screen, the Cards look shows them on pages
instead of scrolling: swipe up / down or the arrows of the "‹ 1 / 2 ›"
footer turn the page (see insights_view.lua's onSwipe and _goToPage). A
page break only falls where a section starts (sections._breaks, recorded by
views/cards_look/sections.lua).

Loaded once by main.lua and handed to the insights view as `deps.Pages`.
]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors = deps.Colors

local M = {}

-- "‹  1 / 2  ›" under the page; the arrows turn the page.
local function buildPageFooter(self, fonts, width, height, page, count)
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
local function dropHiddenTargets(self, page_group)
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

-- Splits `sections` into pages at the section starts it recorded
-- (sections._breaks), filling each page with as many whole sections as fit
-- above the page footer, and returns the current page (self._page) with the
-- footer at the bottom of `avail_h`. Sets self._page / self._page_count.
function M.paginate(self, sections, avail_h, fonts, width)
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
    dropHiddenTargets(self, group)

    return VerticalGroup:new{
        align = "left",
        group,
        VerticalSpan:new{ width = math.max(0, room - group:getSize().h) },
        buildPageFooter(self, fonts, width, footer_h, page, count),
    }
end

return M
