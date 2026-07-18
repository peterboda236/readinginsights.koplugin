--[[
Reading Insights - the Tools menu.

Builds the whole *Tools > Reading insights* entry: the "show popup" actions,
the Settings submenu (sleep screen, full-screen refresh, colors, fonts), the
Advanced settings submenu, and the Updates and About entries.

This is ~470 lines of pure menu description - nested tables of text_func /
checked_func / callback - and it was the single largest thing in main.lua,
which is otherwise about wiring: loading modules, registering dispatcher
actions, and the sleep-screen integration. Keeping the two apart means a
menu tweak doesn't involve scrolling past the screensaver patching, and
main.lua now reads as a table of contents for the plugin.

  Menu.build(plugin, deps) -> the menu_items.reading_insights_popup table

`plugin` is the ReadingInsights instance, used for the callbacks that open
the popups (and to ask whether a document is currently open, which decides
whether the two book-specific entries are offered at all). `deps` carries
the modules the menu reads settings from or shows dialogs for - see the
menu_deps table main.lua passes in.
]]--

local UIManager = require("ui/uimanager")

-- Shared modules, passed in as one named table by main.lua. Named rather
-- than positional on purpose: the list had grown long enough that
-- inserting one module in the middle would silently shift every module
-- after it, and the resulting nil would only surface far from the cause.
local deps = ...
local Locale =
    deps.Locale
local _ = Locale._

local M = {}

