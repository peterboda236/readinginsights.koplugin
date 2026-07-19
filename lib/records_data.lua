--[[
Reading Insights - the data behind the Records popup.

Works out the five records the popup shows - most reading time in a day,
most pages in a day, best daily streak, and the last/next total-hours
milestone - and keeps them in a small cache file so opening the popup
doesn't rescan the whole reading history every time.

Split out of records_view.lua, which held the queries, the cache and the
widgets in one file. Everything here is plain computation over
statistics.sqlite3, so it can be exercised without KOReader's UI.

How the cache stays correct: alongside the values it stores a fingerprint of
the statistics DB - the highest start_time seen, and the total row count.
On the next open, if only newer rows have been added (row growth matches
exactly the number of rows past the stored watermark), the records are
updated incrementally from just those rows; anything else - rows deleted, a
restored backup, another device's history merged in - means the fingerprint
doesn't add up and everything is recomputed from scratch. Streaks and the
milestone date are re-queried only when the new rows could actually have
changed them.

The cache file itself is read and written through LuaSettings rather than by
hand. Its path and flat key layout are unchanged from the hand-written
version, which LuaSettings loads as-is, so an existing cache carries over
and no one pays for a recompute on upgrade.

  RecordsData.load()               -> { longest, best_day, streak,
                                        total_secs, last_ms_date }
  RecordsData.getMilestones(hours) -> last_reached, next_ahead
]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local deps = ...
local StatsDb = deps.StatsDb

local M = {}

-- Every key stored in the cache file, in one place so the reader can't
-- drift out of step with the writer.
local CACHE_KEYS = {
    "hw_max_time", "hw_row_count", "total_secs",
    "longest_sec", "longest_date",
    "best_day_pages", "best_day_date",
    "streak_days", "streak_start", "streak_end",
    "last_ms_date",
}

-- ---------------------------------------------------------------------------
-- Milestone ladder (total reading hours)
-- ---------------------------------------------------------------------------
local MILESTONES = { 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }

-- ---------------------------------------------------------------------------
-- DB helpers
-- ---------------------------------------------------------------------------
-- The records cache lives next to the statistics DB, in the settings dir.
local function cachePath()
    return DataStorage:getSettingsDir() .. "/readinginsights_records_cache.lua"
end

-- The cache table passed around inside this module (the on-disk keys are
-- the flat CACHE_KEYS above):
--   hw_max_time  (integer) highest start_time seen when cache was written
--   hw_row_count (integer) total page_stat row count when cache was written
--   longest      { duration_sec, date }  -- most reading time in a day
--   best_day     { pages, date }
--   streak       { days, start_date, end_date }
--   total_secs   (integer)
--   last_ms_date (string|nil)

local function loadCache()
    local ok, store = pcall(function() return LuaSettings:open(cachePath()) end)
    if not ok or not store then return nil end
    -- No fingerprint means no usable cache (missing file, or one written by
    -- something else); the caller then does a full recompute.
    if store:readSetting("hw_max_time") == nil then return nil end
    local c = {}
    for _, key in ipairs(CACHE_KEYS) do
        c[key] = store:readSetting(key)
    end
    return c
end

local function saveCache(c)
    local ok = pcall(function()
        local store = LuaSettings:open(cachePath())
        store:saveSetting("hw_max_time",    c.hw_max_time  or 0)
        store:saveSetting("hw_row_count",   c.hw_row_count or 0)
        store:saveSetting("total_secs",     c.total_secs   or 0)
        store:saveSetting("longest_sec",    c.longest.duration_sec or 0)
        store:saveSetting("longest_date",   c.longest.date)
        store:saveSetting("best_day_pages", c.best_day.pages or 0)
        store:saveSetting("best_day_date",  c.best_day.date)
        store:saveSetting("streak_days",    c.streak.days or 0)
        store:saveSetting("streak_start",   c.streak.start_date)
        store:saveSetting("streak_end",     c.streak.end_date)
        store:saveSetting("last_ms_date",   c.last_ms_date)
        store:flush()
    end)
    return ok
end

local function cacheToData(c)
    -- Reconstruct the data tables from the flat cache fields
    return {
        longest  = { duration_sec = c.longest_sec or 0, date = c.longest_date or nil },
        best_day = { pages = c.best_day_pages or 0, date = c.best_day_date or nil },
        streak   = { days = c.streak_days or 0,
                     start_date = c.streak_start or nil,
                     end_date   = c.streak_end   or nil },
        total_secs  = c.total_secs or 0,
        last_ms_date = c.last_ms_date or nil,
    }
end

local function dateDiffDays(a, b)
    local function toTime(s)
        local y, mo, d = s:match("^(%d+)-(%d+)-(%d+)$")
        return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
    end
    return math.floor((toTime(b) - toTime(a)) / 86400 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Full queries (run when cache is absent or invalid)
-- ---------------------------------------------------------------------------
local function fullQueryMostReadingTimeDay(conn)
    local result = { duration_sec = 0, date = nil }
    StatsDb.withStatement(conn, [[
        SELECT date(start_time, 'unixepoch', 'localtime') AS day,
               SUM(duration) AS day_dur
        FROM page_stat
        GROUP BY day
        ORDER BY day_dur DESC
        LIMIT 1
    ]], function(stmt)
        for row in stmt:rows() do
            result.duration_sec = tonumber(row[2]) or 0
            result.date         = row[1]
        end
    end)
    return result
end

local function fullQueryMostPagesDay(conn)
    local result = { pages = 0, date = nil }
    StatsDb.withStatement(conn, [[
        SELECT date(start_time, 'unixepoch', 'localtime') AS day,
               COUNT(DISTINCT id_book || '-' || page) AS page_count
        FROM page_stat
        GROUP BY day
        ORDER BY page_count DESC
        LIMIT 1
    ]], function(stmt)
        for row in stmt:rows() do
            result.pages = tonumber(row[2]) or 0
            result.date  = row[1]
        end
    end)
    return result
end

local function fullQueryBestStreak(conn)
    local dates = {}
    StatsDb.withStatement(conn, [[
        SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d
        FROM page_stat ORDER BY d ASC
    ]], function(stmt)
        for row in stmt:rows() do
            table.insert(dates, row[1])
        end
    end)
    if #dates == 0 then return { days = 0, start_date = nil, end_date = nil } end

    local best_len, best_start, best_end = 1, dates[1], dates[1]
    local cur_len, cur_start = 1, dates[1]

    for i = 2, #dates do
        if dateDiffDays(dates[i-1], dates[i]) == 1 then
            cur_len = cur_len + 1
            if cur_len > best_len then
                best_len   = cur_len
                best_start = cur_start
                best_end   = dates[i]
            end
        else
            cur_len   = 1
            cur_start = dates[i]
        end
    end
    return { days = best_len, start_date = best_start, end_date = best_end }
end

local function fullQueryTotalSecs(conn)
    local total = 0
    StatsDb.withStatement(conn, "SELECT SUM(duration) FROM page_stat", function(stmt)
        for row in stmt:rows() do total = tonumber(row[1]) or 0 end
    end)
    return total
end

local function fullQueryMilestoneDate(conn, threshold_hours)
    if not threshold_hours then return nil end
    local cumulative = 0
    local result = nil
    StatsDb.withStatement(conn, [[
        SELECT date(start_time, 'unixepoch', 'localtime') AS day,
               SUM(duration) AS day_dur
        FROM page_stat
        GROUP BY day
        ORDER BY day ASC
    ]], function(stmt)
        for row in stmt:rows() do
            if not result then
                cumulative = cumulative + (tonumber(row[2]) or 0)
                if cumulative / 3600 >= threshold_hours then
                    result = row[1]
                end
            end
        end
    end)
    return result
end

-- ---------------------------------------------------------------------------
-- DB fingerprint helpers
-- ---------------------------------------------------------------------------
local function getDbFingerprint(conn)
    local max_time  = 0
    local row_count = 0
    StatsDb.withStatement(conn, "SELECT MAX(start_time), COUNT(*) FROM page_stat", function(stmt)
        for row in stmt:rows() do
            max_time  = tonumber(row[1]) or 0
            row_count = tonumber(row[2]) or 0
        end
    end)
    return max_time, row_count
end

-- Returns updated most-reading-time day: checks whether any calendar day
-- touched by new rows (summed across all books) beats the cached champion.
local function incrMostReadingTimeDay(conn, hw_time, cached)
    local result = { duration_sec = cached.duration_sec, date = cached.date }
    -- For each day that has new rows, recompute that day's total across all
    -- books (new rows alone can't give the full picture for a day already
    -- partially in cache, so we re-aggregate the whole day).
    local touched_days = {}
    StatsDb.withStatement(conn, string.format([[
        SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS day
        FROM page_stat
        WHERE start_time > %d
    ]], hw_time), function(stmt)
        for row in stmt:rows() do
            table.insert(touched_days, row[1])
        end
    end)
    for _, day in ipairs(touched_days) do
        StatsDb.withStatement(conn, string.format([[
            SELECT SUM(duration)
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = %q
        ]], day), function(stmt)
            for row in stmt:rows() do
                local dur = tonumber(row[1]) or 0
                if dur > result.duration_sec then
                    result.duration_sec = dur
                    result.date         = day
                end
            end
        end)
    end
    return result
end

-- Returns updated most-pages day similarly.
local function incrMostPagesDay(conn, hw_time, cached)
    local result = { pages = cached.pages, date = cached.date }
    local touched_days = {}
    StatsDb.withStatement(conn, string.format([[
        SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS day
        FROM page_stat
        WHERE start_time > %d
    ]], hw_time), function(stmt)
        for row in stmt:rows() do
            table.insert(touched_days, row[1])
        end
    end)
    for _, day in ipairs(touched_days) do
        StatsDb.withStatement(conn, string.format([[
            SELECT COUNT(DISTINCT id_book || '-' || page)
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = %q
        ]], day), function(stmt)
            for row in stmt:rows() do
                local cnt = tonumber(row[1]) or 0
                if cnt > result.pages then
                    result.pages = cnt
                    result.date  = day
                end
            end
        end)
    end
    return result
end

-- Returns extra seconds accumulated in rows newer than hw_time.
local function incrExtraSecs(conn, hw_time)
    local extra = 0
    StatsDb.withStatement(conn, string.format(
        "SELECT SUM(duration) FROM page_stat WHERE start_time > %d", hw_time
    ), function(stmt)
        for row in stmt:rows() do extra = tonumber(row[1]) or 0 end
    end)
    return extra
end

-- ---------------------------------------------------------------------------
-- Milestone helpers
-- ---------------------------------------------------------------------------
function M.getMilestones(total_hours)
    local last_ms, next_ms = nil, nil
    for _, ms in ipairs(MILESTONES) do
        if ms <= total_hours then
            last_ms = ms
        elseif next_ms == nil then
            next_ms = ms
        end
    end
    return last_ms, next_ms
end

-- ---------------------------------------------------------------------------
-- Main data loader with cache logic
-- ---------------------------------------------------------------------------
function M.load()
    return StatsDb.withDb({
        longest      = { duration_sec = 0, date = nil },
        best_day     = { pages = 0, date = nil },
        streak       = { days = 0, start_date = nil, end_date = nil },
        total_secs   = 0,
        last_ms_date = nil,
    }, function(conn)

        -- 1. Get current DB fingerprint
        local cur_max_time, cur_row_count = getDbFingerprint(conn)

        -- 2. Try to load existing cache
        local cache = loadCache()

        -- Helper: run full queries, write cache, return data
        local function fullRecompute()
            local longest   = fullQueryMostReadingTimeDay(conn)
            local best_day  = fullQueryMostPagesDay(conn)
            local streak    = fullQueryBestStreak(conn)
            local tot_secs  = fullQueryTotalSecs(conn)
            local tot_hours = math.floor(tot_secs / 3600)
            local last_ms   = M.getMilestones(tot_hours)
            local lmd       = fullQueryMilestoneDate(conn, last_ms)

            local new_cache = {
                hw_max_time  = cur_max_time,
                hw_row_count = cur_row_count,
                longest      = longest,
                best_day     = best_day,
                streak       = streak,
                total_secs   = tot_secs,
                last_ms_date = lmd,
            }
            saveCache(new_cache)
            return {
                longest      = longest,
                best_day     = best_day,
                streak       = streak,
                total_secs   = tot_secs,
                last_ms_date = lmd,
            }
        end

        -- 3. No cache → full recompute
        if not cache then
            return fullRecompute()
        end

        -- 4. Cache matches DB exactly → return cached data directly
        if cache.hw_max_time == cur_max_time and cache.hw_row_count == cur_row_count then
            return cacheToData(cache)
        end

        -- 5. Row count shrank or max timestamp receded → data was deleted/modified
        --    Cannot increment safely → full recompute.
        if cur_row_count < (cache.hw_row_count or 0)
            or cur_max_time < (cache.hw_max_time or 0)
        then
            return fullRecompute()
        end

        -- 6. Only new rows added (count grew and max_time advanced or stayed).
        --    Verify the old high-water timestamp still exists (guards against
        --    a sync that replaced rows with same or higher timestamps).
        if (cache.hw_max_time or 0) > 0 then
            local old_still_exists = false
            StatsDb.withStatement(conn, string.format(
                "SELECT 1 FROM page_stat WHERE start_time = %d LIMIT 1",
                cache.hw_max_time
            ), function(stmt)
                for _ in stmt:rows() do old_still_exists = true end
            end)
            if not old_still_exists then
                return fullRecompute()
            end
        end

        -- 7. Incremental update
        local d = cacheToData(cache)
        local hw = cache.hw_max_time or 0

        d.longest  = incrMostReadingTimeDay(conn, hw, d.longest)
        d.best_day = incrMostPagesDay(conn, hw, d.best_day)

        local extra_secs = incrExtraSecs(conn, hw)
        d.total_secs = (d.total_secs or 0) + extra_secs

        local old_hours = math.floor((cache.total_secs or 0) / 3600)
        local new_hours = math.floor(d.total_secs / 3600)
        local old_last  = M.getMilestones(old_hours)
        local new_last  = M.getMilestones(new_hours)

        -- Streak: only re-run the full streak query when new days were added;
        -- the streak can only grow if reading happened on a day adjacent to the
        -- cached streak end, or on a new day not yet in the streak sequence.
        -- Re-running only when new distinct dates appeared keeps it correct.
        local new_distinct_dates = false
        if cache.streak_end then
            StatsDb.withStatement(conn, string.format([[
                SELECT 1 FROM page_stat
                WHERE start_time > %d
                  AND date(start_time, 'unixepoch', 'localtime') != %q
                LIMIT 1
            ]], hw, cache.streak_end), function(stmt)
                for _ in stmt:rows() do new_distinct_dates = true end
            end)
        else
            new_distinct_dates = true
        end
        if new_distinct_dates then
            d.streak = fullQueryBestStreak(conn)
        end

        -- Milestone date: only re-query if the last milestone changed
        if new_last ~= old_last then
            d.last_ms_date = fullQueryMilestoneDate(conn, new_last)
        end

        -- Rewrite cache with updated values
        local new_cache = {
            hw_max_time  = cur_max_time,
            hw_row_count = cur_row_count,
            longest      = d.longest,
            best_day     = d.best_day,
            streak       = d.streak,
            total_secs   = d.total_secs,
            last_ms_date = d.last_ms_date,
        }
        saveCache(new_cache)
        return d
    end)
end

return M
