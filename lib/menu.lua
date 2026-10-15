--[[
Reading Insights - the Tools menu.

Builds the whole *Tools > Reading insights* entry: the "open a popup" actions
(statistics popups, then the popups about the open book), the Settings submenu
(Date & time, Appearance, one group per view - Reading insight popup,
Heatmap & time of day, Book progress popup, Book info, Book progress
calendar - and Advanced settings last), and the Updates and About entries. The Settings layout is spelled
out in one place, under "Settings menu layout" near the end of M.build.

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
    -- The popup entries. Which of them are listed is set under
    -- Settings > Advanced settings > "Menu items"; the list is rebuilt each
    -- time the menu opens (sub_item_table_func at the bottom), so a change
    -- shows up right away. The three book entries also need an open book.
    local popup_entries = {
        { key = "insights",      label = _("Reading insights"),
          open = function() self:onShowReadingInsightsPopup() end },
        { key = "streak",        label = _("Reading streak"),
          open = function() self:onShowReadingStreakPopup() end },
        { key = "heatmap",       label = _("Reading heatmap"),
          open = function() self:onShowReadingHeatmapPopup() end },
        { key = "records",       label = _("Records"),
          open = function() self:onShowReadingRecordsPopup() end },
        { key = "achievements",  label = _("Achievements"),
          open = function() self:onShowReadingAchievements() end },
        { key = "book_progress", label = _("Book progress"), book = true,
          open = function() self:onShowReadingStatsPopup() end },
        { key = "book_info",     label = _("Book info"), book = true,
          open = function() self:onShowBookInfoPopup() end },
        { key = "book_calendar", label = _("Book progress calendar"), book = true,
          open = function() self:onShowBookCalendarPopup() end },
    }

    local function buildPopupEntries()
        local items = {}
        local has_open_document = self:_hasOpenDocument()
        local previous_was_book
        for _idx, e in ipairs(popup_entries) do
            if deps.ViewSettings.Opt.readMenuItem(e.key)
                and (has_open_document or not e.book) then
                -- Divider between the statistics popups and the popups
                -- about the open book.
                if #items > 0 and e.book and not previous_was_book then
                    items[#items].separator = true
                end
                table.insert(items, {
                    text = e.label,
                    keep_menu_open = false,
                    callback = e.open,
                })
                previous_was_book = e.book
            end
        end
        -- Separator after the "open a popup" entries, before the
        -- settings submenu below.
        if #items > 0 then items[#items].separator = true end
        return items
    end

    -- Everything below the popup entries (Settings, Updates, About).
    local sub_item_table = {}

    -- Every settings entry below is built once and stored by name in I; the
    -- Settings menu is put together from them in one place at the end of
    -- this function (see "Settings menu layout"), so moving an entry to
    -- another group is a one-line change there and nothing depends on the
    -- order in which the entries happen to be defined.
    local I = {}

    -- Lays out a list of entries: the string "-" puts a divider line under
    -- the entry before it. Any divider an entry carried on its own is
    -- dropped, so the dividers come from the layout alone.
    local function layout(spec)
        local out = {}
        for _idx, v in ipairs(spec) do
            if v == "-" then
                if out[#out] then out[#out].separator = true end
            else
                v.separator = nil
                out[#out + 1] = v
            end
        end
        return out
    end

    -- A submenu entry made of a list of entries (see layout above).
    local function group(text, spec)
        return {
            text = text,
            keep_menu_open = true,
            sub_item_table = layout(spec),
        }
    end

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

    -- Sleep-screen indicator: the one setting here that is about the sleep
    -- screen rather than about the popups, so it sits at the top with a
    -- divider under it, above the appearance settings that follow.
    I.sleep_indicator = {
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
    }

    I.full_refresh = {
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
    }

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
    I.colors = {
        text = _("Colors"),
        keep_menu_open = true,
        sub_item_table = deps.Colors.buildMenu(),
    }

    -- Unified font settings (name + size) for every text role in both
    -- popups. Same idea as deps.Colors above. Any change here applies to both,
    -- next time each popup is (re)opened.
    I.fonts = {
        text = _("Fonts"),
        keep_menu_open = true,
        separator = true,
        sub_item_table = deps.Fonts.buildMenu(),
    }

    -- "Menu items": tick the popups that should be listed under Tools >
    -- Reading insights (all of them by default).
    local menu_items_sub_item_table = {}
    for _idx, e in ipairs(popup_entries) do
        table.insert(menu_items_sub_item_table, {
            text = e.label,
            keep_menu_open = true,
            checked_func = function()
                return deps.ViewSettings.Opt.readMenuItem(e.key)
            end,
            callback = function()
                deps.ViewSettings.Opt.saveMenuItem(e.key, not deps.ViewSettings.Opt.readMenuItem(e.key))
            end,
        })
    end
    I.menu_items = {
        text = _("Menu items"),
        help_text = _("Tick the popups that should be listed under Tools > Reading insights. The book popups only appear while a book is open."),
        keep_menu_open = true,
        separator = true,
        sub_item_table = menu_items_sub_item_table,
    }

    -- Bar chart heights, now kept with the view each one belongs to:
    --   Reading insight popup > Bar chart height   (automatic, Last 7 days, Months)
    --   Book progress popup > Bar chart height     (chapters, skim bar)
    --
    -- Automatic is on by default: the two Reading insights charts size
    -- themselves so the whole page fits the screen, which is both the best use
    -- of the space and the only way to be sure the scroll bar never shows up.
    -- Switching it off restores the two fixed values, which is why they stay
    -- here (greyed out while automatic is on, so it's obvious they're not in
    -- effect rather than simply being ignored).
    local function barHeightAuto()
        return deps.ViewSettings.Opt.readBarHeightAuto()
    end
    I.insights_heights = {
        text = _("Bar chart height"),
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Automatic"),
                help_text = _("Sizes the Reading insights bar charts so the page fits the screen without a scroll bar."),
                keep_menu_open = true,
                separator = true,
                checked_func = barHeightAuto,
                callback = function(touchmenu_instance)
                    deps.ViewSettings.Opt.saveBarHeightAuto(not barHeightAuto())
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            buildBarHeightMenuEntry(
                _("Last 7 days"),
                deps.ViewSettings.readWeeklyBarHeightSetting,
                deps.ViewSettings.saveWeeklyBarHeightSetting,
                deps.ViewSettings.DEFAULT_WEEKLY_BAR_HEIGHT,
                10, 200,
                function() return not barHeightAuto() end
            ),
            buildBarHeightMenuEntry(
                _("Months"),
                deps.ViewSettings.readMonthlyBarHeightSetting,
                deps.ViewSettings.saveMonthlyBarHeightSetting,
                deps.ViewSettings.DEFAULT_MONTHLY_BAR_HEIGHT,
                10, 200,
                function() return not barHeightAuto() end
            ),
        },
    }
    I.book_heights = {
        text = _("Bar chart height"),
        keep_menu_open = true,
        sub_item_table = {
            buildBarHeightMenuEntry(
                _("Chapters"),
                deps.ChapterBar.readHeightSetting,
                deps.ChapterBar.saveHeightSetting,
                deps.ChapterBar.DEFAULT_HEIGHT,
                10, 200
            ),
            buildBarHeightMenuEntry(
                _("Skim bar"),
                deps.SkimBar.readHeightSetting,
                deps.SkimBar.saveHeightSetting,
                deps.SkimBar.DEFAULT_HEIGHT,
                deps.SkimBar.MIN_HEIGHT, deps.SkimBar.MAX_HEIGHT
            ),
        },
    }


    -- Affects every duration this plugin prints, in all the popups, so it
    -- lives under General rather than in one of the per-view groups.
    I.long_durations = {
        text         = _("Show long durations (24h+) as days"),
        separator    = true,
        keep_menu_open = true,
        checked_func = function() return deps.Locale.readDurationDaysSetting() end,
        callback     = function()
            deps.Locale.saveDurationDaysSetting(not deps.Locale.readDurationDaysSetting())
        end,
    }

    -- "Date & time": how clock times and dates are spelled out, wherever
    -- the plugin prints one. Filled in here; the date-format entry is added
    -- further down.
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

    -- Extra "Week" column (ISO week number) on the Reading streak calendar
    -- and the Book progress calendar. Off by default - see
    -- ViewSettings.readShowWeekNumbers.
    table.insert(date_time_sub_item_table, {
        text = _("Show week numbers"),
        help_text = _("Add a \"Week\" column with each row's week number to the reading streak and Book progress calendars."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.readShowWeekNumbers() end,
        callback = function()
            deps.ViewSettings.saveShowWeekNumbers(not deps.ViewSettings.readShowWeekNumbers())
        end,
    })

    -- "Reading insight popup": everything that changes what the insights
    -- popup itself shows. The entries are defined here and grouped under
    -- "Settings menu layout" at the end.

    -- The reading-goal and achievements sections of the popup, each with its
    -- own checkbox. A hidden goal section isn't drawn or queried; the
    -- achievements list stays reachable via "Show Achievements" either way.
    do
        local Opt = deps.ViewSettings.Opt
        I.goal = {
            text = _("Daily / weekly goal"),
            help_text = _("Show the daily and weekly reading time goals above \"Last 7 days\". Long press the section to set the goals."),
            keep_menu_open = true,
            checked_func = function() return deps.ViewSettings.readShowTimeGoals() end,
            callback = function()
                deps.ViewSettings.saveShowTimeGoals(not deps.ViewSettings.readShowTimeGoals())
            end,
        }
        I.goal_bar = {
            text = _("Daily / weekly goal bar"),
            help_text = _("Show a thin progress bar under the daily and weekly goal values."),
            keep_menu_open = true,
            enabled_func = function() return deps.ViewSettings.readShowTimeGoals() end,
            checked_func = function() return deps.ViewSettings.readShowTimeGoalBar() end,
            callback = function()
                deps.ViewSettings.saveShowTimeGoalBar(not deps.ViewSettings.readShowTimeGoalBar())
            end,
        }
        I.reading_goal = {
            text = _("Reading goal"),
            keep_menu_open = true,
            checked_func = function() return Opt.readShowReadingGoal() end,
            callback = function() Opt.saveShowReadingGoal(not Opt.readShowReadingGoal()) end,
        }
        I.achievements = {
            text = _("Achievements"),
            keep_menu_open = true,
            separator = true,
            checked_func = function() return Opt.readShowAchievements() end,
            callback = function() Opt.saveShowAchievements(not Opt.readShowAchievements()) end,
        }
    end

    I.hamburger = {
        text = _("Hamburger menu"),
        help_text = _("Show the hamburger menu (top left of the title bar) with quick access to the streak, heatmap, records and achievements popups."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowHamburgerMenu() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowHamburgerMenu(not deps.ViewSettings.Opt.readShowHamburgerMenu())
        end,
    }

    I.heatmap_months = {
        text_func = function()
            local months = deps.ViewSettings.readHeatmapMonthsSetting()
            local label
            if months == 3 then label = _("3 months")
            elseif months == 6 then label = _("6 months")
            elseif months == 12 then label = _("12 months")
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
            {
                text = _("12 months"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.ViewSettings.readHeatmapMonthsSetting() == 12 end,
                callback = function() deps.ViewSettings.saveHeatmapMonthsSetting(12) end,
            },
        },
    }

    I.time_of_day = {
        text_func = function()
            local style = deps.ViewSettings.readTimeOfDayViewSetting() == "heatmap"
                and _("Heatmap")
                or  _("Chart")
            return _("Time of day view") .. ": " .. style
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Chart"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.readTimeOfDayViewSetting() == "chart"
                end,
                callback = function() deps.ViewSettings.saveTimeOfDayViewSetting("chart") end,
            },
            {
                text = _("Heatmap"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.readTimeOfDayViewSetting() == "heatmap"
                end,
                callback = function() deps.ViewSettings.saveTimeOfDayViewSetting("heatmap") end,
            },
        },
    }

    I.trend_order = {
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
    }

    -- Which end of the "Last 7 days" bar chart today sits at. The default is
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
        I.today_side = {
            text_func = function()
                local side = VSet.readWeeklyBarOrderSetting() == LAST
                    and _("Today on the right")
                    or  _("Today on the left")
                return _("Bar order") .. ": " .. side
            end,
            keep_menu_open = true,
            sub_item_table = {
                orderEntry(FIRST, _("Today on the left")),
                orderEntry(LAST,  _("Today on the right")),
            },
        }
    end

    -- "Last 7 days" chart style: bars (default) or line with dots.
    do
        local VSet = deps.ViewSettings
        local BARS = VSet.WEEKLY_STYLE_BARS
        local LINE = VSet.WEEKLY_STYLE_LINE
        local function weeklyStyleEntry(value, text)
            return {
                text = text,
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return VSet.readWeeklyStyleSetting() == value
                end,
                callback = function() VSet.saveWeeklyStyleSetting(value) end,
            }
        end
        I.weekly_style = {
            text_func = function()
                local v = VSet.readWeeklyStyleSetting() == LINE
                    and _("Line with dots")
                    or  _("Bars")
                return _("Chart style") .. ": " .. v
            end,
            keep_menu_open = true,
            sub_item_table = {
                weeklyStyleEntry(BARS, _("Bars")),
                weeklyStyleEntry(LINE, _("Line with dots")),
            },
        }
    end

    -- Months (yearly) chart style: line with dots (default) or bars.
    do
        local VSet  = deps.ViewSettings
        local LINE  = VSet.MONTHLY_STYLE_LINE
        local BARS  = VSet.MONTHLY_STYLE_BARS
        local function monthlyStyleEntry(value, text)
            return {
                text = text,
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return VSet.readMonthlyStyleSetting() == value
                end,
                callback = function() VSet.saveMonthlyStyleSetting(value) end,
            }
        end
        I.monthly_style = {
            text_func = function()
                local v = VSet.readMonthlyStyleSetting() == BARS
                    and _("Bars")
                    or  _("Line with dots")
                return _("Chart style") .. ": " .. v
            end,
            keep_menu_open = true,
            sub_item_table = {
                monthlyStyleEntry(LINE, _("Line with dots")),
                monthlyStyleEntry(BARS, _("Bars")),
            },
        }
    end

    -- Months (yearly) bar chart layout (bars style only): a single row with all 12 months
    -- (default) or two rows of 6 months.
    do
        local VSet = deps.ViewSettings
        local TWO  = VSet.MONTHLY_LAYOUT_TWO_ROWS
        local ONE  = VSet.MONTHLY_LAYOUT_ONE_ROW
        local function monthlyLayoutEntry(value, text)
            return {
                text = text,
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return VSet.readMonthlyLayoutSetting() == value
                end,
                callback = function() VSet.saveMonthlyLayoutSetting(value) end,
            }
        end
        I.monthly_layout = {
            text_func = function()
                local v = VSet.readMonthlyLayoutSetting() == TWO
                    and _("2 rows of 6 months")
                    or  _("12 months in one row")
                return _("Chart layout") .. ": " .. v
            end,
            keep_menu_open = true,
            sub_item_table = {
                monthlyLayoutEntry(ONE, _("12 months in one row")),
                monthlyLayoutEntry(TWO, _("2 rows of 6 months")),
            },
        }
    end

    -- "Last 7 days" extras: the compact row (total + daily average) is
    -- always shown; the second (time and pages) row and the comparison with
    -- the previous 7 days can each be switched on separately (both off by
    -- default).
    do
        local VSet = deps.ViewSettings
        I.weekly_extra_row = {
            text = _("Time and pages row"),
            help_text = _("Show a second row with the other metric (pages when the chart shows time, time when it shows pages) below the total and daily average."),
            keep_menu_open = true,
            checked_func = function() return VSet.readWeeklyExtraRow() end,
            callback = function() VSet.saveWeeklyExtraRow(not VSet.readWeeklyExtraRow()) end,
        }
        I.weekly_vs_prev = {
            text = _("Comparison with previous 7 days row"),
            help_text = _("Below the chart, show how the total and the daily average changed compared to the 7 days before."),
            keep_menu_open = true,
            checked_func = function() return VSet.readWeeklyVsPrev() end,
            callback = function() VSet.saveWeeklyVsPrev(not VSet.readWeeklyVsPrev()) end,
        }
    end

    -- How often achievements re-evaluate in the background: once a day
    -- (default) or on every popup open. Either way the heavy re-scan only
    -- runs when the reading data actually changed since the last check.
    do
        local Opt   = deps.ViewSettings.Opt
        local DAILY = Opt.ACH_REFRESH_DAILY
        local EVERY = Opt.ACH_REFRESH_EVERY
        local function refreshEntry(value, text)
            return {
                text = text,
                keep_menu_open = true,
                radio = true,
                checked_func = function() return Opt.readAchievementRefresh() == value end,
                callback = function() Opt.saveAchievementRefresh(value) end,
            }
        end
        I.ach_refresh = {
            text_func = function()
                local mode = Opt.readAchievementRefresh() == EVERY
                    and _("Every open")
                    or  _("Once a day")
                return _("Achievement refresh") .. ": " .. mode
            end,
            keep_menu_open = true,
            sub_item_table = {
                refreshEntry(DAILY, _("Once a day")),
                refreshEntry(EVERY, _("Every open")),
            },
        }
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

    -- "Date & time" is a group of its own directly under Settings.
    I.date_time = {
        text = _("Date & time"),
        keep_menu_open = true,
        sub_item_table = date_time_sub_item_table,
    }

    -- "Book progress popup": what the Book progress popup itself shows.
    -- Two on/off toggles for optional rows, both on by default (see
    -- deps.ViewSettings.Opt.readShowChapterBar / readShowPaceDates and the
    -- gates in book_stats_view.lua).
    -- Where the popup sits: hanging from the top edge, full width (the
    -- original look), or as a bordered box in the middle of the screen at
    -- the same width as the Book progress calendar.
    I.bp_position = {
        text_func = function()
            local Opt = deps.ViewSettings.Opt
            local pos = (Opt.readBookPopupPosition() == Opt.BOOK_POPUP_POSITION_CENTER)
                and _("Centered") or _("Top of the screen")
            return _("Popup position") .. ": " .. pos
        end,
        keep_menu_open = true,
        separator = true,
        sub_item_table = {
            {
                text = _("Top of the screen"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    local Opt = deps.ViewSettings.Opt
                    return Opt.readBookPopupPosition() == Opt.BOOK_POPUP_POSITION_TOP
                end,
                callback = function()
                    local Opt = deps.ViewSettings.Opt
                    Opt.saveBookPopupPosition(Opt.BOOK_POPUP_POSITION_TOP)
                end,
            },
            {
                text = _("Centered"),
                help_text = _("A bordered box in the middle of the screen, as wide as the Book progress calendar."),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    local Opt = deps.ViewSettings.Opt
                    return Opt.readBookPopupPosition() == Opt.BOOK_POPUP_POSITION_CENTER
                end,
                callback = function()
                    local Opt = deps.ViewSettings.Opt
                    Opt.saveBookPopupPosition(Opt.BOOK_POPUP_POSITION_CENTER)
                end,
            },
        },
    }

    -- "This book" section style: the original rows, or a donut (default)
    -- chart with the read percentage on the left and pages / time read /
    -- time left stacked on the right (widgets/donutwidget.lua).
    I.bp_style = {
        text_func = function()
            local Opt = deps.ViewSettings.Opt
            local style = (Opt.readBookSectionStyle() == Opt.BOOK_SECTION_STYLE_DONUT)
                and _("Donut chart") or _("Classic")
            return _("Book section style") .. ": " .. style
        end,
        help_text = _("How the \"This book\" section looks. \"Classic\" keeps the rows and the progress bar. \"Donut chart\" shows a large donut with the read percentage on the left and the pages, the time read and the reading time left stacked on the right (the progress bar is replaced by the donut)."),
        keep_menu_open = true,
        separator = true,
        sub_item_table = {
            {
                text = _("Classic"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    local Opt = deps.ViewSettings.Opt
                    return Opt.readBookSectionStyle() == Opt.BOOK_SECTION_STYLE_CLASSIC
                end,
                callback = function()
                    local Opt = deps.ViewSettings.Opt
                    Opt.saveBookSectionStyle(Opt.BOOK_SECTION_STYLE_CLASSIC)
                end,
            },
            {
                text = _("Donut chart"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    local Opt = deps.ViewSettings.Opt
                    return Opt.readBookSectionStyle() == Opt.BOOK_SECTION_STYLE_DONUT
                end,
                callback = function()
                    local Opt = deps.ViewSettings.Opt
                    Opt.saveBookSectionStyle(Opt.BOOK_SECTION_STYLE_DONUT)
                end,
            },
        },
    }

    -- Which parts of each section are shown. When every part of a section is
    -- off, its header disappears too (chapter section, "This book", "Pace").
    I.this_chapter = {
        text = _("This chapter"),
        help_text = _("Show the \"This chapter\" column (reading time or pages left in the chapter). If this and \"Next chapter\" are both off, the whole chapter section is hidden."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowChapterCurrent() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowChapterCurrent(not deps.ViewSettings.Opt.readShowChapterCurrent())
        end,
    }

    I.next_chapter = {
        text = _("Next chapter"),
        help_text = _("Show the \"Next chapter\" column. If this and \"This chapter\" are both off, the whole chapter section is hidden."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowChapterNext() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowChapterNext(not deps.ViewSettings.Opt.readShowChapterNext())
        end,
    }

    -- How many upcoming chapters that column's reading-time estimate covers.
    -- Only changes anything in the reading-time view (not the tap-to-toggle
    -- pages view), and only when a chapter after the next one actually
    -- exists - otherwise it quietly behaves like "1".
    I.next_count = {
        text = _("Next chapters shown"),
        help_text = _("How many upcoming chapters the \"Next chapter\" column's reading-time estimate covers. With \"2\", once a second chapter follows the next one, the header switches to \"Next 2 chapters\" and shows both chapters' times, e.g. \"00:10 | 00:28\". Falls back to a single chapter when there is no chapter after the next one, or no next chapter at all."),
        separator = true,
        sub_item_table = {
            {
                text = _("1 (default)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.ViewSettings.Opt.readNextChapterCount() == 1 end,
                callback = function() deps.ViewSettings.Opt.saveNextChapterCount(1) end,
            },
            {
                text = _("2"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.ViewSettings.Opt.readNextChapterCount() == 2 end,
                callback = function() deps.ViewSettings.Opt.saveNextChapterCount(2) end,
            },
        },
    }


    -- With the "Donut chart" Book section style the donut row always shows
    -- the pages and the times, so the two toggles below are greyed out and
    -- displayed as checked. The saved values are left untouched: switching
    -- back to "Classic" restores whatever was set there.
    local function isDonutStyle()
        local Opt = deps.ViewSettings.Opt
        return Opt.readBookSectionStyle() == Opt.BOOK_SECTION_STYLE_DONUT
    end

    I.read_row = {
        text = _("Read row"),
        help_text = _("Show the row with the read percentage and page count in the \"This book\" section. If every part of the section is off, its header is hidden too."),
        keep_menu_open = true,
        enabled_func = function() return not isDonutStyle() end,
        checked_func = function() return isDonutStyle() or deps.ViewSettings.Opt.readShowBookReadRow() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowBookReadRow(not deps.ViewSettings.Opt.readShowBookReadRow())
        end,
    }

    I.time_row = {
        text = _("Reading time row"),
        help_text = _("Show the row with the time read so far and the reading time left in the \"This book\" section. If every part of the section is off, its header is hidden too."),
        keep_menu_open = true,
        enabled_func = function() return not isDonutStyle() end,
        checked_func = function() return isDonutStyle() or deps.ViewSettings.Opt.readShowBookTimeRow() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowBookTimeRow(not deps.ViewSettings.Opt.readShowBookTimeRow())
        end,
    }

    I.chapter_bar = {
        text = _("Chapter bar"),
        help_text = _("Show the chapter bar chart in the \"This book\" section."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowChapterBar() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowChapterBar(not deps.ViewSettings.Opt.readShowChapterBar())
        end,
    }

    I.chapter_count_row = {
        text = _("Chapter count row"),
        help_text = _("Show the number of chapters read and the typical chapter length under the chapter bar chart. Tap the typical chapter length in the popup to switch between time and pages."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowChapterCountRow() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowChapterCountRow(not deps.ViewSettings.Opt.readShowChapterCountRow())
        end,
    }

    -- Chapter bar style: the per-chapter bar chart (default), or a single
    -- bar drawn like KOReader's "Skim to" dialog (widgets/skimbarwidget.lua),
    -- in the plugin's active / inactive colors.
    do
        local function styleEntry(text, help, style)
            return {
                text = text,
                help_text = help,
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return deps.ViewSettings.Opt.readChapterBarStyle() == style
                end,
                callback = function()
                    deps.ViewSettings.Opt.saveChapterBarStyle(style)
                end,
            }
        end
        local Opt = deps.ViewSettings.Opt
        I.chapter_bar_style = {
            text_func = function()
                local name = (Opt.readChapterBarStyle() == Opt.CHAPTER_BAR_STYLE_SKIM)
                    and _("Skim bar") or _("Chapter bars")
                return _("Chapter bar style") .. ": " .. name
            end,
            help_text = _("Choose how the chapter bar is drawn: one bar per chapter, or a single bar like the one in KOReader's \"Skim to\" dialog."),
            keep_menu_open = true,
            sub_item_table = {
                styleEntry(_("Chapter bars"),
                    _("One bar per chapter, as tall as the chapter is long."),
                    Opt.CHAPTER_BAR_STYLE_BARS),
                styleEntry(_("Skim bar"),
                    _("A single bar like KOReader's \"Skim to\" dialog: filled up to the current page, chapter separators and the position marker. Uses the active and inactive bar colors."),
                    Opt.CHAPTER_BAR_STYLE_SKIM),
            },
        }
    end

    -- Chapters per page: how many chapter columns the chapter bar shows at
    -- once before the arrows/swipe page to the next batch (ChapterBar.PAGE_SIZE
    -- was hardcoded to 25). "All chapters" (no paging), four preset radio
    -- choices plus a "Custom value…"
    -- entry that opens a SpinWidget for anything in between; the header shows
    -- whichever value is in force.
    do
        local presets = { 10, 25, 35, 50 }
        local function presetEntry(n)
            return {
                text = tostring(n),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return deps.ChapterBar.readPageSizeSetting() == n end,
                callback = function() deps.ChapterBar.savePageSizeSetting(n) end,
            }
        end
        local page_size_sub_item_table = {}
        -- "All chapters": one column per chapter, no paging (no 100 cap).
        table.insert(page_size_sub_item_table, {
            text = _("All chapters"),
            help_text = _("Draw every chapter in one row, without paging."),
            keep_menu_open = true,
            radio = true,
            checked_func = function() return deps.ChapterBar.isAllChapters() end,
            callback = function() deps.ChapterBar.savePageSizeSetting(deps.ChapterBar.PAGE_SIZE_ALL) end,
        })
        for _idx, n in ipairs(presets) do
            table.insert(page_size_sub_item_table, presetEntry(n))
        end
        table.insert(page_size_sub_item_table, {
            text_func = function()
                if deps.ChapterBar.isAllChapters() then return _("Custom value") end
                return _("Custom value") .. ": " .. tostring(deps.ChapterBar.readPageSizeSetting())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text    = _("Chapters per page"),
                    value         = deps.ChapterBar.isAllChapters() and deps.ChapterBar.DEFAULT_PAGE_SIZE
                                    or deps.ChapterBar.readPageSizeSetting(),
                    value_min     = deps.ChapterBar.MIN_PAGE_SIZE,
                    value_max     = deps.ChapterBar.MAX_PAGE_SIZE,
                    value_step    = 1,
                    value_hold_step = 5,
                    default_value = deps.ChapterBar.DEFAULT_PAGE_SIZE,
                    ok_text       = _("Set"),
                    callback      = function(spin)
                        deps.ChapterBar.savePageSizeSetting(spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        })
        I.chapters_per_page = {
            text_func = function()
                if deps.ChapterBar.isAllChapters() then
                    return _("Chapters per page") .. ": " .. _("All chapters")
                end
                return _("Chapters per page") .. ": " .. tostring(deps.ChapterBar.readPageSizeSetting())
            end,
            help_text = _("How many chapters the chapter bar shows at once before paging with the arrows."),
            keep_menu_open = true,
            sub_item_table = page_size_sub_item_table,
        }
    end

    -- "Progress bar": the thin bar under the book percentage (lib/uikit.lua, UI.withCellBar / UI.buildRowBar). They use the chart's
    -- active / inactive bar colors (Colors menu), so there are no separate
    -- color or height settings.
    I.progress_bar = {
        text = _("Progress bar"),
        help_text = _("Show a thin progress bar under the book percentage."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowCellBars() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowCellBars(not deps.ViewSettings.Opt.readShowCellBars())
        end,
    }

    I.read_today = {
        text = _("Read today row"),
        help_text = _("Show the row with today's reading time and the average time per day in the \"Pace\" section. If this and the started / expected finish row are both off, the whole \"Pace\" section is hidden."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowPaceToday() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowPaceToday(not deps.ViewSettings.Opt.readShowPaceToday())
        end,
    }

    I.pace_dates = {
        text = _("Started / expected finish row"),
        help_text = _("Show the \"started …\" and \"expected finish\" date row in the \"Pace\" section."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowPaceDates() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowPaceDates(not deps.ViewSettings.Opt.readShowPaceDates())
        end,
    }

    -- "Book info" popup: which parts of the small cover + title / author /
    -- series popup are shown. Cover frame options (rounded corners, shadow,
    -- border) only matter while the cover itself is on, so they grey out
    -- with it. Fonts live under Settings > Fonts > Book info.
    local function bookInfoToggle(name, text, help_text, depends_on_cover, separator)
        return {
            text = text,
            help_text = help_text,
            keep_menu_open = true,
            separator = separator,
            enabled_func = depends_on_cover and function()
                return deps.ViewSettings.Opt.readBookInfo("cover")
            end or nil,
            checked_func = function()
                return deps.ViewSettings.Opt.readBookInfo(name)
            end,
            callback = function()
                deps.ViewSettings.Opt.saveBookInfo(name, not deps.ViewSettings.Opt.readBookInfo(name))
            end,
        }
    end
    -- Cover size: small (50%) / medium (100%, default) / large (150%).
    -- Greyed out together with the cover itself.
    local function coverSizeRadio(size, text)
        return {
            text = text,
            keep_menu_open = true,
            radio = true,
            checked_func = function()
                return deps.ViewSettings.Opt.readBookInfoCoverSize() == size
            end,
            callback = function()
                deps.ViewSettings.Opt.saveBookInfoCoverSize(size)
            end,
        }
    end
    local coverSizeItem = {
        text_func = function()
            local Opt = deps.ViewSettings.Opt
            local size = Opt.readBookInfoCoverSize()
            local label = (size == Opt.BOOK_INFO_COVER_SIZE_SMALL and _("Small"))
                or (size == Opt.BOOK_INFO_COVER_SIZE_LARGE and _("Large"))
                or _("Medium")
            return _("Cover size") .. ": " .. label
        end,
        help_text = _("Size of the cover in the Book info popup. Medium is the default size; Small is half of it and Large is one and a half times it."),
        keep_menu_open = true,
        enabled_func = function()
            return deps.ViewSettings.Opt.readBookInfo("cover")
        end,
        sub_item_table = {
            coverSizeRadio(deps.ViewSettings.Opt.BOOK_INFO_COVER_SIZE_SMALL, _("Small")),
            coverSizeRadio(deps.ViewSettings.Opt.BOOK_INFO_COVER_SIZE_MEDIUM, _("Medium")),
            coverSizeRadio(deps.ViewSettings.Opt.BOOK_INFO_COVER_SIZE_LARGE, _("Large")),
        },
    }
    local book_info_sub_item_table = {
        bookInfoToggle("cover", _("Show cover"),
            _("Show the book's cover on the left."),
            false, true),
        coverSizeItem,
        bookInfoToggle("rounded", _("Rounded corners"),
            _("Round the corners of the cover."), true),
        bookInfoToggle("shadow", _("Cover shadow"),
            _("Draw a drop shadow behind the cover."), true),
        bookInfoToggle("border", _("Cover border"),
            _("Draw a thin frame around the cover."), true, true),
        bookInfoToggle("author", _("Show author"),
            _("Show the author line. Several authors are joined with a language-appropriate \"and\"."), false),
        bookInfoToggle("series", _("Show series"),
            _("Show the series line (series name and the book's number in it) when the book is part of a series."), false),
        bookInfoToggle("description", _("Show description"),
            _("Show the book's description under the author / series, as far down as the bottom of the cover, cut with an ellipsis when it does not fit. Tap it to read the full description. While this is on, the popup is as wide as it can be."), false),
    }

    I.book_info = {
        text = _("Book info"),
        keep_menu_open = true,
        sub_item_table = book_info_sub_item_table,
    }

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

    I.book_calendar_settings = {
        text = _("Book progress calendar"),
        keep_menu_open = true,
        separator = true,
        sub_item_table = book_calendar_sub_item_table,
    }

    -- Settings menu layout, top to bottom:
    --
    --   Date & time                how dates, times and weeks are shown
    --   Appearance                 colors and fonts
    --   -------------------------
    --   one group per view         Reading insight popup, Heatmap & time of
    --                              day, Book progress popup, Book progress
    --                              calendar, Book info
    --   -------------------------
    --   Advanced settings          behaviour that isn't about one popup:
    --                              sleep screen, refresh, long durations,
    --                              which popups the Tools menu lists
    --
    -- Bar chart heights sit with the view they belong to: Reading insight
    -- popup > Bar chart height, Book progress popup > Bar chart height.
    local insights_popup_sub_item_table = layout({
        I.hamburger,
        "-",
        I.goal, I.goal_bar, I.reading_goal, I.achievements, I.ach_refresh,
        "-",
        group(_("Last 7 days"), {
            I.weekly_style, I.today_side, I.weekly_extra_row, I.weekly_vs_prev,
            I.trend_order,
        }),
        group(_("Months"), { I.monthly_style, I.monthly_layout }),
        I.insights_heights,
    })

    local book_progress_sub_item_table = layout({
        I.bp_position, I.bp_style,
        "-",
        group(_("Chapters"), {
            I.this_chapter, I.next_chapter, I.next_count,
            "-",
            I.chapter_bar, I.chapter_bar_style, I.chapters_per_page,
            I.chapter_count_row,
        }),
        group(_("This book"), { I.read_row, I.time_row, I.progress_bar }),
        group(_("Pace"), { I.read_today, I.pace_dates }),
        I.book_heights,
    })

    local settings_sub_item_table = layout({
        I.date_time,
        group(_("Appearance"), { I.colors, I.fonts }),
        "-",
        {
            text = _("Reading insight popup"),
            keep_menu_open = true,
            sub_item_table = insights_popup_sub_item_table,
        },
        group(_("Heatmap & time of day"), { I.heatmap_months, I.time_of_day }),
        {
            text = _("Book progress popup"),
            keep_menu_open = true,
            sub_item_table = book_progress_sub_item_table,
        },
        I.book_calendar_settings,
        I.book_info,
        "-",
        group(_("Advanced settings"), {
            I.sleep_indicator, I.full_refresh, I.long_durations,
            "-",
            I.menu_items,
        }),
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
        sub_item_table_func = function()
            local items = buildPopupEntries()
            for _idx, item in ipairs(sub_item_table) do
                table.insert(items, item)
            end
            return items
        end,
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
