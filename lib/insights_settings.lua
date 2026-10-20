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

-- Which value the streak-history popup's per-day bars show ("time" or
-- "pages") - toggled by tapping the value on the right of any row (see
-- streak_calendar_view.lua's M.showHistory). Persisted like every other
-- "which numbers am I looking at" display mode in this file, so the popup
-- reopens showing whichever one was last picked.
M.SETTINGS_KEY_STREAK_HISTORY_METRIC = "reading_insights_streak_history_metric"

function M.readStreakHistoryMetricSetting()
    local v = Prefs.read(M.SETTINGS_KEY_STREAK_HISTORY_METRIC, "time")
    if v ~= "pages" then return "time" end
    return v
end

function M.saveStreakHistoryMetricSetting(value)
    Prefs.save(M.SETTINGS_KEY_STREAK_HISTORY_METRIC, value == "pages" and "pages" or "time")
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
    -- Bar-chart height mode (Settings > Reading insight popup > "Bar chart
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

    -- Auto mode only: whole pixels (not enough for another bar point) that
    -- the fit hands to the monthly chart, as a spacer under it, so the page
    -- ends exactly at the bottom of the screen. Remembered between builds
    -- like auto_height; 0 = none.
    monthly_extra_px = 0,

    -- Landscape only: the text scale the last fit settled on (< 1 when the
    -- page had to shrink its fonts to lose the scroll bar), kept as the
    -- first guess for the next build. nil = fonts at their configured size.
    -- Never persisted; see _buildUI in views/insights_view.lua.
    font_scale = nil,

    -- Snapshot of this plugin's settings that font_scale was computed
    -- under; a mismatch at the next build means a setting changed, and the
    -- remembered scale is dropped (see settingsSignature in insights_view).
    settings_sig = nil,

    -- Set by the chart builders during a build so the fit loop knows how
    -- many of the two adjustable charts are actually on the page for the
    -- current year/mode/data (an empty year has no monthly chart, for
    -- instance) and can split the leftover pixels between the right number
    -- of them.
    built_weekly  = false,
    built_monthly = false,

    -- Whether the "Reading goal" section is shown at all (Settings >
    -- Reading insight popup > "Reading goal"). On by default. When off
    -- the section is skipped while building the popup *and* its
    -- finished-book count is never queried (see _loadAndRebuild), so
    -- turning it off also removes its share of the work on every open.
    SHOW_GOAL_KEY     = "reading_insights_show_reading_goal",
    SHOW_GOAL_DEFAULT = true,

    -- What the reading-goal section shows (Settings > 
    -- Reading insight popup > "Reading goal section"):
    --   "both"      (default) finished/target figure + achievements count
    --   "goal_only" the old two-cell view: finished count | yearly target
    --   "off"       the whole section is hidden (and not queried)
    GOAL_MODE_KEY  = "reading_insights_goal_section_mode",
    GOAL_MODE_BOTH = "both",
    GOAL_MODE_GOAL = "goal_only",
    GOAL_MODE_OFF  = "off",

    -- Independent on/off switches for the two sections (Settings > Reading
    -- insight popup > "Reading goal" / "Achievements"), both on by default.
    -- They replace the single three-way mode above; when a switch has never
    -- been touched it falls back to what the old mode implied, so existing
    -- setups keep looking the same (see readShowReadingGoal /
    -- readShowAchievements).
    SHOW_GOAL_ROW_KEY = "reading_insights_goal_row_enabled",
    SHOW_ACH_ROW_KEY  = "reading_insights_achievements_row_enabled",

    -- What the right-hand cell of the "Reading goal" section counts
    -- (Settings > Reading insight popup > "Reading goal
    -- display"). "total" (default) shows the year's goal itself - "30 books
    -- to read"; "remaining" shows how many of it are still left after the
    -- finished books on the left - "18 books left". Either way it is the
    -- same goal value underneath, and a long press on the cell still edits
    -- that goal.
    GOAL_DISPLAY_KEY       = "reading_insights_goal_display",
    GOAL_DISPLAY_TOTAL     = "total",
    GOAL_DISPLAY_REMAINING = "remaining",

    -- How often the achievements re-evaluate in the background (Settings >
    -- Reading insight popup > "Achievement refresh").
    -- "daily" (default): at most once per calendar day; "every_open": on
    -- every insights popup open. Either way the heavy re-scan only actually
    -- runs when the reading data changed since the last evaluation; a
    -- title-bar force-reload (popup or achievements list) always re-scans now.
    ACH_REFRESH_KEY   = "reading_insights_ach_refresh",
    ACH_REFRESH_DAILY = "daily",
    ACH_REFRESH_EVERY = "every_open",

    -- Book progress popup: whether the chapter bar (the visual bar chart of
    -- all chapters, in the "This book" section) is shown. On by default.
    SHOW_CHAPTER_BAR_KEY     = "reading_insights_book_show_chapter_bar",
    SHOW_CHAPTER_BAR_DEFAULT = true,

    -- Book progress popup: the row under the chapter bar chart with the
    -- number of chapters read ("23 / 46 chapters read") and the average
    -- chapter length (tap it to switch between time and pages). On by
    -- default.
    SHOW_CHAPTER_COUNT_ROW_KEY     = "reading_insights_book_show_chapter_count_row",
    SHOW_CHAPTER_COUNT_ROW_DEFAULT = true,

    -- Book progress popup: how that chapter bar is drawn. "bars" (default,
    -- unchanged look) is the per-chapter bar chart; "skim" is a single bar
    -- like the one in KOReader's "Skim to" dialog - filled up to the current
    -- page, a separator at every chapter start and the position marker (see
    -- widgets/skimbarwidget.lua).
    CHAPTER_BAR_STYLE_KEY  = "reading_insights_book_chapter_bar_style",
    CHAPTER_BAR_STYLE_BARS = "bars",
    CHAPTER_BAR_STYLE_SKIM = "skim",

    -- Book progress popup: whether the "started … / expected finish" date
    -- row at the bottom of the "Pace" section is shown. On by default.
    SHOW_PACE_DATES_KEY      = "reading_insights_book_show_pace_dates",
    SHOW_PACE_DATES_DEFAULT  = true,

    -- Book progress popup: whether the thin (5 px) progress bars under the
    -- "This chapter" value and under the book percentage are shown (drawn
    -- with the chart's active / inactive bar colors, see UI.buildRowBar in
    -- lib/uikit.lua). On by default.
    SHOW_CELL_BARS_KEY     = "reading_insights_book_show_cell_bars",
    SHOW_CELL_BARS_DEFAULT = true,

    -- Book progress popup: which rows / columns are shown. All on by default.
    -- A section whose parts are all off is hidden with its header (see
    -- buildSections in views/book_stats_view.lua).
    --   chapter section: "This chapter" / "Next chapter" columns
    --   "This book":     the "read" row (percent + pages), the reading-time row
    --   "Pace":          the "read today / avg per day" row
    SHOW_CHAPTER_CURRENT_KEY = "reading_insights_book_show_chapter_current",
    SHOW_CHAPTER_NEXT_KEY    = "reading_insights_book_show_chapter_next",

    -- Book progress popup: how many upcoming chapters the "Next chapter"
    -- column's reading-time estimate covers - 1 (default, unchanged
    -- behaviour: just the immediately-following chapter) or 2 (the header
    -- becomes "Next 2 chapters" and the value shows both chapters' times,
    -- e.g. "00:10 | 00:28"). Only affects the reading-time view of that
    -- column; falls back to 1 whenever there is no chapter after the next
    -- one (last-but-one chapter) or no next chapter at all (last chapter).
    NEXT_CHAPTER_COUNT_KEY   = "reading_insights_book_next_chapter_count",
    SHOW_BOOK_READ_ROW_KEY   = "reading_insights_book_show_read_row",
    SHOW_BOOK_TIME_ROW_KEY   = "reading_insights_book_show_time_row",
    SHOW_PACE_TODAY_KEY      = "reading_insights_book_show_pace_today",

    -- Book progress popup: where it is placed on screen. "top" (default) is
    -- the original full-width sheet hanging from the top edge; "center" is a
    -- bordered box in the middle of the screen, as wide as the Book progress
    -- calendar (94% of the screen width). Settings > 
    -- Book progress popup > "Popup position".
    BOOK_POPUP_POSITION_KEY    = "reading_insights_book_popup_position",
    BOOK_POPUP_POSITION_TOP    = "top",
    BOOK_POPUP_POSITION_CENTER = "center",

    -- Book progress popup, "This book" section: "classic" is the original
    -- rows (percent + pages, time read + time left);
    -- "donut" replaces them with one large donut chart (percentage in the
    -- middle, "read" beside it) on the left and, after the column divider,
    -- pages / time read / time left stacked on the right. Settings >
    -- Book progress popup > "Book section style".
    BOOK_SECTION_STYLE_KEY     = "reading_insights_book_section_style",
    BOOK_SECTION_STYLE_CLASSIC = "classic",
    BOOK_SECTION_STYLE_DONUT   = "donut",

    -- Reading insights popup: whether the title bar's hamburger menu (top
    -- left - quick access to the streak/heatmap/records/achievements
    -- popups) is shown at all (Settings > Reading
    -- insight popup > "Hamburger menu"). On by default.
    SHOW_HAMBURGER_MENU_KEY     = "reading_insights_show_hamburger_menu",
    SHOW_HAMBURGER_MENU_DEFAULT = false,

}

