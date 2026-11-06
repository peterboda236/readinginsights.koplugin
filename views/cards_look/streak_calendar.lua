--[[
Reading Insights - the "Cards" look of the Reading calendar (streak) popup
(Settings > Appearance > Look).

The popup itself (views/streak_calendar_view.lua) keeps its title bar and the
calendar; in the Cards look its month header is UI.buildNavHeader, today gets
an outline, and the current / best streak section at the bottom is the
Streaks card built here. The Current / Best streak dialog it opens gets its
content from M.buildHistoryContent.

Loaded once by main.lua and handed to the streak calendar view as
`deps.Cards`.
]]--

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, UI = deps.Locale, deps.Colors, deps.UI

local _           = Locale._
local N_          = Locale.N_
local formatCount = Locale.formatCount

local M = {}

-- Flame icon + "Streaks", then "Current ›" | "Best ›" columns with
-- "N days · N weeks". The popup's own tap zones cover the two halves of the
-- card (tap: that streak's history), so the "›" is hidden when readonly.
function M.buildStreaksCard(fonts, layout, width, cur_days, cur_weeks, best_days, best_weeks, readonly)
    local ilayout = UI.buildLayout(UI.cardInnerWidth(width), 0, layout.column_gap)
    local col_w = ilayout.col_width

    local function column(title, days, weeks)
        local head = HorizontalGroup:new{
            align = "center",
            TextWidget:new{ text = title, face = fonts.label, bold = true, fgcolor = Colors.section(), max_width = col_w },
        }
        if not readonly then
            table.insert(head, HorizontalSpan:new{ width = Size.padding.default })
            table.insert(head, UI.chevron(fonts.label))
        end
        return VerticalGroup:new{
            align = "left",
            head,
            UI.buildDaysWeeksLine(fonts, col_w,
                formatCount(days), N_("day", "days", days),
                formatCount(weeks), N_("week", "weeks", weeks)),
        }
    end

    local body = VerticalGroup:new{
        align = "left",
        UI.cardHeader("flame", _("Streaks"), fonts.section, ilayout.content_width, false),
        VerticalSpan:new{ width = Size.padding.small },
        UI.buildTwoColRow(column(_("Current"), cur_days, cur_weeks), column(_("Best"), best_days, best_weeks),
            ilayout, false, nil, Size.line.thin, Colors.cardsColor("divider")),
        VerticalSpan:new{ width = Size.padding.default },
    }
    return UI.buildCard(body, width)
end

-- Content of the Current / Best streak dialog (StreakHistoryPopup) in the
-- Cards look: the page's date range with chevron icons, a card with the view
-- name (+ "▾", tap: the four views) and the rows, and a card with the
-- streak's length and the dates it spans. Sets the popup's header and
-- view-list geometry (_range_*, _list_dy, _list_h) for its tap zones.
function M.buildHistoryContent(popup, fonts, width, page_items, max_value, range_str, prev_available, next_available, view_label)
    local inner_w = UI.cardInnerWidth(width)
    local header, _lf, _rf, left_w, right_w, header_h =
        UI.buildNavHeader(range_str, width, fonts.section, prev_available, next_available)
    popup._range_header_h = header_h
    popup._range_left_w, popup._range_right_w = left_w, right_w

    local rows_title = UI.cardHeader("chart", view_label, fonts.section, inner_w, "menu")
    local rows = VerticalGroup:new{ align = "left" }
    for _i, item in ipairs(page_items) do
        table.insert(rows, (popup:_buildRow(item, popup:_statsOf(item), max_value, fonts)))
    end
    local rows_card = UI.buildCard(VerticalGroup:new{
        align = "left",
        rows_title,
        VerticalSpan:new{ width = Size.padding.small },
        rows,
        VerticalSpan:new{ width = Size.padding.small },
    }, width)
    popup._list_dy = header_h + Size.padding.small + UI.cardBorder() + Size.padding.small
    popup._list_h  = rows_title:getSize().h

    local content = VerticalGroup:new{
        align = "left",
        header,
        VerticalSpan:new{ width = Size.padding.small },
        rows_card,
    }

    local r = popup.infos and popup.infos[popup.unit]
    if r then
        local ilayout = UI.buildLayout(inner_w, 0, Size.padding.large)
        local streak_card = UI.buildCard(VerticalGroup:new{
            align = "left",
            UI.cardHeader("flame", popup:_caption(), fonts.section, inner_w, false),
            VerticalSpan:new{ width = Size.padding.small },
            UI.buildTwoColRow(
                UI.buildStatCell(fonts, ilayout.col_width, r.value, r.unit),
                TextBoxWidget:new{ text = r.range, face = fonts.label, fgcolor = Colors.label(), width = ilayout.col_width },
                ilayout, false, nil, Size.line.thin, Colors.cardsColor("divider")),
            VerticalSpan:new{ width = Size.padding.default },
        }, width)
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        table.insert(content, streak_card)
    end
    return content
end

return M
