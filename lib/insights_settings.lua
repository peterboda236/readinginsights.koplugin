--[[
Reading Insights - settings for the insights view.

Every user-settable option the insights popup reads or writes, in one
place: the Tools-menu toggles (full-screen refresh, 8-week chart order),
the bar-chart heights and their automatic mode, the heatmap options, the
per-year reading goal and its manual finished-book overrides, the week
start day, and the two "which numbers am I looking at" display modes
(monthly chart mode, weekly chart mode) that are persisted the same way.

Split out of insights_view.lua, which was carrying ~50 settings accessors
as top-level locals - close enough to Lua's limit of 200 per scope that the
next feature would have failed to compile. Everything here is a field on one
table, so it costs the view a single local however many options are added.
]]--

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Prefs =
    deps.Prefs

local M = {}

-- Prefs keys
M.SETTINGS_KEY_FULL_REFRESH   = "reading_insights_full_refresh_on_open_close"

M.SETTINGS_KEY_8W_ASCENDING   = "reading_insights_8week_ascending"

-- Generic boolean-setting reader/writer; replaces the previous 4 near-identical
-- read/save*Setting functions that only differed by key and default.
function M.readBoolSetting(key, default)
    return Prefs.readBool(key, default)
end

function M.saveBoolSetting(key, value)
    Prefs.save(key, value)
end

function M.readFullRefreshSetting()
    return M.readBoolSetting(M.SETTINGS_KEY_FULL_REFRESH, false)
end

function M.readAscendingSetting()
    -- default: ascending (oldest on the left)
    return M.readBoolSetting(M.SETTINGS_KEY_8W_ASCENDING, true)
end

function M.saveFullRefreshSetting(value)
    M.saveBoolSetting(M.SETTINGS_KEY_FULL_REFRESH, value)
end

function M.saveAscendingSetting(value)
    M.saveBoolSetting(M.SETTINGS_KEY_8W_ASCENDING, value)
end

