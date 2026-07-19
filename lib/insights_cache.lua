--[[
Reading Insights - data cache for the insights view.

Everything the insights popup remembers between opens: the in-memory
per-minute/per-day caches, the "stale" copies that let the popup paint
last-known numbers instantly while fresh ones load in the background, the
"up to yesterday" base aggregates that keep a same-day refresh from
rescanning full history, the persisted finished-books lists behind the
reading-goal count, and the small settings file all of those are mirrored
to so they survive a KOReader restart.

This was lifted out of insights_view.lua unchanged in behaviour. The reason
is the same one behind lib/insights_settings.lua: Lua allows only 200 active
locals per function scope, and roughly 30 of them were being spent on cache
tables and helpers declared at the top level of the view. As fields on one
table they cost the view a single local instead.

Note that the tables are reassigned wholesale by M.clearAllCache() (the
title-bar "reload data" long press), which is exactly why every reference -
here and in the view - goes through M rather than through a local alias: an
alias would still point at the discarded table afterwards.

  M.ENABLE_CACHE               master switch; false = always hit the DB
  M.clearAllCache()            drop everything, including the stale copies
  M.loadDiskCache() / M.saveDiskCache()
                               mirror to/from the settings file on disk
  M.currentMinute() / M.todayDateStr()
                               the two cache stamps everything is keyed on
  M.getMinuteCache/setMinuteCache
                               per-minute read/write (+ stale mirror)
  M.getCachedBase/makeCachedBase
                               per-day "up to yesterday" base entries
  M.findStaleByPrefix/bestKnownFullResult
                               stale lookups for the prefix-keyed caches
]]--

local DataStorage = require("datastorage")
local logger      = require("logger")

local M = {}

-- true: cache DB results (streaks/year_range per day, last-week per minute, yearly/monthly per day).
-- false: always query DB fresh on open.
M.ENABLE_CACHE = true

M._cache = {
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
    daily_data        = nil,
}

M._yearly_cache  = {}

M._monthly_cache = {}

-- Finished-book count for the reading-goal section, keyed per year like
-- M._yearly_cache. Per-minute in-memory throttle only; the actual per-year
-- results this wraps are backed by the persisted, incrementally-updated
-- tables below (M._goal_finished_books / M._goal_scan_watermark), which is what
-- makes each cache-miss cheap instead of a full-table rescan.
M._goal_cache       = {}

M._stale_goal_cache = {}

-- Persisted "finished books" list for the reading-goal count (see
-- getFinishedBookCountForYear below). Refreshing it never rescans the whole
-- page_stat history: only books with activity newer than the last scan for
-- that year are examined, and each of those is re-judged from scratch -
-- added to the list if it now qualifies, removed if it no longer does. That
-- removal matters for books that move between years (finished in December,
-- reread in January) and for finished books that were reopened and left
-- partway through; without it they would stay counted in the old year
-- forever, on top of being counted in the new one.
-- Both tables are mirrored to disk (see M.loadDiskCache/M.saveDiskCache), so
-- the list survives a KOReader restart instead of starting over empty.
--   M._goal_finished_books[year] = { [id_book] = last_time, ... }
--   M._goal_scan_watermark[year] = { time = start_time already scanned up to
--                                  for that year's list,
--                                  rows = page_stat row count at that
--                                  moment - see the sanity check in
--                                  getFinishedBookCountForYear }
M._goal_finished_books   = {}

M._goal_scan_watermark   = {}

-- "Up to yesterday" base aggregates (excludes today), kept separate from
-- M._yearly_cache/M._monthly_cache so they never collide with the stale-prefix
-- lookups those tables are searched with (e.g. "books:<year>:").
-- Recomputed once per day; today's slice is queried fresh and merged in on
-- every call, so totals stay live across repeated opens on the same day.
M._yearly_base_cache  = {}

M._monthly_base_cache = {}

M._alltime_base_cache = nil

-- Stale cache: holds expired values for immediate display on the next open.
-- M._stale_cache is read-only in init(); writes go to the primary cache tables.
M._stale_cache   = {}

M._stale_yearly  = {}

M._stale_monthly = {}

function M.clearAllCache()
    M._cache.streaks                 = nil
    M._cache.streaks_date            = nil
    M._cache.streaks_date_minute     = nil
    M._cache.streaks_today_confirmed = nil
    M._cache.year_range      = nil
    M._cache.year_range_date = nil
    M._cache.all_time        = nil
    M._cache.all_time_minute = nil
    M._cache.last_week        = nil
    M._cache.last_week_minute = nil
    M._cache.last_week_daily        = nil
    M._cache.last_week_daily_minute = nil
    M._cache.last8weeks        = nil
    M._cache.last8weeks_minute = nil
    M._cache.daily_data        = nil
    M._yearly_cache          = {}
    M._monthly_cache         = {}
    M._yearly_base_cache     = {}
    M._monthly_base_cache    = {}
    M._alltime_base_cache    = nil
    M._goal_cache            = {}
    -- Force a full re-scan of the finished-books lists on manual reload,
    -- rather than only looking for activity since the last watermark.
    M._goal_finished_books   = {}
    M._goal_scan_watermark   = {}
    -- Stale cache is wiped on force-reload so stale data is not shown after a manual refresh.
    M._stale_cache           = {}
    M._stale_yearly          = {}
    M._stale_monthly         = {}
    M._stale_goal_cache      = {}
