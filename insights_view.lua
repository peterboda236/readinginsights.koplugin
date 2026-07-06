--[[
Reading Insights Popup (view module)

Full-screen scrollable popup showing reading history from statistics.sqlite3.
This is one of the plugin's two views; see main.lua for how it is wired up
(Tools menu entry, gesture/dispatcher action) and stats_view.lua for the
other view (live per-book reading stats overlay).

Loaded by main.lua via loadfile(...)( L10N ) -- L10N is the shared
translation/number-formatting module (l10n.lua), passed in as the sole
chunk argument so this file has no top-level `require("l10n")` path
issues regardless of how KOReader resolves plugin-relative requires.

Sections:
  - Last week     7-day total and average time/pages + daily bar chart
                  (tap a value to see an 8-week trend popup)
  - Streaks       current and best daily/weekly streaks
  - Year          time, days read, or books read + pages, navigable by year
  - Monthly chart bar chart per month (hours, days, or books mode, tappable)
  - Total read    all-time totals

Gestures:
  - Tap yearly value or monthly bar    open book list for that period
  - Tap monthly chart header           cycle hours/days/books mode
  - Tap on Streak                      show the streak period date and some more stats
  - Long press title bar               force-reload all data from DB
  - Swipe left/right                   change year
  - Swipe down / any key               close
  - Tap on book list element           show book stats
  - Tap value in Last week section     show 8-week trend popup (line chart)
  - Tap on Today in Last week          open Today Timeline
  - Long Press on Current month        open Calendar View

Monthly chart modes (cycle by tapping header):
  hours  – reading time per month (HH:MM bars)
  days   – reading days per month
  books  – distinct books with reading data per month (getMonthlyBookCounts)

Refresh behaviour:
  - Main popup open/close: "ui" refresh by default; "full" if the
    "Full-screen refresh on open/close" Tools-menu toggle is on.
  - 8-week trend popup and streak detail popup: partial "ui" refresh limited
    to the popup box area only — no full-screen flicker on open or close.
  - CalendarView open/close: managed by KOReader's own CalendarView widget,
    not controllable from this plugin.

Caching:
  Streaks, yearly, monthly, and all-time stats are all cached per minute
  (a cheap "today" slice is merged fresh on every call into a once-per-day
  cached "up to yesterday" base, so totals stay live without re-scanning
  full history each open). Year range cached per day. Monthly book counts
  cached under "books:<year>:<date>" keys, mirrored to _stale_monthly.
  Stale-while-revalidate: the popup opens immediately with cached data
  while fresh values load in the background.

  Last week: on every popup open, the current reading session's in-memory
  data is first flushed into statistics.sqlite3 (same insertDB() call the
  statistics koplugin itself makes before showing its own dialogs), and the
  last-week cache is invalidated so it is always re-read from the DB right
  after - not just once per minute. The previous value is still shown
  instantly (stale-while-revalidate) until the fresh one is ready.

  CalendarView: when closed, the popup reopens with the same year, mode,
  and cached data — no extra DB queries needed on return. If CalendarView
  is not available the long press is silently ignored.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local SQ3 = require("lua-ljsqlite3/init")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local T = require("ffi/util").template

-- Shared translations/number-formatting, loaded once by main.lua and passed
-- in as the module argument (see the `return function(L10N) ... end` wrapper
-- at the bottom of this file).
local L10N = ...

-- true: cache DB results (streaks/year_range per day, last-week per minute, yearly/monthly per day).
-- false: always query DB fresh on open.
local ENABLE_CACHE = true

-- true: today's bar in the weekly chart is black. false: all bars gray.
local WEEKLY_CHART_HIGHLIGHT_TODAY = true

-- Settings keys
local SETTINGS_KEY_FULL_REFRESH   = "reading_insights_full_refresh_on_open_close"
local SETTINGS_KEY_8W_ASCENDING   = "reading_insights_8week_ascending"

-- Generic boolean-setting reader/writer; replaces the previous 4 near-identical
-- read/save*Setting functions that only differed by key and default.
local function readBoolSetting(key, default)
    if G_reader_settings and G_reader_settings.readSetting then
        local v = G_reader_settings:readSetting(key)
        if v == nil then return default end
        return v == true
    end
    return default
end

local function saveBoolSetting(key, value)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(key, value)
    end
end

local function readFullRefreshSetting()
    return readBoolSetting(SETTINGS_KEY_FULL_REFRESH, false)
end

local function readAscendingSetting()
    -- default: ascending (oldest on the left)
    return readBoolSetting(SETTINGS_KEY_8W_ASCENDING, true)
end

local function saveFullRefreshSetting(value)
    saveBoolSetting(SETTINGS_KEY_FULL_REFRESH, value)
end

local function saveAscendingSetting(value)
    saveBoolSetting(SETTINGS_KEY_8W_ASCENDING, value)
end

local _cache = {
    streaks                = nil,
    streaks_date           = nil,
    streaks_date_minute    = nil,
    streaks_today_confirmed = nil,
    year_range      = nil,
    year_range_date = nil,
    all_time        = nil,
    all_time_minute = nil,
    last_week        = nil,
    last_week_minute = nil,
    last_week_daily        = nil,
    last_week_daily_minute = nil,
    last8weeks        = nil,
    last8weeks_minute = nil,
}

local _yearly_cache  = {}
local _monthly_cache = {}

-- "Up to yesterday" base aggregates (excludes today), kept separate from
-- _yearly_cache/_monthly_cache so they never collide with the stale-prefix
-- lookups those tables are searched with (e.g. "books:<year>:").
-- Recomputed once per day; today's slice is queried fresh and merged in on
-- every call, so totals stay live across repeated opens on the same day.
local _yearly_base_cache  = {}
local _monthly_base_cache = {}
local _alltime_base_cache = nil

-- Stale cache: holds expired values for immediate display on the next open.
-- _stale_cache is read-only in init(); writes go to the primary cache tables.
local _stale_cache   = {}
local _stale_yearly  = {}
local _stale_monthly = {}

local function clearAllCache()
    _cache.streaks                 = nil
    _cache.streaks_date            = nil
    _cache.streaks_date_minute     = nil
    _cache.streaks_today_confirmed = nil
    _cache.year_range      = nil
    _cache.year_range_date = nil
    _cache.all_time        = nil
    _cache.all_time_minute = nil
    _cache.last_week        = nil
    _cache.last_week_minute = nil
    _cache.last_week_daily        = nil
    _cache.last_week_daily_minute = nil
    _cache.last8weeks        = nil
    _cache.last8weeks_minute = nil
    _yearly_cache          = {}
    _monthly_cache         = {}
    _yearly_base_cache     = {}
    _monthly_base_cache    = {}
    _alltime_base_cache    = nil
    -- Stale cache is wiped on force-reload so stale data is not shown after a manual refresh.
    _stale_cache           = {}
    _stale_yearly          = {}
    _stale_monthly         = {}
end

-- Disk-persisted cache -------------------------------------------------
--
-- Everything above (_cache, _stale_cache, _yearly_cache, ...) lives only in
-- memory, so it is empty right after a KOReader restart (this module is
-- freshly loaded). Without a disk copy, the very first popup open after a
-- restart has nothing to show and falls back to a blocking "Loading data..."
-- placeholder until _loadAndRebuild() finishes querying the DB.
--
-- To avoid that, the stale-cache tables (the same ones used for
-- stale-while-revalidate display) are mirrored to a small Lua settings file
-- on disk: loaded once into memory when this module loads (i.e. on plugin
-- start/KOReader start), and saved every time _loadAndRebuild() finishes
-- refreshing the popup's data. This way the popup can always open instantly
-- with the last known numbers, then refresh in the background and redraw -
-- restart or not.
local LuaSettings = require("luasettings")
local DISK_CACHE_PATH = DataStorage:getSettingsDir() .. "/reading_insights_cache.lua"

local function loadDiskCache()
    local ok, settings = pcall(function() return LuaSettings:open(DISK_CACHE_PATH) end)
    if not ok or not settings then return end

    local stale_cache   = settings:readSetting("stale_cache")
    local stale_yearly  = settings:readSetting("stale_yearly")
    local stale_monthly = settings:readSetting("stale_monthly")

    if type(stale_cache) == "table" then
        for k, v in pairs(stale_cache) do _stale_cache[k] = v end
    end
    if type(stale_yearly) == "table" then
        for k, v in pairs(stale_yearly) do _stale_yearly[k] = v end
    end
    if type(stale_monthly) == "table" then
        for k, v in pairs(stale_monthly) do _stale_monthly[k] = v end
    end
end

-- Best-effort save; any failure (full disk, odd permissions, ...) is
-- silently ignored so it can never break the popup itself.
local function saveDiskCache()
    local ok, settings = pcall(function() return LuaSettings:open(DISK_CACHE_PATH) end)
    if not ok or not settings then return end
    settings:saveSetting("stale_cache", _stale_cache)
    settings:saveSetting("stale_yearly", _stale_yearly)
    settings:saveSetting("stale_monthly", _stale_monthly)
    pcall(function() settings:flush() end)
end

-- Seed the in-memory stale caches from disk immediately, so even the very
-- first ReadingInsightsPopup:init() after a KOReader restart already has
-- last-known data available via the existing stale-cache fallback below.
loadDiskCache()

local function todayDateStr()
    return os.date("%Y-%m-%d")
end

local function currentMinute()
    return math.floor(os.time() / 60)
end

-- Per-minute cache read: returns the cached value for `key` if caching is
-- on and it was last refreshed during the current minute, else nil.
-- `minute_key` is the sibling field/key holding the minute stamp (e.g.
-- "all_time_minute", or key .. ":minute" for the dynamically-keyed caches).
local function getMinuteCache(cache_table, key, minute_key, minute)
    if ENABLE_CACHE and cache_table[key] ~= nil and cache_table[minute_key] == minute then
        return cache_table[key]
    end
    return nil
end

-- Per-minute cache write: stores value + minute stamp, and mirrors it into
-- stale_table (read on the next popup open for instant stale-while-revalidate
-- display). No-op when caching is disabled.
local function setMinuteCache(cache_table, stale_table, key, minute_key, minute, value)
    if ENABLE_CACHE then
        cache_table[key]   = value
        cache_table[minute_key] = minute
        stale_table[key]   = value
    end
end

-- "Up to yesterday" base-aggregate read: returns the cached data only if it
-- was computed today, else nil (meaning: recompute). For per-key caches
-- (yearly/monthly) pass base_key; for the single un-keyed all-time cache
-- pass base_key = nil and the cache variable's current value as cache_entry.
local function getCachedBase(cache_table, base_key, today)
    if not ENABLE_CACHE then return nil end
    local entry
    if base_key then
        entry = cache_table[base_key]
    else
        entry = cache_table
    end
    if entry and entry.date == today then
        return entry.data
    end
    return nil
end

-- Builds the { date, data } shape stored by the base caches above; caller
-- assigns the result to cache_table[base_key] (or to the all-time base-cache
-- variable directly, since it isn't keyed).
local function makeCachedBase(today, data)
    return { date = today, data = data }
end

-- Value-based (not reference-based) equality for the small stat tables
-- returned by the getters below. Needed because a per-minute cache refresh
-- allocates a brand new result table every time it recomputes, even when
-- the actual numbers haven't changed (e.g. no reading happened in the last
-- minute) - a plain "==" would treat that as "changed" and force a needless
-- UI rebuild + e-ink redraw on almost every popup open.
local function valuesEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not valuesEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- The statistics koplugin keeps the current reading session's page timings
-- in memory (self.page_stat) and only periodically writes them into
-- statistics.sqlite3. Its own dialogs (e.g. "Current statistics") call
-- self:insertDB() right before reading anything from the DB, so the numbers
-- shown always include the still-open session. We do the same thing here
-- before querying "Last week", otherwise time spent in the current session
-- would be missing until KOReader's own autosave/close flushes it.
local function flushStatsToDB(ui)
    local stats_plugin = ui and ui.statistics or nil
    if stats_plugin and stats_plugin.insertDB then
        pcall(stats_plugin.insertDB, stats_plugin)
    end
    return stats_plugin
end

-- Localisation and number formatting now live in the shared l10n.lua module
-- (required by main.lua and handed to this view as `L10N`), so both this
-- popup and the reading-stats popup translate from the same l10n/<lang>.po
-- files instead of each keeping its own copy.
local _            = L10N._
local N_           = L10N.N_
local getLangBase  = L10N.getLangBase
local formatNumber = L10N.formatNumber
local formatCount  = L10N.formatCount

-- Format a YYYY-MM-DD string for display (EN: DD/MM/YYYY, HU: YYYY.MM.DD.)
-- no_trailing_dot: HU only - omit the final dot (used for the first date in a range)
local function formatDateForDisplay(date_str, no_trailing_dot)
    if not date_str then return "?" end
    local y, m, d = date_str:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return date_str end
    if getLangBase() == "hu" then
        return string.format("%s.%s.%s%s", y, m, d, no_trailing_dot and "" or ".")
    else
        return string.format("%s/%s/%s", d, m, y)
    end
end

local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}
local MONTH_NAMES_FULL = {
    _("January"), _("February"), _("March"), _("April"), _("May "), _("June"),
    _("July"), _("August"), _("September"), _("October"), _("November"), _("December"),
}

-- Builds the 12-entry month array shared by getMonthlyReadingDays/Hours/
-- BookCounts. `entry_fn(year_month, month_num)` returns the mode-specific
-- fields (e.g. { days = ... } or { hours = ..., seconds = ... }); month,
-- label and label_full are filled in here.
local function buildMonthlyArray(year, entry_fn)
    local months = {}
    for month_num = 1, 12 do
        local year_month = string.format("%04d-%02d", year, month_num)
        local entry = entry_fn(year_month, month_num)
        entry.month      = year_month
        entry.label      = MONTH_NAMES_SHORT[month_num]
        entry.label_full = MONTH_NAMES_FULL[month_num]
        table.insert(months, entry)
    end
    return months
end

-- Scans a stale-cache table for the first entry whose key starts with
-- `prefix`. Used as a fallback when no fresh/minute-cached value is
-- available yet (e.g. right after a restart, mode switch, or year change).
local function findStaleByPrefix(stale_table, prefix)
    if not ENABLE_CACHE then return nil end
    for k, v in pairs(stale_table) do
        if k:sub(1, #prefix) == prefix then
            return v
        end
    end
    return nil
end

local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local ReadingInsightsPopup

local INSIGHTS_MODE_KEY = "reading_insights_popup_mode"
local INSIGHTS_MODE_DAYS = "days"
local INSIGHTS_MODE_HOURS = "hours"
local INSIGHTS_MODE_BOOKS = "books"

local function normalizeInsightsMode(mode)
    if mode == INSIGHTS_MODE_DAYS then
        return INSIGHTS_MODE_DAYS
    end
    if mode == INSIGHTS_MODE_BOOKS then
        return INSIGHTS_MODE_BOOKS
    end
    return INSIGHTS_MODE_HOURS
end

-- Returns the _monthly_cache/_stale_monthly key prefix for a given insights
-- mode ("hours:" / "books:" / "days:"). Shared by init(), the mode-toggle
-- and year-navigation handlers, all of which need to guess the right
-- monthly cache key before the real data has loaded.
local function monthKeyPrefixForMode(mode)
    if mode == INSIGHTS_MODE_HOURS then return "hours:" end
    if mode == INSIGHTS_MODE_BOOKS then return "books:" end
    return "days:"
end

local function readInsightsMode()
    if G_reader_settings and G_reader_settings.readSetting then
        return normalizeInsightsMode(G_reader_settings:readSetting(INSIGHTS_MODE_KEY, INSIGHTS_MODE_HOURS))
    end
    return INSIGHTS_MODE_HOURS
end

local function saveInsightsMode(mode)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(INSIGHTS_MODE_KEY, mode)
    end
end

local function withStatsDb(fallback, fn)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(db_path, "mode") ~= "file" then
        return fallback
    end

    local conn = SQ3.open(db_path)
    if not conn then return fallback end

    pcall(function()
        conn:exec("PRAGMA journal_mode=WAL; PRAGMA cache_size=2000; PRAGMA temp_store=MEMORY;")
    end)

    local ok, result = pcall(fn, conn)
    conn:close()
    if ok then
        return result
    end
    return fallback
end

-- Open a persistent DB connection for batch use; caller must call conn:close().
-- Returns nil if the DB file does not exist or cannot be opened.
local function openStatsDb()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(db_path, "mode") ~= "file" then return nil end
    local conn = SQ3.open(db_path)
    if not conn then return nil end
    pcall(function()
        conn:exec("PRAGMA journal_mode=WAL; PRAGMA cache_size=2000; PRAGMA temp_store=MEMORY;")
    end)
    return conn
end

-- Like withStatsDb but reuses an already-open connection (conn must be non-nil).
-- Does NOT close the connection; the caller owns it.
local function withConn(conn, fallback, fn)
    if not conn then return fallback end
    local ok, result = pcall(fn, conn)
    if ok then return result end
    return fallback
end

-- Normalizes calling withConn (3 args) vs withStatsDb (2 args) behind one
-- signature, so callers don't have to branch on which one they picked.
local function withDb(shared_conn, fallback, fn)
    if shared_conn then
        return withConn(shared_conn, fallback, fn)
    end
    return withStatsDb(fallback, fn)
end

local function withStatement(conn, sql, fn)
    local stmt = conn:prepare(sql)
    if not stmt then return end
    local ok, result = pcall(fn, stmt)
    stmt:close()
    if ok then
        return result
    end
end

local function computeStreaks(entries_desc, is_consecutive, is_current_start)
    if #entries_desc == 0 then
        return 0, 0
    end

    local current = 0
    if is_current_start(entries_desc[1]) then
        current = 1
        for i = 2, #entries_desc do
            if is_consecutive(entries_desc[i - 1], entries_desc[i]) then
                current = current + 1
            else
                break
            end
        end
    end

    local best = 1
    local run = 1
    for i = 2, #entries_desc do
        if is_consecutive(entries_desc[i - 1], entries_desc[i]) then
            run = run + 1
            if run > best then
                best = run
            end
        else
            run = 1
        end
    end

    return current, best
end

-- Like computeStreaks but also returns {start, end} date strings for current and best streaks.
local function computeStreaksWithDates(entries_desc, is_consecutive, is_current_start)
    if #entries_desc == 0 then
        return 0, 0, nil, nil
    end

    local current = 0
    local current_start, current_end
    if is_current_start(entries_desc[1]) then
        current = 1
        current_end   = entries_desc[1]
        current_start = entries_desc[1]
        for i = 2, #entries_desc do
            if is_consecutive(entries_desc[i - 1], entries_desc[i]) then
                current = current + 1
                current_start = entries_desc[i]
            else
                break
            end
        end
    end

    local best = 1
    local run = 1
    local run_start_idx = 1
    local best_start_idx, best_end_idx = 1, 1
    for i = 2, #entries_desc do
        if is_consecutive(entries_desc[i - 1], entries_desc[i]) then
            run = run + 1
            if run > best then
                best = run
                best_end_idx   = run_start_idx
                best_start_idx = i
            end
        else
            run = 1
            run_start_idx = i
        end
    end

    local best_dates  = { start = entries_desc[best_start_idx], end_ = entries_desc[best_end_idx] }
    local current_dates = current > 0
        and { start = current_start, end_ = current_end }
        or nil

    return current, best, current_dates, best_dates
end

local function parseDateYMD(date_str)
    if not date_str then return end
    local year = tonumber(date_str:sub(1,4))
    local month = tonumber(date_str:sub(6,7))
    local day = tonumber(date_str:sub(9,10))
    if not year or not month or not day then return end
    return year, month, day
end

local function parseWeekYear(week_str)
    if not week_str then return end
    local year_str, week_str_num = week_str:match("(%d+)-(%d+)")
    local year = tonumber(year_str)
    local week = tonumber(week_str_num)
    if not year or week == nil then return end
    return year, week
end

local Math = require("optmath")

local function formatTimeRead(seconds)
    if not seconds or seconds <= 0 then
        return "", ""
    end
    
    if seconds < 60 then
        local s = Math.round(seconds)  -- Math.round instead of math.floor
        return formatNumber(s, 0),
               N_("second read", "seconds read", s)

    elseif seconds < 3600 then
        local m = Math.round(seconds / 60)
        return formatNumber(m, 0),
               N_("minute read", "minutes read", m)

    else
        local rounded_minutes = Math.round(seconds / 60)
        local h = math.floor(rounded_minutes / 60 * 10) / 10
        return formatNumber(h, 1),
               N_("hour read", "hours read", h)
    end
end

local function formatHoursRead(seconds)
    if not seconds or seconds <= 0 then
        return "0", N_("hour read", "hours read", 0)
    end

    local rounded_minutes = Math.round(seconds / 60)
    local h = math.floor(rounded_minutes / 60 * 10) / 10
    h = math.floor(h)  -- drop decimal
    return formatNumber(h, 0),
           N_("hour read", "hours read", h)
end

-- Format seconds as HH:MM:SS for book list display.
local function formatHHMMSS(seconds)
    if not seconds or seconds <= 0 then return "00:00:00" end
    local s = math.floor(seconds)
    local hh = math.floor(s / 3600)
    local mm = math.floor((s % 3600) / 60)
    local ss = s % 60
    return string.format("%02d:%02d:%02d", hh, mm, ss)
end

local function getSerifFace(font_name, fallback_name, size)
    return Font:getFace(font_name, size) or Font:getFace(fallback_name, size)
end

local function buildSerifFonts()
    return {
        section = getSerifFace("NotoSans-Bold.ttf", "tfont", 22),
        value   = getSerifFace("NotoSans-Bold.ttf",    "tfont", 26),
        label   = getSerifFace("NotoSans-Regular.ttf", "x_smallinfofont", 20),
        small   = getSerifFace("NotoSans-Regular.ttf", "xx_smallinfofont", 15),

    }

end

local function buildLayout(screen_w, padding_h, column_gap)
    local separator_width = 2 * column_gap + Size.line.medium
    local content_width = screen_w - 2 * padding_h
    local col_width = math.floor((content_width - separator_width) / 2)
    return {
        full_width    = screen_w,
        padding_h     = padding_h,
        column_gap    = column_gap,
        separator_width = separator_width,
        content_width = content_width,
        col_width     = col_width,
    }
end

local _cached_fonts  = nil
local _cached_layout = nil

local function getCachedFonts()
    if not _cached_fonts then _cached_fonts = buildSerifFonts() end
    return _cached_fonts
end

local function getCachedLayout()
    if not _cached_layout then
        local screen_w = Screen:getWidth()
        _cached_layout = buildLayout(screen_w, Size.padding.large, Screen:scaleBySize(20))
    end
    return _cached_layout
end

local function buildColumnSeparator(column_gap, height)
    local v_padding = Size.padding.default
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = column_gap },
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ height = v_padding },
            LineWidget:new{
                dimen = Geom:new{ w = Size.line.medium, h = height - 2 * v_padding },
                background = Blitbuffer.COLOR_GRAY,
            },
            VerticalSpan:new{ height = v_padding },
        },
        HorizontalSpan:new{ width = column_gap },
    }
