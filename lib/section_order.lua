--[[
Reading Insights - the "Section order" screen.

Lets the reader put the sections of a popup in the order they want
(Settings > Reading insights popup > Section order, Settings > Book
progress popup > Section order). It is KOReader's own SortWidget - the
"Arrange items in status bar" screen: tap a row to pick it up, then move it
with the arrows at the bottom, and save with the check mark. The ☰ in the
title bar (which in the stock widget sorts A-Z, meaningless here) offers
"Restore default order" instead.

The order itself - where it is stored, what the default is, how the popups
apply it - lives in lib/insights_settings.lua (VS.Order).

  SectionOrder.open(view, on_change)   "insights" or "book"; on_change()
                                       runs after the order was saved or reset
  SectionOrder.label(view)             "Default" / "Custom" for menu texts
]]--

local ButtonDialog = require("ui/widget/buttondialog")
local SortWidget   = require("ui/widget/sortwidget")
local UIManager    = require("ui/uimanager")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, VS = deps.Locale, deps.VS
local _ = Locale._

local M = {}

-- The name of every section, as the popup titles it.
local function sectionNames(view)
    if view == "insights" then
        return {
            time_goals = _("Daily / weekly goal"),
            week       = VS.readWeeklyViewIsCalendar() and _("Week") or _("Last 7 days"),
            streaks    = _("Streaks"),
            year       = _("Yearly & monthly"),
            goal_ach   = _("Reading goal") .. " / " .. _("Achievements"),
            all_time   = _("All time"),
        }
    end
    return {
        chapter  = _("This chapter") .. " / " .. _("Next chapter"),
        chapters = _("Chapters"),
        book     = _("This book"),
        pace     = _("Pace"),
    }
end

-- The stock SortWidget with its title bar menu replaced: one entry that
-- throws the saved order away.
local OrderWidget = SortWidget:extend{
    order_view      = nil,
    order_on_change = nil,
}

function OrderWidget:onShowWidgetMenu()
    local dialog
    dialog = ButtonDialog:new{
        shrink_unneeded_width = true,
        buttons = {
            {{
                text  = _("Restore default order"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    VS.Order.reset(self.order_view)
                    -- Nothing left to save: close without the "unsaved
                    -- changes" question.
                    self.orig_item_table = nil
                    UIManager:close(self)
                    UIManager:setDirty(nil, "ui")
                    if self.order_on_change then self.order_on_change() end
                end,
            }},
        },
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
    return true
end

function M.open(view, on_change)
    local names = sectionNames(view)
    local items = {}
    for _i, id in ipairs(VS.Order.read(view)) do
        table.insert(items, { text = names[id] or id, section_id = id })
    end
    local widget = OrderWidget:new{
        title           = _("Section order"),
        item_table      = items,
        order_view      = view,
        order_on_change = on_change,
        -- Called by the check mark; `items` is the list the widget has been
        -- rearranging in place.
        callback = function()
            local list = {}
            for _i, item in ipairs(items) do table.insert(list, item.section_id) end
            VS.Order.save(view, list)
            if on_change then on_change() end
        end,
    }
    UIManager:show(widget)
end

function M.label(view)
    return VS.Order.isCustom(view) and _("Custom") or _("Default")
end

return M