end

-- Disk-persisted cache -------------------------------------------------
--
-- Everything above lives in memory only, so it is empty right after a
-- KOReader restart and the first popup open would have nothing to show but
-- a "Loading data..." placeholder. Two things are therefore mirrored to a
-- small settings file: the stale tables, so the popup can open instantly
-- with the last known numbers and refresh behind them, and the "up to
-- yesterday" base aggregates, so the first call of the day doesn't have to
-- rescan the whole history (which would also make the displayed total jump
-- once the rescan replaced the placeholder). A base entry carries its own
-- date, so an out-of-date one loaded from disk is ignored and recomputed
-- exactly as if it had never been saved.
local LuaSettings = require("luasettings")

local DISK_CACHE_PATH = DataStorage:getSettingsDir() .. "/reading_insights_cache.lua"

function M.loadDiskCache()
    local ok, settings = pcall(function() return LuaSettings:open(DISK_CACHE_PATH) end)
    if not ok or not settings then return end

    local stale_cache   = settings:readSetting("stale_cache")
    local stale_yearly  = settings:readSetting("stale_yearly")
    local stale_monthly = settings:readSetting("stale_monthly")
    local alltime_base  = settings:readSetting("alltime_base")
    local yearly_base   = settings:readSetting("yearly_base")
    local monthly_base  = settings:readSetting("monthly_base")
    local goal_finished_books = settings:readSetting("goal_finished_books")
    local goal_scan_watermark = settings:readSetting("goal_scan_watermark")

    if type(stale_cache) == "table" then
        for k, v in pairs(stale_cache) do M._stale_cache[k] = v end
    end
    if type(stale_yearly) == "table" then
        for k, v in pairs(stale_yearly) do M._stale_yearly[k] = v end
    end
    if type(stale_monthly) == "table" then
        for k, v in pairs(stale_monthly) do M._stale_monthly[k] = v end
    end
    -- alltime_base is the single un-keyed base-cache entry itself (a
    -- { date, data } table, or nil); the other two are keyed tables of such
    -- entries, so they're merged key by key like the stale caches above.
    if type(alltime_base) == "table" then
        M._alltime_base_cache = alltime_base
    end
    -- getYearlyStats()/getMonthlyBookCounts() unconditionally index
    -- base.book_ids / base.current_month_book_ids without a nil check,
    -- since a freshly-queried base always has them. A disk-loaded entry is
    -- defensively backfilled with an empty table here (instead of trusting
    -- the file to always contain them) so a cache file written by an older
    -- plugin version, or edited/truncated by hand, can't crash those
    -- lookups - worst case it just treats every book as "new" for one
    -- lookup, same as an empty history would.
    if type(yearly_base) == "table" then
        for k, v in pairs(yearly_base) do
            if type(v) == "table" and type(v.data) == "table" and v.data.book_ids == nil then
                v.data.book_ids = {}
            end
            M._yearly_base_cache[k] = v
        end
    end
    if type(monthly_base) == "table" then
        for k, v in pairs(monthly_base) do
            if type(v) == "table" and type(v.data) == "table" and v.data.current_month_book_ids == nil then
                v.data.current_month_book_ids = {}
            end
            M._monthly_base_cache[k] = v
        end
    end
    if type(goal_finished_books) == "table" then
        for k, v in pairs(goal_finished_books) do M._goal_finished_books[k] = v end
    end
    if type(goal_scan_watermark) == "table" then
        for k, v in pairs(goal_scan_watermark) do M._goal_scan_watermark[k] = v end
    end
end

-- Best-effort save; any failure (full disk, odd permissions, ...) is
-- silently ignored so it can never break the popup itself.
--
-- LuaSettings only serializes its whole in-memory table once, on flush().
-- That means a single bad value anywhere in that table can make the *whole*
-- flush() fail (and flush() is wrapped in pcall below, so that failure is
-- silent) - which would drop even the already-reliable stale_cache /
-- M._stale_yearly / M._stale_monthly placeholders that the "no Loading data...
-- after restart" behavior depends on, just because one of the newer,
-- lower-priority base-cache entries turned out to be unexpectedly shaped or
-- oversized.
--
-- To make sure the essential placeholders can never be taken down by a
-- problem in the base caches, they're saved and flushed to disk in their
-- own pass first; the base caches (a pure performance optimization, see the
-- big comment above M.loadDiskCache()) are only added and flushed afterwards,
-- as a second, independent pass on the same file.
function M.saveDiskCache()
    local ok, settings = pcall(function() return LuaSettings:open(DISK_CACHE_PATH) end)
    if not ok or not settings then return end

    settings:saveSetting("stale_cache", M._stale_cache)
    settings:saveSetting("stale_yearly", M._stale_yearly)
    settings:saveSetting("stale_monthly", M._stale_monthly)
    local stale_flush_ok, stale_flush_err = pcall(function() settings:flush() end)
    if not stale_flush_ok then
        logger.warn("ReadingInsights: failed to flush stale-cache placeholders: " .. tostring(stale_flush_err))
        return -- don't even attempt the base caches against a settings object that just failed to flush
    end

    settings:saveSetting("alltime_base", M._alltime_base_cache)
    settings:saveSetting("yearly_base", M._yearly_base_cache)
    settings:saveSetting("monthly_base", M._monthly_base_cache)
    settings:saveSetting("goal_finished_books", M._goal_finished_books)
    settings:saveSetting("goal_scan_watermark", M._goal_scan_watermark)
    local base_flush_ok, base_flush_err = pcall(function() settings:flush() end)
    if not base_flush_ok then
        logger.warn("ReadingInsights: failed to flush base caches: " .. tostring(base_flush_err))
    end