end

local function buildSectionHeader(font_section, text, width, left_padding)
    left_padding = left_padding or Size.padding.large
    local text_widget = TextWidget:new{ text = text, face = font_section }
    return FrameContainer:new{
        background    = Blitbuffer.COLOR_WHITE,
        bordersize    = 0,
        padding_top   = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left  = left_padding,
        padding_right = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = width - left_padding, h = text_widget:getSize().h },
            text_widget,
        },
    }
    
end

local function buildValueLine(font_value, font_label, col_width, value, unit)
    if value == "" then
        return TextBoxWidget:new{
            text      = unit,
            face      = font_label,
            width     = col_width,
            alignment = "left",
        }
    end

    local value_widget = TextWidget:new{ text = value, face = font_value }
    local value_width = value_widget:getSize().w
    local text_desc_width = col_width - value_width - Size.padding.large
    return HorizontalGroup:new{
        align = "center",
        value_widget,
        HorizontalSpan:new{ width = Size.padding.large },
        TextBoxWidget:new{
            text      = unit,
            face      = font_label,
            width     = text_desc_width,
            alignment = "left",
        },
    }
end

local function fixedCol(widget, width)
    return LeftContainer:new{
        dimen  = Geom:new{ w = width, h = widget:getSize().h },
        widget,
    }
end

local function padded(padding_h, widget)
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = padding_h },
        widget,
    }
end

local function buildTwoColRow(left_widget, right_widget, layout)
    return HorizontalGroup:new{
        align = "center",
        fixedCol(left_widget, layout.col_width),
        buildColumnSeparator(layout.column_gap, left_widget:getSize().h),
        fixedCol(right_widget, layout.col_width),
    }
end

local function tappableCell(widget, col_width, callback)
    local cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = col_width, h = widget:getSize().h },
        widget,
    }
    cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } },
    }
    function cell:onTap()
        callback()
        return true
    end
    return cell
end

local function addSectionWithRow(sections, header_widget, row, layout, opts)
    local pad_row        = true
    local add_divider    = true
    local no_bottom_line = false
    local no_top_line    = false
    if opts then
        if opts.pad_row        == false then pad_row        = false end
        if opts.add_divider    == false then add_divider    = false end
        if opts.no_bottom_line == true  then no_bottom_line = true  end
        if opts.no_top_line    == true  then no_top_line    = true  end
    end

    table.insert(sections, header_widget)
    table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
    if add_divider and not no_top_line then
        table.insert(sections, padded(layout.padding_h, LineWidget:new{
            dimen      = Geom:new{ w = layout.content_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        }))
    end
    table.insert(sections, pad_row and padded(layout.padding_h, row) or row)
    table.insert(sections, VerticalSpan:new{ height = Size.padding.large })
    if add_divider and not no_bottom_line then
        table.insert(sections, padded(layout.padding_h, LineWidget:new{
            dimen      = Geom:new{ w = layout.content_width, h = Size.line.thick },
            background = Blitbuffer.COLOR_GRAY,
        }))
    end
end

local function buildYearHeader(font_section, layout, year_range, selected_year)
    local prev_available = selected_year > year_range.min_year
    local next_available = selected_year < year_range.max_year

    local inner_pad = Size.padding.default
    local gap       = Size.padding.small

    local sample_arrow = TextWidget:new{ text = "\xe2\x80\xb9", face = font_section }
    local arrow_w = sample_arrow:getSize().w
    sample_arrow:free()

    local sample_yr = TextWidget:new{ text = tostring(selected_year - 1), face = font_section }
    local yr_side_w = sample_yr:getSize().w
    sample_yr:free()

    local slot_w = arrow_w + gap + yr_side_w + inner_pad

    local year_label = TextWidget:new{
        text = tostring(selected_year),
        face = font_section,
    }

    local function makeSlot(yr, arrow_glyph, left, visible)
        if not visible then
            return HorizontalSpan:new{ width = slot_w }, slot_w
        end

        local arrow_tw = TextWidget:new{
            text    = arrow_glyph,
            face    = font_section,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local yr_tw = TextWidget:new{
            text    = tostring(yr),
            face    = font_section,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local parts
        if left then
            parts = HorizontalGroup:new{
                align = "center",
                arrow_tw,
                HorizontalSpan:new{ width = gap },
                yr_tw,
                HorizontalSpan:new{ width = inner_pad },
            }
        else
            parts = HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = inner_pad },
                yr_tw,
                HorizontalSpan:new{ width = gap },
                arrow_tw,
            }
        end
        return parts, slot_w
    end

    local left_slot,  left_w  = makeSlot(selected_year - 1, "\xe2\x80\xb9", true,  prev_available)
    local right_slot, right_w = makeSlot(selected_year + 1, "\xe2\x80\xba", false, next_available)

    local year_w    = year_label:getSize().w
    local remaining = layout.content_width - left_w - right_w - year_w
    if remaining < 0 then remaining = 0 end
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l

    local header_content = HorizontalGroup:new{
        align = "center",
        left_slot,
        HorizontalSpan:new{ width = side_l },
        year_label,
        HorizontalSpan:new{ width = side_r },
        right_slot,
    }

    return FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = layout.padding_h,
        padding_right  = layout.padding_h,
        header_content,
    }
end

