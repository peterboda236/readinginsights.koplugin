--[[
Reading Insights - the achievements list popup.

Opened two ways: by tapping the "N earned" cell in the Reading insights
popup's reading-goal section, and from Tools > Reading insights > "Show
achievements". Both call M.show().

Drawn with the same list widget (widgets/booklistwidget.lua) as the plugin's
editable book lists, so per-row styling is fully under our control: earned
achievements are shown in bold with their unlock date on the right; the
still-locked ones are normal weight and greyed out (item.dim). Each row leads
with a plain BMP Unicode symbol (see the catalogue's `icon` field) rather
than an emoji, so the mark renders on every device.

Earned come first (most recently unlocked at the top) under the default
order; the title bar's left icon opens the shared sort menu, relabelled for
achievements: by unlock time (newest/oldest first) or by name (A-Z / Z-A).
Tapping a row shows its one-line description; the list stays open.

The data and its persistence live in lib/achievements.lua; this module is
only the widget that draws it.
]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Achievements, Locale, ListWidget =
    deps.Achievements, deps.Locale, deps.ListWidget
local _ = Locale._

-- Remembered per-list, like the book lists' own sort keys.
local SORT_KEY = "reading_insights_achievements_sort"

-- Which achievements the list shows. Kept for the KOReader session (resets on
-- restart) rather than persisted - a transient view choice, like a filter.
local FILTER_ALL, FILTER_EARNED, FILTER_LOCKED = "all", "earned", "locked"
local current_filter = FILTER_ALL

local M = {}

function M.show(on_close)
    local items = Achievements.list()

    -- Builds the rows for the current filter. The progress figure in the
    -- header always reflects the full catalogue, not the filtered view.
    local function buildItems()
        local item_table = {}
        for _idx, it in ipairs(items) do
            local include = current_filter == FILTER_ALL
                or (current_filter == FILTER_EARNED and it.earned)
                or (current_filter == FILTER_LOCKED and not it.earned)
            if include then
                local def    = it.def
                local earned = it.earned
                local desc   = def.desc
                local title  = def.title
                -- Right-hand column: the unlock date for earned achievements
                -- (nothing for locked ones). Achievements earned since the
                -- list was last opened get a leading star here - the same
                -- "new" mark as the star next to the count in the insights
                -- popup. The star sits on the right (not on the name) so it
                -- can't be mistaken for the row's own icon, which is itself a
                -- star for the book-count achievements.
                local value = earned and Locale.formatDateFromTS(it.earned_ts) or ""
                if it.is_new then value = "★ " .. value end
                item_table[#item_table + 1] = {
                    -- Icon in its own fixed-width column (see BookListItem),
                    -- so the title starts at the same x on every row.
                    icon = def.icon,
                    text = title,
                    -- Earned in bold, locked greyed and normal weight.
                    bold = earned,
                    dim  = not earned,
                    mandatory = value,
                    -- Keeps earned (sort_time > 0, newest first) above locked
                    -- (sort_time 0) under the default order; ties -> title.
                    sort_title = title,
                    sort_time  = (earned and it.earned_ts) or 0,
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = def.icon .. "  " .. title .. "\n\n" .. desc,
                        })
                    end,
                }
            end
        end
        return item_table
    end

    -- The four shared orders (see ListWidget.SORT_MODES), relabelled for
    -- achievements: "recent" is the unlock time, "title" is the name.
    local sort_labels = {
        recent_desc = _("Earned (newest first)"),
        recent_asc  = _("Earned (oldest first)"),
        title_asc   = _("Name (A to Z)"),
        title_desc  = _("Name (Z to A)"),
    }

    -- Opening the list acknowledges every earned achievement: the "new"
    -- stars (here and the badge in the insights popup) clear from now on.
    -- The rows built above already captured their is_new flags, so this
    -- open still shows the stars; only the next view is cleared.
    Achievements.markAllSeen()

    -- Header shows progress, e.g. "Achievements  37/63 (53%)".
    local total   = #Achievements.CATALOGUE
    local earned  = Achievements.earnedCount()
    local pct     = total > 0 and math.floor(earned / total * 100 + 0.5) or 0
    local title   = _("Achievements") .. "  " .. earned .. "/" .. total .. " (" .. pct .. "%)"

    local widget

    -- Filter entries added to the title-bar's sort menu (U+2713 in front of
    -- the active one). Changing the filter reopens the list so the menu's
    -- check marks and the rows both reflect the new choice.
    local function filterButton(value, label)
        return {
            text = (current_filter == value and "\xe2\x9c\x93 " or "    ") .. label,
            callback = function()
                if current_filter == value then return end
                current_filter = value
                UIManager:close(widget)
                M.show(on_close)
            end,
        }
    end

    widget = ListWidget.new{
        title            = title,
        item_table       = buildItems(),
        show_ok_cancel   = false,
        sort_setting_key = SORT_KEY,
        sort_labels      = sort_labels,
        no_checkbox      = true,
        -- Extra rows under the sort orders in the title-bar menu: show all
        -- achievements, only earned, or only locked (still-to-do) ones.
        extra_menu_buttons = {
            filterButton(FILTER_ALL,    _("Show all")),
            filterButton(FILTER_EARNED, _("Show earned only")),
            filterButton(FILTER_LOCKED, _("Show locked only")),
        },
        -- Lets the caller refresh the insights popup's "N earned ★" cell
        -- once the list closes, so the badge disappears without waiting for
        -- the next open. nil when opened from the Tools menu.
        close_callback   = on_close,
        -- Long-press the title bar: re-scan everything from the database
        -- immediately (regardless of the daily/every-open setting), then
        -- reopen the list fresh so the new progress/stars show at once.
        title_hold_callback = function()
            local info = InfoMessage:new{ text = _("Reloading achievements...") }
            UIManager:show(info)
            UIManager:scheduleIn(0.2, function()
                pcall(Achievements.recompute)
                UIManager:close(info)
                UIManager:close(widget)
                M.show(on_close)
            end)
        end,
    }
    UIManager:show(widget)
    return widget
end

return M
