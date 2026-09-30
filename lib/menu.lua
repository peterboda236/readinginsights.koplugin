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
    -- The "Show ..." entries. Which of them are listed is set under
    -- Settings > Advanced settings > "Menu items"; the list is rebuilt each
    -- time the menu opens (sub_item_table_func at the bottom), so a change
    -- shows up right away. The three book entries also need an open book.
    local popup_entries = {
        { key = "insights",      label = _("Reading insights"),
          text = _("Show Reading insights"),
          open = function() self:onShowReadingInsightsPopup() end },
        { key = "streak",        label = _("Reading streak"),
          text = _("Show Reading streak"),
          open = function() self:onShowReadingStreakPopup() end },
        { key = "heatmap",       label = _("Reading heatmap"),
          text = _("Show Reading heatmap"),
          open = function() self:onShowReadingHeatmapPopup() end },
        { key = "records",       label = _("Records"),
          text = _("Show Records"),
          open = function() self:onShowReadingRecordsPopup() end },
        { key = "achievements",  label = _("Achievements"),
          text = _("Show Achievements"),
          open = function() self:onShowReadingAchievements() end },
        { key = "book_progress", label = _("Book progress"), book = true,
          text = _("Show Book progress"),
          open = function() self:onShowReadingStatsPopup() end },
        { key = "book_info",     label = _("Book info"), book = true,
          text = _("Show Book info"),
          open = function() self:onShowBookInfoPopup() end },
        { key = "book_calendar", label = _("Book progress calendar"), book = true,
          text = _("Show Book progress calendar"),
          open = function() self:onShowBookCalendarPopup() end },
    }

    local function buildPopupEntries()
        local items = {}
        local has_open_document = self:_hasOpenDocument()
        for _idx, e in ipairs(popup_entries) do
            if deps.ViewSettings.Opt.readMenuItem(e.key)
                and (has_open_document or not e.book) then
                table.insert(items, {
                    text = e.text,
                    keep_menu_open = false,
                    callback = e.open,
                })
            end
        end
        -- Separator after the "open a popup" entries, before the
        -- settings submenu below.
        if #items > 0 then items[#items].separator = true end
        return items
    end

    -- Everything below the popup entries (Settings, Updates, About).
    local sub_item_table = {}

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

    -- Settings menu layout, top to bottom:
    --   Sleep-screen indicator, Full-screen refresh      (behaviour)
    --   Colors, Fonts                                    (appearance)
    --   ---------------------------------------------
    --   Reading insight popup, Book progress popup,
    --   Book progress calendar                           (one submenu per view)
    --   ---------------------------------------------
    --   Advanced settings                                (less commonly touched)
    --
    -- "Advanced settings" holds what applies to everything the plugin
    -- draws: bar chart height, long durations as days, and the "Date &
    -- time" group (how dates and times are spelled out anywhere). The
    -- divider above the per-view block is the one set on the "Fonts"
    -- entry; the divider under it is set on "Book progress calendar".
    local advanced_settings_sub_item_table = {}

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
    table.insert(advanced_settings_sub_item_table, {
        text = _("Menu items"),
        help_text = _("Tick the popups that should be listed under Tools > Reading insights. The book popups only appear while a book is open."),
        keep_menu_open = true,
        separator = true,
        sub_item_table = menu_items_sub_item_table,
    })

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
            -- The skim-style chapter bar's height lives here with the other
            -- chart heights (it used to sit under Book progress popup >
            -- Chapter bar style).
            buildBarHeightMenuEntry(
                _("Book progress") .. ": " .. _("Skim bar"),
                deps.SkimBar.readHeightSetting,
                deps.SkimBar.saveHeightSetting,
                deps.SkimBar.DEFAULT_HEIGHT,
                deps.SkimBar.MIN_HEIGHT, deps.SkimBar.MAX_HEIGHT
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
    -- popup itself shows. Inserted into Advanced settings below, after the
    -- "Date & time" group.
    local insights_popup_sub_item_table = {}

    -- What the reading-goal section shows: the goal + achievements, the goal
    -- only (old two-cell view), or nothing. When off it isn't drawn or
    -- queried; achievements stay reachable via "Show Achievements".
    do
        local Opt  = deps.ViewSettings.Opt
        local BOTH = Opt.GOAL_MODE_BOTH
        local GOAL = Opt.GOAL_MODE_GOAL
        local OFF  = Opt.GOAL_MODE_OFF
        local function modeEntry(value, text)
            return {
                text = text,
                keep_menu_open = true,
                radio = true,
                checked_func = function() return Opt.readGoalSectionMode() == value end,
                callback = function() Opt.saveGoalSectionMode(value) end,
            }
        end
        table.insert(insights_popup_sub_item_table, {
            text_func = function()
                local m = Opt.readGoalSectionMode()
                local label = (m == GOAL and _("Reading goal only"))
                    or (m == OFF and _("Off"))
                    or _("Reading goal & achievements")
                return _("Reading goal section") .. ": " .. label
            end,
            keep_menu_open = true,
            separator = true,
            sub_item_table = {
                modeEntry(BOTH, _("Reading goal & achievements")),
                modeEntry(GOAL, _("Reading goal only")),
                modeEntry(OFF,  _("Off")),
            },
        })
    end

    table.insert(insights_popup_sub_item_table, {
        text = _("Hamburger menu"),
        help_text = _("Show the hamburger menu (top left of the title bar) with quick access to the streak, heatmap, records and achievements popups."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowHamburgerMenu() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowHamburgerMenu(not deps.ViewSettings.Opt.readShowHamburgerMenu())
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
        table.insert(insights_popup_sub_item_table, {
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

    -- "Date & time" closes off Advanced settings; the three per-view groups
    -- go directly into the Settings menu, under Fonts.
    table.insert(advanced_settings_sub_item_table, {
        text = _("Date & time"),
        keep_menu_open = true,
        sub_item_table = date_time_sub_item_table,
    })

    table.insert(settings_sub_item_table, {
        text = _("Reading insight popup"),
        keep_menu_open = true,
        sub_item_table = insights_popup_sub_item_table,
    })

    -- "Book progress popup": what the Book progress popup itself shows.
    -- Two on/off toggles for optional rows, both on by default (see
    -- deps.ViewSettings.Opt.readShowChapterBar / readShowPaceDates and the
    -- gates in book_stats_view.lua).
    local book_progress_sub_item_table = {}

    -- Where the popup sits: hanging from the top edge, full width (the
    -- original look), or as a bordered box in the middle of the screen at
    -- the same width as the Book progress calendar.
    table.insert(book_progress_sub_item_table, {
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
    })

    -- "This book" section style: the original rows, or a donut (default)
    -- chart with the read percentage on the left and pages / time read /
    -- time left stacked on the right (widgets/donutwidget.lua).
    table.insert(book_progress_sub_item_table, {
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
    })

    -- Which parts of each section are shown. When every part of a section is
    -- off, its header disappears too (chapter section, "This book", "Pace").
    table.insert(book_progress_sub_item_table, {
        text = _("This chapter"),
        help_text = _("Show the \"This chapter\" column (reading time or pages left in the chapter). If this and \"Next chapter\" are both off, the whole chapter section is hidden."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowChapterCurrent() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowChapterCurrent(not deps.ViewSettings.Opt.readShowChapterCurrent())
        end,
    })

    table.insert(book_progress_sub_item_table, {
        text = _("Next chapter"),
        help_text = _("Show the \"Next chapter\" column. If this and \"This chapter\" are both off, the whole chapter section is hidden."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowChapterNext() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowChapterNext(not deps.ViewSettings.Opt.readShowChapterNext())
        end,
    })

    -- How many upcoming chapters that column's reading-time estimate covers.
    -- Only changes anything in the reading-time view (not the tap-to-toggle
    -- pages view), and only when a chapter after the next one actually
    -- exists - otherwise it quietly behaves like "1".
    table.insert(book_progress_sub_item_table, {
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
    })


    -- With the "Donut chart" Book section style the donut row always shows
    -- the pages and the times, so the two toggles below are greyed out and
    -- displayed as checked. The saved values are left untouched: switching
    -- back to "Classic" restores whatever was set there.
    local function isDonutStyle()
        local Opt = deps.ViewSettings.Opt
        return Opt.readBookSectionStyle() == Opt.BOOK_SECTION_STYLE_DONUT
    end

    table.insert(book_progress_sub_item_table, {
        text = _("Read row"),
        help_text = _("Show the row with the read percentage and page count in the \"This book\" section. If every part of the section is off, its header is hidden too."),
        keep_menu_open = true,
        enabled_func = function() return not isDonutStyle() end,
        checked_func = function() return isDonutStyle() or deps.ViewSettings.Opt.readShowBookReadRow() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowBookReadRow(not deps.ViewSettings.Opt.readShowBookReadRow())
        end,
    })

    table.insert(book_progress_sub_item_table, {
        text = _("Reading time row"),
        help_text = _("Show the row with the time read so far and the reading time left in the \"This book\" section. If every part of the section is off, its header is hidden too."),
        keep_menu_open = true,
        enabled_func = function() return not isDonutStyle() end,
        checked_func = function() return isDonutStyle() or deps.ViewSettings.Opt.readShowBookTimeRow() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowBookTimeRow(not deps.ViewSettings.Opt.readShowBookTimeRow())
        end,
    })

    table.insert(book_progress_sub_item_table, {
        text = _("Chapter bar"),
        help_text = _("Show the chapter bar chart in the \"This book\" section."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowChapterBar() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowChapterBar(not deps.ViewSettings.Opt.readShowChapterBar())
        end,
    })

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
        table.insert(book_progress_sub_item_table, {
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
        })
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
        table.insert(book_progress_sub_item_table, {
            text_func = function()
                if deps.ChapterBar.isAllChapters() then
                    return _("Chapters per page") .. ": " .. _("All chapters")
                end
                return _("Chapters per page") .. ": " .. tostring(deps.ChapterBar.readPageSizeSetting())
            end,
            help_text = _("How many chapters the chapter bar shows at once before paging with the arrows."),
            keep_menu_open = true,
            sub_item_table = page_size_sub_item_table,
        })
    end

    -- "Progress bar": the filled bar shown between the "This book" header
    -- and the percentage row (widgets/progressbarwidget.lua). On/off toggle
    -- and the bar's height live here; its two colors moved to the top-level
    -- Colors menu (Colors > Book progress bar), alongside every other color
    -- in the plugin, instead of being duplicated here.
    do
        local progress_bar_sub_item_table = {}

        table.insert(progress_bar_sub_item_table, {
            text = _("Show progress bar"),
            help_text = _("Show the progress bar in the \"This book\" section."),
            keep_menu_open = true,
            checked_func = function() return deps.ViewSettings.Opt.readShowProgressBar() end,
            callback = function()
                deps.ViewSettings.Opt.saveShowProgressBar(not deps.ViewSettings.Opt.readShowProgressBar())
            end,
        })

        table.insert(progress_bar_sub_item_table, buildBarHeightMenuEntry(
            _("Progress bar height"),
            deps.ProgressBar.readHeightSetting,
            deps.ProgressBar.saveHeightSetting,
            deps.ProgressBar.DEFAULT_HEIGHT,
            1, 200
        ))

        -- Greyed out with the "Donut chart" section style: the donut
        -- replaces the linear progress bar, so its settings have no effect.
        table.insert(book_progress_sub_item_table, {
            text = _("Progress bar"),
            keep_menu_open = true,
            enabled_func = function()
                local Opt = deps.ViewSettings.Opt
                return Opt.readBookSectionStyle() ~= Opt.BOOK_SECTION_STYLE_DONUT
            end,
            sub_item_table = progress_bar_sub_item_table,
        })
    end

    table.insert(book_progress_sub_item_table, {
        text = _("Read today row"),
        help_text = _("Show the row with today's reading time and the average time per day in the \"Pace\" section. If this and the started / expected finish row are both off, the whole \"Pace\" section is hidden."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowPaceToday() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowPaceToday(not deps.ViewSettings.Opt.readShowPaceToday())
        end,
    })

    table.insert(book_progress_sub_item_table, {
        text = _("Started / expected finish row"),
        help_text = _("Show the \"started …\" and \"expected finish\" date row in the \"Pace\" section."),
        keep_menu_open = true,
        checked_func = function() return deps.ViewSettings.Opt.readShowPaceDates() end,
        callback = function()
            deps.ViewSettings.Opt.saveShowPaceDates(not deps.ViewSettings.Opt.readShowPaceDates())
        end,
    })

    table.insert(settings_sub_item_table, {
        text = _("Book progress popup"),
        keep_menu_open = true,
        sub_item_table = book_progress_sub_item_table,
    })

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

    table.insert(settings_sub_item_table, {
        text = _("Book info"),
        keep_menu_open = true,
        sub_item_table = book_info_sub_item_table,
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

    table.insert(settings_sub_item_table, {
        text = _("Book progress calendar"),
        keep_menu_open = true,
        separator = true,
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