local function buildYearlyRow(popup_self, yearly_stats, fonts, layout)
    local left_value = ""
    local left_unit  = ""
    if popup_self.mode == INSIGHTS_MODE_HOURS then
        local yr_secs = yearly_stats.duration or 0
        local yr_total_mins = math.floor(yr_secs / 60 + 0.5)
        local yr_h = math.floor(yr_total_mins / 60)
        local yr_m = yr_total_mins % 60
        left_value = string.format("%02d:%02d", yr_h, yr_m)
        left_unit  = _("reading time")
    elseif popup_self.mode == INSIGHTS_MODE_BOOKS then
        left_value = formatCount(yearly_stats.books_started)
        left_unit  = N_("book read", "books read", yearly_stats.books_started)
    else
        left_value = formatCount(yearly_stats.days)
        left_unit  = N_("day read", "days read", yearly_stats.days)
    end
    local left_line = buildValueLine(
        fonts.value, fonts.label, layout.col_width, left_value, left_unit)
    local right_value, right_unit
    if popup_self.mode == INSIGHTS_MODE_DAYS then
        local selected_year = popup_self.selected_year or tonumber(os.date("%Y"))
        local current_year  = tonumber(os.date("%Y"))
        local days_in_year
        if selected_year == current_year then
            days_in_year = tonumber(os.date("%j"))
        else
            local is_leap = (selected_year % 4 == 0 and selected_year % 100 ~= 0)
                         or (selected_year % 400 == 0)
            days_in_year = is_leap and 366 or 365
        end
        local pct = (days_in_year > 0)
            and math.floor((yearly_stats.days / days_in_year) * 100 + 0.5)
            or 0
        right_value = pct .. "%"
        right_unit  = _("of days read")
    elseif popup_self.mode == INSIGHTS_MODE_BOOKS then
        local avg_days = yearly_stats.avg_days_per_book or 0
        right_value = formatCount(avg_days)
        right_unit  = N_("day/book avg", "days/book avg", avg_days)
    else
        right_value = formatCount(yearly_stats.pages)
        right_unit  = N_("page read", "pages read", yearly_stats.pages)
    end
    local pages_val = buildValueLine(
        fonts.value, fonts.label, layout.col_width, right_value, right_unit)

    local selected_year_for_tap = popup_self.selected_year

    local left_cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = left_line:getSize().h },
        left_line,
    }
    left_cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = left_cell.dimen } },
    }
    function left_cell:onTap()
        popup_self:showBooksForYear(selected_year_for_tap)
        return true
    end

    local right_cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = pages_val:getSize().h },
        pages_val,
    }
    right_cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = right_cell.dimen } },
    }
    function right_cell:onTap()
        popup_self:showBooksForYear(selected_year_for_tap)
        return true
    end

    local yearly_row = buildTwoColRow(left_cell, right_cell, layout)

    return VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            padded(layout.padding_h, yearly_row),
        },
    }
end

local function buildMonthlyChart(popup_self, monthly_data, layout, fonts)
    if #monthly_data == 0 then return nil end

    local value_key = (popup_self.mode == INSIGHTS_MODE_HOURS and "hours")
        or (popup_self.mode == INSIGHTS_MODE_BOOKS and "book_count")
        or "days"
    local max_value = 1
    for _, m in ipairs(monthly_data) do
        local v = tonumber(m[value_key]) or 0
        if v > max_value then max_value = v end
    end

    local chart_width  = layout.content_width
    local bar_height   = tonumber(Screen:scaleBySize(48))
    local bar_width    = math.floor(chart_width / 6) - tonumber(Screen:scaleBySize(8))
    local bar_gap      = math.floor((chart_width - bar_width * 6) / 5)
    local font_small   = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local current_year  = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")

    local function createBarRow(data_slice)
        local bars_row        = HorizontalGroup:new{ align = "bottom" }
        local month_labels_row = HorizontalGroup:new{ align = "top" }
        local baseline_h      = Size.line.medium
        local total_bar_height = bar_height + label_height

        for i, m in ipairs(data_slice) do
            local value = tonumber(m[value_key]) or 0
            local ratio = max_value > 0 and (value / max_value) or 0
            local bar_h = math.floor(ratio * bar_height + 0.5)
            if bar_h == 0 and value > 0 then bar_h = 1 end

            local is_current = (popup_self.selected_year == current_year) and (m.month == current_month)
            local bar_color  = is_current and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY

            local bar_label_str
            if popup_self.mode == INSIGHTS_MODE_HOURS then
                local mo_secs = tonumber(m.seconds) or math.floor((tonumber(m.hours) or 0) * 3600 + 0.5)
                local mo_mins = math.floor(mo_secs / 60 + 0.5)
                local mo_h = math.floor(mo_mins / 60)
                local mo_m = mo_mins % 60
                bar_label_str = string.format("%02d:%02d", mo_h, mo_m)
            else
                bar_label_str = formatNumber(value)
            end            local value_label   = TextWidget:new{ text = bar_label_str, face = font_small }
            local centered_label = CenterContainer:new{
                dimen  = Geom:new{ w = bar_width, h = label_height },
                value_label,
            }

            local bar_column = VerticalGroup:new{ align = "center" }
            table.insert(bar_column, centered_label)
            if bar_h > 0 then
                table.insert(bar_column, LineWidget:new{
                    dimen      = Geom:new{ w = bar_width, h = bar_h },
                    background = bar_color,
                })
            end
            table.insert(bar_column, LineWidget:new{
                dimen      = Geom:new{ w = bar_width, h = baseline_h },
                background = bar_color,
            })

            local bar_container = BottomContainer:new{
                dimen = Geom:new{ w = bar_width, h = total_bar_height },
                bar_column,
            }

            local tappable_bar = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = bar_width, h = total_bar_height },
                bar_container,
            }
            local month_data       = m
            local month_year_label = m.label_full .. " " .. popup_self.selected_year
            tappable_bar.ges_events = {
                Tap  = { GestureRange:new{ ges = "tap",  range = tappable_bar.dimen } },
            }
            function tappable_bar:onTap()
                popup_self:showBooksForMonth(month_data.month, month_year_label)
                return true
            end
            if is_current then
                popup_self._current_month_bar_widget = tappable_bar
            end

            table.insert(bars_row, tappable_bar)

            local month_label_widget = TextWidget:new{ text = m.label, face = font_small }
            table.insert(month_labels_row, CenterContainer:new{
                dimen = Geom:new{ w = bar_width, h = month_label_widget:getSize().h },
                month_label_widget,
            })

            if i < #data_slice then
                table.insert(bars_row,         HorizontalSpan:new{ width = bar_gap })
                table.insert(month_labels_row, HorizontalSpan:new{ width = bar_gap })
            end
        end

        return VerticalGroup:new{
            align = "center",
            bars_row,
            VerticalSpan:new{ height = Size.padding.small },
            month_labels_row,
        }
    end

    local chart     = VerticalGroup:new{ align = "center" }
    local row_index = 0
    for i = 1, #monthly_data, 6 do
        local row_data = {}
        for j = i, math.min(i + 5, #monthly_data) do
            table.insert(row_data, monthly_data[j])
        end
        if #row_data > 0 then
            if row_index > 0 then
                table.insert(chart, VerticalSpan:new{ height = Size.padding.default })
            end
            table.insert(chart, createBarRow(row_data))
            row_index = row_index + 1
        end
    end

    return chart
end

-- ============================================================
-- 8-week reading trend popup (tap a Last-week cell to open it)
-- ============================================================

-- Minimal line-chart widget: draws straight segments between `points`
-- ({x, y} pixel pairs, relative to the widget's own top-left corner)
-- using only bb:paintRect, so it doesn't depend on any diagonal-line
-- drawing primitive that may or may not exist in a given KOReader build.
local LineChartWidget = Widget:extend{
    width      = nil,
    height     = nil,
    points     = nil,
    line_color = nil,
}

function LineChartWidget:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function LineChartWidget:paintTo(bb, x, y)
    if not self.points or #self.points == 0 then return end
    local color = self.line_color or Blitbuffer.COLOR_BLACK

    if #self.points > 1 then
        for i = 1, #self.points - 1 do
            local p1, p2 = self.points[i], self.points[i + 1]
            local dx, dy = p2.x - p1.x, p2.y - p1.y
            local steps  = math.max(math.abs(dx), math.abs(dy), 1)
            for s = 0, steps do
                local t  = s / steps
                local px = math.floor(p1.x + dx * t + 0.5)
                local py = math.floor(p1.y + dy * t + 0.5)
                bb:paintRect(x + px, y + py, 2, 2, color)
            end
        end
    end
end

-- Same rounding rule used for the "avg/day" pages cell in the main popup:
-- integer above 10, 1 decimal place below.
local function roundAvgPages(value)
    if value >= 10 then
        return math.floor(value + 0.5)
    else
        return math.floor(value * 10 + 0.5) / 10
    end
end

-- Format a single week's bucket value for the given metric.
-- Returns (display_string, raw_numeric_value).
local function formatWeekValue(metric, week_entry)
    if metric == "time_total" or metric == "time_avg" then
        local secs = week_entry.seconds or 0
        if metric == "time_avg" then secs = secs / 7 end
        local mins = math.floor(secs / 60 + 0.5)
        local h = math.floor(mins / 60)
        local m = mins % 60
        return string.format("%02d:%02d", h, m), secs
    else
        local pages = week_entry.pages or 0
        if metric == "pages_avg" then
            pages = roundAvgPages(pages / 7)
            return formatNumber(pages, pages ~= math.floor(pages) and 1 or 0), pages
        end
        return formatCount(pages), pages
    end
end

local TREND_TITLE_KEYS = {
    time_total  = "Reading time over the last 8 weeks",
    pages_total = "Pages read over the last 8 weeks",
    time_avg    = "Average daily reading time, last 8 weeks",
    pages_avg   = "Average daily pages, last 8 weeks",
}

local function trendTitle(metric)
    local key = TREND_TITLE_KEYS[metric]
    return key and _(key) or ""
end

local function totalForMetric(metric, weeks)
    local total_secs, total_pages = 0, 0
    for _, w in ipairs(weeks) do
        total_secs  = total_secs  + (w.seconds or 0)
        total_pages = total_pages + (w.pages or 0)
    end
    if metric == "time_total" then
        local mins = math.floor(total_secs / 60 + 0.5)
        return string.format("%02d:%02d", math.floor(mins / 60), mins % 60)
    elseif metric == "time_avg" then
        local avg_secs = total_secs / (7 * #weeks)
        local mins = math.floor(avg_secs / 60 + 0.5)
        return string.format("%02d:%02d", math.floor(mins / 60), mins % 60)
    elseif metric == "pages_total" then
        return formatCount(total_pages)
    else -- pages_avg
        local avg = roundAvgPages(total_pages / (7 * #weeks))
        return formatNumber(avg, avg ~= math.floor(avg) and 1 or 0)
    end
end

-- Builds the chart: one dot per week, connected by straight segments,
-- with the per-week value printed above each dot and a baseline below.
-- "Máj 6" / "May 6" style label using the same month names as the monthly chart.
local function formatShortDate(date_str)
    local y, m, d = date_str:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return date_str end
    local month_name = MONTH_NAMES_SHORT[tonumber(m)] or m
    if getLangBase() == "hu" then
        return month_name .. " " .. tostring(tonumber(d)) .. "."
    else
        return month_name .. " " .. tostring(tonumber(d))
    end
end

local function buildLine8WeekChart(weeks, metric, chart_width, fonts)
    if not weeks or #weeks == 0 then return nil end

    local bar_height  = tonumber(Screen:scaleBySize(120))
    local num_points  = #weeks
    local col_width   = math.floor(chart_width / num_points)
    local font_small  = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local values = {}
    local max_value = 0
    for i, w in ipairs(weeks) do
        local _unused, raw = formatWeekValue(metric, w)
        values[i] = raw
        if raw > max_value then max_value = raw end
    end
    if max_value <= 0 then max_value = 1 end

    local dot_size    = tonumber(Screen:scaleBySize(6))
    local baseline_h  = Size.line.medium
    local total_col_h = bar_height + label_height

    -- Ascending = weeks[1] (oldest) leftmost; descending = weeks[num_points] (newest) leftmost.
    local ascending = readAscendingSetting()

    local bars_row = HorizontalGroup:new{ align = "bottom" }
    local points   = {}

    for col = 1, num_points do
        local i = ascending and col or (num_points - col + 1)
        local ratio = values[i] / max_value
        local dot_y_from_bottom = math.floor(ratio * (bar_height - dot_size))
        local val_str = formatWeekValue(metric, weeks[i])

        local value_label    = TextWidget:new{ text = val_str, face = font_small }
        local centered_label = CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = label_height },
            value_label,
        }

        local col_group = VerticalGroup:new{ align = "center" }
        table.insert(col_group, centered_label)
        local space_above = bar_height - dot_size - dot_y_from_bottom
        if space_above > 0 then
            table.insert(col_group, VerticalSpan:new{ height = space_above })
        end
        table.insert(col_group, CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = dot_size },
            LineWidget:new{
                dimen      = Geom:new{ w = dot_size, h = dot_size },
                background = Blitbuffer.COLOR_BLACK,
            },
        })
        if dot_y_from_bottom > 0 then
            table.insert(col_group, VerticalSpan:new{ height = dot_y_from_bottom })
        end
        table.insert(col_group, LineWidget:new{
            dimen      = Geom:new{ w = col_width, h = baseline_h },
            background = Blitbuffer.COLOR_GRAY,
        })

        table.insert(bars_row, BottomContainer:new{
            dimen = Geom:new{ w = col_width, h = total_col_h },
            col_group,
        })

        points[col] = {
            x = (col - 1) * col_width + math.floor(col_width / 2),
            y = label_height + space_above + math.floor(dot_size / 2),
        }
    end

    local line_widget = LineChartWidget:new{
        width      = num_points * col_width,
        height     = total_col_h,
        points     = points,
        line_color = Blitbuffer.COLOR_BLACK,
    }

    local chart_area = OverlapGroup:new{
        dimen = Geom:new{ w = num_points * col_width, h = total_col_h },
        bars_row,
        line_widget,
    }

    -- Per-week start/end date, same font size as the value labels above the dots.
    -- Order follows the same ascending/descending setting as the columns above.
    local date_labels_row = HorizontalGroup:new{ align = "top" }
    for col = 1, num_points do
        local i = ascending and col or (num_points - col + 1)
        local start_lbl = TextWidget:new{ text = formatShortDate(weeks[i].start_date), face = font_small }
        local col_dates  = CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = start_lbl:getSize().h },
            start_lbl,
        }
        table.insert(date_labels_row, col_dates)
    end

    return VerticalGroup:new{
        align = "center",
        chart_area,
        VerticalSpan:new{ height = Size.padding.small },
        date_labels_row,
    }
end

-- Full-screen tap-anywhere-to-close popup that hosts the trend chart.
local WeeklyTrendPopup = InputContainer:extend{
    modal       = true,
    box_content = nil,
}

function WeeklyTrendPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.box_content,
    }
end

function WeeklyTrendPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.box_content.dimen
    end)
    return true
end

function WeeklyTrendPopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.box_content.dimen
    end)
end

function WeeklyTrendPopup:onTap()           UIManager:close(self) return true end
function WeeklyTrendPopup:onSwipe()         UIManager:close(self) return true end
function WeeklyTrendPopup:onAnyKeyPressed() UIManager:close(self) return true end

