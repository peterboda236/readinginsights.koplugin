--[[
Reading Insights - the data behind the insights popup.

Every reading-history figure the popup shows: streaks, the yearly and
monthly aggregates for all three modes (time, days, books), the last-week
and 8-week series, all-time totals, the weekday x hour matrix behind the
day-part heatmap, and the finished-book count for the reading goal.

Split out of insights_view.lua the same way lib/records_data.lua was split
out of the records popup. These were already plain functions in disguise -
written as methods on the popup class, but not one of them touched popup
state, only the statistics DB and the cache - so they lost the `self` they
never used and became module functions.

Caching is not done here but in lib/insights_cache.lua; this module decides
*what* to cache and when a cached value is still good, using the same
patterns throughout: per-minute for volatile figures, per-day "up to
yesterday" base aggregates merged with a cheap today-only query for the
rest, and stale copies as a fallback when the DB can't be read at all.

  Data.calculateStreaks(conn)              current/best daily + weekly streaks
  Data.getYearlyStats(year, conn)          time, days read and pages for a year
  Data.getMonthlyReadingHours/Days/BookCounts(year, conn)
                                           the monthly chart's three modes
  Data.getLastWeekAll(conn)                7-day averages + per-day series
  Data.getLast8WeeksData(metric, conn)     the 8-week trend series
  Data.getAllTimeStats(conn)               all-time hours and pages
  Data.getDailyReadingData(year, conn)     per-day totals, for the heatmap
  Data.getWeekdayHourReadingData(from, to, conn)
                                           weekday x hour totals
  Data.getYearRange(conn)                  first and last year with data
  Data.getFinishedBookCountForYear(year, conn)
                                           the reading goal's count
  Data.getFinishedBooksForYear(year)       the books behind that count
  Data.getStreakPeriodStats(from, to)      totals for one streak's date range
  Data.getBooksForPeriod(from, to) / Data.getAllBooks()
                                           the books behind the tapped period
  Data.withBatchConnection(fn)             one DB connection for a whole
                                           batch of the getters above
  Data.flushStatsToDB(ui)                  ask KOReader's statistics plugin to
                                           write pending rows before a reload
]]--

local deps = ...
local Locale, StatsDb, Cache, VS =
    deps.Locale, deps.StatsDb, deps.Cache, deps.VS
local Math = require("optmath")

-- Month labels for the monthly series. Same strings the view uses for its
-- own axis labels; they are attached to the data because the chart, the
-- book lists and the popup titles all want them.
local _ = Locale._
local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}
local MONTH_NAMES_FULL = {
    _("January"), _("February"), _("March"), _("April"), _("May"), _("June"),
    _("July"), _("August"), _("September"), _("October"), _("November"), _("December"),
}

local M = {}

-- The statistics koplugin keeps the current reading session's page timings
-- in memory (self.page_stat) and only periodically writes them into
-- statistics.sqlite3. Its own dialogs (e.g. "Current statistics") call
-- self:insertDB() right before reading anything from the DB, so the numbers
-- shown always include the still-open session. We do the same thing here
-- before querying "Last week", otherwise time spent in the current session
-- would be missing until KOReader's own autosave/close flushes it.
function M.flushStatsToDB(ui)
    local stats_plugin = ui and ui.statistics or nil
    if stats_plugin and stats_plugin.insertDB then
        pcall(stats_plugin.insertDB, stats_plugin)
    end
    return stats_plugin
end

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
function M.computeStreaksWithDates(entries_desc, is_consecutive, is_current_start)
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

-- Local midnight bounds of a "YYYY-MM-DD" day, as epoch seconds: everything
-- from lo (inclusive) to hi (exclusive) belongs to that local day.
--
-- Why this exists: `WHERE date(start_time,'unixepoch','localtime') = '...'`
-- reads well but wraps the indexed column in a function, so SQLite can use
-- no index and converts every row's timestamp to local time to test it. The
-- same filter written as a plain range on start_time uses
-- page_stat_data_start_time and is an order of magnitude cheaper on a real
-- database. os.time() normalises the components, so day + 1 rolls over
-- months and years correctly, and both ends are computed in local time, so
-- a DST day is 23 or 25 hours wide exactly as it should be.
function M.dayBounds(date_str)
    local y, m, d = M.parseDateYMD(date_str)
    if not y then return nil, nil end
    local lo = os.time{ year = y, month = m, day = d,     hour = 0, min = 0, sec = 0 }
    local hi = os.time{ year = y, month = m, day = d + 1, hour = 0, min = 0, sec = 0 }
    return lo, hi
end

function M.parseDateYMD(date_str)
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

