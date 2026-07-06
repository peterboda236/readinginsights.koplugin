--[[
Reading Insights (plugin entry point)

This plugin adds two views, each implemented in its own file:

  insights_view.lua
    "Reading insights" - full-screen, scrollable reading-history popup
    (last week, streaks, yearly/monthly charts, all-time totals). Available
    everywhere (book view and file manager), via the Tools menu and via a
    general gesture/dispatcher action.

  stats_view.lua
    "Reading statistics: overview" - compact live overlay for the book
    currently open (chapter/book time left, progress, pace). Book-view only:
    it needs an open document, so it's only offered in the Tools menu while
    reading, and its gesture/dispatcher action only shows up for assignment
    under Reader gestures (not File manager gestures).

This file itself only does the wiring: it loads the shared translation
module (l10n.lua) and both view modules, registers the two dispatcher
actions (for gesture/shortcut assignment), builds the Tools menu entries,
and forwards the two "show popup" events to the right view.

Both view files are loaded with loadfile()(...) rather than require(...)
so they don't depend on this plugin's directory being on package.path -
they get the shared L10N module passed straight in as their chunk argument.
]]--

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local function pluginDir()
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*/)")
    return dir or "./"
end

local PLUGIN_DIR = pluginDir()

-- Loads <name> from this plugin's directory and calls the resulting chunk
-- with `...` as its arguments (e.g. the shared L10N module).
local function loadModule(name, ...)
    local path = PLUGIN_DIR .. name
    local chunk, err = loadfile(path)
    if not chunk then
        error(("Reading Insights: failed to load %s: %s"):format(name, tostring(err)))
    end
    return chunk(...)
end

local L10N = loadModule("l10n.lua")
local _ = L10N._

-- Shared chart/text color settings (Colors menu), used by both views so
-- there's a single, unified place to configure them. See colors.lua.
local Colors = loadModule("colors.lua", L10N)

local Insights = loadModule("insights_view.lua", L10N, Colors)
local StatsPopup = loadModule("stats_view.lua", L10N, Colors)

--[[
Plugin wiring.

is_doc_only = false, so KOReader instantiates this plugin both while
reading a book (self.ui = ReaderUI) and in the file browser
(self.ui = FileManager). The insights popup works in both contexts; the
stats popup needs an open document, so it's only offered/registered where
self.ui.document is present (i.e. in Reader view).
]]--
local ReadingInsights = WidgetContainer:extend{
    name = "readinginsights",
    is_doc_only = false,
}

function ReadingInsights:onDispatcherRegisterActions()
    Dispatcher:registerAction("reading_insights_popup", {
        category = "none",
        event    = "ShowReadingInsightsPopup",
        title    = _("Reading insights"),
        general  = true,
    })
    -- reader = true (not general): only assignable to gestures/shortcuts
    -- while in book view, matching the popup's book-only requirement.
    Dispatcher:registerAction("reading_stats_popup", {
        category = "none",
        event    = "ShowReadingStatsPopup",
        title    = _("Book progress"),
        reader   = true,
    })
end

function ReadingInsights:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- Force this plugin's entry to the top of the Tools menu
    -- (both in Reader view and in the File manager)
    UIManager:scheduleIn(1, function()
        local function forceFirst(module_path_new, module_path_old)
            local ok_new, order_module = pcall(require, module_path_new)
            if not ok_new then
                local ok_old, res_old = pcall(require, module_path_old)
                if ok_old then order_module = res_old end
            end
            if order_module then
                if order_module.insertSorted then
                    order_module.insertSorted("tools", "reading_insights_popup", 1)
                elseif order_module.tools then
                    for i, v in ipairs(order_module.tools) do
                        if v == "reading_insights_popup" then
                            table.remove(order_module.tools, i)
                            break
                        end
                    end
                    table.insert(order_module.tools, 1, "reading_insights_popup")
                end
            end
        end

        forceFirst("ui/elements/reader_menu_order", "apps/reader/modules/readermenuorder")
        forceFirst("ui/elements/filemanager_menu_order", "apps/filemanager/modules/filemanagermenuorder")
    end)
end

-- True only when there's a book currently open (Reader view, not File manager).
function ReadingInsights:_hasOpenDocument()
    return self.ui ~= nil and self.ui.document ~= nil
end

function ReadingInsights:onShowReadingInsightsPopup()
    local popup = Insights.Popup:new{ ui = self.ui }
    UIManager:show(popup)
    return true
end