-- Weekly bar chart: 7 bars, index 1 = today (leftmost), index 7 = 6 days ago.
-- Labels: "Today", "Yesterday", then weekday abbreviations.
local function buildWeeklyChart(popup_self, daily_data, layout, fonts)
    if not daily_data or #daily_data == 0 then return nil end

    -- Pad to exactly 7 entries.
    while #daily_data < 7 do
        table.insert(daily_data, { hours = 0, label = "" })
    end

    local chart_width  = layout.content_width

    local bar_height   = tonumber(Screen:scaleBySize(48))
    local num_bars     = 7
    local bar_width    = math.floor(chart_width / num_bars) - tonumber(Screen:scaleBySize(6))
    local bar_gap      = math.floor((chart_width - bar_width * num_bars) / (num_bars - 1))
    local font_small   = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local max_value = 0
    for _, d in ipairs(daily_data) do
        local v = tonumber(d.seconds) or 0
        if v > max_value then max_value = v end
    end
    if max_value < 0.1 then max_value = 1 end  -- avoid division by zero

    local bars_row        = HorizontalGroup:new{ align = "bottom" }
    local day_labels_row  = HorizontalGroup:new{ align = "top" }
    local baseline_h      = Size.line.medium
    local total_bar_height = bar_height + label_height

    for i = 1, num_bars do
        local d = daily_data[i]
        local value = tonumber(d.seconds) or 0
        local ratio = value / max_value
        local bar_h = math.floor(ratio * bar_height + 0.5)
        if bar_h == 0 and value > 0 then bar_h = 1 end

        local bar_color = (WEEKLY_CHART_HIGHLIGHT_TODAY and i == 1) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY

        local secs = tonumber(d.seconds) or 0
        local total_mins = math.floor(secs / 60 + 0.5)
        local h = math.floor(total_mins / 60)
        local m = total_mins % 60
        local val_str = string.format("%02d:%02d", h, m)
        local value_label   = TextWidget:new{ text = val_str, face = font_small }
        local centered_label = CenterContainer:new{
            dimen  = Geom:new{ w = bar_width, h = label_height },
            value_label,
        }

        local bar_column = VerticalGroup:new{ align = "center" }
        table.insert(bar_column, centered_label)
        if bar_h > 0 then
            table.insert(bar_column, LineWidget:new{
                dimen      = Geom:new{ w = bar_width, h = bar_h },
                background = bar_color,
            })
        end
        table.insert(bar_column, LineWidget:new{
            dimen      = Geom:new{ w = bar_width, h = baseline_h },
            background = bar_color,
        })

        local bar_container = BottomContainer:new{
            dimen = Geom:new{ w = bar_width, h = total_bar_height },
            bar_column,
        }
        
        if i == 1 then
            local tappable_bar = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = bar_width, h = total_bar_height },
                bar_container,
            }
            tappable_bar.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = tappable_bar.dimen } },
            }
            function tappable_bar:onTap()
                popup_self:openTodayTimeline()
                return true
            end
            table.insert(bars_row, tappable_bar)
        else
            table.insert(bars_row, bar_container)
        end

        local day_label_widget = TextWidget:new{ text = d.label, face = font_small }
        table.insert(day_labels_row, CenterContainer:new{
            dimen = Geom:new{ w = bar_width, h = day_label_widget:getSize().h },
            day_label_widget,
        })

        if i < num_bars then
            table.insert(bars_row,       HorizontalSpan:new{ width = bar_gap })
            table.insert(day_labels_row, HorizontalSpan:new{ width = bar_gap })
        end
    end

    return VerticalGroup:new{
        align = "center",
        bars_row,
        VerticalSpan:new{ height = Size.padding.small },
        day_labels_row,
    }
end

-- Convert "YYYY-WW" to the Monday date of that ISO week as "YYYY-MM-DD".
local function weekStrToMondayDate(week_str)
    if not week_str then return nil end
    local year, week = parseWeekYear(week_str)
    if not year or not week then return nil end
    -- Jan 4 is always in week 1; find Monday of week 1, then offset.
    local jan4 = os.time({ year = year, month = 1, day = 4 })
    local dow4 = tonumber(os.date("%w", jan4))  -- 0=Sun
    if dow4 == 0 then dow4 = 7 end
    local week1_mon = jan4 - (dow4 - 1) * 86400
    local target_mon = week1_mon + (week - 1) * 7 * 86400
    return os.date("%Y-%m-%d", target_mon)
end

-- Total reading seconds and distinct book count for a "YYYY-MM-DD" date range (inclusive).
local function getStreakPeriodStats(start_date, end_date)
    local stats = { duration = 0, books = 0 }
    if not start_date or not end_date then return stats end
    return withStatsDb(stats, function(conn)
        local sql = string.format([[
            SELECT COALESCE(SUM(duration), 0) AS total_duration,
                   COUNT(DISTINCT id_book) AS book_count
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
        ]], start_date, end_date)
        withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                stats.duration = tonumber(row[1]) or 0
                stats.books    = tonumber(row[2]) or 0
            end
        end)
        return stats
    end)
end

-- Number of calendar days between two "YYYY-MM-DD" dates, inclusive.
local function daysBetweenInclusive(start_date, end_date)
    local sy, sm, sd = parseDateYMD(start_date)
    local ey, em, ed = parseDateYMD(end_date)
    if not sy or not ey then return 1 end
    local t1 = os.time({ year = sy, month = sm, day = sd })
    local t2 = os.time({ year = ey, month = em, day = ed })
    local days = math.floor((t2 - t1) / 86400) + 1
    if days < 1 then days = 1 end
    return days
end

-- Show a popup (styled like the main insights popup) with the period start/end
-- dates for a streak, plus total reading time, average time/day, and book count.
-- dates table: { start = "YYYY-MM-DD" or "YYYY-WW", end_ = same }, is_weekly = bool
-- is_current: true = current streak, false = best streak. When given, a label
-- naming which streak's period is shown is prepended above the date range.
local function showStreakDatePopup(dates, is_weekly, is_current)
    if not dates then
        UIManager:show(InfoMessage:new{ text = _("No streak dates") })
        return
    end
    local start_str, end_str, range_start, range_end
    if is_weekly then
        local mon_from = weekStrToMondayDate(dates.start)
        local mon_to   = weekStrToMondayDate(dates.end_)
        local sun_to
        if mon_to then
            sun_to = os.date("%Y-%m-%d", os.time({ year = tonumber(mon_to:sub(1,4)),
                month = tonumber(mon_to:sub(6,7)), day = tonumber(mon_to:sub(9,10)) }) + 6 * 86400)
        end
        range_start = mon_from
        range_end   = sun_to or mon_to
        start_str = formatDateForDisplay(mon_from, true)
        end_str   = formatDateForDisplay(sun_to or mon_to)
    else
        range_start = dates.start
        range_end   = dates.end_
        start_str = formatDateForDisplay(dates.start, true)
        end_str   = formatDateForDisplay(dates.end_)
    end

    local period = getStreakPeriodStats(range_start, range_end)
    local num_days = daysBetweenInclusive(range_start, range_end)
    local avg_seconds = num_days > 0 and (period.duration / num_days) or 0

    local total_mins = math.floor(period.duration / 60 + 0.5)
    local total_time_val = string.format("%02d:%02d", math.floor(total_mins / 60), total_mins % 60)

    local avg_mins = math.floor(avg_seconds / 60 + 0.5)
    local avg_time_val = string.format("%02d:%02d", math.floor(avg_mins / 60), avg_mins % 60)

    local book_count = period.books
    local book_label
    if is_current then
        book_label = N_("book read in this streak",
                         "books read in this streak", book_count)
    else
        book_label = N_("book read in this streak",
                         "books read in this streak", book_count)
    end

    local fonts = getCachedFonts()
    local inner_padding = Size.padding.large
    local max_width = math.floor(Screen:getWidth() * 0.9) - 2 * inner_padding

    -- Build the title/date text widgets first so we can measure their natural width.
    local title_w
    if is_current ~= nil then
        local label = is_current and _("Current streak") or _("Best streak")
        title_w = TextWidget:new{ text = label, face = fonts.section }
    end
    local date_w = TextWidget:new{ text = start_str .. " – " .. end_str, face = fonts.label }

    -- Measure each value/label row at its own natural (unwrapped) width.
    local function naturalRowWidth(value, unit)
        local value_w = TextWidget:new{ text = value, face = fonts.value }:getSize().w
        local label_w = TextWidget:new{ text = unit,  face = fonts.label }:getSize().w
        return value_w + Size.padding.large + label_w
    end

    local row_width = math.max(
        naturalRowWidth(total_time_val, _("total reading time")),
        naturalRowWidth(avg_time_val, _("avg time/day")),
        naturalRowWidth(tostring(book_count), book_label)
    )

    -- The box hugs whichever element is widest (title / date / value rows),
    -- capped so it never overflows the screen. No more fixed 86%-wide box.
    local content_width = row_width
    if title_w then content_width = math.max(content_width, title_w:getSize().w) end
    content_width = math.max(content_width, date_w:getSize().w)
    content_width = math.min(content_width, max_width)
    row_width = math.min(row_width, content_width)

    local content = VerticalGroup:new{ align = "left" }

    if title_w then
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = content_width, h = title_w:getSize().h }, title_w,
        })
        table.insert(content, VerticalSpan:new{ height = Size.padding.default })
    end

    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = content_width, h = date_w:getSize().h }, date_w,
    })
    table.insert(content, VerticalSpan:new{ height = Size.padding.default })
    table.insert(content, LineWidget:new{
        dimen      = Geom:new{ w = content_width, h = Size.line.thin },
        background = Blitbuffer.COLOR_GRAY,
    })
    table.insert(content, VerticalSpan:new{ height = Size.padding.large })

    local value_lines = VerticalGroup:new{ align = "left" }
    table.insert(value_lines, buildValueLine(fonts.value, fonts.label, row_width,
        total_time_val, _("total reading time")))
    table.insert(value_lines, VerticalSpan:new{ height = Size.padding.default })
    table.insert(value_lines, buildValueLine(fonts.value, fonts.label, row_width,
        avg_time_val, _("avg time/day")))
    table.insert(value_lines, VerticalSpan:new{ height = Size.padding.default })
    table.insert(value_lines, buildValueLine(fonts.value, fonts.label, row_width,
        tostring(book_count), book_label))

    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = content_width, h = value_lines:getSize().h },
        value_lines,
    })

    local box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }

    UIManager:show(WeeklyTrendPopup:new{ box_content = box })
end

local function buildInsightsSections(popup_self, streaks, yearly_stats, year_range, monthly_data, all_time_stats, last_week_stats, last_week_daily, fonts, layout)
    local sections = VerticalGroup:new{ align = "left" }

    do
        local lw = last_week_stats or { avg_seconds = 0, avg_pages = 0 }
        local has_week = lw.avg_seconds > 0 or lw.avg_pages > 0
        if has_week then

            local avg_secs = lw.avg_seconds or 0
            local avg_total_mins = math.floor(avg_secs / 60 + 0.5)
            local avg_h = math.floor(avg_total_mins / 60)
            local avg_m = avg_total_mins % 60
            local week_time_val = string.format("%02d:%02d", avg_h, avg_m)
            local week_time_unit_full = _("read time avg/day")

            local avg_pages_rounded
            if lw.avg_pages >= 10 then
                avg_pages_rounded = math.floor(lw.avg_pages + 0.5)
            else
                avg_pages_rounded = math.floor(lw.avg_pages * 10 + 0.5) / 10
            end
            local week_pages_val  = formatNumber(avg_pages_rounded, avg_pages_rounded ~= math.floor(avg_pages_rounded) and 1 or 0)
            local pages_unit_base = N_("page read", "pages read", avg_pages_rounded)
            local avg_day_str = _("avg/day")
            local week_pages_unit
            if getLangBase() == "hu" then
                week_pages_unit = avg_day_str
            else
                week_pages_unit = pages_unit_base .. " " .. avg_day_str
            end

            local week_row = buildTwoColRow(
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, week_time_val,   week_time_unit_full),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("time_avg") end),
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, week_pages_val,  week_pages_unit),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("pages_avg") end),
                layout)

            local total_secs = math.floor((lw.avg_seconds or 0) * 7 + 0.5)
            local total_mins = math.floor(total_secs / 60 + 0.5)
            local total_hh = math.floor(total_mins / 60)
            local total_mm = total_mins % 60
            local total_time_val = string.format("%02d:%02d", total_hh, total_mm)
            local total_time_unit = _("reading time")

            local total_pages_raw = math.floor((lw.avg_pages or 0) * 7 + 0.5)
            local total_pages_val = formatCount(total_pages_raw)
            local total_pages_unit = N_("page read", "pages read", total_pages_raw)

            local total_row = buildTwoColRow(
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, total_time_val, total_time_unit),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("time_total") end),
                tappableCell(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, total_pages_val, total_pages_unit),
                    layout.col_width, function() popup_self:showWeeklyTrendPopup("pages_total") end),
                layout)

            local weekly_chart = buildWeeklyChart(popup_self, last_week_daily, layout, fonts)
            local last_week_content = VerticalGroup:new{
                align = "left",
                padded(layout.padding_h, total_row),
                VerticalSpan:new{ height = Size.padding.default },
                padded(layout.padding_h, week_row),
            }
            if weekly_chart then
                table.insert(last_week_content, VerticalSpan:new{ height = Size.padding.default })
                table.insert(last_week_content, padded(layout.padding_h, weekly_chart))
            end

            addSectionWithRow(sections,
                buildSectionHeader(fonts.section, _("Last week"), layout.full_width),
                last_week_content, layout, { pad_row = false })
        end
    end

    local function streakDisplay(n, unit_label, empty_label)
        if n < 2 then return "", empty_label end
        return formatCount(n), unit_label(n)
    end

    local cd_val, cd_unit = streakDisplay(streaks.current_days,
        function(n) return N_("day in a row",  "days in a row",  n) end, _("No daily streak"))
    local cw_val, cw_unit = streakDisplay(streaks.current_weeks,
        function(n) return N_("week in a row", "weeks in a row", n) end, _("No weekly streak"))
    local bd_val, bd_unit = streakDisplay(streaks.best_days,
        function(n) return N_("day in a row",  "days in a row",  n) end, _("No daily streak"))
    local bw_val, bw_unit = streakDisplay(streaks.best_weeks,
        function(n) return N_("week in a row", "weeks in a row", n) end, _("No weekly streak"))

    -- Two-column streak header (tappable: shows date range for that streak).
    local streak_header_left  = buildSectionHeader(fonts.section, _("Current streak"), layout.col_width, 0)
    local streak_header_right = buildSectionHeader(fonts.section, _("Best streak"),    layout.col_width, 0)
    local sep_h = streak_header_left:getSize().h

    local tap_current_header = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=streak_header_left:getSize().h },
        streak_header_left,
    }
    tap_current_header.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_current_header.dimen } } }
    function tap_current_header:onTap()
        showStreakDatePopup(streaks.current_days_dates, false, true)
        return true
    end

    local tap_best_header = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=streak_header_right:getSize().h },
        streak_header_right,
    }
    tap_best_header.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_best_header.dimen } } }
    function tap_best_header:onTap()
        showStreakDatePopup(streaks.best_days_dates, false, false)
        return true
    end

    local streak_combined_header = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = layout.padding_h },
            fixedCol(tap_current_header, layout.col_width),
            buildColumnSeparator(layout.column_gap, sep_h),
            fixedCol(tap_best_header,    layout.col_width),
        },
    }

    -- Days row: tappable cells show date range
    local cd_line = buildValueLine(fonts.value, fonts.label, layout.col_width, cd_val, cd_unit)
    local bd_line = buildValueLine(fonts.value, fonts.label, layout.col_width, bd_val, bd_unit)

    local tap_cd = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=cd_line:getSize().h }, cd_line,
    }
    tap_cd.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_cd.dimen } } }
    function tap_cd:onTap() showStreakDatePopup(streaks.current_days_dates, false, true) return true end

    local tap_bd = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=bd_line:getSize().h }, bd_line,
    }
    tap_bd.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_bd.dimen } } }
    function tap_bd:onTap() showStreakDatePopup(streaks.best_days_dates, false, false) return true end

    local days_row = buildTwoColRow(tap_cd, tap_bd, layout)

    -- Weeks row: tappable cells show date range
    local cw_line = buildValueLine(fonts.value, fonts.label, layout.col_width, cw_val, cw_unit)
    local bw_line = buildValueLine(fonts.value, fonts.label, layout.col_width, bw_val, bw_unit)

    local tap_cw = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=cw_line:getSize().h }, cw_line,
    }
    tap_cw.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_cw.dimen } } }
    function tap_cw:onTap() showStreakDatePopup(streaks.current_weeks_dates, true, true) return true end

    local tap_bw = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=bw_line:getSize().h }, bw_line,
    }
    tap_bw.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_bw.dimen } } }
    function tap_bw:onTap() showStreakDatePopup(streaks.best_weeks_dates, true, false) return true end

    local weeks_row = buildTwoColRow(tap_cw, tap_bw, layout)

    local streak_rows = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            padded(layout.padding_h, days_row),
        },
        VerticalSpan:new{ height = Size.padding.default },
        FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            padded(layout.padding_h, weeks_row),
        },
    }

    addSectionWithRow(sections,
        streak_combined_header,
        streak_rows, layout, { pad_row = false })

    local year_header = buildYearHeader(fonts.section, layout, year_range, popup_self.selected_year)
    local yearly_row  = buildYearlyRow(popup_self, yearly_stats, fonts, layout)

    local chart = buildMonthlyChart(popup_self, monthly_data, layout, fonts)

    addSectionWithRow(sections, year_header, yearly_row, layout, { pad_row = false, no_bottom_line = not chart })

    if chart then
        local chart_header_text = (popup_self.mode == INSIGHTS_MODE_HOURS
            and _("Time read per month"))
            or (popup_self.mode == INSIGHTS_MODE_BOOKS
            and _("Books read per month"))
            or _("Days read per month")
        chart_header_text = chart_header_text .. " \xe2\x80\xba"
        local chart_header = buildSectionHeader(fonts.section, chart_header_text, layout.full_width)
        local tappable_chart_header = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = chart_header:getSize().w, h = chart_header:getSize().h },
            chart_header,
        }
        tappable_chart_header.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = tappable_chart_header.dimen } },
        }
        function tappable_chart_header:onTap()
            popup_self:cycleInsightsMode()
            return true
        end
        addSectionWithRow(sections, tappable_chart_header, chart, layout, { add_divider = true, no_bottom_line = false })
    end

    do
        local all_hours = all_time_stats and all_time_stats.hours or 0
        local all_pages = all_time_stats and all_time_stats.pages or 0

        local all_secs_approx = (all_time_stats and all_time_stats.duration) or (all_hours * 3600)
        local all_total_mins = math.floor(all_secs_approx / 60 + 0.5)
        local all_hh = math.floor(all_total_mins / 60)
        local all_mm = all_total_mins % 60
        local all_time_val  = string.format("%02d:%02d", all_hh, all_mm)
        local all_time_unit = _("reading time")
        local all_pages_val  = formatCount(all_pages)
        local all_pages_unit = N_("page read", "pages read", all_pages)

        local left_line  = buildValueLine(fonts.value, fonts.label, layout.col_width, all_time_val,  all_time_unit)
        local right_line = buildValueLine(fonts.value, fonts.label, layout.col_width, all_pages_val, all_pages_unit)

        local left_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = left_line:getSize().h },
            left_line,
        }
        left_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = left_cell.dimen } },
        }
        function left_cell:onTap()
            popup_self:showAllBooks()
            return true
        end

        local right_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = right_line:getSize().h },
            right_line,
        }
        right_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = right_cell.dimen } },
        }
        function right_cell:onTap()
            popup_self:showAllBooks()
            return true
        end

        local all_time_row = buildTwoColRow(left_cell, right_cell, layout)

        local all_book_count = all_time_stats and all_time_stats.book_count or 0
        local header_text = _("Total read")

        addSectionWithRow(sections,
            buildSectionHeader(fonts.section, header_text, layout.full_width),
            all_time_row, layout, { no_bottom_line = true })
    end

    return sections