end

function M.todayDateStr()
    return os.date("%Y-%m-%d")
end

function M.currentMinute()
    return math.floor(os.time() / 60)
end

-- Per-minute cache read: returns the cached value for `key` if caching is
-- on and it was last refreshed during the current minute, else nil.
-- `minute_key` is the sibling field/key holding the minute stamp (e.g.
-- "all_time_minute", or key .. ":minute" for the dynamically-keyed caches).
function M.getMinuteCache(cache_table, key, minute_key, minute)
    if M.ENABLE_CACHE and cache_table[key] ~= nil and cache_table[minute_key] == minute then
        return cache_table[key]
    end
    return nil
end

-- Per-minute cache write: stores value + minute stamp, and mirrors it into
-- stale_table (read on the next popup open for instant stale-while-revalidate
-- display). No-op when caching is disabled.
function M.setMinuteCache(cache_table, stale_table, key, minute_key, minute, value)
    if M.ENABLE_CACHE then
        cache_table[key]   = value
        cache_table[minute_key] = minute
        stale_table[key]   = value
    end
end

-- "Up to yesterday" base-aggregate read: returns the cached data only if it
-- was computed today, else nil (meaning: recompute). For per-key caches
-- (yearly/monthly) pass base_key; for the single un-keyed all-time cache
-- pass base_key = nil and the cache variable's current value as cache_entry.
function M.getCachedBase(cache_table, base_key, today)
    if not M.ENABLE_CACHE then return nil end
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
function M.makeCachedBase(today, data)
    return { date = today, data = data }
end

-- Scans a stale-cache table for the entry whose key starts with `prefix`
-- and has the most recent date suffix. Used as a fallback when no
-- fresh/minute-cached value is available yet (e.g. right after a restart,
-- mode switch, or year change).
--
-- Entries are never pruned from these tables (each calendar day adds a new
-- date-suffixed key rather than overwriting the previous one - see
-- M.setMinuteCache), so a given prefix (e.g. "2026:v3:") can match several
-- entries at once, one per day the plugin has ever run. pairs() iteration
-- order is undefined, so simply returning the first match found could just
-- as easily return yesterday's (or older) entry as today's, which is
-- exactly what caused the "yesterday's value flashes briefly after
-- restart" bug: the date suffix is an ISO "YYYY-MM-DD" string, so the
-- lexicographically greatest matching key is also the chronologically
-- most recent one - that's the one we want.
function M.findStaleByPrefix(stale_table, prefix)
    if not M.ENABLE_CACHE then return nil end
    local best_key, best_val
    for k, v in pairs(stale_table) do
        if k:sub(1, #prefix) == prefix then
            if not best_key or k > best_key then
                best_key, best_val = k, v
            end
        end
    end
    return best_val
end

-- Used by every base/today merge function below (getYearlyStats,
-- getAllTimeStats, getMonthlyReading*, getMonthlyBookCounts) when their
-- "today" DB read fails - most often a transient statistics.sqlite3 lock
-- right after a KOReader restart, while KOReader's own built-in
-- statistics plugin is also touching the file. Without this, the caller's
-- own fallback merges `base` (which excludes today by definition) with an
-- all-zero "today" slice, silently dropping today's already-known
-- activity - and since that regressed result looks like legitimate fresh
-- data, it gets cached and displayed, causing the numbers on screen to
-- briefly drop before a later, successful read corrects them again.
-- Prefers this session's own cache (session_cache[key]) over the last
-- value persisted to disk (stale_table, matched by prefix - see
-- M.findStaleByPrefix), and returns nil only when there's genuinely nothing
-- better yet (e.g. the very first run, before anything has been cached).
function M.bestKnownFullResult(session_cache, key, stale_table, stale_prefix)
    if session_cache and key and session_cache[key] then
        return session_cache[key]
    end
    return M.findStaleByPrefix(stale_table, stale_prefix)
end

-- Seed the in-memory stale caches from disk as soon as this module loads
-- (i.e. at plugin/KOReader start), so even the very first popup open has
-- last-known data available through the stale-cache fallback instead of
-- showing the "Loading data..." placeholder.
M.loadDiskCache()

return M
