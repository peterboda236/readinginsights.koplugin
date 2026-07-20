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
  RecordsData.clearCache()         drop the cache; the next load() recomputes
                                   everything from the database
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

-- Throws the cache away, so the next M.load() rebuilds every record from
-- the statistics database instead of trusting what it stored last time.
-- Behind the Records popup's "hold the title to reload" (the same gesture
-- the insights popup uses for its own caches): the incremental update below
-- is careful, but "recompute the lot" is the answer when what's on screen
-- and what the user knows they read have drifted apart, and it's cheaper
-- than asking anyone to go and find a file.
--
-- Only the fingerprint has to go for loadCache() to give up on the entry,
-- but the values follow it out: leaving them behind would keep a stale set
-- of records in the file for anyone reading it later (which is exactly how
-- this popup's own bug got diagnosed).
function M.clearCache()
    return pcall(function()
        local store = LuaSettings:open(cachePath())
        for _, key in ipairs(CACHE_KEYS) do
            store:saveSetting(key, nil)
        end
        store:flush()
    end)
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

-- "Not one second, not one page, not one day" - what a fresh install
-- honestly looks like, and what a database with page_stat rows in it can
-- never honestly look like. Used to spot a result (or a stored cache) that
-- a failed read produced rather than an empty history.
local function isEmptyHistory(d)
    return (d.total_secs or 0) == 0
        and (d.longest.duration_sec or 0) == 0
        and (d.best_day.pages or 0) == 0
        and (d.streak.days or 0) == 0
end

-- Whole days between two "YYYY-MM-DD" strings, or nil if either isn't a
-- date this machine can place on the calendar. os.time returns nil for a
-- year outside the range of a 32-bit time_t, which is what an e-reader has
-- and what a runaway clock can easily produce, so the nil is a real case
-- rather than paranoia: without it a single such row anywhere in the
-- history took down the whole Records popup, all five rows of it.
local function dateDiffDays(a, b)
    local function toTime(s)
        local y, mo, d = tostring(s):match("^(%d+)-(%d+)-(%d+)$")
        if not y then return nil end
        return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
    end
    local ta, tb = toTime(a), toTime(b)
    if not ta or not tb then return nil end
    return math.floor((tb - ta) / 86400 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Full queries (run when cache is absent or invalid)
-- ---------------------------------------------------------------------------
-- Each of these returns its result plus "the query ran" (see
-- StatsDb.withStatement): a locked database hands back no rows rather than
-- an error, which is indistinguishable from an empty history unless the
-- statement itself reports in. M.load() below refuses to cache anything a
-- failed read had a hand in.
local function fullQueryMostReadingTimeDay(conn)
    local result = { duration_sec = 0, date = nil }
    local _, ok = StatsDb.withStatement(conn, [[
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
    return result, ok
end

local function fullQueryMostPagesDay(conn)
    local result = { pages = 0, date = nil }
    local _, ok = StatsDb.withStatement(conn, [[
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
    return result, ok
end

local function fullQueryBestStreak(conn)
    local dates = {}
    local _, ok = StatsDb.withStatement(conn, [[
        SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d
        FROM page_stat ORDER BY d ASC
    ]], function(stmt)
        for row in stmt:rows() do
            -- Only well-formed dates: date() yields NULL for a start_time
            -- it can't render (a clock that ran away, a merged-in history),
            -- and dateDiffDays would then be doing arithmetic on nil. The
            -- insights view guards the same spot the same way.
            if type(row[1]) == "string" and row[1]:match("^%d%d%d%d%-%d%d%-%d%d$") then
                table.insert(dates, row[1])
            end
        end
    end)
    if #dates == 0 then return { days = 0, start_date = nil, end_date = nil }, ok end

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
    return { days = best_len, start_date = best_start, end_date = best_end }, ok
end

local function fullQueryTotalSecs(conn)
    local total = 0
    local _, ok = StatsDb.withStatement(conn, "SELECT SUM(duration) FROM page_stat", function(stmt)
        for row in stmt:rows() do total = tonumber(row[1]) or 0 end
    end)
    return total, ok
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
    local _, ok = StatsDb.withStatement(conn, "SELECT MAX(start_time), COUNT(*) FROM page_stat", function(stmt)
        for row in stmt:rows() do
            max_time  = tonumber(row[1]) or 0
            row_count = tonumber(row[2]) or 0
        end
    end)
    return max_time, row_count, ok
end

-- Returns the updated most-reading-time day: any calendar day that new rows
-- landed in has to be re-totalled in full (the new rows alone don't describe
-- a day already partly counted), but all such days are totalled in one
-- grouped pass. The previous version ran a separate full-history query per
-- touched day, so being away from the popup for a month cost thirty of them.
local function incrMostReadingTimeDay(conn, hw_time, cached)
    local result = { duration_sec = cached.duration_sec, date = cached.date }
    local _, ok = StatsDb.withStatement(conn, string.format([[
        SELECT day, SUM(duration) AS total
        FROM (
            SELECT date(start_time, 'unixepoch', 'localtime') AS day, duration
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') IN (
                SELECT DISTINCT date(start_time, 'unixepoch', 'localtime')
                FROM page_stat WHERE start_time > %d
            )
        )
        GROUP BY day
        ORDER BY total DESC
        LIMIT 1
    ]], hw_time), function(stmt)
        for row in stmt:rows() do
            local dur = tonumber(row[2]) or 0
            if dur > result.duration_sec then
                result.duration_sec = dur
                result.date         = row[1]
            end
        end
    end)
    return result, ok
end

-- Same single-pass shape for the most-pages day.
local function incrMostPagesDay(conn, hw_time, cached)
    local result = { pages = cached.pages, date = cached.date }
    local _, ok = StatsDb.withStatement(conn, string.format([[
        SELECT day, COUNT(DISTINCT id_book || '-' || page) AS pages
        FROM (
            SELECT date(start_time, 'unixepoch', 'localtime') AS day, id_book, page
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') IN (
                SELECT DISTINCT date(start_time, 'unixepoch', 'localtime')
                FROM page_stat WHERE start_time > %d
            )
        )
        GROUP BY day
        ORDER BY pages DESC
        LIMIT 1
    ]], hw_time), function(stmt)
        for row in stmt:rows() do
            local cnt = tonumber(row[2]) or 0
            if cnt > result.pages then
                result.pages = cnt
                result.date  = row[1]
            end
        end
    end)
    return result, ok
end

-- Returns extra seconds accumulated in rows newer than hw_time.
local function incrExtraSecs(conn, hw_time)
    local extra = 0
    local _, ok = StatsDb.withStatement(conn, string.format(
        "SELECT SUM(duration) FROM page_stat WHERE start_time > %d", hw_time
    ), function(stmt)
        for row in stmt:rows() do extra = tonumber(row[1]) or 0 end
    end)
    return extra, ok
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
    -- The cache is read here, before the database is touched, and doubles as
    -- the fallback for the whole read. It used to be loaded inside the
    -- callback below, which meant a database that couldn't be opened - or a
    -- query that raised on the way in - threw away a perfectly good set of
    -- records and left the popup showing a dash on every row, while the
    -- insights popup, which keeps its own copies outside its database calls,
    -- carried on showing real numbers. Records the user has already earned
    -- should not depend on the database being readable this second; slightly
    -- out-of-date records beat none.
    local cache = loadCache()
    local fallback = cache and cacheToData(cache) or {
        longest      = { duration_sec = 0, date = nil },
        best_day     = { pages = 0, date = nil },
        streak       = { days = 0, start_date = nil, end_date = nil },
        total_secs   = 0,
        last_ms_date = nil,
    }

    return StatsDb.withDb(fallback, function(conn)

        -- 1. Get current DB fingerprint
        local cur_max_time, cur_row_count, fp_ok = getDbFingerprint(conn)

        -- Helper: run full queries, write cache, return data
        local function fullRecompute()
            local longest,  q1 = fullQueryMostReadingTimeDay(conn)
            local best_day, q2 = fullQueryMostPagesDay(conn)
            local streak,   q3 = fullQueryBestStreak(conn)
            local tot_secs, q4 = fullQueryTotalSecs(conn)
            local tot_hours = math.floor(tot_secs / 3600)
            local last_ms   = M.getMilestones(tot_hours)
            local lmd       = fullQueryMilestoneDate(conn, last_ms)

            local data = {
                longest      = longest,
                best_day     = best_day,
                streak       = streak,
                total_secs   = tot_secs,
                last_ms_date = lmd,
            }

            -- Only a reading history every query agreed on is worth keeping.
            -- A query that lost a race with KOReader's own statistics writer
            -- returns no rows rather than an error, so a single lost race
            -- used to be cached as "you have never read anything" - together
            -- with a perfectly valid fingerprint, which then matched on every
            -- later open and served those zeros back without ever consulting
            -- the database again. The popup stayed empty for good, while the
            -- insights popup (which keeps its own stale copies) carried on
            -- showing real numbers.
            if fp_ok and q1 and q2 and q3 and q4 then
                saveCache({
                    hw_max_time  = cur_max_time,
                    hw_row_count = cur_row_count,
                    longest      = longest,
                    best_day     = best_day,
                    streak       = streak,
                    total_secs   = tot_secs,
                    last_ms_date = lmd,
                })
            end
            return data
        end

        -- 3. No cache → full recompute
        if not cache then
            return fullRecompute()
        end

        -- 4. Cache matches DB exactly → return cached data directly
        if fp_ok and cache.hw_max_time == cur_max_time and cache.hw_row_count == cur_row_count then
            -- Unless it claims there is nothing to show while the database
            -- plainly has rows: that combination can't arise honestly, and
            -- is the signature a cache poisoned by an older version left
            -- behind. Recomputing heals it in place, so nobody has to go and
            -- delete the cache file by hand.
            if cur_row_count > 0 and isEmptyHistory(cacheToData(cache)) then
                return fullRecompute()
            end
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

        local i1, i2, i3
        d.longest,  i1 = incrMostReadingTimeDay(conn, hw, d.longest)
        d.best_day, i2 = incrMostPagesDay(conn, hw, d.best_day)

        local extra_secs
        extra_secs, i3 = incrExtraSecs(conn, hw)
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
        local i4 = true
        if new_distinct_dates then
            d.streak, i4 = fullQueryBestStreak(conn)
        end

        -- Milestone date: only re-query if the last milestone changed
        if new_last ~= old_last then
            d.last_ms_date = fullQueryMilestoneDate(conn, new_last)
        end

        -- Same rule as in fullRecompute: the watermark only moves forward
        -- over rows that were actually read. Storing cur_max_time after a
        -- query that quietly returned nothing would write those rows off as
        -- counted, and no later open would go looking for them again.
        if fp_ok and i1 and i2 and i3 and i4 then
            saveCache({
                hw_max_time  = cur_max_time,
                hw_row_count = cur_row_count,
                longest      = d.longest,
                best_day     = d.best_day,
                streak       = d.streak,
                total_secs   = d.total_secs,
                last_ms_date = d.last_ms_date,
            })
        end
        return d
    end)
end

return M