end


local ReadingInsightsPopup = InputContainer:extend{
    modal         = true,
    ui            = nil,
    width         = nil,
    height        = nil,
    selected_year = nil,
    mode          = nil,
}

function ReadingInsightsPopup:calculateStreaks(shared_conn)
    local today  = todayDateStr()
    local minute = currentMinute()

    -- Daily lock: once we have confirmed today's reading and cached the result
    -- for today, skip the expensive full-table scan for the rest of the day.
    -- If today has no reading yet, fall back to per-minute checks so the streak
    -- updates as soon as the user starts reading.
    -- Force-reload (clearAllCache) wipes streaks_date so this is always bypassed.
    if ENABLE_CACHE and _cache.streaks then
        if _cache.streaks_date == today then
            return _cache.streaks
        end
        if _cache.streaks_today_confirmed and _cache.streaks_date_minute == minute then
            return _cache.streaks
        end
    end

    local streaks = {
        current_days  = 0,
        best_days     = 0,
        current_weeks = 0,
        best_weeks    = 0,
    }

    local result = withDb(shared_conn, streaks, function(conn)
        local dates = {}
        local sql = "SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') as d FROM page_stat ORDER BY d DESC"
        withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do table.insert(dates, row[1]) end
        end)

        local today_str   = os.date("%Y-%m-%d")
        local yesterday   = os.date("%Y-%m-%d", os.time() - 86400)

        local function isCurrentDayStart(first_date)
            return first_date == today_str or first_date == yesterday
        end

        local function isConsecutiveDay(prev_date, curr_date)
            local year, month, day = parseDateYMD(prev_date)
            if not year then return false end
            local prev_time   = os.time({ year = year, month = month, day = day })
            local expected_prev = os.date("%Y-%m-%d", prev_time - 86400)
            return curr_date == expected_prev
        end

        streaks.current_days, streaks.best_days,
        streaks.current_days_dates, streaks.best_days_dates =
            computeStreaksWithDates(dates, isConsecutiveDay, isCurrentDayStart)

        local weeks    = {}
        local sql_weeks = "SELECT DISTINCT strftime('%Y-%W', start_time, 'unixepoch', 'localtime') as w FROM page_stat ORDER BY w DESC"
        withStatement(conn, sql_weeks, function(stmt_weeks)
            for row in stmt_weeks:rows() do table.insert(weeks, row[1]) end
        end)

        local current_week = os.date("%Y-%W")
        local last_week    = os.date("%Y-%W", os.time() - 7 * 86400)

        local function isCurrentWeekStart(first_week)
            return first_week == current_week or first_week == last_week
        end

        local function isConsecutiveWeek(prev_week, curr_week)
            local prev_year, prev_wk = parseWeekYear(prev_week)
            local curr_year, curr_wk = parseWeekYear(curr_week)
            if not prev_year or not curr_year then return false end
            if prev_year == curr_year and prev_wk == curr_wk + 1 then return true end
            if prev_year == curr_year + 1 and prev_wk == 0 and curr_wk >= 52 then return true end
            return false
        end

        streaks.current_weeks, streaks.best_weeks,
        streaks.current_weeks_dates, streaks.best_weeks_dates =
            computeStreaksWithDates(weeks, isConsecutiveWeek, isCurrentWeekStart)

        -- Check whether today already has confirmed reading activity in the DB.
        -- If yes, the streak result is stable for the rest of the day.
        local today_confirmed = false
        if dates[1] == today_str then
            today_confirmed = true
        end
        streaks._today_confirmed = today_confirmed

        return streaks
    end)

    if ENABLE_CACHE then
        _cache.streaks      = result
        _stale_cache.streaks = result
        -- If today's reading is confirmed in the DB, lock to daily refresh.
        -- Otherwise keep the per-minute fallback so the first read of the day is picked up.
        local today_confirmed = result and result._today_confirmed
        _cache.streaks_today_confirmed = today_confirmed
        if today_confirmed then
            _cache.streaks_date        = today
            _cache.streaks_date_minute = nil
        else
            _cache.streaks_date        = nil
            _cache.streaks_date_minute = minute
        end
    end
    return result
end

function ReadingInsightsPopup:getMonthlyReadingDays(year, shared_conn)
    local today         = todayDateStr()
    local key           = "days:" .. year .. ":" .. today
    local base_key      = "days:" .. year
    local current_month = today:sub(1, 7)
    local minute        = currentMinute()

    -- Fast path: already served this exact minute, skip the DB entirely.
    local cached_val = getMinuteCache(_monthly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = getCachedBase(_monthly_base_cache, base_key, today)

    -- One connection covers both the (rare, once/day) base recompute and the
    -- (frequent) cheap today-only check.
    local merged = withDb(shared_conn, nil, function(conn)
        local base = cached_base
        if not base then
            local year_str = tostring(year)
            local sql = string.format([[
                SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS month,
                       COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime')) AS days_read
                FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                  AND date(start_time, 'unixepoch', 'localtime') < '%s'
                GROUP BY month
                ORDER BY month ASC
            ]], year_str, today)

            base = {}
            withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do base[row[1]] = row[2] end
            end)
        end

        local today_has_activity = false
        withStatement(conn, string.format([[
            SELECT 1 FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
            LIMIT 1
        ]], today), function(stmt)
            for _ in stmt:rows() do today_has_activity = true end
        end)

        return { base = base, today_has_activity = today_has_activity }
    end)
    if not merged then
        merged = { base = cached_base or {}, today_has_activity = false }
    end

    if ENABLE_CACHE and not cached_base then
        _monthly_base_cache[base_key] = makeCachedBase(today, merged.base)
    end

    local months = buildMonthlyArray(year, function(year_month)
        local days = tonumber(merged.base[year_month]) or 0
        if merged.today_has_activity and year_month == current_month then
            days = days + 1
        end
        return { days = days }
    end)

    setMinuteCache(_monthly_cache, _stale_monthly, key, key .. ":minute", minute, months)
    return months
end

function ReadingInsightsPopup:getMonthlyReadingHours(year, shared_conn)
    local today         = todayDateStr()
    local key           = "hours:" .. year .. ":" .. today
    local base_key      = "hours:" .. year
    local current_month = today:sub(1, 7)
    local minute        = currentMinute()

    local cached_val = getMinuteCache(_monthly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = getCachedBase(_monthly_base_cache, base_key, today)

    local merged = withDb(shared_conn, nil, function(conn)
        local base = cached_base
        if not base then
            local year_str = tostring(year)
            local sql = string.format([[
                SELECT dates AS month,
                       SUM(sum_duration) AS sum_duration
                FROM (
                    SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS dates,
                           sum(duration) AS sum_duration
                    FROM page_stat
                    WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                      AND date(start_time, 'unixepoch', 'localtime') < '%s'
                    GROUP BY id_book, page, dates
                )
                GROUP BY dates
                ORDER BY dates ASC
            ]], year_str, today)

            base = {}
            withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do base[row[1]] = row[2] end
            end)
        end

        local today_seconds = 0
        withStatement(conn, string.format([[
            SELECT id_book, page, SUM(duration) AS dur
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
            GROUP BY id_book, page
        ]], today), function(stmt)
            for row in stmt:rows() do
                today_seconds = today_seconds + (tonumber(row[3]) or 0)
            end
        end)

        return { base = base, today_seconds = today_seconds }
    end)
    if not merged then
        merged = { base = cached_base or {}, today_seconds = 0 }
    end

    if ENABLE_CACHE and not cached_base then
        _monthly_base_cache[base_key] = makeCachedBase(today, merged.base)
    end

    local months = buildMonthlyArray(year, function(year_month)
        local seconds_raw = tonumber(merged.base[year_month]) or 0
        if year_month == current_month then
            seconds_raw = seconds_raw + merged.today_seconds
        end
        local hours = seconds_raw / 3600.0
        if hours >= 1 then
            hours = math.floor(hours)
        elseif hours > 0 then
            hours = (math.floor(hours * 10)) / 10
        end
        return { hours = hours, seconds = math.floor(seconds_raw + 0.5) }
    end)

    setMinuteCache(_monthly_cache, _stale_monthly, key, key .. ":minute", minute, months)
    return months
end

function ReadingInsightsPopup:getYearlyStats(year, shared_conn)
    local today    = todayDateStr()
    local key      = year .. ":v3:" .. today
    local base_key = year .. ":v3"
    local minute   = currentMinute()

    local cached_val = getMinuteCache(_yearly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = getCachedBase(_yearly_base_cache, base_key, today)

    -- One connection covers both the (once/day) base recompute and the
    -- (frequent) cheap today-only slice.
    local merged = withDb(shared_conn, nil, function(conn)
        local base = cached_base
        if not base then
            local year_str = tostring(year)
            local sql = string.format([[
                WITH dedup AS (
                    SELECT id_book,
                           page,
                           date(start_time, 'unixepoch', 'localtime') AS day,
                           SUM(duration) AS dur
                    FROM page_stat
                    WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                      AND date(start_time, 'unixepoch', 'localtime') < '%s'
                    GROUP BY id_book, page, day
                )
                SELECT
                    COUNT(DISTINCT day)      AS days_read,
                    COUNT(*)                 AS pages_read,
                    SUM(dur)                 AS total_duration,
                    COUNT(DISTINCT id_book)  AS books_started
                FROM dedup
            ]], year_str, today)

            base = { days = 0, pages = 0, duration = 0, books_started = 0, book_ids = {} }
            withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do
                    base.days          = tonumber(row[1]) or 0
                    base.pages         = tonumber(row[2]) or 0
                    base.duration      = tonumber(row[3]) or 0
                    base.books_started = tonumber(row[4]) or 0
                end
            end)

            local ids_sql = string.format([[
                SELECT DISTINCT id_book
                FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                  AND date(start_time, 'unixepoch', 'localtime') < '%s'
            ]], year_str, today)
            withStatement(conn, ids_sql, function(stmt)
                for row in stmt:rows() do base.book_ids[tostring(row[1])] = true end
            end)
        end

        local t = { pages = 0, duration = 0, has_activity = false, new_books = 0 }
        -- Only merge "today" into the total when the requested year is the
        -- current year - otherwise today's (this year's) activity would get
        -- added on top of a past, already-closed year's total.
        if year == tonumber(os.date("%Y")) then
            local seen = {}
            withStatement(conn, string.format([[
                SELECT id_book, page, SUM(duration) AS dur
                FROM page_stat
                WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book, page
            ]], today), function(stmt)
                for row in stmt:rows() do
                    t.pages        = t.pages + 1
                    t.duration     = t.duration + (tonumber(row[3]) or 0)
                    t.has_activity = true
                    local id_book = tostring(row[1])
                    if not base.book_ids[id_book] and not seen[id_book] then
                        seen[id_book] = true
                        t.new_books = t.new_books + 1
                    end
                end
            end)
        end

        return { base = base, today_stats = t }
    end)
    if not merged then
        merged = {
            base        = cached_base or { days = 0, pages = 0, duration = 0, books_started = 0, book_ids = {} },
            today_stats = { pages = 0, duration = 0, has_activity = false, new_books = 0 },
        }
    end

    if ENABLE_CACHE and not cached_base then
        _yearly_base_cache[base_key] = makeCachedBase(today, merged.base)
    end

    local base, today_stats = merged.base, merged.today_stats
    local result = {
        days          = base.days + (today_stats.has_activity and 1 or 0),
        pages         = base.pages + today_stats.pages,
        duration      = base.duration + today_stats.duration,
        books_started = base.books_started + today_stats.new_books,
    }
    result.avg_days_per_book = 0
    if result.books_started > 0 then
        result.avg_days_per_book = math.ceil(result.days / result.books_started)
    end

    setMinuteCache(_yearly_cache, _stale_yearly, key, key .. ":minute", minute, result)
    return result