-- Convert "YYYY-WW" to the Monday date of that ISO week as "YYYY-MM-DD".
function M.weekStrToMondayDate(week_str)
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
function M.getStreakPeriodStats(start_date, end_date)
    local stats = { duration = 0, pages = 0, books = 0 }
    if not start_date or not end_date then return stats end
    return StatsDb.withDb(stats, function(conn)
        -- Pages are counted the same way as everywhere else in this plugin
        -- (see the last-week query): the inner GROUP BY collapses a book's
        -- page to one row per day, so re-reading the same page later that
        -- day doesn't count twice, and the outer COUNT(*) then counts those
        -- rows. Summing the pre-summed durations gives the same total the
        -- flat SUM(duration) did before.
        local sql = string.format([[
            SELECT COALESCE(SUM(sum_dur), 0) AS total_duration,
                   COUNT(*)                  AS total_pages,
                   COUNT(DISTINCT id_book)   AS book_count
            FROM (
                SELECT id_book,
                       SUM(duration) AS sum_dur
                FROM page_stat
                WHERE date(start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
                GROUP BY id_book, page, date(start_time, 'unixepoch', 'localtime')
            )
        ]], start_date, end_date)
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                stats.duration = tonumber(row[1]) or 0
                stats.pages    = tonumber(row[2]) or 0
                stats.books    = tonumber(row[3]) or 0
            end
        end)
        return stats
    end)
end

-- Number of calendar days between two "YYYY-MM-DD" dates, inclusive.
function M.daysBetweenInclusive(start_date, end_date)
    local sy, sm, sd = M.parseDateYMD(start_date)
    local ey, em, ed = M.parseDateYMD(end_date)
    if not sy or not ey then return 1 end
    local t1 = os.time({ year = sy, month = sm, day = sd })
    local t2 = os.time({ year = ey, month = em, day = ed })
    local days = math.floor((t2 - t1) / 86400) + 1
    if days < 1 then days = 1 end
    return days
end

function M.calculateStreaks(shared_conn)
    local today  = Cache.todayDateStr()
    local minute = Cache.currentMinute()

    -- Daily lock: once we have confirmed today's reading and cached the result
    -- for today, skip the expensive full-table scan for the rest of the day.
    -- If today has no reading yet, fall back to per-minute checks so the streak
    -- updates as soon as the user starts reading.
    -- Force-reload (Cache.clearAllCache) wipes streaks_date so this is always bypassed.
    if Cache.ENABLE_CACHE and Cache._cache.streaks then
        if Cache._cache.streaks_date == today then
            return Cache._cache.streaks
        end
        if Cache._cache.streaks_today_confirmed and Cache._cache.streaks_date_minute == minute then
            return Cache._cache.streaks
        end
    end

    local streaks = {
        current_days  = 0,
        best_days     = 0,
        current_weeks = 0,
        best_weeks    = 0,
    }

    local result = StatsDb.withShared(shared_conn, streaks, function(conn)
        local dates = {}
        local sql = "SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') as d FROM page_stat ORDER BY d DESC"
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do table.insert(dates, row[1]) end
        end)

        local today_str   = os.date("%Y-%m-%d")
        local yesterday   = os.date("%Y-%m-%d", os.time() - 86400)

        local function isCurrentDayStart(first_date)
            return first_date == today_str or first_date == yesterday
        end

        local function isConsecutiveDay(prev_date, curr_date)
            local year, month, day = M.parseDateYMD(prev_date)
            if not year then return false end
            local prev_time   = os.time({ year = year, month = month, day = day })
            local expected_prev = os.date("%Y-%m-%d", prev_time - 86400)
            return curr_date == expected_prev
        end

        streaks.current_days, streaks.best_days,
        streaks.current_days_dates, streaks.best_days_dates =
            M.computeStreaksWithDates(dates, isConsecutiveDay, isCurrentDayStart)

        local weeks    = {}
        local sql_weeks = "SELECT DISTINCT strftime('%Y-%W', start_time, 'unixepoch', 'localtime') as w FROM page_stat ORDER BY w DESC"
        StatsDb.withStatement(conn, sql_weeks, function(stmt_weeks)
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
            M.computeStreaksWithDates(weeks, isConsecutiveWeek, isCurrentWeekStart)

        -- Check whether today already has confirmed reading activity in the DB.
        -- If yes, the streak result is stable for the rest of the day.
        local today_confirmed = false
        if dates[1] == today_str then
            today_confirmed = true
        end
        streaks._today_confirmed = today_confirmed

        return streaks
    end)

    if Cache.ENABLE_CACHE then
        Cache._cache.streaks      = result
        Cache._stale_cache.streaks = result
        -- If today's reading is confirmed in the DB, lock to daily refresh.
        -- Otherwise keep the per-minute fallback so the first read of the day is picked up.
        local today_confirmed = result and result._today_confirmed
        Cache._cache.streaks_today_confirmed = today_confirmed
        if today_confirmed then
            Cache._cache.streaks_date        = today
            Cache._cache.streaks_date_minute = nil
        else
            Cache._cache.streaks_date        = nil
            Cache._cache.streaks_date_minute = minute
        end
    end
    return result
end