-- Bar-chart height settings (Prefs ▸ "Oszlopdiagram magassága" / "Bar
-- chart height"). Values are the same "points" number previously hardcoded
-- into Screen:scaleBySize(...) at each chart's call site, so restoring the
-- default here reproduces the exact original look.
--
-- Renamed from reading_insights_weekly_bar_height /
-- reading_insights_monthly_bar_height (default 44) to the _v2 keys below
-- (default 30): a plain default-constant change only affects users who
-- never touched this setting - anyone who had already saved a value (even
-- one that happened to equal the old default) would keep it forever.
-- Reading from a brand-new, never-before-saved key means *everyone* -
-- including previous customizers - starts fresh from the new default after
-- upgrading. The old keys are simply left orphaned in the settings file.
M.SETTINGS_KEY_WEEKLY_BAR_HEIGHT  = "reading_insights_weekly_bar_height_v2"

M.SETTINGS_KEY_MONTHLY_BAR_HEIGHT = "reading_insights_monthly_bar_height_v2"

M.DEFAULT_WEEKLY_BAR_HEIGHT  = 30

M.DEFAULT_MONTHLY_BAR_HEIGHT = 30

function M.readNumSetting(key, default)
    return Prefs.readNum(key, default)
end

function M.saveNumSetting(key, value)
    Prefs.save(key, value)
end

function M.readWeeklyBarHeightSetting()
    return M.readNumSetting(M.SETTINGS_KEY_WEEKLY_BAR_HEIGHT, M.DEFAULT_WEEKLY_BAR_HEIGHT)
end

function M.saveWeeklyBarHeightSetting(value)
    M.saveNumSetting(M.SETTINGS_KEY_WEEKLY_BAR_HEIGHT, value)
end

function M.readMonthlyBarHeightSetting()
    return M.readNumSetting(M.SETTINGS_KEY_MONTHLY_BAR_HEIGHT, M.DEFAULT_MONTHLY_BAR_HEIGHT)
end

function M.saveMonthlyBarHeightSetting(value)
    M.saveNumSetting(M.SETTINGS_KEY_MONTHLY_BAR_HEIGHT, value)
end

-- Newer view options, kept on one table for the reason in the header: a
-- field costs no local, a top-level `local` costs one of the 200.
M.Opt = {
    -- Bar-chart height mode (Settings > Advanced settings > "Bar chart
    -- height" > "Automatic (Reading insights)").
    --
    -- true (default): the weekly and monthly bar heights are not taken from
    -- the two settings above at all - they are computed while the popup is
    -- built so the whole page ends up as close to exactly one screen tall
    -- as possible. The charts grow into whatever vertical space the other
    -- sections leave over, and - the point of the exercise - the page never
    -- becomes taller than the screen, so the scroll bar never appears.
    --
    -- false: the two fixed values above are used, exactly as before (a
    -- value that's too large then makes the page scroll again, which is
    -- what manual mode is for).
    BAR_AUTO_KEY     = "reading_insights_bar_height_auto",
    BAR_AUTO_DEFAULT = true,

    -- Bounds for the automatically computed heights - the same range the
    -- manual spin widgets in main.lua allow, so auto mode can never produce
    -- a chart the user couldn't also have dialed in by hand.
    AUTO_MIN = 10,
    AUTO_MAX = 200,

    -- Heights currently in force in auto mode: set by _buildUI's fit loop
    -- right before it (re)builds the sections, read back by the two chart
    -- builders via M.Opt.weeklyBarHeight()/M.Opt.monthlyBarHeight(). They are
    -- deliberately kept between builds - the result that fit last time is
    -- the fit loop's starting guess next time, so the usual case is a
    -- single build that already fits, with no extra measuring pass at all.
    -- Deliberately ONE value for both charts, not two: the weekly and the
    -- monthly bars must end up exactly the same height, and the surest way
    -- to guarantee that is for there to be nothing that could differ. Two
    -- separately clamped values could land a point apart at the MIN/MAX
    -- boundaries and show up as a one-pixel mismatch between the charts.
    auto_height = nil,

    -- Set by the chart builders during a build so the fit loop knows how
    -- many of the two adjustable charts are actually on the page for the
    -- current year/mode/data (an empty year has no monthly chart, for
    -- instance) and can split the leftover pixels between the right number
    -- of them.
    built_weekly  = false,
    built_monthly = false,

    -- Whether the "Reading goal" section is shown at all (Settings >
    -- Advanced settings > "Reading goal section"). On by default. When off
    -- the section is skipped while building the popup *and* its
    -- finished-book count is never queried (see _loadAndRebuild), so
    -- turning it off also removes its share of the work on every open.
    SHOW_GOAL_KEY     = "reading_insights_show_reading_goal",
    SHOW_GOAL_DEFAULT = true,

    -- What the right-hand cell of the "Reading goal" section counts
    -- (Settings > Advanced settings > Reading insight popup > "Reading goal
    -- display"). "total" (default) shows the year's goal itself - "30 books
    -- to read"; "remaining" shows how many of it are still left after the
    -- finished books on the left - "18 books left". Either way it is the
    -- same goal value underneath, and a long press on the cell still edits
    -- that goal.
    GOAL_DISPLAY_KEY       = "reading_insights_goal_display",
    GOAL_DISPLAY_TOTAL     = "total",
    GOAL_DISPLAY_REMAINING = "remaining",
}

-- Reading heatmap period length (Prefs ▸ Advanced settings ▸ how many
-- months the heatmap grid shows at once - 3, 4 or 6). Read by
-- getHeatmapPeriodRange below every time a heatmap page is built, so a
-- change takes effect the next time the popup (re)opens/pages.
M.SETTINGS_KEY_HEATMAP_MONTHS = "reading_insights_heatmap_months_per_period"

M.DEFAULT_HEATMAP_MONTHS      = 6

M.VALID_HEATMAP_MONTHS        = { [3] = true, [4] = true, [6] = true }

function M.readHeatmapMonthsSetting()
    local v = M.readNumSetting(M.SETTINGS_KEY_HEATMAP_MONTHS, M.DEFAULT_HEATMAP_MONTHS)
    if not M.VALID_HEATMAP_MONTHS[v] then return M.DEFAULT_HEATMAP_MONTHS end
    return v
end

function M.saveHeatmapMonthsSetting(value)
    M.saveNumSetting(M.SETTINGS_KEY_HEATMAP_MONTHS, value)
end

-- Time-of-day heatmap hour format (Prefs ▸ Advanced settings ▸ Date & time
-- ▸ "Time format" - 24-hour or 12-hour AM/PM). Previously the hour header
-- always showed 24-hour labels ("00".."21"); this is now an explicit,
-- language-independent setting instead of silently following the
-- interface language. Read by buildDayPartHeatmapWidget every time the
-- time-of-day heatmap is built.
M.SETTINGS_KEY_HEATMAP_HOUR_FORMAT = "reading_insights_heatmap_hour_format"

M.DEFAULT_HEATMAP_HOUR_FORMAT      = "24"

M.VALID_HEATMAP_HOUR_FORMAT        = { ["24"] = true, ["12"] = true }

function M.readHeatmapHourFormatSetting()
    local v = Prefs.read(M.SETTINGS_KEY_HEATMAP_HOUR_FORMAT, nil)
    if not M.VALID_HEATMAP_HOUR_FORMAT[v] then return M.DEFAULT_HEATMAP_HOUR_FORMAT end
    return v
end

function M.saveHeatmapHourFormatSetting(value)
    Prefs.save(M.SETTINGS_KEY_HEATMAP_HOUR_FORMAT, value)
end

-- Per-year reading goal ("2026 reading goal" section, shown above "Total
-- read"). One integer target per calendar year, keyed by year so switching
-- years (swipe/arrow, same navigation as the rest of the popup) shows and
-- edits that year's own goal. Edited via long press on the goal value (see
-- ReadingInsightsPopup:onHold / editReadingGoal).
M.DEFAULT_READING_GOAL = 12

function M.readingGoalSettingsKey(year)
    return "reading_insights_reading_goal_" .. tostring(year)
end

function M.readReadingGoal(year)
    return tonumber(Prefs.read(M.readingGoalSettingsKey(year), M.DEFAULT_READING_GOAL)) or M.DEFAULT_READING_GOAL
end

function M.saveReadingGoal(year, value)
    Prefs.save(M.readingGoalSettingsKey(year), value)
end

-- Per-book, per-year manual overrides for the reading-goal section's
-- "finished" determination (see getFinishedBooksForYear's own query-based
-- definition above it). Set via a long press on the "N book(s) finished"
-- cell, which opens a checklist of every book with activity that year
-- (FinishedBooksChecklistPopup below) letting the user tick/untick each
-- one - e.g. to exclude a book the query counted as finished but the user
-- considers unfinished (a reread left partway through), or to include one
-- the query missed. Only entries that differ from the query's own verdict
-- are stored - overrides[id_book] == true means "count as finished even
-- though the query disagrees (or doesn't know about it)", == false means
-- "don't count as finished even though the query says so". A book with no
-- entry here just uses the query's verdict unchanged.
function M.finishedOverridesSettingsKey(year)
    return "reading_insights_finished_overrides_" .. tostring(year)
end

function M.readFinishedOverrides(year)
    local raw = Prefs.read(M.finishedOverridesSettingsKey(year), nil)
    if type(raw) ~= "table" then return {} end
    return raw
end

function M.saveFinishedOverrides(year, overrides)
    Prefs.save(M.finishedOverridesSettingsKey(year), overrides)
end

-- Week start day for both reading heatmaps (Prefs ▸ Advanced settings ▸ Date
-- & time ▸ "First day of week" - Monday or Sunday). This is the same global
-- Book progress calendar keys off, so it now lives in the shared
-- Settings module (see settings.lua); these thin wrappers keep the existing
-- local + exported names working. Read by buildRangeHeatmapGrid (calendar
-- heatmap) and buildDayPartHeatmapWidget (time-of-day heatmap) every time
-- either grid is built, so a change takes effect on the next (re)open.
function M.readWeekStartSetting()
    return Prefs.readWeekStart()
end

function M.saveWeekStartSetting(value)
    Prefs.saveWeekStart(value)
end

-- 0 = Sunday, 1 = Monday (os.date("%w") convention) for the currently
-- configured week start day - the shared building block both heatmap
-- grids use to lay their rows/columns out.
function M.weekStartWday()
    return Prefs.weekStartWday()
end

M.INSIGHTS_MODE_KEY = "reading_insights_popup_mode"

M.INSIGHTS_MODE_DAYS = "days"

M.INSIGHTS_MODE_HOURS = "hours"

M.INSIGHTS_MODE_BOOKS = "books"

function M.normalizeInsightsMode(mode)
    if mode == M.INSIGHTS_MODE_DAYS then
        return M.INSIGHTS_MODE_DAYS
    end
    if mode == M.INSIGHTS_MODE_BOOKS then
        return M.INSIGHTS_MODE_BOOKS
    end
    return M.INSIGHTS_MODE_HOURS
end

-- Returns the _monthly_cache/_stale_monthly key prefix for a given insights
-- mode ("hours:" / "books:" / "days:"). Shared by init(), the mode-toggle
-- and year-navigation handlers, all of which need to guess the right
-- monthly cache key before the real data has loaded.
function M.monthKeyPrefixForMode(mode)
    if mode == M.INSIGHTS_MODE_HOURS then return "hours:" end
    if mode == M.INSIGHTS_MODE_BOOKS then return "books:" end
    return "days:"
end

-- "Last week" chart mode: tapping the "Last week" header toggles the daily
-- bar chart between reading time (HH:MM) and pages read per day. The choice
-- is persisted so the popup remembers it instead of always defaulting to time.
M.SETTINGS_KEY_WEEKLY_CHART_MODE = "reading_insights_weekly_chart_mode"

M.WEEKLY_CHART_MODE_TIME  = "time"

M.WEEKLY_CHART_MODE_PAGES = "pages"

function M.normalizeWeeklyChartMode(mode)
    if mode == M.WEEKLY_CHART_MODE_PAGES then
        return M.WEEKLY_CHART_MODE_PAGES
    end
    return M.WEEKLY_CHART_MODE_TIME
end

function M.readWeeklyChartMode()
    return M.normalizeWeeklyChartMode(Prefs.read(M.SETTINGS_KEY_WEEKLY_CHART_MODE, M.WEEKLY_CHART_MODE_TIME))
end

function M.saveWeeklyChartMode(mode)
    Prefs.save(M.SETTINGS_KEY_WEEKLY_CHART_MODE, mode)
end

-- "Last week" bar order (Prefs ▸ Advanced settings ▸ Reading insight popup ▸
-- "Last week chapter bar order"). The chart's data always arrives with index
-- 1 = today; this only decides which end of the row that first bar is drawn
-- at, so everything keyed off "bar 1 is today" (the highlight colour, the tap
-- that opens the Today Timeline) keeps working either way.
M.SETTINGS_KEY_WEEKLY_BAR_ORDER = "reading_insights_weekly_bar_order"

M.WEEKLY_BAR_ORDER_TODAY_FIRST = "today_first"

M.WEEKLY_BAR_ORDER_TODAY_LAST  = "today_last"

function M.readWeeklyBarOrderSetting()
    -- default: today on the left, which is what the chart did before this
    -- setting existed
    local v = Prefs.read(M.SETTINGS_KEY_WEEKLY_BAR_ORDER, nil)
    if v == M.WEEKLY_BAR_ORDER_TODAY_LAST then return M.WEEKLY_BAR_ORDER_TODAY_LAST end
    return M.WEEKLY_BAR_ORDER_TODAY_FIRST
end

function M.saveWeeklyBarOrderSetting(value)
    Prefs.save(M.SETTINGS_KEY_WEEKLY_BAR_ORDER, value)
end

function M.readInsightsMode()
    return M.normalizeInsightsMode(Prefs.read(M.INSIGHTS_MODE_KEY, M.INSIGHTS_MODE_HOURS))
end

function M.saveInsightsMode(mode)
    Prefs.save(M.INSIGHTS_MODE_KEY, mode)
end

function M.Opt.readBarHeightAuto()
    return M.readBoolSetting(M.Opt.BAR_AUTO_KEY, M.Opt.BAR_AUTO_DEFAULT)
end

function M.Opt.saveBarHeightAuto(value)
    M.saveBoolSetting(M.Opt.BAR_AUTO_KEY, value)
end

function M.Opt.weeklyBarHeight()
    if M.Opt.readBarHeightAuto() then
        return M.Opt.auto_height or M.DEFAULT_WEEKLY_BAR_HEIGHT
    end
    return M.readWeeklyBarHeightSetting()
end

function M.Opt.monthlyBarHeight()
    if M.Opt.readBarHeightAuto() then
        return M.Opt.auto_height or M.DEFAULT_MONTHLY_BAR_HEIGHT
    end
    return M.readMonthlyBarHeightSetting()
end

function M.Opt.readShowReadingGoal()
    return M.readBoolSetting(M.Opt.SHOW_GOAL_KEY, M.Opt.SHOW_GOAL_DEFAULT)
end

function M.Opt.saveShowReadingGoal(value)
    M.saveBoolSetting(M.Opt.SHOW_GOAL_KEY, value)
end

function M.Opt.readGoalDisplay()
    local v = Prefs.read(M.Opt.GOAL_DISPLAY_KEY, nil)
    if v == M.Opt.GOAL_DISPLAY_REMAINING then return M.Opt.GOAL_DISPLAY_REMAINING end
    return M.Opt.GOAL_DISPLAY_TOTAL
end

function M.Opt.saveGoalDisplay(value)
    Prefs.save(M.Opt.GOAL_DISPLAY_KEY, value)
end

return M