end

-- Returns { min_year, max_year } from the DB, cached per day.
function ReadingInsightsPopup:getYearRange(shared_conn)
    local today        = todayDateStr()
    local range_cached = ENABLE_CACHE and _cache.year_range and _cache.year_range_date == today

    if range_cached then
        return _cache.year_range
    end

    local current_year = tonumber(os.date("%Y"))
    local range = { min_year = current_year, max_year = current_year }

    withDb(shared_conn, nil, function(conn)
        local sql_range = [[
            SELECT MIN(strftime('%Y', start_time, 'unixepoch', 'localtime')) AS min_year,
                   MAX(strftime('%Y', start_time, 'unixepoch', 'localtime')) AS max_year
            FROM page_stat
        ]]
        withStatement(conn, sql_range, function(stmt)
            for row in stmt:rows() do
                if row[1] then range.min_year = tonumber(row[1]) or current_year end
                if row[2] then range.max_year = tonumber(row[2]) or current_year end
            end
        end)
        if ENABLE_CACHE then
            _cache.year_range      = range
            _cache.year_range_date = today
            _stale_cache.year_range = range
        end
    end)

    return range
end

function ReadingInsightsPopup:getAllTimeStats(shared_conn)
    local today  = todayDateStr()
    local minute = currentMinute()

    local cached_val = getMinuteCache(_cache, "all_time", "all_time_minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = getCachedBase(_alltime_base_cache, nil, today)

    -- One connection covers both the (once/day, whole-history) base
    -- recompute and today's cheap, narrowly-scoped queries.
    local merged = withDb(shared_conn, nil, function(conn)
        local base = cached_base
        if not base then
            base = { duration = 0, pages = 0, book_count = 0 }
            withStatement(conn, string.format([[
                SELECT SUM(sum_dur), COUNT(DISTINCT dedup_page)
                FROM (
                    SELECT SUM(duration) AS sum_dur, id_book || '-' || page AS dedup_page
                    FROM page_stat
                    WHERE date(start_time, 'unixepoch', 'localtime') < '%s'
                    GROUP BY id_book, page, date(start_time, 'unixepoch', 'localtime')
                )
            ]], today), function(stmt)
                for row in stmt:rows() do
                    base.duration = tonumber(row[1]) or 0
                    base.pages    = tonumber(row[2]) or 0
                end
            end)
            withStatement(conn, string.format([[
                SELECT COUNT(DISTINCT id_book) FROM page_stat
                WHERE date(start_time, 'unixepoch', 'localtime') < '%s'
            ]], today), function(stmt)
                for row in stmt:rows() do base.book_count = tonumber(row[1]) or 0 end
            end)
        end

        local t = { duration = 0, new_pages = 0, new_books = 0 }

        withStatement(conn, string.format([[
            SELECT SUM(duration) FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
        ]], today), function(stmt)
            for row in stmt:rows() do t.duration = tonumber(row[1]) or 0 end
        end)

        withStatement(conn, string.format([[
            SELECT COUNT(*) FROM (
                SELECT DISTINCT id_book, page FROM page_stat
                WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
            ) t
            WHERE NOT EXISTS (
                SELECT 1 FROM page_stat p
                WHERE p.id_book = t.id_book AND p.page = t.page
                  AND date(p.start_time, 'unixepoch', 'localtime') < '%s'
            )
        ]], today, today), function(stmt)
            for row in stmt:rows() do t.new_pages = tonumber(row[1]) or 0 end
        end)

        withStatement(conn, string.format([[
            SELECT COUNT(DISTINCT id_book) FROM page_stat t
            WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
              AND NOT EXISTS (
                SELECT 1 FROM page_stat p
                WHERE p.id_book = t.id_book
                  AND date(p.start_time, 'unixepoch', 'localtime') < '%s'
              )
        ]], today, today), function(stmt)
            for row in stmt:rows() do t.new_books = tonumber(row[1]) or 0 end
        end)

        return { base = base, today_stats = t }
    end)
    if not merged then
        merged = {
            base        = cached_base or { duration = 0, pages = 0, book_count = 0 },
            today_stats = { duration = 0, new_pages = 0, new_books = 0 },
        }
    end

    if ENABLE_CACHE and not cached_base then
        _alltime_base_cache = makeCachedBase(today, merged.base)
    end

    local base, today_stats = merged.base, merged.today_stats
    local duration = base.duration + today_stats.duration
    local mins = Math.round(duration / 60)
    local result = {
        hours      = math.floor(mins / 60),
        pages      = base.pages + today_stats.new_pages,
        book_count = base.book_count + today_stats.new_books,
        duration   = duration,
    }

    setMinuteCache(_cache, _stale_cache, "all_time", "all_time_minute", minute, result)
    return result
end

-- Returns both last-week stats in one DB connection:
--   last_week:       { avg_seconds, avg_pages }
--   last_week_daily: array[7] of { hours, seconds, label, midnight_ts }, index 1 = today
function ReadingInsightsPopup:getLastWeekAll(shared_conn)
    local minute = currentMinute()
    local lw_ok    = getMinuteCache(_cache, "last_week", "last_week_minute", minute) ~= nil
    local daily_ok = getMinuteCache(_cache, "last_week_daily", "last_week_daily_minute", minute) ~= nil
    if lw_ok and daily_ok then
        return _cache.last_week, _cache.last_week_daily
    end

    local now_ts  = os.time()
    local now_t   = os.date("*t")
    local today_midnight = now_ts - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec)
    local week_start_ts  = today_midnight - 6 * 86400

    local DOW_KEYS = { [0]="Sun", [1]="Mon", [2]="Tue", [3]="Wed", [4]="Thu", [5]="Fri", [6]="Sat" }
    local date_info = {}
    for i = 0, 6 do
        local day_midnight = today_midnight - i * 86400
        local date_str = os.date("%Y-%m-%d", day_midnight)
        local dow      = tonumber(os.date("%w", day_midnight))
        local label
        if i == 0 then
            label = _("Today")
        elseif i == 1 then
            label = _("Yesterday")
        else
            label = _(DOW_KEYS[dow] or "")
        end
        date_info[i + 1] = { date_str = date_str, label = label, midnight_ts = day_midnight }
    end

    local lw_result    = lw_ok    and _cache.last_week       or { avg_seconds = 0, avg_pages = 0 }
    local daily_result = daily_ok and _cache.last_week_daily or nil

    withDb(shared_conn, nil, function(conn)
        -- Single query: per-day totals for the last 7 days.
        -- From this we derive both the 7-day averages and the per-day chart data.
        local sql = string.format([[
            SELECT date(start_time, 'unixepoch', 'localtime') AS day,
                   SUM(sum_dur)    AS total_sec,
                   COUNT(*)        AS total_pages
            FROM (
                SELECT start_time,
                       SUM(duration) AS sum_dur
                FROM page_stat
                WHERE start_time >= %d
                GROUP BY id_book, page, date(start_time, 'unixepoch', 'localtime')
            )
            GROUP BY day
        ]], week_start_ts)

        local seconds_by_date = {}
        local pages_by_date   = {}
        if not lw_ok or not daily_ok then
            withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do
                    seconds_by_date[row[1]] = tonumber(row[2]) or 0
                    pages_by_date[row[1]]   = tonumber(row[3]) or 0
                end
            end)
        end

        if not lw_ok then
            local total_sec   = 0
            local total_pages = 0
            for _, secs in pairs(seconds_by_date) do total_sec   = total_sec   + secs end
            for _, pgs  in pairs(pages_by_date)   do total_pages = total_pages + pgs  end
            lw_result = { avg_seconds = total_sec / 7, avg_pages = total_pages / 7 }
        end

        if not daily_ok then
            local hours_by_date = {}
            for date_str, secs in pairs(seconds_by_date) do
                local h = secs / 3600.0
                if h >= 1 then
                    h = math.floor(h + 0.5)
                elseif h > 0 then
                    h = math.floor(h * 10 + 0.5) / 10
                end
                hours_by_date[date_str] = h
            end
            daily_result = {}
            for i = 1, 7 do
                local di = date_info[i]
                daily_result[i] = {
                    hours       = hours_by_date[di.date_str]   or 0,
                    seconds     = seconds_by_date[di.date_str] or 0,
                    label       = di.label,
                    midnight_ts = di.midnight_ts,
                }
            end
        end
    end)

    if not daily_result then
        daily_result = {}
        for i = 1, 7 do
            local di = date_info[i]
            daily_result[i] = { hours = 0, seconds = 0, label = di.label, midnight_ts = di.midnight_ts }
        end
    end

    setMinuteCache(_cache, _stale_cache, "last_week", "last_week_minute", minute, lw_result)
    setMinuteCache(_cache, _stale_cache, "last_week_daily", "last_week_daily_minute", minute, daily_result)
    return lw_result, daily_result
end

-- Returns an array of 8 weekly buckets (index 1 = oldest of the 8 weeks,
-- index 8 = current week), each { start_date, end_date, seconds, pages }.
-- Mirrors the de-duplication logic used by getLastWeekAll, just over a
-- wider 56-day window split into 7-day chunks.
function ReadingInsightsPopup:getLast8WeeksData()
    local minute = currentMinute()
    local cached_val = getMinuteCache(_cache, "last8weeks", "last8weeks_minute", minute)
    if cached_val then
        return cached_val
    end

    local now_ts  = os.time()
    local now_t   = os.date("*t")
    local today_midnight = now_ts - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec)
    local period_start_ts = today_midnight - (8 * 7 - 1) * 86400

    local weeks = {}
    for w = 1, 8 do
        local week_end_midnight   = today_midnight - (8 - w) * 7 * 86400
        local week_start_midnight = week_end_midnight - 6 * 86400
        weeks[w] = {
            start_date = os.date("%Y-%m-%d", week_start_midnight),
            end_date   = os.date("%Y-%m-%d", week_end_midnight),
            seconds    = 0,
            pages      = 0,
        }
    end

    withStatsDb(nil, function(conn)
        local sql = string.format([[
            SELECT date(start_time, 'unixepoch', 'localtime') AS day,
                   SUM(sum_dur) AS total_sec,
                   COUNT(*)     AS total_pages
            FROM (
                SELECT start_time,
                       SUM(duration) AS sum_dur
                FROM page_stat
                WHERE start_time >= %d
                GROUP BY id_book, page, date(start_time, 'unixepoch', 'localtime')
            )
            GROUP BY day
        ]], period_start_ts)

        withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                local day_str = row[1]
                local secs  = tonumber(row[2]) or 0
                local pages = tonumber(row[3]) or 0
                local y, m, d = parseDateYMD(day_str)
                if y then
                    local day_ts = os.time({ year = y, month = m, day = d })
                    local diff_days = math.floor((today_midnight - day_ts) / 86400 + 0.5)
                    local week_from_end = math.floor(diff_days / 7)  -- 0 = current week
                    local w = 8 - week_from_end
                    if w >= 1 and w <= 8 then
                        weeks[w].seconds = weeks[w].seconds + secs
                        weeks[w].pages   = weeks[w].pages   + pages
                    end
                end
            end
        end)
    end)

    setMinuteCache(_cache, _stale_cache, "last8weeks", "last8weeks_minute", minute, weeks)
    return weeks
end

-- Build and show the 8-week trend popup for the given metric:
-- "time_total" | "pages_total" | "time_avg" | "pages_avg".
function ReadingInsightsPopup:showWeeklyTrendPopup(metric)
    local weeks = self:getLast8WeeksData()
    if not weeks or #weeks == 0 then
        UIManager:show(InfoMessage:new{ text = _("No streak dates") })
        return
    end

    local has_data = false
    for _, w in ipairs(weeks) do
        if (w.seconds or 0) > 0 or (w.pages or 0) > 0 then
            has_data = true
            break
        end
    end
    if not has_data then
        UIManager:show(InfoMessage:new{ text = _("No reading data in the last 8 weeks") })
        return
    end

    local fonts  = getCachedFonts()
    local inner_padding = Size.padding.large
    local box_width   = math.floor(Screen:getWidth() * 0.86)
    local chart_width = box_width - 2 * inner_padding

    local title_w = TextWidget:new{ text = trendTitle(metric), face = fonts.section }
    local title_centered = CenterContainer:new{
        dimen = Geom:new{ w = chart_width, h = title_w:getSize().h }, title_w,
    }

    local value_w = TextWidget:new{ text = totalForMetric(metric, weeks), face = fonts.value }
    local value_centered = CenterContainer:new{
        dimen = Geom:new{ w = chart_width, h = value_w:getSize().h }, value_w,
    }

    local chart_widget = buildLine8WeekChart(weeks, metric, chart_width, fonts)

    local content = VerticalGroup:new{
        align = "center",
        title_centered,
        VerticalSpan:new{ height = Size.padding.default },
        value_centered,
        VerticalSpan:new{ height = Size.padding.large },
        chart_widget,
    }

    local box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }

    UIManager:show(WeeklyTrendPopup:new{ box_content = box })
end

-- Sums the .duration field (seconds) across a list of books; used to build
-- the "(H:MM:SS)" suffix in the various "books read in <period>" titles.
local function sumDuration(books)
    local total_secs = 0
    for _, b in ipairs(books) do
        total_secs = total_secs + (b.duration or 0)
    end
    return total_secs
end