function ReadingInsights:onShowReadingStatsPopup()
    -- Book-view only: silently ignore if there's no document open (e.g. if
    -- somehow triggered from the file manager).
    if not self:_hasOpenDocument() then return true end
    local popup = StatsPopup:new{ ui = self.ui }
    UIManager:show(popup)
    return true
end

-- Adds "Reading insights" under Tools as a submenu.
-- Sub-entries: open the insights popup, open the stats popup (book view
-- only), a separator, then a "Settings" submenu holding the two
-- persistent settings for the insights popup plus the Colors submenu.
function ReadingInsights:addToMainMenu(menu_items)
    local sub_item_table = {
        {
            text = _("Show Reading insights"),
            keep_menu_open = false,
            callback = function()
                self:onShowReadingInsightsPopup()
            end,
        },
    }

    local has_open_document = self:_hasOpenDocument()
    if has_open_document then
        table.insert(sub_item_table, {
            text = _("Show Book progress"),
            keep_menu_open = false,
            callback = function()
                self:onShowReadingStatsPopup()
            end,
        })
    end

    -- Separator after the two "open a popup" entries, before the
    -- settings submenu below.
    sub_item_table[#sub_item_table].separator = true

    local settings_sub_item_table = {}

    table.insert(settings_sub_item_table, {
        text = _("Full-screen refresh on open/close"),
        keep_menu_open = true,
        checked_func = function()
            return Insights.readFullRefreshSetting()
        end,
        callback = function()
            Insights.saveFullRefreshSetting(not Insights.readFullRefreshSetting())
        end,
    })

    table.insert(settings_sub_item_table, {
        text_func = function()
            local order = Insights.readAscendingSetting()
                and _("Oldest first")
                or  _("Newest first")
            return _("8-week chart order") .. ": " .. order
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Newest first (descending)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return not Insights.readAscendingSetting()
                end,
                callback = function()
                    Insights.saveAscendingSetting(false)
                end,
            },
            {
                text = _("Oldest first (ascending)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return Insights.readAscendingSetting()
                end,
                callback = function()
                    Insights.saveAscendingSetting(true)
                end,
            },
        },
    })

    -- Bar-chart height settings: one entry per chart, each opening a
    -- SpinWidget (KOReader's standard numeric-value picker) with the
    -- current value pre-filled and a "default" value to reset to. The
    -- default matches the value that was hardcoded before this setting
    -- existed, so "reset to default" reproduces the original look exactly.
    local function buildBarHeightMenuEntry(text, read_fn, save_fn, default_value, value_min, value_max)
        return {
            text_func = function()
                return text .. ": " .. tostring(read_fn())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text    = text,
                    value         = read_fn(),
                    value_min     = value_min,
                    value_max     = value_max,
                    value_step    = 1,
                    value_hold_step = 5,
                    default_value = default_value,
                    ok_text       = _("Set"),
                    callback      = function(spin)
                        save_fn(spin.value)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }
    end

    table.insert(settings_sub_item_table, {
        text = _("Bar chart height"),
        keep_menu_open = true,
        sub_item_table = {
            buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Last week"),
                Insights.readWeeklyBarHeightSetting,
                Insights.saveWeeklyBarHeightSetting,
                Insights.DEFAULT_WEEKLY_BAR_HEIGHT,
                10, 200
            ),
            buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Months"),
                Insights.readMonthlyBarHeightSetting,
                Insights.saveMonthlyBarHeightSetting,
                Insights.DEFAULT_MONTHLY_BAR_HEIGHT,
                10, 200
            ),
            buildBarHeightMenuEntry(
                _("Book progress") .. ": " .. _("Chapters"),
                StatsPopup.readChapterBarHeightSetting,
                StatsPopup.saveChapterBarHeightSetting,
                StatsPopup.DEFAULT_CHAPTER_BAR_HEIGHT,
                10, 200
            ),
        },
    })

    -- Unified color settings for every chart/diagram and label in both
    -- popups (insights and stats). Any change here applies to both, next
    -- time each popup is (re)opened.
    table.insert(settings_sub_item_table, {
        text = _("Colors"),
        keep_menu_open = true,
        sub_item_table = Colors.buildMenu(),
    })

    table.insert(sub_item_table, {
        text = _("Settings"),
        keep_menu_open = true,
        sub_item_table = settings_sub_item_table,
    })

    menu_items.reading_insights_popup = {
        text = _("Reading insights"),
        sorting_hint = "tools",
        sub_item_table = sub_item_table,
    }
end

return ReadingInsights