-- Reading heatmap period length (Settings ▸ Heatmap & time of day ▸ how many
-- months the heatmap grid shows at once - 3, 4, 6 or 12). Read by
-- getHeatmapPeriodRange below every time a heatmap page is built, so a
-- change takes effect the next time the popup (re)opens/pages.
M.SETTINGS_KEY_HEATMAP_MONTHS = "reading_insights_heatmap_months_per_period"

M.DEFAULT_HEATMAP_MONTHS      = 6

M.VALID_HEATMAP_MONTHS        = { [3] = true, [4] = true, [6] = true, [12] = true }

function M.readHeatmapMonthsSetting()
    local v = M.readNumSetting(M.SETTINGS_KEY_HEATMAP_MONTHS, M.DEFAULT_HEATMAP_MONTHS)
    if not M.VALID_HEATMAP_MONTHS[v] then return M.DEFAULT_HEATMAP_MONTHS end
    return v
end

function M.saveHeatmapMonthsSetting(value)
    M.saveNumSetting(M.SETTINGS_KEY_HEATMAP_MONTHS, value)
end

-- Time-of-day heatmap hour format (Settings ▸ Date & time
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

-- Time-of-day view style on the reading-heatmap page: the two-hourly bar
-- chart ("hourly", the default), the four day-part bars ("chart") or the
-- older weekday x hour-of-day grid ("heatmap"). Only the time-of-day section is swapped; the calendar
-- heatmap above it is unaffected. Read by M.buildHeatmapBoxContent every
-- time the heatmap page is (re)built.
M.SETTINGS_KEY_TIMEOFDAY_VIEW = "reading_insights_timeofday_view"

M.DEFAULT_TIMEOFDAY_VIEW      = "hourly"

-- ("hourly" = one bar per two hours of the day, 12 bars.)
M.VALID_TIMEOFDAY_VIEW        = { ["chart"] = true, ["hourly"] = true, ["heatmap"] = true }

function M.readTimeOfDayViewSetting()
    local v = Prefs.read(M.SETTINGS_KEY_TIMEOFDAY_VIEW, nil)
    if not M.VALID_TIMEOFDAY_VIEW[v] then return M.DEFAULT_TIMEOFDAY_VIEW end
    return v
end

function M.saveTimeOfDayViewSetting(value)
    Prefs.save(M.SETTINGS_KEY_TIMEOFDAY_VIEW, value)
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

-- Week start day for both reading heatmaps (Settings ▸ Date
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

-- Whether the Reading streak calendar and the Book progress calendar draw
-- an extra "Week" column to the left of their day columns, showing each row's
-- ISO week number (Settings ▸ Date & time ▸ "Show week
-- numbers"). Off by default so neither calendar gets narrower day cells for
-- anyone who hasn't asked for this. Read by streak_calendar_view.lua and
-- book_calendar_view.lua every time their month grid is (re)built.
M.SETTINGS_KEY_SHOW_WEEK_NUMBERS = "reading_insights_calendar_show_week_numbers"

function M.readShowWeekNumbers()
    return M.readBoolSetting(M.SETTINGS_KEY_SHOW_WEEK_NUMBERS, false)
end

function M.saveShowWeekNumbers(value)
    M.saveBoolSetting(M.SETTINGS_KEY_SHOW_WEEK_NUMBERS, value)
end

-- Whether the Reading streak calendar draws the streak line (the dark
-- "read day" / light "week with reading" bar) under the covers in each day
-- cell. Off by default: without the line the covers get that height too and
-- are shown larger. Read by streak_calendar_view.lua every time its month
-- grid is (re)built.
M.SETTINGS_KEY_SHOW_STREAK_BAR = "reading_insights_calendar_show_streak_bar"

function M.readShowStreakBar()
    return M.readBoolSetting(M.SETTINGS_KEY_SHOW_STREAK_BAR, false)
end

function M.saveShowStreakBar(value)
    M.saveBoolSetting(M.SETTINGS_KEY_SHOW_STREAK_BAR, value)
end

M.INSIGHTS_MODE_KEY = "reading_insights_popup_mode"

M.INSIGHTS_MODE_DAYS = "days"

M.INSIGHTS_MODE_HOURS = "hours"

M.INSIGHTS_MODE_BOOKS = "books"

-- Pages read per month: the second step of the monthly chart's cycle
-- (time -> pages -> days -> books).
M.INSIGHTS_MODE_PAGES = "pages"

function M.normalizeInsightsMode(mode)
    if mode == M.INSIGHTS_MODE_DAYS then
        return M.INSIGHTS_MODE_DAYS
    end
    if mode == M.INSIGHTS_MODE_PAGES then
        return M.INSIGHTS_MODE_PAGES
    end
    if mode == M.INSIGHTS_MODE_BOOKS then
        return M.INSIGHTS_MODE_BOOKS
    end
    return M.INSIGHTS_MODE_HOURS
end

-- Returns the _monthly_cache/_stale_monthly key prefix for a given insights
-- mode ("hours:" / "pages:" / "books:" / "days:"). Shared by init(), the mode-toggle
-- and year-navigation handlers, all of which need to guess the right
-- monthly cache key before the real data has loaded.
function M.monthKeyPrefixForMode(mode)
    if mode == M.INSIGHTS_MODE_HOURS then return "hours:" end
    if mode == M.INSIGHTS_MODE_PAGES then return "pages:" end
    if mode == M.INSIGHTS_MODE_BOOKS then return "books:" end
    return "days:"
end

-- "Last 7 days" chart mode: tapping the "Last 7 days" header toggles the daily
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

-- Time goals ("Daily goal | Weekly goal" section above "Last 7 days"). Both are
-- stored in minutes and edited by a long press on the section. Defaults:
-- 30 minutes a day, 5 hours (300 minutes) a week.
M.DEFAULT_DAILY_GOAL_MIN  = 30
M.DEFAULT_WEEKLY_GOAL_MIN = 300
M.TIME_GOAL_MAX_MIN       = 9999
M.SETTINGS_KEY_DAILY_GOAL_MIN  = "reading_insights_daily_goal_min"
M.SETTINGS_KEY_WEEKLY_GOAL_MIN = "reading_insights_weekly_goal_min"
M.SETTINGS_KEY_SHOW_TIME_GOALS = "reading_insights_show_time_goals"
M.SETTINGS_KEY_SHOW_TIME_GOAL_BAR = "reading_insights_show_time_goal_bar"

-- Whether the "Daily goal | Weekly goal" section is drawn (default: on).
function M.readShowTimeGoals()
    return Prefs.read(M.SETTINGS_KEY_SHOW_TIME_GOALS, true) ~= false
end

function M.saveShowTimeGoals(value)
    Prefs.save(M.SETTINGS_KEY_SHOW_TIME_GOALS, value and true or false)
end

-- Whether the thin (5 px) progress bar under the daily / weekly goal values
-- is drawn (default: on).
function M.readShowTimeGoalBar()
    return Prefs.read(M.SETTINGS_KEY_SHOW_TIME_GOAL_BAR, true) ~= false
end

function M.saveShowTimeGoalBar(value)
    Prefs.save(M.SETTINGS_KEY_SHOW_TIME_GOAL_BAR, value and true or false)
end

function M.readDailyGoalMinutes()
    local v = tonumber(Prefs.read(M.SETTINGS_KEY_DAILY_GOAL_MIN, M.DEFAULT_DAILY_GOAL_MIN))
    if not v or v < 1 then return M.DEFAULT_DAILY_GOAL_MIN end
    return math.floor(v)
end

function M.saveDailyGoalMinutes(value)
    Prefs.save(M.SETTINGS_KEY_DAILY_GOAL_MIN, value)
end

function M.readWeeklyGoalMinutes()
    local v = tonumber(Prefs.read(M.SETTINGS_KEY_WEEKLY_GOAL_MIN, M.DEFAULT_WEEKLY_GOAL_MIN))
    if not v or v < 1 then return M.DEFAULT_WEEKLY_GOAL_MIN end
    return math.floor(v)
end

function M.saveWeeklyGoalMinutes(value)
    Prefs.save(M.SETTINGS_KEY_WEEKLY_GOAL_MIN, value)
end

-- "Last 7 days" section rows (Settings > Reading insight
-- popup > "Last 7 days"). The compact row (total + daily average of the
-- selected chart mode, time or pages) is always shown. Two optional extras,
-- both off by default and independent of each other:
--   * "Time and pages row": a second row with the other metric (pages when
--     the chart shows time, time when it shows pages), i.e. what the old
--     "full" layout added to the compact one.
--   * "Compared to previous 7 days": under the chart, after a thin divider,
--     the change of the total and of the daily average against the 7 days
--     before the last 7 days.
M.SETTINGS_KEY_WEEKLY_EXTRA_ROW = "reading_insights_weekly_extra_row"
M.SETTINGS_KEY_WEEKLY_VS_PREV   = "reading_insights_weekly_vs_prev_week"

function M.readWeeklyExtraRow()
    return M.readBoolSetting(M.SETTINGS_KEY_WEEKLY_EXTRA_ROW, false)
end

function M.saveWeeklyExtraRow(value)
    M.saveBoolSetting(M.SETTINGS_KEY_WEEKLY_EXTRA_ROW, value)
end

function M.readWeeklyVsPrev()
    return M.readBoolSetting(M.SETTINGS_KEY_WEEKLY_VS_PREV, false)
end

function M.saveWeeklyVsPrev(value)
    M.saveBoolSetting(M.SETTINGS_KEY_WEEKLY_VS_PREV, value)
end

-- "Last 7 days" bar order (Settings ▸ Reading insight popup ▸
-- "Last 7 days chapter bar order"). The chart's data always arrives with index
-- 1 = today; this only decides which end of the row that first bar is drawn
-- at, so everything keyed off "bar 1 is today" (the highlight colour, the tap
-- that opens the Today Timeline) keeps working either way.
M.SETTINGS_KEY_WEEKLY_BAR_ORDER = "reading_insights_weekly_bar_order"

M.WEEKLY_BAR_ORDER_TODAY_FIRST = "today_first"

M.WEEKLY_BAR_ORDER_TODAY_LAST  = "today_last"

function M.readWeeklyBarOrderSetting()
    -- default: today (the newest day) on the right, so the chart reads
    -- like a timeline from left to right. Only an explicit "today on the
    -- left" choice flips it.
    local v = Prefs.read(M.SETTINGS_KEY_WEEKLY_BAR_ORDER, nil)
    if v == M.WEEKLY_BAR_ORDER_TODAY_FIRST then return M.WEEKLY_BAR_ORDER_TODAY_FIRST end
    return M.WEEKLY_BAR_ORDER_TODAY_LAST
end

function M.saveWeeklyBarOrderSetting(value)
    Prefs.save(M.SETTINGS_KEY_WEEKLY_BAR_ORDER, value)
end

-- Which week the weekly section of the insights popup shows (Settings >
-- Reading insight popup > Week > "View"):
--   "last7"    (default) the rolling last 7 days, ending today.
--   "calendar" the current calendar week (from the shared week start day),
--              pageable back and forth like the year; every figure of the
--              section (totals, averages, chart, comparison) covers that
--              one week only.
M.SETTINGS_KEY_WEEKLY_VIEW = "reading_insights_weekly_view"

M.WEEKLY_VIEW_LAST7    = "last7"

M.WEEKLY_VIEW_CALENDAR = "calendar"

function M.readWeeklyViewSetting()
    local v = Prefs.read(M.SETTINGS_KEY_WEEKLY_VIEW, nil)
    if v == M.WEEKLY_VIEW_CALENDAR then return M.WEEKLY_VIEW_CALENDAR end
    return M.WEEKLY_VIEW_LAST7
end

function M.saveWeeklyViewSetting(value)
    Prefs.save(M.SETTINGS_KEY_WEEKLY_VIEW, value)
end

function M.readWeeklyViewIsCalendar()
    return M.readWeeklyViewSetting() == M.WEEKLY_VIEW_CALENDAR
end

-- Layout of the yearly (months) bar chart in the Reading insights popup
-- (Settings > Reading insight popup > "Months chart layout"). "one_row" is
-- the default: all 12 months in a single row. "two_rows" draws two rows of
-- 6 months in portrait. Landscape always uses a single row regardless of
-- this setting.
M.SETTINGS_KEY_MONTHLY_LAYOUT = "reading_insights_monthly_chart_layout"

M.MONTHLY_LAYOUT_TWO_ROWS = "two_rows"

M.MONTHLY_LAYOUT_ONE_ROW  = "one_row"

function M.readMonthlyLayoutSetting()
    local v = Prefs.read(M.SETTINGS_KEY_MONTHLY_LAYOUT, nil)
    if v == M.MONTHLY_LAYOUT_TWO_ROWS then return M.MONTHLY_LAYOUT_TWO_ROWS end
    return M.MONTHLY_LAYOUT_ONE_ROW
end

function M.saveMonthlyLayoutSetting(value)
    Prefs.save(M.SETTINGS_KEY_MONTHLY_LAYOUT, value)
end

-- Style of the yearly (months) chart in the Reading insights popup
-- (Settings > Reading insight popup > "Months chart style"). "bars" (the
-- default) is the bar chart (which honours the "Months chart
-- layout" setting); "line" draws one line with a dot per month, all 12 months
-- in a single row.
M.SETTINGS_KEY_MONTHLY_STYLE = "reading_insights_monthly_chart_style"

M.MONTHLY_STYLE_LINE = "line"

M.MONTHLY_STYLE_BARS = "bars"

function M.readMonthlyStyleSetting()
    local v = Prefs.read(M.SETTINGS_KEY_MONTHLY_STYLE, nil)
    if v == M.MONTHLY_STYLE_LINE then return M.MONTHLY_STYLE_LINE end
    return M.MONTHLY_STYLE_BARS
end

function M.saveMonthlyStyleSetting(value)
    Prefs.save(M.SETTINGS_KEY_MONTHLY_STYLE, value)
end

-- Style of the "Last 7 days" chart (Settings > Reading insight popup >
-- "Last 7 days chart style"): "bars" (default) or "line" (smooth line with a
-- dot per day, like the yearly chart).
M.SETTINGS_KEY_WEEKLY_STYLE = "reading_insights_weekly_chart_style"

M.WEEKLY_STYLE_BARS = "bars"

M.WEEKLY_STYLE_LINE = "line"

function M.readWeeklyStyleSetting()
    local v = Prefs.read(M.SETTINGS_KEY_WEEKLY_STYLE, nil)
    if v == M.WEEKLY_STYLE_LINE then return M.WEEKLY_STYLE_LINE end
    return M.WEEKLY_STYLE_BARS
end

function M.saveWeeklyStyleSetting(value)
    Prefs.save(M.SETTINGS_KEY_WEEKLY_STYLE, value)
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

-- Heatmap popup bar charts (Settings > Heatmap & time of day > Bar chart
-- height): the "time of day" (day-part) chart and the weekday chart each
-- have their own maximum bar height. The default (46) is the same as the
-- chapter bar's default height (ChapterBar.DEFAULT_HEIGHT).
M.Opt.HEATMAP_TOD_BAR_KEY      = "reading_insights_heatmap_timeofday_bar_height"
M.Opt.HEATMAP_WEEKDAY_BAR_KEY  = "reading_insights_heatmap_weekday_bar_height"
M.Opt.DEFAULT_HEATMAP_BAR_HEIGHT = 46
M.Opt.MIN_HEATMAP_BAR_HEIGHT   = 10
M.Opt.MAX_HEATMAP_BAR_HEIGHT   = 200

function M.Opt.clampHeatmapBar(v)
    v = tonumber(v) or M.Opt.DEFAULT_HEATMAP_BAR_HEIGHT
    if v < M.Opt.MIN_HEATMAP_BAR_HEIGHT then v = M.Opt.MIN_HEATMAP_BAR_HEIGHT end
    if v > M.Opt.MAX_HEATMAP_BAR_HEIGHT then v = M.Opt.MAX_HEATMAP_BAR_HEIGHT end
    return v
end

function M.Opt.readHeatmapTimeOfDayBarHeight()
    return M.Opt.clampHeatmapBar(M.readNumSetting(M.Opt.HEATMAP_TOD_BAR_KEY, M.Opt.DEFAULT_HEATMAP_BAR_HEIGHT))
end

function M.Opt.saveHeatmapTimeOfDayBarHeight(value)
    M.saveNumSetting(M.Opt.HEATMAP_TOD_BAR_KEY, value)
end

function M.Opt.readHeatmapWeekdayBarHeight()
    return M.Opt.clampHeatmapBar(M.readNumSetting(M.Opt.HEATMAP_WEEKDAY_BAR_KEY, M.Opt.DEFAULT_HEATMAP_BAR_HEIGHT))
end

function M.Opt.saveHeatmapWeekdayBarHeight(value)
    M.saveNumSetting(M.Opt.HEATMAP_WEEKDAY_BAR_KEY, value)
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

-- Which layout the reading-goal section uses (or "off"). Invalid/unset ->
-- the default "both".
function M.Opt.readGoalSectionMode()
    local v = Prefs.read(M.Opt.GOAL_MODE_KEY, nil)
    if v == M.Opt.GOAL_MODE_GOAL or v == M.Opt.GOAL_MODE_OFF then return v end
    return M.Opt.GOAL_MODE_BOTH
end

function M.Opt.saveGoalSectionMode(value)
    Prefs.save(M.Opt.GOAL_MODE_KEY, value)
end

-- Whether the "Reading goal" section is drawn. Several call sites (the
-- section build, the finished-book query in _loadAndRebuild) gate on it.
-- Unset -> derived from the legacy three-way mode (only "off" hides it).
function M.Opt.readShowReadingGoal()
    local v = Prefs.read(M.Opt.SHOW_GOAL_ROW_KEY, nil)
    if v ~= nil then return v == true end
    return M.Opt.readGoalSectionMode() ~= M.Opt.GOAL_MODE_OFF
end

function M.Opt.saveShowReadingGoal(value)
    Prefs.save(M.Opt.SHOW_GOAL_ROW_KEY, value and true or false)
end

-- Whether the "Achievements" section (earned count | latest achievement) is
-- drawn, independently of the reading goal. Unset -> derived from the legacy
-- mode (only "both" showed achievements).
function M.Opt.readShowAchievements()
    local v = Prefs.read(M.Opt.SHOW_ACH_ROW_KEY, nil)
    if v ~= nil then return v == true end
    return M.Opt.readGoalSectionMode() == M.Opt.GOAL_MODE_BOTH
end

function M.Opt.saveShowAchievements(value)
    Prefs.save(M.Opt.SHOW_ACH_ROW_KEY, value and true or false)
end

function M.Opt.readGoalDisplay()
    local v = Prefs.read(M.Opt.GOAL_DISPLAY_KEY, nil)
    if v == M.Opt.GOAL_DISPLAY_REMAINING then return M.Opt.GOAL_DISPLAY_REMAINING end
    return M.Opt.GOAL_DISPLAY_TOTAL
end

function M.Opt.saveGoalDisplay(value)
    Prefs.save(M.Opt.GOAL_DISPLAY_KEY, value)
end

function M.Opt.readShowChapterBar()
    return M.readBoolSetting(M.Opt.SHOW_CHAPTER_BAR_KEY, M.Opt.SHOW_CHAPTER_BAR_DEFAULT)
end

function M.Opt.saveShowChapterBar(value)
    M.saveBoolSetting(M.Opt.SHOW_CHAPTER_BAR_KEY, value)
end

function M.Opt.readShowChapterCountRow()
    return M.readBoolSetting(M.Opt.SHOW_CHAPTER_COUNT_ROW_KEY, M.Opt.SHOW_CHAPTER_COUNT_ROW_DEFAULT)
end

function M.Opt.saveShowChapterCountRow(value)
    M.saveBoolSetting(M.Opt.SHOW_CHAPTER_COUNT_ROW_KEY, value)
end

-- Book progress popup: the tap-toggled display modes, remembered between
-- openings. name = "chapter_view" (This/Next chapter: "time" | "pages"),
-- "chapter_avg" (typical chapter length: "time" | "pages") or "chapter_read"
-- (chapters: "read" | "left") or "pace_view" (Pace row: "time" | "pages").
local POPUP_MODES = {
    chapter_view = { key = "reading_insights_book_chapter_view_mode", default = "time", other = "pages" },
    chapter_avg  = { key = "reading_insights_book_chapter_avg_mode",  default = "time", other = "pages" },
    chapter_read = { key = "reading_insights_book_chapter_read_mode", default = "read", other = "left"  },
    pace_view    = { key = "reading_insights_book_pace_view_mode",    default = "time", other = "pages" },
}

function M.Opt.readPopupMode(name)
    local m = POPUP_MODES[name]
    if not m then return nil end
    local v = Prefs.read(m.key, nil)
    if v == m.other then return m.other end
    return m.default
end

function M.Opt.savePopupMode(name, value)
    local m = POPUP_MODES[name]
    if not m then return end
    if value ~= m.other then value = m.default end
    Prefs.save(m.key, value)
end

function M.Opt.readChapterBarStyle()
    local v = Prefs.read(M.Opt.CHAPTER_BAR_STYLE_KEY, nil)
    if v == M.Opt.CHAPTER_BAR_STYLE_SKIM then return M.Opt.CHAPTER_BAR_STYLE_SKIM end
    return M.Opt.CHAPTER_BAR_STYLE_BARS
end

function M.Opt.saveChapterBarStyle(value)
    Prefs.save(M.Opt.CHAPTER_BAR_STYLE_KEY, value)
end

function M.Opt.readShowPaceDates()
    return M.readBoolSetting(M.Opt.SHOW_PACE_DATES_KEY, M.Opt.SHOW_PACE_DATES_DEFAULT)
end

function M.Opt.saveShowPaceDates(value)
    M.saveBoolSetting(M.Opt.SHOW_PACE_DATES_KEY, value)
end

function M.Opt.readShowChapterCurrent() return M.readBoolSetting(M.Opt.SHOW_CHAPTER_CURRENT_KEY, true) end
function M.Opt.saveShowChapterCurrent(v)  M.saveBoolSetting(M.Opt.SHOW_CHAPTER_CURRENT_KEY, v) end
function M.Opt.readShowChapterNext()    return M.readBoolSetting(M.Opt.SHOW_CHAPTER_NEXT_KEY, true) end
function M.Opt.saveShowChapterNext(v)     M.saveBoolSetting(M.Opt.SHOW_CHAPTER_NEXT_KEY, v) end

function M.Opt.readNextChapterCount()
    local v = M.readNumSetting(M.Opt.NEXT_CHAPTER_COUNT_KEY, 1)
    if v == 2 then return 2 end
    return 1
end

function M.Opt.saveNextChapterCount(value)
    M.saveNumSetting(M.Opt.NEXT_CHAPTER_COUNT_KEY, value)
end
function M.Opt.readShowBookReadRow()    return M.readBoolSetting(M.Opt.SHOW_BOOK_READ_ROW_KEY, true) end
function M.Opt.saveShowBookReadRow(v)     M.saveBoolSetting(M.Opt.SHOW_BOOK_READ_ROW_KEY, v) end
function M.Opt.readShowBookTimeRow()    return M.readBoolSetting(M.Opt.SHOW_BOOK_TIME_ROW_KEY, true) end
function M.Opt.saveShowBookTimeRow(v)     M.saveBoolSetting(M.Opt.SHOW_BOOK_TIME_ROW_KEY, v) end
function M.Opt.readShowPaceToday()      return M.readBoolSetting(M.Opt.SHOW_PACE_TODAY_KEY, true) end
function M.Opt.saveShowPaceToday(v)       M.saveBoolSetting(M.Opt.SHOW_PACE_TODAY_KEY, v) end

function M.Opt.readBookPopupPosition()
    local v = Prefs.read(M.Opt.BOOK_POPUP_POSITION_KEY, nil)
    if v == M.Opt.BOOK_POPUP_POSITION_CENTER then return M.Opt.BOOK_POPUP_POSITION_CENTER end
    return M.Opt.BOOK_POPUP_POSITION_TOP
end

function M.Opt.saveBookPopupPosition(value)
    Prefs.save(M.Opt.BOOK_POPUP_POSITION_KEY, value)
end

function M.Opt.readBookSectionStyle()
    local v = Prefs.read(M.Opt.BOOK_SECTION_STYLE_KEY, nil)
    -- Default (nothing saved yet) is the classic style; an explicit "donut"
    -- choice is saved and kept.
    if v == M.Opt.BOOK_SECTION_STYLE_DONUT then return M.Opt.BOOK_SECTION_STYLE_DONUT end
    return M.Opt.BOOK_SECTION_STYLE_CLASSIC
end

function M.Opt.saveBookSectionStyle(value)
    Prefs.save(M.Opt.BOOK_SECTION_STYLE_KEY, value)
end

function M.Opt.readShowCellBars()
    return M.readBoolSetting(M.Opt.SHOW_CELL_BARS_KEY, M.Opt.SHOW_CELL_BARS_DEFAULT)
end

function M.Opt.saveShowCellBars(value)
    M.saveBoolSetting(M.Opt.SHOW_CELL_BARS_KEY, value)
end

-- Reading insights popup's title-bar hamburger menu (Settings > Advanced
-- settings > Reading insight popup > "Hamburger menu"). Read by
-- insights_view.lua's _buildUI when deciding whether to draw the title
-- bar's left icon at all.
function M.Opt.readShowHamburgerMenu()
    return M.readBoolSetting(M.Opt.SHOW_HAMBURGER_MENU_KEY, M.Opt.SHOW_HAMBURGER_MENU_DEFAULT)
end

function M.Opt.saveShowHamburgerMenu(value)
    M.saveBoolSetting(M.Opt.SHOW_HAMBURGER_MENU_KEY, value)
end

-- Book info popup (Settings > Book info). Every option is an on/off toggle
-- that defaults to on; the keys are listed once here so the popup
-- (views/book_info_view.lua) and the menu (lib/menu.lua) share them.
--   cover    show the cover on the left
--   rounded  rounded cover corners
--   shadow   drop shadow behind the cover
--   border   thin frame around the cover
--   author   author line
--   series   series line
--   description  the book's description under the author / series, down to
--                the bottom of the cover (tap it for the full text)
M.Opt.BOOK_INFO_KEYS = {
    cover   = "reading_insights_book_info_cover",
    rounded = "reading_insights_book_info_rounded",
    shadow  = "reading_insights_book_info_shadow",
    border  = "reading_insights_book_info_border",
    author  = "reading_insights_book_info_author",
    series  = "reading_insights_book_info_series",
    description = "reading_insights_book_info_description",
}

function M.Opt.readBookInfo(name)
    local key = M.Opt.BOOK_INFO_KEYS[name]
    if not key then return true end
    return M.readBoolSetting(key, true)
end

function M.Opt.saveBookInfo(name, value)
    local key = M.Opt.BOOK_INFO_KEYS[name]
    if not key then return end
    M.saveBoolSetting(key, value and true or false)
end

-- The cover look shared by every place that shows covers - the Book info
-- popup, the Reading calendar's day cells and the Reading shelf - set under
-- Settings > Appearance > Covers: the frame, rounded corners and drop shadow,
-- each on or off. (They keep the keys they had when they were Book info
-- options, so an existing choice carries over.) Returns the sizes in pixels,
-- 0 for what is switched off:
--   { border = <frame thickness>, radius = <corner radius>, shadow = <shadow offset> }
-- The shadow lies outside the cover's own size, the frame inside it.
function M.Opt.coverDecor()
    local Screen = require("device").screen
    local function S(n) return Screen:scaleBySize(n) end
    return {
        border = M.Opt.readBookInfo("border")  and math.max(2, S(1)) or 0,
        radius = M.Opt.readBookInfo("rounded") and S(4) or 0,
        shadow = M.Opt.readBookInfo("shadow")  and S(4) or 0,
    }
end

-- Book info popup cover size (Settings > Book info > "Cover size"). "medium"
-- is the original size (the default). "small" and "large" are fitted to the
-- text by the popup (views/book_info_view.lua): small is as tall as the text
-- beside it, large the biggest cover that leaves room for all of it (within
-- 94% of the width). BOOK_INFO_COVER_SCALE lists the valid sizes (and the
-- nominal factors).
M.Opt.BOOK_INFO_COVER_SIZE_KEY    = "reading_insights_book_info_cover_size"
M.Opt.BOOK_INFO_COVER_SIZE_SMALL  = "small"
M.Opt.BOOK_INFO_COVER_SIZE_MEDIUM = "medium"
M.Opt.BOOK_INFO_COVER_SIZE_LARGE  = "large"
M.Opt.BOOK_INFO_COVER_SCALE = {
    small  = 0.5,
    medium = 1.0,
    large  = 1.5,
}

function M.Opt.readBookInfoCoverSize()
    local v = Prefs.read(M.Opt.BOOK_INFO_COVER_SIZE_KEY, nil)
    if M.Opt.BOOK_INFO_COVER_SCALE[v] then return v end
    return M.Opt.BOOK_INFO_COVER_SIZE_MEDIUM
end

function M.Opt.saveBookInfoCoverSize(value)
    if not M.Opt.BOOK_INFO_COVER_SCALE[value] then return end
    Prefs.save(M.Opt.BOOK_INFO_COVER_SIZE_KEY, value)
end

-- Tools > Reading insights: which "Show ..." entries are listed (Settings >
-- Advanced settings > "Menu items"). All on by default; this only affects
-- the menu, the gesture / dispatcher actions keep working either way.
M.Opt.MENU_ITEM_ORDER = {
    "insights", "streak", "shelf", "heatmap", "records", "achievements",
    "book_progress", "book_info", "book_calendar",
}

function M.Opt.readMenuItem(name)
    return M.readBoolSetting("reading_insights_menu_item_" .. name, true)
end

function M.Opt.saveMenuItem(name, value)
    M.saveBoolSetting("reading_insights_menu_item_" .. name, value and true or false)
end

function M.Opt.readAchievementRefresh()
    local v = Prefs.read(M.Opt.ACH_REFRESH_KEY, nil)
    if v == M.Opt.ACH_REFRESH_EVERY then return M.Opt.ACH_REFRESH_EVERY end
    return M.Opt.ACH_REFRESH_DAILY
end

function M.Opt.saveAchievementRefresh(value)
    Prefs.save(M.Opt.ACH_REFRESH_KEY, value)
end

return M