local function getBooksForPeriod(period_format, period_value)
    local books = {}
    return withStatsDb(books, function(conn)
        -- De-duplicated reading time per book for the period.
        -- period_format inserted via concatenation to avoid %% escape conflicts.
        local sql = [[
            SELECT book.title, book.authors,
                   COUNT(DISTINCT ps_dedup.page) AS pages_read,
                   SUM(ps_dedup.period_sum) AS duration_sec,
                   fin.finish_time,
                   MAX(ps_dedup.last_read) AS last_read_time,
                   day_counts.days_read,
                   book.id AS id_book
            FROM (
                SELECT id_book, page,
                       SUM(duration) AS period_sum,
                       MAX(start_time) AS last_read
                FROM page_stat
                WHERE strftime(']] .. period_format .. [[', start_time, 'unixepoch', 'localtime') = ']] .. period_value .. [['
                GROUP BY id_book, page
            ) ps_dedup
            JOIN book ON ps_dedup.id_book = book.id
            LEFT JOIN (
                SELECT ps2.id_book, MAX(ps2.start_time) AS finish_time
                FROM page_stat ps2
                JOIN book b2 ON ps2.id_book = b2.id
                WHERE b2.pages > 0
                GROUP BY ps2.id_book
                HAVING MAX(ps2.page) >= b2.pages
            ) fin ON ps_dedup.id_book = fin.id_book
            LEFT JOIN (
                SELECT id_book,
                       COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime')) AS days_read
                FROM page_stat
                WHERE strftime(']] .. period_format .. [[', start_time, 'unixepoch', 'localtime') = ']] .. period_value .. [['
                GROUP BY id_book
            ) day_counts ON ps_dedup.id_book = day_counts.id_book
            GROUP BY ps_dedup.id_book
            ORDER BY MAX(ps_dedup.last_read) DESC
        ]]

        withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    title     = row[1] or _("Unknown"),
                    authors   = "",
                    pages     = tonumber(row[3]) or 0,
                    duration  = tonumber(row[4]) or 0,
                    days_read = tonumber(row[7]) or 0,
                    id_book   = tonumber(row[8]),
                })
            end
        end)
        return books
    end)
end

local function getAllBooks()
    local books = {}
    return withStatsDb(books, function(conn)
        local sql = [[
            SELECT book.title, book.authors,
                   COUNT(DISTINCT ps_dedup.page) AS pages_read,
                   SUM(ps_dedup.period_sum) AS duration_sec,
                   MAX(ps_dedup.last_read) AS last_read_time,
                   book.id AS id_book
            FROM (
                SELECT id_book, page,
                       SUM(duration) AS period_sum,
                       MAX(start_time) AS last_read
                FROM page_stat
                GROUP BY id_book, page
            ) ps_dedup
            JOIN book ON ps_dedup.id_book = book.id
            GROUP BY ps_dedup.id_book
            ORDER BY last_read_time DESC
        ]]
        withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    title    = row[1] or _("Unknown"),
                    authors  = "",
                    pages    = tonumber(row[3]) or 0,
                    duration = tonumber(row[4]) or 0,
                    id_book  = tonumber(row[6]),
                })
            end
        end)
        return books
    end)
end

function ReadingInsightsPopup:getBooksForMonth(year_month)
    return getBooksForPeriod("%Y-%m", year_month)
end

local function showBookList(title, books, on_close, stats_plugin)
    local KeyValuePage = require("ui/widget/keyvaluepage")

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books read") })
        return
    end

    local kv_pairs = {}
    for _, book in ipairs(books) do
        local display_text = book.title
        if book.authors and book.authors ~= "" then
            display_text = display_text .. "\n" .. book.authors
        end

        local time_str
        if book.duration and book.duration > 0 then
            time_str = formatHHMMSS(book.duration)
        else
            time_str = "00:00:00"
        end
        local time_text = time_str
        local book_id = book.id_book
        local book_title = book.title
        local cb = nil
        if book_id and stats_plugin then
            cb = function()
                local kv2
                kv2 = KeyValuePage:new{
                    title           = book_title,
                    kv_pairs        = stats_plugin:getBookStat(book_id),
                    value_align     = "right",
                    single_page     = true,
                    callback_return = function()
                        UIManager:close(kv2)
                    end,
                    close_callback  = function() kv2 = nil end,
                }
                UIManager:show(kv2)
            end
        end
        table.insert(kv_pairs, {
            display_text,
            time_text,
            callback = cb,
        })
    end

    local kv
    kv = KeyValuePage:new{
        title          = title,
        kv_pairs       = kv_pairs,
        value_align    = "right",
        close_callback = function()
            UIManager:close(kv)
            UIManager:scheduleIn(0, function()
                if on_close then on_close() end
            end)
        end,
    }
    UIManager:show(kv)
end

local function showBooksForPeriod(popup_self, books, empty_text, title)
    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = empty_text })
        return
    end

    local saved_year     = popup_self.selected_year
    local saved_mode     = popup_self.mode
    local saved_ui       = popup_self.ui

    local saved_streaks        = popup_self._streaks
    local saved_yr             = popup_self._year_range
    local saved_yearly         = popup_self._yearly
    local saved_monthly        = popup_self._monthly
    local saved_all_time       = popup_self._all_time
    local saved_last_week      = popup_self._last_week
    local saved_last_week_daily = popup_self._last_week_daily

    popup_self._closed = true
    UIManager:close(popup_self)

    local stats_plugin = saved_ui and saved_ui.statistics or nil
    showBookList(title, books, function()
        local p = ReadingInsightsPopup:new{
            ui               = saved_ui,
            selected_year    = saved_year,
            mode             = saved_mode,
            _streaks         = saved_streaks,
            _year_range      = saved_yr,
            _yearly          = saved_yearly,
            _monthly         = saved_monthly,
            _all_time        = saved_all_time,
            _last_week       = saved_last_week,
            _last_week_daily = saved_last_week_daily,
        }
        UIManager:show(p)
    end, stats_plugin)
end