function M.getMonthlyReadingDays(year, shared_conn)
    local today         = Cache.todayDateStr()
    local key           = "days:" .. year .. ":" .. today
    local base_key      = "days:" .. year
    local current_month = today:sub(1, 7)
    local minute        = Cache.currentMinute()

    -- Fast path: already served this exact minute, skip the DB entirely.
    local cached_val = Cache.getMinuteCache(Cache._monthly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = Cache.getCachedBase(Cache._monthly_base_cache, base_key, today)

    -- One connection covers both the (rare, once/day) base recompute and the
    -- (frequent) cheap today-only check.
    local merged = StatsDb.withShared(shared_conn, nil, function(conn)
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
            StatsDb.withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do base[row[1]] = tonumber(row[2]) or 0 end
            end)
        end

        local today_has_activity = false
        local day_lo, day_hi = M.dayBounds(today)
        StatsDb.withStatement(conn, string.format([[
            SELECT 1 FROM page_stat
            WHERE start_time >= %d AND start_time < %d
            LIMIT 1
        ]], day_lo, day_hi), function(stmt)
            for _ in stmt:rows() do today_has_activity = true end
        end)

        return { base = base, today_has_activity = today_has_activity }
    end)
    if not merged then
        local known_good = Cache.bestKnownFullResult(Cache._monthly_cache, key, Cache._stale_monthly, base_key .. ":")
        if known_good then return known_good end
        merged = { base = cached_base or {}, today_has_activity = false }
    end

    if Cache.ENABLE_CACHE and not cached_base then
        Cache._monthly_base_cache[base_key] = Cache.makeCachedBase(today, merged.base)
    end

    local months = buildMonthlyArray(year, function(year_month)
        local days = tonumber(merged.base[year_month]) or 0
        if merged.today_has_activity and year_month == current_month then
            days = days + 1
        end
        return { days = days }
    end)

    Cache.setMinuteCache(Cache._monthly_cache, Cache._stale_monthly, key, key .. ":minute", minute, months)
    return months
end

