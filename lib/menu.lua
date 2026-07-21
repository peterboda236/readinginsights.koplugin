--[[
Reading Insights - the Tools menu.

Builds the whole *Tools > Reading insights* entry: the "show popup" actions,
the Settings submenu (sleep-screen indicator, full-screen refresh, colors,
fonts), the Advanced settings submenu below it (bar chart height, long
durations, then one group per area - Date & time, Reading insight popup,
Book progress calendar), and the Updates and About entries.

This is ~600 lines of pure menu description - nested tables of text_func /
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

-- Shared modules, passed in as one named table by main.lua (see there).
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

    -- Sleep-screen indicator: the one setting here that is about the sleep
    -- screen rather than about the popups, so it sits at the top with a
    -- divider under it, above the appearance settings that follow.
    table.insert(settings_sub_item_table, {
        text_func = function()
            local label_mode = deps.readScreensaverLabelMode()
            return _("Sleep-screen indicator") .. ": " ..
                ((label_mode == "text") and _("\"(sleeping…)\" after the title") or _("None"))
        end,
        keep_menu_open = true,
        separator = true,
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

    table.insert(settings_sub_item_table, {
        text = _("Full-screen refresh on open/close"),
        keep_menu_open = true,
        -- Divider under it: the two entries above are behaviour, Colors and
        -- Fonts below are appearance.
        separator = true,
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
    -- Draws a divider under an entry. A one-line wrapper rather than an
    -- eighth positional argument to buildBarHeightMenuEntry, whose parameter
    -- list is already long enough to be easy to miscount.
    local function withSeparator(entry)
        entry.separator = true
        return entry
    end

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
    -- their own submenu. A separator is placed above this entry itself (set
    -- on the preceding "Fonts" entry) to set it apart from the rest of the
    -- Settings menu.
    --
    -- Two settings that apply to everything the plugin draws sit at the top
    -- (bar chart height, long durations as days), then the rest grouped by
    -- what it affects, one submenu each: "Date & time" (how dates and times
    -- are spelled out anywhere), "Reading insight popup" and "Book progress
    -- calendar". Dividers separate the three blocks: under the pair at the
    -- top, and under "Date & time" (the only group that reaches outside the
    -- two popups below it).
    local advanced_settings_sub_item_table = {}

    table.insert(advanced_settings_sub_item_table, {
        text = _("Bar chart height"),
        keep_menu_open = true,
        sub_item_table = {
            -- Grouping: the automatic toggle and the two Reading insights
            -- entries it governs belong together, with the divider below
            -- them - "Book progress: Chapters" is a different view's
            -- setting and is always set by hand.
            --
            -- Automatic is on by default: the two charts size themselves so
            -- the whole page fits the screen, which is both the best use of
            -- the space and the only way to be sure the scroll bar never
            -- shows up. Switching it off restores the two fixed values,
            -- which is why they stay here (greyed out while automatic is
            -- on, so it's obvious they're not in effect rather than simply
            -- being ignored).
            {
                -- Composed from the same two strings the entries below use,
                -- so the name of the view can't end up worded one way here
                -- and another way two rows down.
                text = _("Automatic") .. " (" .. _("Reading insights") .. ")",
                help_text = _("Sizes the Reading insights bar charts so the page fits the screen without a scroll bar."),
                keep_menu_open = true,
                checked_func = function() return deps.ViewSettings.Opt.readBarHeightAuto() end,
                callback = function(touchmenu_instance)
                    deps.ViewSettings.Opt.saveBarHeightAuto(not deps.ViewSettings.Opt.readBarHeightAuto())
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Last week"),
                deps.ViewSettings.readWeeklyBarHeightSetting,
                deps.ViewSettings.saveWeeklyBarHeightSetting,
                deps.ViewSettings.DEFAULT_WEEKLY_BAR_HEIGHT,
                10, 200,
                function() return not deps.ViewSettings.Opt.readBarHeightAuto() end
            ),
            withSeparator(buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Months"),
                deps.ViewSettings.readMonthlyBarHeightSetting,
                deps.ViewSettings.saveMonthlyBarHeightSetting,
                deps.ViewSettings.DEFAULT_MONTHLY_BAR_HEIGHT,
                10, 200,
                function() return not deps.ViewSettings.Opt.readBarHeightAuto() end
            )),
            buildBarHeightMenuEntry(
                _("Book progress") .. ": " .. _("Chapters"),
                deps.ChapterBar.readHeightSetting,
                deps.ChapterBar.saveHeightSetting,
                deps.ChapterBar.DEFAULT_HEIGHT,
                10, 200
            ),
        },
    })

    -- Affects every duration this plugin prints, in all four popups, so it
    -- stays a flat entry up here instead of going into one of the
    -- per-view groups below.
    table.insert(advanced_settings_sub_item_table, {
        text         = _("Show long durations (24h+) as days"),
        separator    = true,
        keep_menu_open = true,
        checked_func = function() return deps.Locale.readDurationDaysSetting() end,
        callback     = function()
            deps.Locale.saveDurationDaysSetting(not deps.Locale.readDurationDaysSetting())
        end,
    })

    -- "Date & time": how clock times and dates are spelled out, wherever
    -- the plugin prints one. Filled in here and closed off (inserted into
    -- Advanced settings) after the date-format entry further down.
    local date_time_sub_item_table = {}

    -- Named "Time format" rather than after the one grid it currently
    -- governs: it is the plugin's answer to "12- or 24-hour?", and lives
    -- with the date settings for that reason.
    table.insert(date_time_sub_item_table, {
        text_func = function()
            local fmt = deps.ViewSettings.readHeatmapHourFormatSetting() == "12"
                and _("12-hour (AM/PM)")
                or  _("24-hour")
            return _("Time format") .. ": " .. fmt
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

    table.insert(date_time_sub_item_table, {
        text_func = function()
            local start_day = deps.ViewSettings.readWeekStartSetting() == "sunday"
                and _("Sunday")
                or  _("Monday")
            return _("First day of week") .. ": " .. start_day
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

    -- "Reading insight popup": everything that changes what the insights
    -- popup itself shows. Inserted into Advanced settings below, after the
    -- "Date & time" group.
    local insights_popup_sub_item_table = {}

    -- Shows/hides the whole "Reading goal" section of the insights popup
    -- (finished-book count vs. this year's target). On by default; when
    -- off, its data isn't even queried on open.
    table.insert(insights_popup_sub_item_table, {
        text = _("Reading goal section"),
        help_text = _("Shows the number of books finished this year next to your yearly goal. Long press the goal value to change it."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowReadingGoal() end,
        callback = function(touchmenu_instance)
            deps.ViewSettings.Opt.saveShowReadingGoal(not deps.ViewSettings.Opt.readShowReadingGoal())
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    table.insert(insights_popup_sub_item_table, {
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

    table.insert(insights_popup_sub_item_table, {
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

    -- Which end of the "Last week" bar chart today sits at. The default is
    -- what the chart always did before this setting existed - today on the
    -- left, the week running backwards from there.
    do
        -- Both the label and the two radio entries need the same two
        -- constant names; spelled out in full they don't fit a line.
        local VSet  = deps.ViewSettings
        local FIRST = VSet.WEEKLY_BAR_ORDER_TODAY_FIRST
        local LAST  = VSet.WEEKLY_BAR_ORDER_TODAY_LAST
        local function orderEntry(value, text)
            return {
                text = text,
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return VSet.readWeeklyBarOrderSetting() == value
                end,
                callback = function() VSet.saveWeeklyBarOrderSetting(value) end,
            }
        end
        table.insert(insights_popup_sub_item_table, {
            text_func = function()
                local side = VSet.readWeeklyBarOrderSetting() == LAST
                    and _("Today on the right")
                    or  _("Today on the left")
                return _("Last week chapter bar order") .. ": " .. side
            end,
            keep_menu_open = true,
            sub_item_table = {
                orderEntry(FIRST, _("Today on the left")),
                orderEntry(LAST,  _("Today on the right")),
            },
        })
    end

    -- What the Reading goal section's right-hand value counts: the year's
    -- goal itself, or how much of it is still left. Either way a long press
    -- on that cell edits the goal.
    do
        local Opt       = deps.ViewSettings.Opt
        local TOTAL     = Opt.GOAL_DISPLAY_TOTAL
        local REMAINING = Opt.GOAL_DISPLAY_REMAINING
        local function displayEntry(value, text)
            return {
                text = text,
                keep_menu_open = true,
                radio = true,
                checked_func = function() return Opt.readGoalDisplay() == value end,
                callback = function() Opt.saveGoalDisplay(value) end,
            }
        end
        table.insert(insights_popup_sub_item_table, {
            text_func = function()
                local mode = Opt.readGoalDisplay() == REMAINING
                    and _("Remaining")
                    or  _("Goal total")
                return _("Reading goal display") .. ": " .. mode
            end,
            -- Greyed out while the section it configures is switched off.
            enabled_func = function() return Opt.readShowReadingGoal() end,
            keep_menu_open = true,
            sub_item_table = {
                displayEntry(TOTAL,     _("Goal total")),
                displayEntry(REMAINING, _("Remaining")),
            },
        })
    end

    -- How every numeric date this plugin prints is spelled out (book
    -- lists, streak/records/stats popups, the Book progress calendar's day
    -- detail, and the manual book list's date field). One explicit setting
    -- instead of following the interface language; see Locale.formatDate. The
    -- entries are labelled with the pattern itself plus today's date as an
    -- example, so neither needs translating.
    do
        local function dateFormatEntry(fmt)
            return {
                -- text_func, not text: the example is today's date, and
                -- this table is built once when the menu is assembled.
                text_func = function()
                    return deps.Locale.DATE_FORMAT_HINTS[fmt] .. "  \xE2\x80\x93  " ..
                        deps.Locale.formatDateSample(fmt)
                end,
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.Locale.readDateFormatSetting() == fmt
                end,
                callback = function() deps.Locale.saveDateFormatSetting(fmt) end,
            }
        end
        local date_format_sub_item_table = {}
        for _idx, fmt in ipairs(deps.Locale.DATE_FORMATS) do
            table.insert(date_format_sub_item_table, dateFormatEntry(fmt))
        end
        table.insert(date_time_sub_item_table, {
            text_func = function()
                return _("Date format") .. ": " ..
                    deps.Locale.DATE_FORMAT_HINTS[deps.Locale.readDateFormatSetting()]
            end,
            keep_menu_open = true,
            sub_item_table = date_format_sub_item_table,
        })
    end

    -- The three groups, in the order they appear under Advanced settings.
    -- Both tables above are complete by now.
    table.insert(advanced_settings_sub_item_table, {
        text = _("Date & time"),
        keep_menu_open = true,
        separator = true,
        sub_item_table = date_time_sub_item_table,
    })

    table.insert(advanced_settings_sub_item_table, {
        text = _("Reading insight popup"),
        keep_menu_open = true,
        sub_item_table = insights_popup_sub_item_table,
    })

    local book_calendar_sub_item_table = {}

    -- What the Book progress calendar's day cells show: cumulative
    -- "+13%" progress through the whole book (default), that day's own
    -- page count ("+101o"), or that day's own time spent (honoring
    -- KOReader's global "Duration format" setting) - see
    -- deps.BookCalendar.readCalendarCellModeSetting in book_calendar_view.lua.
    table.insert(book_calendar_sub_item_table, {
        text_func = function()
            local mode_key = deps.BookCalendar.readCalendarCellModeSetting()
            local mode = (mode_key == "pages" and _("Pages"))
                or (mode_key == "time" and _("Time"))
                or _("Percent")
            return _("Book progress calendar cell content") .. ": " .. mode
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

    table.insert(advanced_settings_sub_item_table, {
        text = _("Book progress calendar"),
        keep_menu_open = true,
        sub_item_table = book_calendar_sub_item_table,
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