function ReadingInsightsPopup:showBooksForMonth(year_month, month_label_full)
    local books = self:getBooksForMonth(year_month)
    local total_secs = sumDuration(books)
    local title = T(N_("%1 - book read %2", "%1 - books read %2", #books), month_label_full, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")"
    showBooksForPeriod(
        self, books,
        T(_("No books read in %1"), month_label_full),
        title)
end

-- Open CalendarView for the given "YYYY-MM" string.
-- Closes this popup first; reopens it when CalendarView is dismissed.
function ReadingInsightsPopup:openCalendarForMonth(year_month)
    local year  = tonumber(year_month:sub(1, 4))
    local month = tonumber(year_month:sub(6, 7))
    if not year or not month then return end

    local ok, CalendarView = pcall(require, "ui/widget/calendarview")
    if not ok or not CalendarView then
        ok, CalendarView = pcall(require, "calendarview")
    end
    if not ok or not CalendarView then
        UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
        return
    end

    -- Save state so the popup can be recreated after CalendarView closes.
    local saved_year             = self.selected_year
    local saved_mode             = self.mode
    local saved_ui               = self.ui
    local saved_streaks          = self._streaks
    local saved_yr               = self._year_range
    local saved_yearly           = self._yearly
    local saved_monthly          = self._monthly
    local saved_all_time         = self._all_time
    local saved_last_week        = self._last_week
    local saved_last_week_daily  = self._last_week_daily

    self._closed = true
    UIManager:close(self)

    -- Wait one frame so the popup is fully closed before opening CalendarView.
    UIManager:scheduleIn(0, function()
        local stats_plugin = saved_ui and saved_ui.statistics or nil

        local function reopen_popup()
            local p = ReadingInsightsPopup:new{
                ui               = saved_ui,
                selected_year    = saved_year,
                mode             = saved_mode,
                _streaks         = saved_streaks,
                _year_range      = saved_yr,
                _yearly          = saved_yearly,
                _monthly         = saved_monthly,
                _all_time        = saved_all_time,
                _last_week       = saved_last_week,
                _last_week_daily = saved_last_week_daily,
            }
            UIManager:show(p)
        end

        local reopened = false
        local function reopen_once()
            if reopened then return end
            reopened = true
            UIManager:scheduleIn(0, reopen_popup)
        end

        local cv
        cv = CalendarView:new{
            reader_statistics = stats_plugin,
            shown_year        = year,
            shown_month       = month,
            close_callback    = function()

                reopen_once()
            end,
        }
        -- onCloseWidget fires on all dismiss paths; the flag prevents double-open.
        local orig_onCloseWidget = cv.onCloseWidget
        cv.onCloseWidget = function(self_cv, ...)
            if orig_onCloseWidget then orig_onCloseWidget(self_cv, ...) end
            reopen_once()
        end
        UIManager:show(cv)
    end)
end

-- Open today's reading timeline (CalendarDayView) for the current day.
-- Closes this popup first; reopens it when the timeline is dismissed.
function ReadingInsightsPopup:openTodayTimeline()
    local ok, CalendarView = pcall(require, "ui/widget/calendarview")
    if not ok or not CalendarView then
        ok, CalendarView = pcall(require, "calendarview")
    end
    if not ok or not CalendarView then
        UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
        return
    end

    -- Save state so the popup can be recreated after the timeline closes.
    local saved_year             = self.selected_year
    local saved_mode             = self.mode
    local saved_ui               = self.ui
    local saved_streaks          = self._streaks
    local saved_yr               = self._year_range
    local saved_yearly           = self._yearly
    local saved_monthly          = self._monthly
    local saved_all_time         = self._all_time
    local saved_last_week        = self._last_week
    local saved_last_week_daily  = self._last_week_daily

    self._closed = true
    UIManager:close(self)

    -- Wait one frame so the popup is fully closed before opening the timeline.
    UIManager:scheduleIn(0, function()
        local stats_plugin = saved_ui and saved_ui.statistics or nil
        if not stats_plugin then
            UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
            return
        end

        local function reopen_popup()
            local p = ReadingInsightsPopup:new{
                ui               = saved_ui,
                selected_year    = saved_year,
                mode             = saved_mode,
                _streaks         = saved_streaks,
                _year_range      = saved_yr,
                _yearly          = saved_yearly,
                _monthly         = saved_monthly,
                _all_time        = saved_all_time,
                _last_week       = saved_last_week,
                _last_week_daily = saved_last_week_daily,
            }
            UIManager:show(p)
        end

        local reopened = false
        local function reopen_once()
            if reopened then return end
            reopened = true
            UIManager:scheduleIn(0, reopen_popup)
        end

        -- CalendarView:showCalendarDayView() builds and shows the day's
        -- CalendarDayView for us (its day_ts logic respects the user's
        -- configured calendar_day_start_hour/minute), but it doesn't expose
        -- a close_callback hook. We build a CalendarView purely to call
        -- that helper (it's never itself shown), and intercept the single
        -- UIManager:show() call it makes so we can attach our own
        -- close_callback / onCloseWidget before the widget is painted.
        local cv = CalendarView:new{ reader_statistics = stats_plugin }

        local orig_show = UIManager.show
        UIManager.show = function(mgr, widget, ...)
            UIManager.show = orig_show -- one-shot: restore immediately
            widget.close_callback = reopen_once
            local orig_onCloseWidget = widget.onCloseWidget
            widget.onCloseWidget = function(self_w, ...)
                if orig_onCloseWidget then orig_onCloseWidget(self_w, ...) end
                reopen_once()
            end
            return orig_show(mgr, widget, ...)
        end

        cv:showCalendarDayView(stats_plugin)
    end)
end

-- Open CalendarView for today's month.
function ReadingInsightsPopup:openCalendarForCurrentMonth()
    local year_month = os.date("%Y-%m")
    self:openCalendarForMonth(year_month)
end

function ReadingInsightsPopup:getMonthlyBookCounts(year, shared_conn)
    local today         = todayDateStr()
    local key           = "books:" .. year .. ":" .. today
    local base_key      = "books:" .. year
    local current_month = today:sub(1, 7)
    local minute        = currentMinute()

    local cached_val = getMinuteCache(_monthly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = getCachedBase(_monthly_base_cache, base_key, today)

    local merged = withDb(shared_conn, nil, function(conn)
        local base = cached_base
        if not base then
            local year_str = tostring(year)
            local sql = string.format([[
                SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS month,
                       COUNT(DISTINCT id_book) AS book_count
                FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                  AND date(start_time, 'unixepoch', 'localtime') < '%s'
                GROUP BY month
                ORDER BY month ASC
            ]], year_str, today)

            local counts = {}
            withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do counts[row[1]] = row[2] end
            end)

            local ids_sql = string.format([[
                SELECT DISTINCT id_book
                FROM page_stat
                WHERE strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
                  AND date(start_time, 'unixepoch', 'localtime') < '%s'
            ]], current_month, today)
            local book_ids = {}
            withStatement(conn, ids_sql, function(stmt)
                for row in stmt:rows() do book_ids[tostring(row[1])] = true end
            end)

            base = { counts = counts, current_month_book_ids = book_ids }
        end

        local new_books_today = 0
        withStatement(conn, string.format([[
            SELECT DISTINCT id_book FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
        ]], today), function(stmt)
            for row in stmt:rows() do
                local id_book = tostring(row[1])
                if not base.current_month_book_ids[id_book] then
                    new_books_today = new_books_today + 1
                end
            end
        end)

        return { base = base, new_books_today = new_books_today }
    end)
    if not merged then
        merged = { base = cached_base or { counts = {}, current_month_book_ids = {} }, new_books_today = 0 }
    end

    if ENABLE_CACHE and not cached_base then
        _monthly_base_cache[base_key] = makeCachedBase(today, merged.base)
    end

    local months = buildMonthlyArray(year, function(year_month)
        local book_count = tonumber(merged.base.counts[year_month]) or 0
        if year_month == current_month then
            book_count = book_count + merged.new_books_today
        end
        return { book_count = book_count }
    end)

    setMinuteCache(_monthly_cache, _stale_monthly, key, key .. ":minute", minute, months)
    return months
end

function ReadingInsightsPopup:getBooksForYear(year)
    return getBooksForPeriod("%Y", tostring(year))
end

function ReadingInsightsPopup:showAllBooks()
    local books = getAllBooks()
    local total_secs = sumDuration(books)
    showBooksForPeriod(
        self, books,
        _("No books read"),
        T(_("All books read %1"), formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
end

function ReadingInsightsPopup:showBooksForYear(year)
    local books = self:getBooksForYear(year)
    local total_secs = sumDuration(books)
    showBooksForPeriod(
        self, books,
        _("No books read in ") .. year,
        T(N_("%1 - book read %2", "%1 - books read %2", #books), year, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
end

function ReadingInsightsPopup:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local fonts    = getCachedFonts()
    local layout   = getCachedLayout()

    -- Cold start (e.g. right after a KOReader restart): no cache, no stale
    -- data, nothing to show yet. Rather than flashing zeroed-out sections
    -- for a moment, show a plain loading message; _loadAndRebuild() will
    -- call _buildUI() again as soon as real data is available.
    if self._initial_loading then
        local title_bar_inner = TitleBar:new{
            fullscreen     = true,
            width          = screen_w,
            align          = "left",
            title          = _("Reading insights"),
            close_callback = function() UIManager:close(self) end,
            show_parent    = self,
            top_v_padding    = Size.padding.default,
            bottom_v_padding = Size.padding.default,
        }
        self._title_bar_height = title_bar_inner:getSize().h

        self.popup_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            radius     = 0,
            padding    = 0,
            width      = screen_w,
            height     = screen_h,
            VerticalGroup:new{
                align = "left",
                title_bar_inner,
                CenterContainer:new{
                    dimen = Geom:new{ w = screen_w, h = screen_h - title_bar_inner:getSize().h },
                    TextWidget:new{
                        text = _("Loading data…"),
                        face = fonts.label,
                    },
                },
            },
        }
        self.popup_frame.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self[1] = VerticalGroup:new{ self.popup_frame }
        return
    end

    local sections = buildInsightsSections(
        self,
        self._streaks    or { current_days=0, best_days=0, current_weeks=0, best_weeks=0 },
        self._yearly     or { days=0, pages=0, duration=0 },
        self._year_range or { min_year=self.selected_year, max_year=self.selected_year },
        self._monthly    or {},
        self._all_time   or { hours=0, pages=0 },
        self._last_week  or { avg_seconds=0, avg_pages=0 },
        self._last_week_daily or nil,
        fonts, layout)

    local title_bar_inner = TitleBar:new{
        fullscreen     = true,
        width          = screen_w,
        align          = "left",
        title          = _("Reading insights"),
        close_callback = function() UIManager:close(self) end,
        show_parent    = self,
        top_v_padding    = Size.padding.default,
        bottom_v_padding = Size.padding.default,
    }

    local title_bar_h = title_bar_inner:getSize().h
    self._title_bar_height = title_bar_h

    local title_bar = title_bar_inner

    local content = VerticalGroup:new{
        align = "left",
        title_bar,
        padded(layout.padding_h, LineWidget:new{
            dimen      = Geom:new{ w = layout.content_width, h = Size.line.thick },
            background = Blitbuffer.COLOR_GRAY,
        }),
        sections,
        VerticalSpan:new{ height = title_bar:getSize().h },
    }

    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")

    self.scroll_container = ScrollableContainer:new{
        dimen               = Geom:new{ w = screen_w, h = screen_h },
        show_parent         = self,
        scroll_bar_position = "right",
        content,
    }

    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        radius     = 0,
        padding    = 0,
        width      = screen_w,
        VerticalGroup:new{
            align = "left",
            self.scroll_container,
        },
    }

    self.popup_frame.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    self[1] = VerticalGroup:new{ self.popup_frame }
end

function ReadingInsightsPopup:_loadAndRebuild()
    -- Re-fetch all data using a single shared DB connection (6→1 open/close cycles).
    -- Each getter still manages its own cache; shared_conn is just passed through
    -- so it skips the redundant open/close when data is actually read.
    local shared_conn = openStatsDb()

    local new_streaks    = self:calculateStreaks(shared_conn)
    local new_year_range = self:getYearRange(shared_conn)
    local new_yearly     = self:getYearlyStats(self.selected_year, shared_conn)
    local new_all_time   = self:getAllTimeStats(shared_conn)
    local new_last_week, new_last_week_daily = self:getLastWeekAll(shared_conn)
    local new_monthly
    if self.mode == INSIGHTS_MODE_HOURS then
        new_monthly = self:getMonthlyReadingHours(self.selected_year, shared_conn)
    elseif self.mode == INSIGHTS_MODE_BOOKS then
        new_monthly = self:getMonthlyBookCounts(self.selected_year, shared_conn)
    else
        new_monthly = self:getMonthlyReadingDays(self.selected_year, shared_conn)
    end

    if shared_conn then shared_conn:close() end

    -- Skip rebuild if nothing actually displayed would change - compared by
    -- value, not by table reference (see valuesEqual() for why reference
    -- equality isn't enough now that all_time/yearly refresh every minute).
    -- Exception: coming out of the cold-start "Loading data..." placeholder
    -- always needs a rebuild, even if the freshly-loaded values happen to
    -- be all-zero (e.g. a brand new, still-empty statistics.sqlite3).
    local was_initial_loading = self._initial_loading
    if not was_initial_loading and
       valuesEqual(new_streaks,         self._streaks)         and
       valuesEqual(new_year_range,      self._year_range)      and
       valuesEqual(new_yearly,          self._yearly)          and
       valuesEqual(new_all_time,        self._all_time)        and
       valuesEqual(new_last_week,       self._last_week)       and
       valuesEqual(new_last_week_daily, self._last_week_daily) and
       valuesEqual(new_monthly,         self._monthly)         then
        -- Still adopt the new table references so future comparisons are
        -- against the freshest cache entries, but skip the rebuild/redraw.
        self._streaks         = new_streaks
        self._year_range      = new_year_range
        self._yearly          = new_yearly
        self._all_time        = new_all_time
        self._last_week       = new_last_week
        self._last_week_daily = new_last_week_daily
        self._monthly         = new_monthly
        saveDiskCache()
        return
    end

    self._streaks         = new_streaks
    self._year_range      = new_year_range
    self._yearly          = new_yearly
    self._all_time        = new_all_time
    self._last_week       = new_last_week
    self._last_week_daily = new_last_week_daily
    self._monthly         = new_monthly
    self._initial_loading = false

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    saveDiskCache()
end

-- init() shows cached/stale data immediately, then _loadAndRebuild() refreshes in the background.
function ReadingInsightsPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Write the current (in-memory, not yet saved) reading session into
    -- statistics.sqlite3, then invalidate the "Last week" cache so it is
    -- always re-queried from the DB on every open of this popup - not just
    -- once per minute. Older cached/stale values are still shown instantly
    -- below (stale-while-revalidate); _loadAndRebuild() then replaces them
    -- with the freshly-flushed numbers a moment later.
    flushStatsToDB(self.ui)
    _cache.last_week              = nil
    _cache.last_week_minute       = nil
    _cache.last_week_daily        = nil
    _cache.last_week_daily_minute = nil

    -- Use fresh cache if available.
    if ENABLE_CACHE then
        self._streaks    = self._streaks    or _cache.streaks
        local minute = currentMinute()
        self._year_range = self._year_range or _cache.year_range
        self._all_time   = self._all_time   or _cache.all_time
        local year_key = (self.selected_year or tonumber(os.date("%Y"))) .. ":v3:" .. todayDateStr()
        self._yearly  = self._yearly  or _yearly_cache[year_key]
        local mode = normalizeInsightsMode(self.mode or readInsightsMode())
        local month_key = monthKeyPrefixForMode(mode) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":" .. todayDateStr()
        self._monthly = self._monthly or _monthly_cache[month_key]
        if not self._last_week or not self._last_week_daily then
            local lw_cached    = getMinuteCache(_cache, "last_week", "last_week_minute", minute)
            local daily_cached = getMinuteCache(_cache, "last_week_daily", "last_week_daily_minute", minute)
            self._last_week       = self._last_week       or lw_cached
            self._last_week_daily = self._last_week_daily or daily_cached
        end
    end

    -- Fall back to stale cache for anything still missing (e.g. after a restart or day rollover).
    if ENABLE_CACHE then
        local year_key_any   = (self.selected_year or tonumber(os.date("%Y"))) .. ":v3:"
        local mode_fb = normalizeInsightsMode(self.mode or readInsightsMode())
        local month_key_fb = monthKeyPrefixForMode(mode_fb) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":"

        if not self._streaks then
            self._streaks = _stale_cache.streaks
        end

        if not self._year_range then
            self._year_range = _stale_cache.year_range
            -- Ensure selected_year stays within the stale range if we got one.
            if self._year_range and self.selected_year then
                if self.selected_year < self._year_range.min_year then
                    self.selected_year = self._year_range.min_year
                elseif self.selected_year > self._year_range.max_year then
                    self.selected_year = self._year_range.max_year
                end
            end
        end

        if not self._all_time then
            self._all_time = _stale_cache.all_time
        end

        if not self._last_week then
            self._last_week = _stale_cache.last_week
        end

        if not self._last_week_daily then
            self._last_week_daily = _stale_cache.last_week_daily
        end
        -- Find any stale yearly entry for the current year.
        if not self._yearly then
            self._yearly = findStaleByPrefix(_stale_yearly, year_key_any)
        end
        -- Find any stale monthly entry for the current year + mode.
        if not self._monthly then
            self._monthly = findStaleByPrefix(_stale_monthly, month_key_fb)
        end
    end

    self.mode = normalizeInsightsMode(self.mode or readInsightsMode())

    -- True only on a genuine cold start (e.g. right after a KOReader restart):
    -- no fresh cache and no stale fallback for any of the core stats. In that
    -- case _buildUI() shows a "Loading data..." placeholder instead of a
    -- flash of zeroed-out sections; cleared as soon as _loadAndRebuild()
    -- brings in real data.
    self._initial_loading = not (self._streaks or self._yearly or self._monthly
        or self._all_time or self._last_week)

    -- selected_year needs an initial value before _loadAndRebuild runs.
    if not self.selected_year then
        self.selected_year = tonumber(os.date("%Y"))
    end

    self.dimen = Geom:new{ w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        -- Hold handled at popup level to avoid ScrollableContainer eating inner Hold events.
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
        self.ges_events.Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end

    -- Build UI immediately with available data; refresh in background.
    -- Small delay (not 0) so the initial paint actually lands on screen
    -- before _loadAndRebuild() (which now recomputes all_time/yearly on
    -- almost every open, not just once a day) can trigger a second redraw.
    self:_buildUI()
    UIManager:scheduleIn(0.1, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
end

function ReadingInsightsPopup:onSwipe(arg, ges_ev)
    if not ges_ev then return false end
    local dir = ges_ev.direction
    if dir == "west" or dir == "left"  then return self:onGoToNextYear() end
    if dir == "east" or dir == "right" then return self:onGoToPrevYear() end
    if dir == "south" or dir == "down" then UIManager:close(self) return true end
    return false
end

-- Hold dispatch by touch position:
--   title bar      → cache reload
--   chart header   → CalendarView for current month
function ReadingInsightsPopup:onHold(arg, ges_ev)
    if not ges_ev or not ges_ev.pos then return true end
    local pos = ges_ev.pos

    local title_h = self._title_bar_height
    if title_h and pos.y <= title_h then
        local msg = InfoMessage:new{ text = _("Reloading data...") }
        UIManager:show(msg)
        UIManager:scheduleIn(0.5, function()
            UIManager:close(msg)
            clearAllCache()
            self._streaks         = nil
            self._yearly          = nil
            self._monthly         = nil
            self._all_time        = nil
            self._last_week       = nil
            self._last_week_daily = nil
            self:_loadAndRebuild()
        end)
        return true
    end
    
    if self._current_month_bar_widget then
        local d = self._current_month_bar_widget.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            self:openCalendarForCurrentMonth()
            return true
        end
    end

    return true
end

-- Cycles the insights mode (hours -> days -> books -> hours) and reloads
-- the monthly chart for it. Bound to both the "Press" key handler
-- (toggleInsightsMode) and tapping the monthly chart header
-- (cycleInsightsMode) - kept as two names since that's what the gesture/key
-- wiring elsewhere calls, but there's only one implementation.
function ReadingInsightsPopup:cycleInsightsMode()
    local new_mode
    if self.mode == INSIGHTS_MODE_HOURS then
        new_mode = INSIGHTS_MODE_DAYS
    elseif self.mode == INSIGHTS_MODE_DAYS then
        new_mode = INSIGHTS_MODE_BOOKS
    else
        new_mode = INSIGHTS_MODE_HOURS
    end

    saveInsightsMode(new_mode)
    self.mode = new_mode

    local month_key_fb = monthKeyPrefixForMode(new_mode) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":"
    self._monthly = findStaleByPrefix(_stale_monthly, month_key_fb)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    UIManager:scheduleIn(0, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
    return true
end

function ReadingInsightsPopup:toggleInsightsMode()
    return self:cycleInsightsMode()
end

-- Shared implementation for year navigation: moves selected_year by `delta`
-- (-1 or +1), staying within the known year range, serves stale yearly/
-- monthly data for the new year immediately, then reloads for real.
function ReadingInsightsPopup:_goToYear(delta)
    local yr = self._year_range or self.year_range
    if not yr then return true end
    local new_year = self.selected_year + delta
    if new_year < yr.min_year or new_year > yr.max_year then return true end

    self.selected_year = new_year
    self._monthly = nil
    self._yearly  = nil
    -- Serve stale data for the target year immediately.
    local year_key_any = self.selected_year .. ":v3:"
    local mode_fb       = self.mode or INSIGHTS_MODE_HOURS
    local month_key_fb  = monthKeyPrefixForMode(mode_fb) .. self.selected_year .. ":"
    self._yearly  = findStaleByPrefix(_stale_yearly, year_key_any)
    self._monthly = findStaleByPrefix(_stale_monthly, month_key_fb)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    UIManager:scheduleIn(0, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
    return true
end

function ReadingInsightsPopup:onGoToPrevYear()
    return self:_goToYear(-1)
end

function ReadingInsightsPopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:onGoToPrevYear() end
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:onGoToNextYear() end
    if key and key:match({ { "Press" } }) then return self:toggleInsightsMode() end
    UIManager:close(self)
    return true
end

function ReadingInsightsPopup:onGoToNextYear()
    return self:_goToYear(1)
end

function ReadingInsightsPopup:onShow()
    if readFullRefreshSetting() then
        UIManager:setDirty(self, function()
            return "full", self.popup_frame.dimen
        end)
    else
        UIManager:setDirty(self, function()
            return "ui", self.popup_frame.dimen
        end)
    end
    return true
end

function ReadingInsightsPopup:onTapClose()
    UIManager:close(self)
    return true
end

function ReadingInsightsPopup:onCloseWidget()
    self._closed = true
    if self.scroll_container then
        self.scroll_container:free()
    end
    if readFullRefreshSetting() then
        UIManager:setDirty(nil, "full")
    else
        UIManager:setDirty(nil, "ui")
    end
end


-- Module export.
-- The Popup class is what main.lua instantiates on demand; the four setting
-- helpers are exposed too because main.lua's Tools-menu entries (full-screen
-- refresh toggle, 8-week chart order) read/write the same settings keys.
return {
    Popup                   = ReadingInsightsPopup,
    readFullRefreshSetting  = readFullRefreshSetting,
    readAscendingSetting    = readAscendingSetting,
    saveFullRefreshSetting  = saveFullRefreshSetting,
    saveAscendingSetting    = saveAscendingSetting,
}