function M.getMonthlyReadingHours(year, shared_conn)
    local today         = Cache.todayDateStr()
    local key           = "hours:" .. year .. ":" .. today
    local base_key      = "hours:" .. year
    local current_month = today:sub(1, 7)
    local minute        = Cache.currentMinute()

    local cached_val = Cache.getMinuteCache(Cache._monthly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = Cache.getCachedBase(Cache._monthly_base_cache, base_key, today)

    local merged = StatsDb.withShared(shared_conn, nil, function(conn)
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
            StatsDb.withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do base[row[1]] = tonumber(row[2]) or 0 end
            end)
        end

        local today_seconds = 0
        -- Left as a date() filter on purpose: with a start_time range
        -- SQLite reorders page_stat's internal join and scans the
        -- `numbers` table first, which measured 20x slower on a real
        -- database. The range form only pays off where it doesn't
        -- disturb that join order.
        StatsDb.withStatement(conn, string.format([[
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
        local known_good = Cache.bestKnownFullResult(Cache._monthly_cache, key, Cache._stale_monthly, base_key .. ":")
        if known_good then return known_good end
        merged = { base = cached_base or {}, today_seconds = 0 }
    end

    if Cache.ENABLE_CACHE and not cached_base then
        Cache._monthly_base_cache[base_key] = Cache.makeCachedBase(today, merged.base)
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

    Cache.setMinuteCache(Cache._monthly_cache, Cache._stale_monthly, key, key .. ":minute", minute, months)
    return months
end

function M.getYearlyStats(year, shared_conn)
    local today    = Cache.todayDateStr()
    local key      = year .. ":v3:" .. today
    local base_key = year .. ":v3"
    local minute   = Cache.currentMinute()

    local cached_val = Cache.getMinuteCache(Cache._yearly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = Cache.getCachedBase(Cache._yearly_base_cache, base_key, today)

    -- One connection covers both the (once/day) base recompute and the
    -- (frequent) cheap today-only slice.
    local merged = StatsDb.withShared(shared_conn, nil, function(conn)
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
            StatsDb.withStatement(conn, sql, function(stmt)
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
            StatsDb.withStatement(conn, ids_sql, function(stmt)
                for row in stmt:rows() do base.book_ids[tostring(row[1])] = true end
            end)
        end

        local t = { pages = 0, duration = 0, has_activity = false, new_books = 0 }
        -- Only merge "today" into the total when the requested year is the
        -- current year - otherwise today's (this year's) activity would get
        -- added on top of a past, already-closed year's total.
        if year == tonumber(os.date("%Y")) then
            local seen = {}
            -- Left as a date() filter on purpose: with a start_time range
            -- SQLite reorders page_stat's internal join and scans the
            -- `numbers` table first, which measured 20x slower on a real
            -- database. The range form only pays off where it doesn't
            -- disturb that join order.
            StatsDb.withStatement(conn, string.format([[
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
                    if not (base.book_ids and base.book_ids[id_book]) and not seen[id_book] then
                        seen[id_book] = true
                        t.new_books = t.new_books + 1
                    end
                end
            end)
        end

        return { base = base, today_stats = t }
    end)
    if not merged then
        local known_good = Cache.bestKnownFullResult(Cache._yearly_cache, key, Cache._stale_yearly, base_key .. ":")
        if known_good then return known_good end
        merged = {
            base        = cached_base or { days = 0, pages = 0, duration = 0, books_started = 0, book_ids = {} },
            today_stats = { pages = 0, duration = 0, has_activity = false, new_books = 0 },
        }
    end

    if Cache.ENABLE_CACHE and not cached_base then
        Cache._yearly_base_cache[base_key] = Cache.makeCachedBase(today, merged.base)
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

    Cache.setMinuteCache(Cache._yearly_cache, Cache._stale_yearly, key, key .. ":minute", minute, result)
    return result
end

-- Returns a { ["YYYY-MM-DD"] = seconds_read } map covering every day in
-- `year` that has any reading activity (days with none simply have no
-- entry). Used to build the GitHub-style reading heatmap (a single
-- calendar year is fetched and cached at a time; getDailyReadingDataForRange
-- below stitches together whichever year(s) a given half-year period
-- spans). Same dedup approach as getYearlyStats (group by book/page/day
-- first, so a page re-read across multiple sessions on the same day
-- isn't double counted), just grouped further down to per-day totals
-- instead of one yearly sum. Cached per day (like getYearRange below)
-- since the heatmap is only opened on demand, not on every popup rebuild.
function M.getDailyReadingData(year, shared_conn)
    local today = Cache.todayDateStr()
    local cache_key = tostring(year)

    if Cache.ENABLE_CACHE and Cache._cache.daily_data and Cache._cache.daily_data[cache_key]
       and Cache._cache.daily_data[cache_key].date == today then
        return Cache._cache.daily_data[cache_key].data
    end

    local data = StatsDb.withShared(shared_conn, {}, function(conn)
        local year_str = tostring(year)
        local sql = string.format([[
            SELECT day, SUM(dur) AS duration
            FROM (
                SELECT id_book, page,
                       date(start_time, 'unixepoch', 'localtime') AS day,
                       SUM(duration) AS dur
                FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book, page, day
            )
            GROUP BY day
        ]], year_str)

        local result = {}
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                result[row[1]] = tonumber(row[2]) or 0
            end
        end)
        return result
    end)
    data = data or {}

    if Cache.ENABLE_CACHE then
        Cache._cache.daily_data = Cache._cache.daily_data or {}
        Cache._cache.daily_data[cache_key] = { date = today, data = data }
    end
    return data
end

-- Returns a { [1..7] = { [0..23] = seconds_read } } map (1 = Monday) for
-- the inclusive [start_t, end_t] range - the same period the calendar
-- heatmap above it covers - used to build the time-of-day heatmap (see
-- Heatmap.buildDayPartHeatmapWidget). Grouped by book/page/day/hour first, same
-- dedup approach as getDailyReadingData, so a page re-read across
-- multiple sessions in the same hour isn't double counted.
function M.getWeekdayHourReadingData(start_t, end_t, shared_conn)
    local start_str = os.date("%Y-%m-%d", start_t)
    local end_str   = os.date("%Y-%m-%d", end_t)

    local data = {}
    for wd = 1, 7 do
        data[wd] = {}
        for h = 0, 23 do data[wd][h] = 0 end
    end

    return StatsDb.withShared(shared_conn, data, function(conn)
        local sql = string.format([[
            SELECT dow, hour, SUM(dur) AS duration
            FROM (
                SELECT id_book, page,
                       strftime('%%w', start_time, 'unixepoch', 'localtime') AS dow,
                       CAST(strftime('%%H', start_time, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                       date(start_time, 'unixepoch', 'localtime') AS day,
                       SUM(duration) AS dur
                FROM page_stat
                WHERE date(start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
                GROUP BY id_book, page, day, dow, hour
            )
            GROUP BY dow, hour
        ]], start_str, end_str)

        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                local dow_sun0 = tonumber(row[1]) or 0  -- 0=Sun..6=Sat
                local wd = ((dow_sun0 + 6) % 7) + 1     -- 1=Mon..7=Sun
                local hour = tonumber(row[2]) or 0
                data[wd][hour] = tonumber(row[3]) or 0
            end
        end)
        return data
    end)
end

-- Returns { min_year, max_year, min_month } from the DB, cached per day.
-- min_month is the calendar month (1-12) of the very first reading
-- record within min_year - used by the reading heatmap to stop swiping
-- back exactly at the first month with data (see Heatmap.heatmapMaxPeriodsBack)
-- rather than just the first year.
function M.getYearRange(shared_conn)
    local today        = Cache.todayDateStr()
    local range_cached = Cache.ENABLE_CACHE and Cache._cache.year_range and Cache._cache.year_range_date == today

    if range_cached then
        return Cache._cache.year_range
    end

    local current_year = tonumber(os.date("%Y"))
    local range = { min_year = current_year, max_year = current_year, min_month = 1 }

    StatsDb.withShared(shared_conn, nil, function(conn)
        local sql_range = [[
            SELECT MIN(strftime('%Y', start_time, 'unixepoch', 'localtime')) AS min_year,
                   MAX(strftime('%Y', start_time, 'unixepoch', 'localtime')) AS max_year,
                   MIN(strftime('%Y-%m', start_time, 'unixepoch', 'localtime')) AS min_year_month
            FROM page_stat
        ]]
        StatsDb.withStatement(conn, sql_range, function(stmt)
            for row in stmt:rows() do
                if row[1] then range.min_year = tonumber(row[1]) or current_year end
                if row[2] then range.max_year = tonumber(row[2]) or current_year end
                if row[3] then range.min_month = tonumber(row[3]:sub(6, 7)) or 1 end
            end
        end)
        if Cache.ENABLE_CACHE then
            Cache._cache.year_range      = range
            Cache._cache.year_range_date = today
            Cache._stale_cache.year_range = range
        end
    end)

    return range
end

function M.getAllTimeStats(shared_conn)
    local today  = Cache.todayDateStr()
    local minute = Cache.currentMinute()

    local cached_val = Cache.getMinuteCache(Cache._cache, "all_time", "all_time_minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = Cache.getCachedBase(Cache._alltime_base_cache, nil, today)

    -- One connection covers both the (once/day, whole-history) base
    -- recompute and today's cheap, narrowly-scoped queries.
    local merged = StatsDb.withShared(shared_conn, nil, function(conn)
        local base = cached_base
        if not base then
            base = { duration = 0, pages = 0, book_count = 0 }
            StatsDb.withStatement(conn, string.format([[
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
            StatsDb.withStatement(conn, string.format([[
                SELECT COUNT(DISTINCT id_book) FROM page_stat
                WHERE date(start_time, 'unixepoch', 'localtime') < '%s'
            ]], today), function(stmt)
                for row in stmt:rows() do base.book_count = tonumber(row[1]) or 0 end
            end)
        end

        local t = { duration = 0, new_pages = 0, new_books = 0 }

        local day_lo, day_hi = M.dayBounds(today)

        StatsDb.withStatement(conn, string.format([[
            SELECT SUM(duration) FROM page_stat
            WHERE start_time >= %d AND start_time < %d
        ]], day_lo, day_hi), function(stmt)
            for row in stmt:rows() do t.duration = tonumber(row[1]) or 0 end
        end)

        -- "Pages seen for the first time today", asked the cheap way round.
        -- The obvious phrasing - take today's pages, then for each one check
        -- that no earlier row exists - runs that check once per page, and
        -- each check re-scans history. Asking instead for the first time
        -- every page was ever seen, and counting the ones that land in
        -- today, is a single grouped pass: 64ms -> 8ms on a real
        -- statistics.sqlite3, with identical answers on every one of its 79
        -- days.
        StatsDb.withStatement(conn, string.format([[
            SELECT COUNT(*) FROM (
                SELECT id_book, page, MIN(start_time) AS first_seen
                FROM page_stat GROUP BY id_book, page
            )
            WHERE first_seen >= %d AND first_seen < %d
        ]], day_lo, day_hi), function(stmt)
            for row in stmt:rows() do t.new_pages = tonumber(row[1]) or 0 end
        end)

        -- Not rewritten like the pages query above: there are only ever a
        -- handful of books, so the correlated form is already cheap, while
        -- grouping would have to walk the whole history (measured 2.5x
        -- slower).
        StatsDb.withStatement(conn, string.format([[
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
        -- Not prefix-keyed like the yearly/monthly caches (there's only
        -- ever one all-time total), so check the two single-value slots
        -- directly instead of going through Cache.bestKnownFullResult.
        if Cache._cache.all_time then return Cache._cache.all_time end
        if Cache._stale_cache.all_time then return Cache._stale_cache.all_time end
        merged = {
            base        = cached_base or { duration = 0, pages = 0, book_count = 0 },
            today_stats = { duration = 0, new_pages = 0, new_books = 0 },
        }
    end

    if Cache.ENABLE_CACHE and not cached_base then
        Cache._alltime_base_cache = Cache.makeCachedBase(today, merged.base)
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

    Cache.setMinuteCache(Cache._cache, Cache._stale_cache, "all_time", "all_time_minute", minute, result)
    return result
end

-- Counts books "finished" in `year` for the reading-goal section. A book
-- counts when its very last page_stat entry - across its whole history, not
-- just this year - reached at least 99% of the book, and that entry falls in
-- `year`. Deliberately narrower than the "ever reached the last page" check
-- used elsewhere: a book that was finished and later reopened and left
-- partway through should stop counting.
--
-- Two consequences worth remembering: a book read across New Year counts
-- once, in the year it was finished, and a book with no known page count
-- (book.pages = 0, as some formats give) can't be judged at all and is never
-- counted - the manual checklist is the way to include one.
--
-- The list is persisted per year and updated incrementally: each refresh
-- only re-judges books touched since that year's watermark, in both
-- directions, so one that no longer qualifies is dropped again. A manual
-- "reload data" resets it to a full re-scan.
-- Adjusts a query-based finished count by the user's manual overrides for
-- that year (see VS.readFinishedOverrides above): +1 for each override=true
-- book the query didn't already count, -1 for each override=false book the
-- query did count. Applied on every return path of
-- getFinishedBookCountForYear below, cached or freshly-scanned alike, so
-- the "N book(s) finished" figure always matches what the checklist /
-- showFinishedBooksForYear list actually shows.
function M.applyFinishedOverrides(year_key, count)
    local overrides = VS.readFinishedOverrides(year_key)
    if not next(overrides) then return count end
    local known_set = Cache._goal_finished_books[year_key] or {}
    local adjust = 0
    for id_str, val in pairs(overrides) do
        local in_base = known_set[id_str] ~= nil
        if val == true and not in_base then
            adjust = adjust + 1
        elseif val == false and in_base then
            adjust = adjust - 1
        end
    end
    return count + adjust
end

function M.getFinishedBookCountForYear(year, shared_conn)
    local minute = Cache.currentMinute()
    -- v3: the incremental scan below re-checks books it already counted
    -- (v2 never did, see the "re-checking" note above), so a v2 list left
    -- over from an older version - which may hold books this version would
    -- no longer count - must not be reused as-is.
    local key = tostring(year) .. ":goal:v3"
    local year_key = tostring(year)

    local cached = Cache.getMinuteCache(Cache._goal_cache, key, key .. ":minute", minute)
    if cached ~= nil then
        return M.applyFinishedOverrides(year_key, cached)
    end

    local known = Cache._goal_finished_books[year_key]
    if type(known) ~= "table" then
        known = {}
        Cache._goal_finished_books[year_key] = known
    end
    local state     = Cache._goal_scan_watermark[year_key]
    local watermark, prev_rows
    if type(state) == "table" then
        watermark, prev_rows = tonumber(state.time) or 0, tonumber(state.rows)
    else
        -- Plain number: a watermark written by the previous version, which
        -- didn't track the row count. Treated as "row count unknown", which
        -- forces one full re-scan below and upgrades it to the new format.
        watermark, prev_rows = tonumber(state) or 0, nil
    end

    local count = StatsDb.withShared(shared_conn, nil, function(conn)
        -- Watermark sanity check. The incremental scan below only looks at
        -- rows *newer* than the last scan, which silently gives a wrong
        -- answer if the table changed in any other way: rows deleted (a
        -- book removed from the statistics DB), or older rows appearing out
        -- of nowhere (statistics.sqlite3 restored from a backup, or merged
        -- with another device's history - a normal thing for KOReader users
        -- to do). Both are caught by comparing the total row count against
        -- what it was at the end of the last scan: if the difference isn't
        -- exactly the number of rows newer than the watermark, something
        -- other than plain appending happened, and this year's list is
        -- thrown away and rebuilt from scratch.
        local total_rows, rows_after = 0, 0
        StatsDb.withStatement(conn, string.format(
            "SELECT COUNT(*), SUM(CASE WHEN start_time > %d THEN 1 ELSE 0 END) FROM page_stat",
            math.floor(watermark)), function(stmt)
            for row in stmt:rows() do
                total_rows = tonumber(row[1]) or 0
                rows_after = tonumber(row[2]) or 0
            end
        end)

        if prev_rows == nil or (total_rows - prev_rows) ~= rows_after then
            known     = {}
            Cache._goal_finished_books[year_key] = known
            watermark = 0
            rows_after = total_rows
        end

        -- Read the new watermark *before* scanning, not after: a row
        -- inserted while this function runs then still falls after the
        -- recorded watermark and gets picked up by the next scan, instead
        -- of being skipped forever because the watermark was moved past it
        -- without it ever having been looked at.
        local new_watermark = watermark
        StatsDb.withStatement(conn, "SELECT MAX(start_time) FROM page_stat", function(stmt)
            for row in stmt:rows() do
                new_watermark = tonumber(row[1]) or new_watermark
            end
        end)

        -- Every book touched since the last scan, *including* ones already
        -- on this year's list. Re-checking those is what keeps the count
        -- honest when a book stops qualifying: a book finished in December
        -- and then reread into January now has its last entry in the new
        -- year, so it must drop off the old year's list (otherwise it would
        -- be counted in both years for good), and the same goes for a
        -- finished book that was reopened and left partway through.
        local candidates = {}
        StatsDb.withStatement(conn, string.format(
            "SELECT DISTINCT id_book FROM page_stat WHERE start_time > %d",
            math.floor(watermark)), function(stmt)
            for row in stmt:rows() do
                local id_book = tonumber(row[1])
                if id_book then table.insert(candidates, id_book) end
            end
        end)

        if #candidates > 0 then
            local qualifies = {}
            local check_sql = string.format([[
                WITH last_entry AS (
                    SELECT id_book, MAX(start_time) AS last_time
                    FROM page_stat
                    WHERE id_book IN (%s)
                    GROUP BY id_book
                ),
                last_page AS (
                    SELECT le.id_book AS id_book, le.last_time AS last_time,
                           MAX(ps.page) AS last_page
                    FROM last_entry le
                    JOIN page_stat ps ON ps.id_book = le.id_book AND ps.start_time = le.last_time
                    GROUP BY le.id_book, le.last_time
                )
                SELECT lp.id_book, lp.last_time
                FROM last_page lp
                JOIN book b ON b.id = lp.id_book
                WHERE b.pages > 0
                  AND CAST(lp.last_page AS REAL) / b.pages >= 0.99
                  AND strftime('%%Y', lp.last_time, 'unixepoch', 'localtime') = '%s'
            ]], table.concat(candidates, ","), year_key)
            StatsDb.withStatement(conn, check_sql, function(stmt)
                for row in stmt:rows() do
                    local id_book   = tonumber(row[1])
                    local last_time = tonumber(row[2])
                    if id_book then qualifies[tostring(id_book)] = last_time or true end
                end
            end)
            -- Verdict applied in both directions, for every candidate.
            for _, id_book in ipairs(candidates) do
                local id_str = tostring(id_book)
                known[id_str] = qualifies[id_str] -- nil removes it from the list
            end
        end

        Cache._goal_scan_watermark[year_key] = { time = new_watermark, rows = total_rows }

        local c = 0
        for _ in pairs(known) do c = c + 1 end
        return c
    end)

    if count == nil then
        if Cache._goal_cache[key] ~= nil then return M.applyFinishedOverrides(year_key, Cache._goal_cache[key]) end
        if Cache._stale_goal_cache[key] ~= nil then return M.applyFinishedOverrides(year_key, Cache._stale_goal_cache[key]) end
        local c = 0
        for _ in pairs(known) do c = c + 1 end
        count = c
    end

    Cache.setMinuteCache(Cache._goal_cache, Cache._stale_goal_cache, key, key .. ":minute", minute, count)
    return M.applyFinishedOverrides(year_key, count)
end

-- Same "last entry >= 99%" definition as getFinishedBookCountForYear above,
-- but returns the book rows themselves (for the goal section's "N book(s)
-- finished" tap → book list). Not cached: only queried on demand, when the
-- list is actually opened.
function M.getFinishedBooksForYear(year)
    local books = {}
    return StatsDb.withDb(books, function(conn)
        local sql = string.format([[
            WITH last_entry AS (
                SELECT id_book, MAX(start_time) AS last_time
                FROM page_stat
                GROUP BY id_book
            ),
            last_page AS (
                SELECT le.id_book AS id_book, le.last_time AS last_time,
                       MAX(ps.page) AS last_page
                FROM last_entry le
                JOIN page_stat ps ON ps.id_book = le.id_book AND ps.start_time = le.last_time
                GROUP BY le.id_book, le.last_time
            )
            SELECT book.title, book.id AS id_book, lp.last_time AS last_time,
                   (SELECT SUM(duration) FROM page_stat
                    WHERE id_book = book.id
                      AND strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s') AS duration_sec
            FROM last_page lp
            JOIN book ON book.id = lp.id_book
            WHERE book.pages > 0
              AND CAST(lp.last_page AS REAL) / book.pages >= 0.99
              AND strftime('%%Y', lp.last_time, 'unixepoch', 'localtime') = '%s'
            ORDER BY lp.last_time DESC
        ]], tostring(year), tostring(year))
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    title    = row[1] or _("Unknown"),
                    authors  = "",
                    id_book  = tonumber(row[2]),
                    duration = tonumber(row[4]) or 0,
                })
            end
        end)
        return books
    end)
end

-- Returns both last-week stats in one DB connection:
--   last_week:       { avg_seconds, avg_pages }
--   last_week_daily: array[7] of { hours, seconds, pages, label, midnight_ts }, index 1 = today
function M.getLastWeekAll(shared_conn)
    local minute = Cache.currentMinute()
    local lw_ok    = Cache.getMinuteCache(Cache._cache, "last_week", "last_week_minute", minute) ~= nil
    local daily_ok = Cache.getMinuteCache(Cache._cache, "last_week_daily", "last_week_daily_minute", minute) ~= nil
    if lw_ok and daily_ok then
        return Cache._cache.last_week, Cache._cache.last_week_daily
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

    local lw_result    = lw_ok    and Cache._cache.last_week       or { avg_seconds = 0, avg_pages = 0 }
    local daily_result = daily_ok and Cache._cache.last_week_daily or nil

    StatsDb.withShared(shared_conn, nil, function(conn)
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
            StatsDb.withStatement(conn, sql, function(stmt)
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
                    pages       = pages_by_date[di.date_str]   or 0,
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
            daily_result[i] = { hours = 0, seconds = 0, pages = 0, label = di.label, midnight_ts = di.midnight_ts }
        end
    end

    Cache.setMinuteCache(Cache._cache, Cache._stale_cache, "last_week", "last_week_minute", minute, lw_result)
    Cache.setMinuteCache(Cache._cache, Cache._stale_cache, "last_week_daily", "last_week_daily_minute", minute, daily_result)
    return lw_result, daily_result
end

-- Returns an array of 8 weekly buckets (index 1 = oldest of the 8 weeks,
-- index 8 = current week), each { start_date, end_date, seconds, pages }.
-- Mirrors the de-duplication logic used by getLastWeekAll, just over a
-- wider 56-day window split into 7-day chunks.
function M.getLast8WeeksData()
    local minute = Cache.currentMinute()
    local cached_val = Cache.getMinuteCache(Cache._cache, "last8weeks", "last8weeks_minute", minute)
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

    StatsDb.withDb(nil, function(conn)
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

        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                local day_str = row[1]
                local secs  = tonumber(row[2]) or 0
                local pages = tonumber(row[3]) or 0
                local y, m, d = M.parseDateYMD(day_str)
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

    Cache.setMinuteCache(Cache._cache, Cache._stale_cache, "last8weeks", "last8weeks_minute", minute, weeks)
    return weeks
end

function M.getMonthlyBookCounts(year, shared_conn)
    local today         = Cache.todayDateStr()
    local key           = "books:" .. year .. ":" .. today
    local base_key      = "books:" .. year
    local current_month = today:sub(1, 7)
    local minute        = Cache.currentMinute()

    local cached_val = Cache.getMinuteCache(Cache._monthly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = Cache.getCachedBase(Cache._monthly_base_cache, base_key, today)

    local merged = StatsDb.withShared(shared_conn, nil, function(conn)
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
            StatsDb.withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do counts[row[1]] = tonumber(row[2]) or 0 end
            end)

            local ids_sql = string.format([[
                SELECT DISTINCT id_book
                FROM page_stat
                WHERE strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
                  AND date(start_time, 'unixepoch', 'localtime') < '%s'
            ]], current_month, today)
            local book_ids = {}
            StatsDb.withStatement(conn, ids_sql, function(stmt)
                for row in stmt:rows() do book_ids[tostring(row[1])] = true end
            end)

            base = { counts = counts, current_month_book_ids = book_ids }
        end

        local new_books_today = 0
        local day_lo, day_hi = M.dayBounds(today)
        StatsDb.withStatement(conn, string.format([[
            SELECT DISTINCT id_book FROM page_stat
            WHERE start_time >= %d AND start_time < %d
        ]], day_lo, day_hi), function(stmt)
            for row in stmt:rows() do
                local id_book = tostring(row[1])
                if not (base.current_month_book_ids and base.current_month_book_ids[id_book]) then
                    new_books_today = new_books_today + 1
                end
            end
        end)

        return { base = base, new_books_today = new_books_today }
    end)
    if not merged then
        local known_good = Cache.bestKnownFullResult(Cache._monthly_cache, key, Cache._stale_monthly, base_key .. ":")
        if known_good then return known_good end
        merged = { base = cached_base or { counts = {}, current_month_book_ids = {} }, new_books_today = 0 }
    end

    if Cache.ENABLE_CACHE and not cached_base then
        Cache._monthly_base_cache[base_key] = Cache.makeCachedBase(today, merged.base)
    end

    local months = buildMonthlyArray(year, function(year_month)
        local book_count = tonumber(merged.base.counts[year_month]) or 0
        if year_month == current_month then
            book_count = book_count + merged.new_books_today
        end
        return { book_count = book_count }
    end)

    Cache.setMinuteCache(Cache._monthly_cache, Cache._stale_monthly, key, key .. ":minute", minute, months)
    return months
end

-- Sums the .duration field (seconds) across a list of books; used to build
-- the "(H:MM:SS)" suffix in the various "books read in <period>" titles.
function M.sumDuration(books)
    local total_secs = 0
    for _, b in ipairs(books) do
        total_secs = total_secs + (b.duration or 0)
    end
    return total_secs
end

function M.getBooksForPeriod(period_format, period_value)
    local books = {}
    return StatsDb.withDb(books, function(conn)
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

        StatsDb.withStatement(conn, sql, function(stmt)
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

function M.getAllBooks()
    local books = {}
    return StatsDb.withDb(books, function(conn)
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
        StatsDb.withStatement(conn, sql, function(stmt)
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

-- Opens one connection for a whole batch of the getters above. The popup's
-- reload path calls seven of them in a row; handing each the same
-- connection turns seven open/close cycles into one. Every getter still
-- works standalone with no connection at all, so this is an optimisation,
-- never a requirement.
function M.withBatchConnection(fn)
    local conn = StatsDb.open()
    local ok, result = pcall(fn, conn)
    if conn then conn:close() end
    if not ok then return nil end
    return result
end

return M