function M.build(self, deps)
    local sub_item_table = {
        {
            text = _("Show Reading insights"),
            keep_menu_open = false,
            callback = function()
                self:onShowReadingInsightsPopup()
            end,
        },
        {
            text = _("Show Records"),
            keep_menu_open = false,
            callback = function()
                self:onShowReadingRecordsPopup()
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
        table.insert(sub_item_table, {
            text = _("Show Book progress calendar"),
            keep_menu_open = false,
            callback = function()
                self:onShowBookCalendarPopup()
            end,
        })
    end

    -- Separator after the two "open a popup" entries, before the
    -- settings submenu below.
    sub_item_table[#sub_item_table].separator = true

    local settings_sub_item_table = {}

    -- Whether/how it's used as a sleep screen is normally set directly in
    -- KOReader's own Settings > Screen > Sleep screen menu (see the
    -- menu_items.screensaver injection at the end of this function).
    --
    -- That injection depends on menu_items.screensaver already existing
    -- (with a sub_item_table) by the time this addToMainMenu() runs, which
    -- isn't a guaranteed, documented part of KOReader's plugin API - just
    -- an observed implementation detail. If it ever doesn't hold (older/
    -- newer core versions, a different frontend, plugin load order, an
    -- interaction with another sleep-screen plugin, etc.) the injection
    -- silently does nothing, and without a fallback here there would be no
    -- way at all to turn this on. So the same control is duplicated here,
    -- inside our own Settings submenu, guaranteed to always work
    -- regardless of what core's menu looks like.
    --[[
    table.insert(settings_sub_item_table, {
        text = _("Use as sleep screen"),
        keep_menu_open = true,
        checked_func = function()
            return G_reader_settings:readSetting("screensaver_type") == deps.SCREENSAVER_TYPE_VALUE
        end,
        callback = function()
            if G_reader_settings:readSetting("screensaver_type") == deps.SCREENSAVER_TYPE_VALUE then
                G_reader_settings:saveSetting("screensaver_type", "disable")
            else
                G_reader_settings:saveSetting("screensaver_type", deps.SCREENSAVER_TYPE_VALUE)
            end
        end,
    })
    ]]--

    -- Sleep-screen indicator now lives at the top of Advanced settings
    -- instead of here - see advanced_settings_sub_item_table below.

    table.insert(settings_sub_item_table, {
        text = _("Full-screen refresh on open/close"),
        keep_menu_open = true,
        checked_func = function()
            return deps.ViewSettings.readFullRefreshSetting()
        end,
        callback = function()
            deps.ViewSettings.saveFullRefreshSetting(not deps.ViewSettings.readFullRefreshSetting())
        end,
    })

    -- Bar-chart height settings: one entry per chart, each opening a
    -- SpinWidget (KOReader's standard numeric-value picker) with the
    -- current value pre-filled and a "default" value to reset to. The
    -- default matches the value that was hardcoded before this setting
    -- existed, so "reset to default" reproduces the original look exactly.
    -- enabled_func is optional: passed by the two Reading insights entries
    -- so they grey out while the automatic height mode is on (their stored
    -- value isn't used then, and is left untouched so switching back to
    -- manual brings it back).
    local function buildBarHeightMenuEntry(text, read_fn, save_fn, default_value, value_min, value_max, enabled_func)
        return {
            text_func = function()
                return text .. ": " .. tostring(read_fn())
            end,
            enabled_func = enabled_func,
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

    -- Unified color settings for every chart/diagram and label in both
    -- popups (insights and stats). Any change here applies to both, next
    -- time each popup is (re)opened.
    table.insert(settings_sub_item_table, {
        text = _("Colors"),
        keep_menu_open = true,
        sub_item_table = deps.Colors.buildMenu(),
    })

    -- Unified font settings (name + size) for every text role in both
    -- popups. Same idea as deps.Colors above. Any change here applies to both,
    -- next time each popup is (re)opened.
    table.insert(settings_sub_item_table, {
        text = _("Fonts"),
        keep_menu_open = true,
        separator = true,
        sub_item_table = deps.Fonts.buildMenu(),
    })

    -- "Advanced settings": less commonly touched settings, tucked away in
    -- their own submenu (bar chart height, reading heatmap range, and the
    -- 8-week chart order, in that order - no separators inside). A
    -- separator is placed above this entry itself (set on the preceding
    -- "Fonts" entry) to set it apart from the rest of the Settings menu.
    local advanced_settings_sub_item_table = {}

    -- Moved here (to the very top) from the Settings submenu, keeping its
    -- separator so it still visually stands apart from the entries below.
    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local label_mode = deps.readScreensaverLabelMode()
            return _("Sleep-screen indicator") .. ": " ..
                ((label_mode == "text") and _("\"(sleeping…)\" after the title") or _("None"))
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("None"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.readScreensaverLabelMode() == "none" end,
                callback = function() deps.saveScreensaverLabelMode("none") end,
            },
            {
                text = _("\"(sleeping…)\" after the title"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.readScreensaverLabelMode() == "text" end,
                callback = function() deps.saveScreensaverLabelMode("text") end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text = _("Bar chart height"),
        keep_menu_open = true,
        sub_item_table = {
            -- On by default: the two Reading insights charts below size
            -- themselves so the whole page fits the screen, which is both
            -- the best use of the space and the only way to be sure the
            -- scroll bar never shows up. Switching it off restores the two
            -- fixed values, which is why they stay here (greyed out while
            -- automatic is on, so it's obvious they're not in effect
            -- rather than simply being ignored).
            {
                text = _("Automatic (fit screen)"),
                help_text = _("Sizes the Reading insights bar charts so the page fills the screen exactly, without a scroll bar."),
                keep_menu_open = true,
                checked_func = function() return deps.ViewSettings.Opt.readBarHeightAuto() end,
                callback = function(touchmenu_instance)
                    deps.ViewSettings.Opt.saveBarHeightAuto(not deps.ViewSettings.Opt.readBarHeightAuto())
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                separator = true,
            },
            buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Last week"),
                deps.ViewSettings.readWeeklyBarHeightSetting,
                deps.ViewSettings.saveWeeklyBarHeightSetting,
                deps.ViewSettings.DEFAULT_WEEKLY_BAR_HEIGHT,
                10, 200,
                function() return not deps.ViewSettings.Opt.readBarHeightAuto() end
            ),
            buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Months"),
                deps.ViewSettings.readMonthlyBarHeightSetting,
                deps.ViewSettings.saveMonthlyBarHeightSetting,
                deps.ViewSettings.DEFAULT_MONTHLY_BAR_HEIGHT,
                10, 200,
                function() return not deps.ViewSettings.Opt.readBarHeightAuto() end
            ),
            buildBarHeightMenuEntry(
                _("Book progress") .. ": " .. _("Chapters"),
                deps.ChapterBar.readHeightSetting,
                deps.ChapterBar.saveHeightSetting,
                deps.ChapterBar.DEFAULT_HEIGHT,
                10, 200
            ),
        },
    })

    -- Shows/hides the whole "Reading goal" section of the insights popup
    -- (finished-book count vs. this year's target). On by default; when
    -- off, its data isn't even queried on open.
    table.insert(advanced_settings_sub_item_table, {
        text = _("Reading goal section"),
        help_text = _("Shows the number of books finished this year next to your yearly goal. Long press the goal value to change it."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowReadingGoal() end,
        callback = function(touchmenu_instance)
            deps.ViewSettings.Opt.saveShowReadingGoal(not deps.ViewSettings.Opt.readShowReadingGoal())
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local months = deps.ViewSettings.readHeatmapMonthsSetting()
            local label
            if months == 3 then label = _("3 months")
            elseif months == 6 then label = _("6 months")
            else label = _("4 months") end
            return _("Reading heatmap range") .. ": " .. label
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("3 months"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.ViewSettings.readHeatmapMonthsSetting() == 3 end,
                callback = function() deps.ViewSettings.saveHeatmapMonthsSetting(3) end,
            },
            {
                text = _("4 months"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.ViewSettings.readHeatmapMonthsSetting() == 4 end,
                callback = function() deps.ViewSettings.saveHeatmapMonthsSetting(4) end,
            },
            {
                text = _("6 months"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.ViewSettings.readHeatmapMonthsSetting() == 6 end,
                callback = function() deps.ViewSettings.saveHeatmapMonthsSetting(6) end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local fmt = deps.ViewSettings.readHeatmapHourFormatSetting() == "12"
                and _("12-hour (AM/PM)")
                or  _("24-hour")
            return _("Heatmap hour format") .. ": " .. fmt
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("24-hour"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.readHeatmapHourFormatSetting() == "24"
                end,
                callback = function() deps.ViewSettings.saveHeatmapHourFormatSetting("24") end,
            },
            {
                text = _("12-hour (AM/PM)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.readHeatmapHourFormatSetting() == "12"
                end,
                callback = function() deps.ViewSettings.saveHeatmapHourFormatSetting("12") end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local start_day = deps.ViewSettings.readWeekStartSetting() == "sunday"
                and _("Sunday")
                or  _("Monday")
            return _("Week start day") .. ": " .. start_day
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Monday"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.readWeekStartSetting() == "monday"
                end,
                callback = function() deps.ViewSettings.saveWeekStartSetting("monday") end,
            },
            {
                text = _("Sunday"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.readWeekStartSetting() == "sunday"
                end,
                callback = function() deps.ViewSettings.saveWeekStartSetting("sunday") end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local order = deps.ViewSettings.readAscendingSetting()
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
                    return not deps.ViewSettings.readAscendingSetting()
                end,
                callback = function()
                    deps.ViewSettings.saveAscendingSetting(false)
                end,
            },
            {
                text = _("Oldest first (ascending)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.readAscendingSetting()
                end,
                callback = function()
                    deps.ViewSettings.saveAscendingSetting(true)
                end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text         = _("Show long durations (24h+) as days"),
        keep_menu_open = true,
        checked_func = function() return deps.Locale.readDurationDaysSetting() end,
        callback     = function()
            deps.Locale.saveDurationDaysSetting(not deps.Locale.readDurationDaysSetting())
        end,
    })

    -- What the per-book reading calendar's day cells show: cumulative
    -- "+13%" progress through the whole book (default), that day's own
    -- page count ("+101o"), or that day's own time spent (honoring
    -- KOReader's global "Duration format" setting) - see
    -- deps.BookCalendar.readCalendarCellModeSetting in book_calendar_view.lua.
    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local mode_key = deps.BookCalendar.readCalendarCellModeSetting()
            local mode = (mode_key == "pages" and _("Pages"))
                or (mode_key == "time" and _("Time"))
                or _("Percent")
            return _("Book calendar cell content") .. ": " .. mode
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Percent"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.BookCalendar.readCalendarCellModeSetting() == "percent"
                end,
                callback = function() deps.BookCalendar.saveCalendarCellModeSetting("percent") end,
            },
            {
                text = _("Pages"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.BookCalendar.readCalendarCellModeSetting() == "pages"
                end,
                callback = function() deps.BookCalendar.saveCalendarCellModeSetting("pages") end,
            },
            {
                text = _("Time"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.BookCalendar.readCalendarCellModeSetting() == "time"
                end,
                callback = function() deps.BookCalendar.saveCalendarCellModeSetting("time") end,
            },
        },
    })

    table.insert(settings_sub_item_table, {
        text = _("Advanced settings"),
        keep_menu_open = true,
        sub_item_table = advanced_settings_sub_item_table,
    })

    table.insert(sub_item_table, {
        text = _("Settings"),
        keep_menu_open = true,
        sub_item_table = settings_sub_item_table,
    })

    -- In-app updater: check for / install new releases straight from
    -- GitHub. See updater.lua and the ReadingInsights:_updateSubItems()
    -- family of methods above.
    table.insert(sub_item_table, {
        text                = _("Updates"),
        sub_item_table_func = function() return self:_updateSubItems() end,
        separator           = true,
    })

    -- deps.About: plugin title, installed version, short description, and the
    -- GitHub repository URL. See about.lua.
    table.insert(sub_item_table, {
        text = _("About"),
        keep_menu_open = true,
        callback = function()
            deps.About.show()
        end,
    })

    return {
        text = _("Reading insights"),
        sorting_hint = "tools",
        sub_item_table = sub_item_table,
    }

    --[[
    No standalone top-level "Reading insights sleep screen" entry anymore -
    the "Reading insights" choice already lives inside KOReader's own
    Settings > Screen > Sleep screen > Wallpaper radio group (alongside
    "Document cover", "Random image", etc.), baked in by
    deps.patchScreensaverMenuBuilder() above. Having a second, separate entry
    right next to the Sleep screen submenu just duplicated that same
    screensaver_type toggle in a confusing spot, so it's been removed -
    the Wallpaper-submenu entry is now the only place to pick it from
    (besides the Tools > Reading insights > Settings > "Use as sleep
    screen" quick toggle below, which stays).
    ]]--
end

return M
