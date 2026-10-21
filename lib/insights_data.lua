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
  Data.getMaxStartTime(conn)               cheap "anything new since X" probe,
                                           for the heatmap popup's smart
                                           background-refresh gate
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
local Locale, StatsDb, Cache, VS, Manual, Prefs =
    deps.Locale, deps.StatsDb, deps.Cache, deps.VS, deps.Manual, deps.Prefs
local Math = require("optmath")
local DataStorage = require("datastorage")

-- 0 = Sunday, 1 = Monday - the shared "week start day" setting the heatmaps and
-- calendars use. Falls back to Monday if Prefs isn't wired in (e.g. a test).
local function weekStartWday()
    if Prefs and Prefs.weekStartWday then return Prefs.weekStartWday() end
    return 1
end

-- Month labels for the monthly series. Same strings the view uses for its
-- own axis labels; they are attached to the data because the chart, the
-- book lists and the popup titles all want them.
local _ = Locale._
local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}
local MONTH_NAMES_FULL = {
    _("January"), _("February"), _("March"), _("April"), _("May "), _("June"),
    _("July"), _("August"), _("September"), _("October"), _("November"), _("December"),
}

local M = {}

-- The statistics koplugin keeps the current reading session's page timings
-- in memory (self.page_stat) and only periodically writes them into
-- statistics.sqlite3. Its own dialogs (e.g. "Current statistics") call
-- self:insertDB() right before reading anything from the DB, so the numbers
-- shown always include the still-open session. We do the same thing here
-- before querying "Last 7 days", otherwise time spent in the current session
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

-- Are two "YYYY-WW" week labels (strftime('%Y-%W')) adjacent calendar weeks?
-- `prev_week` is the newer label, `curr_week` the older one (streaks iterate
-- newest-first). %W numbers weeks 00-53, week 01 starting on the year's first
-- Monday and the days before it being week 00.
function M.isConsecutiveWeek(prev_week, curr_week)
    local prev_year, prev_wk = parseWeekYear(prev_week)
    local curr_year, curr_wk = parseWeekYear(curr_week)
    if not prev_year or not curr_year then return false end
    if prev_year == curr_year and prev_wk == curr_wk + 1 then return true end
    if prev_year == curr_year + 1 and curr_wk >= 52 then
        -- Old year's last week (52/53) connecting to the new year. Normally
        -- the new year opens with week 00 (the days before its first Monday).
        -- But when Jan 1 is itself a Monday there are no such days, so the
        -- year starts at week 01 and 52/53 connects straight to it. Gate the
        -- week-01 case on Jan 1 actually being a Monday, otherwise a genuinely
        -- skipped week 00 would be papered over as a continuous streak.
        if prev_wk == 0 then return true end
        if prev_wk == 1 then
            local jan1 = os.time({ year = prev_year, month = 1, day = 1, hour = 12 })
            if tonumber(os.date("%w", jan1)) == 1 then return true end
        end
    end
    return false
end

-- Convert a "YYYY-WW" week string to the Monday date of that week, as
-- "YYYY-MM-DD".
--
-- The week numbering here MUST match the one the streak data is grouped by,
-- which is SQLite's strftime('%W'): week 01 begins on the first Monday of the
-- year, and the days before that first Monday are week 00. This is NOT ISO
-- 8601 week numbering. An earlier version computed the Monday with the ISO
-- "Jan 4 is in week 1" rule; that disagrees with %W in every year whose Jan 1
-- is not a Monday (i.e. most years) and shifted the whole range back by a
-- week, so the weekly-streak popup left out the current week entirely - its
-- date range ended on the previous week's Sunday.
function M.weekStrToMondayDate(week_str)
    if not week_str then return nil end
    local year, week = parseWeekYear(week_str)
    if not year or not week then return nil end
    -- Noon (not midnight) so a DST rollover can't push os.date() onto the
    -- previous calendar day when it formats the result.
    local jan1 = os.time({ year = year, month = 1, day = 1, hour = 12 })
    local wday = tonumber(os.date("%w", jan1))  -- 0=Sun .. 6=Sat
    if wday == 0 then wday = 7 end              -- treat Sunday as 7 (Mon..Sun = 1..7)
    -- Days from Jan 1 to the first Monday (the start of %W week 01). Mon->0,
    -- Tue->6, ... Sun->1. For week 00 the (week - 1) term below is -1, which
    -- lands on the Monday just before that first Monday - exactly the block
    -- %W labels the pre-first-Monday days with.
    local days_to_first_monday = (8 - wday) % 7
    local first_monday = jan1 + days_to_first_monday * 86400
    local target_mon = first_monday + (week - 1) * 7 * 86400
    return os.date("%Y-%m-%d", target_mon)
end

-- The shared "week start day" (0 = Sunday, 1 = Monday) as a public accessor,
-- so other modules (e.g. achievements) can group weeks the same way the weekly
-- streak does.
function M.weekStartWday()
    return weekStartWday()
end

-- SQL expression mapping page_stat.start_time to the "YYYY-MM-DD" date its
-- (setting-defined) week starts on. SQLite has no Sunday-week token (%U), so
-- the shift is derived from %w (0=Sun..6=Sat): Monday-start weeks step back
-- (%w+6)%7 days, Sunday-start weeks step back %w days. Used by both the weekly
-- streak and the "most read in a week" achievement, so they agree on where a
-- week begins.
function M.weekStartSqlExpr(week_start_wd)
    local dow = "strftime('%w', start_time, 'unixepoch', 'localtime')"
    local offset = (week_start_wd == 0) and dow or ("((" .. dow .. " + 6) % 7)")
    return "date(start_time, 'unixepoch', 'localtime', '-' || " .. offset .. " || ' days')"
end

-- The "YYYY-MM-DD" date on which the (setting-defined) week containing
-- `date_str` starts. week_start_wd is 0 = Sunday, 1 = Monday, matching
-- Prefs.weekStartWday(). This is what the weekly streak groups reading by now,
-- so the streak follows the same Monday/Sunday choice as the calendar display.
function M.weekStartDate(date_str, week_start_wd)
    local y, m, d = M.parseDateYMD(date_str)
    if not y then return nil end
    local t    = os.time{ year = y, month = m, day = d, hour = 12 }
    local wday = tonumber(os.date("%w", t))  -- 0=Sun..6=Sat
    local offset = (week_start_wd == 0) and wday or ((wday + 6) % 7)
    return os.date("%Y-%m-%d", t - offset * 86400)
end

-- Are two week-start dates ("YYYY-MM-DD", from weekStartDate) adjacent weeks?
-- `prev` is the newer week, `curr` the older one (streaks iterate newest-first),
-- so they are consecutive exactly when they are 7 days apart.
function M.isConsecutiveWeekDate(prev, curr)
    local py, pm, pd = M.parseDateYMD(prev)
    local cy, cm, cd = M.parseDateYMD(curr)
    if not py or not cy then return false end
    local pt = os.time{ year = py, month = pm, day = pd, hour = 12 }
    local ct = os.time{ year = cy, month = cm, day = cd, hour = 12 }
    return math.floor((pt - ct) / 86400 + 0.5) == 7
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

-- Set of days that had any reading in a "YYYY-MM-DD" date range (inclusive),
-- as { ["YYYY-MM-DD"] = true }. Used to fill the streak-date popup's calendar:
-- days present in this set are drawn as read (daily-streak) cells, the rest of
-- the streak's span as weekly-streak gap cells.
function M.getReadingDaysInRange(start_date, end_date)
    local days = {}
    if not start_date or not end_date then return days end
    return StatsDb.withDb(days, function(conn)
        local sql = string.format([[
            SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
        ]], start_date, end_date)
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do days[row[1]] = true end
        end)
        return days
    end)
end

-- Per-day totals ({ seconds = n, pages = n }) for every day in a "YYYY-MM-DD"
-- date range (inclusive) that had any reading, keyed by date string. Used by
-- the streak history popup (streak_calendar_view.lua's M.showHistory) to draw
-- one bar per day, toggled between reading time and pages. Same book/page/day
-- de-dup as getStreakPeriodStats/getDailyReadingData, just grouped by day
-- instead of summed over the whole range, and carrying both metrics at once
-- so switching the toggle never needs a second query.
function M.getDailyStatsInRange(start_date, end_date)
    local days = {}
    if not start_date or not end_date then return days end
    return StatsDb.withDb(days, function(conn)
        local sql = string.format([[
            SELECT day, SUM(dur) AS duration, COUNT(*) AS pages
            FROM (
                SELECT id_book, page,
                       date(start_time, 'unixepoch', 'localtime') AS day,
                       SUM(duration) AS dur
                FROM page_stat
                WHERE date(start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
                GROUP BY id_book, page, day
            )
            GROUP BY day
        ]], start_date, end_date)
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                days[row[1]] = {
                    seconds = tonumber(row[2]) or 0,
                    pages   = tonumber(row[3]) or 0,
                }
            end
        end)
        return days
    end)
end

-- The books read on each day of a "YYYY-MM-DD" date range (inclusive), most
-- read first: { ["YYYY-MM-DD"] = { { id_book, md5, title, authors, seconds },
-- ... } }. Used by the streak calendar to put the cover of the day's most-read
-- book (and the runner-up behind it) into the day's cell. One grouped query for
-- the whole range, so paging the calendar never touches the database again.
function M.getDayBooksInRange(start_date, end_date)
    local days = {}
    if not start_date or not end_date then return days end
    return StatsDb.withDb(days, function(conn)
        local sql = string.format([[
            SELECT date(ps.start_time, 'unixepoch', 'localtime') AS d,
                   ps.id_book, book.md5, book.title, book.authors,
                   SUM(ps.duration) AS secs
            FROM page_stat ps
            JOIN book ON ps.id_book = book.id
            WHERE date(ps.start_time, 'unixepoch', 'localtime') BETWEEN '%s' AND '%s'
            GROUP BY d, ps.id_book
            ORDER BY d ASC, secs DESC, ps.id_book ASC
        ]], start_date, end_date)
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                local d = row[1]
                local list = days[d]
                if not list then list = {}; days[d] = list end
                list[#list + 1] = {
                    id_book = tonumber(row[2]),
                    md5     = row[3],
                    title   = row[4],
                    authors = row[5],
                    seconds = tonumber(row[6]) or 0,
                }
            end
        end)
        return days
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
    local today      = Cache.todayDateStr()
    local minute     = Cache.currentMinute()
    local week_start = weekStartWday()

    -- Daily lock: once we have confirmed today's reading and cached the result
    -- for today, skip the expensive full-table scan for the rest of the day.
    -- If today has no reading yet, fall back to per-minute checks so the streak
    -- updates as soon as the user starts reading.
    -- Force-reload (Cache.clearAllCache) wipes streaks_date so this is always bypassed.
    -- The cache is also bypassed when the week-start setting changed, since that
    -- changes the weekly streak.
    if Cache.ENABLE_CACHE and Cache._cache.streaks and Cache._cache.streaks_week_start == week_start then
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

        -- Group reading into weeks whose first day matches the week-start
        -- setting (Monday or Sunday), by mapping each reading day to the date
        -- its week began on (see M.weekStartSqlExpr).
        local weekstart_expr = M.weekStartSqlExpr(week_start)

        local weeks    = {}
        local sql_weeks = "SELECT DISTINCT " .. weekstart_expr .. " AS w FROM page_stat ORDER BY w DESC"
        StatsDb.withStatement(conn, sql_weeks, function(stmt_weeks)
            for row in stmt_weeks:rows() do table.insert(weeks, row[1]) end
        end)

        local this_week_start = M.weekStartDate(today_str, week_start)
        local last_week_start = M.weekStartDate(os.date("%Y-%m-%d", os.time() - 7 * 86400), week_start)

        local function isCurrentWeekStart(first_week)
            return first_week == this_week_start or first_week == last_week_start
        end

        streaks.current_weeks, streaks.best_weeks,
        streaks.current_weeks_dates, streaks.best_weeks_dates =
            M.computeStreaksWithDates(weeks, M.isConsecutiveWeekDate, isCurrentWeekStart)

        -- Check whether today already has confirmed reading activity in the DB.
        -- If yes, the streak result is stable for the rest of the day.
        local today_confirmed = false
        if dates[1] == today_str then
            today_confirmed = true
        end
        streaks._today_confirmed = today_confirmed

        -- Most recent day with any reading (nil on an empty database); the
        -- streak popup shows it as "Last read" under the current streak.
        streaks.last_read_date = dates[1]

        return streaks
    end)

    if Cache.ENABLE_CACHE then
        Cache._cache.streaks      = result
        Cache._stale_cache.streaks = result
        Cache._cache.streaks_week_start = week_start
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

-- ---------------------------------------------------------------------------
-- Monthly series (days / hours / pages / books per month of one year)
-- ---------------------------------------------------------------------------
--
-- The four getters below share one frame, kept here: the per-minute cache,
-- the "up to yesterday" base aggregate (computed once a day, cached), a cheap
-- live read of today, the merge of the two into the 12-entry month array, and
-- the fall-back to the last known good result when the DB read fails. What
-- differs per getter is only its spec:
--
--   prefix      cache-key prefix ("days:", "hours:", "pages:", "books:").
--               It is part of the persisted stale cache's keys and of
--               insights_settings' mode prefixes, so it must not change.
--   loadBase    (conn, year, today, current_month) -> base. Everything before
--               today; cached for the day.
--   loadToday   (conn, today, base) -> today's contribution. Each getter keeps
--               its own SQL, since the fastest form differs per query (see
--               the notes at the hours and pages ones).
--   emptyBase   () -> a base that means "no data", for when the DB read fails
--               and there is nothing better cached.
--   emptyToday  today's contribution in that case.
--   toEntry     (base, today, is_current_month, year_month) -> the mode's
--               fields of one month's entry (month / label / label_full are
--               added by buildMonthlyArray).

-- Reads "YYYY-MM, value" rows of `sql` into { ["YYYY-MM"] = number }.
local function readMonthMap(conn, sql)
    local map = {}
    StatsDb.withStatement(conn, sql, function(stmt)
        for row in stmt:rows() do map[row[1]] = tonumber(row[2]) or 0 end
    end)
    return map
end

local function monthlyAggregate(spec, year, shared_conn)
    local today         = Cache.todayDateStr()
    local key           = spec.prefix .. year .. ":" .. today
    local base_key      = spec.prefix .. year
    local current_month = today:sub(1, 7)
    local minute        = Cache.currentMinute()

    -- Fast path: already served this exact minute, skip the DB entirely.
    local cached_val = Cache.getMinuteCache(Cache._monthly_cache, key, key .. ":minute", minute)
    if cached_val then
        return cached_val
    end

    local cached_base = Cache.getCachedBase(Cache._monthly_base_cache, base_key, today)

    -- One connection covers both the (rare, once/day) base recompute and the
    -- (frequent) cheap today-only read.
    local merged = StatsDb.withShared(shared_conn, nil, function(conn)
        local base = cached_base or spec.loadBase(conn, year, today, current_month)
        return { base = base, today = spec.loadToday(conn, today, base) }
    end)
    if not merged then
        local known_good = Cache.bestKnownFullResult(Cache._monthly_cache, key, Cache._stale_monthly, base_key .. ":")
        if known_good then return known_good end
        merged = { base = cached_base or spec.emptyBase(), today = spec.emptyToday }
    end

    if Cache.ENABLE_CACHE and not cached_base then
        Cache._monthly_base_cache[base_key] = Cache.makeCachedBase(today, merged.base)
    end

    local months = buildMonthlyArray(year, function(year_month)
        return spec.toEntry(merged.base, merged.today, year_month == current_month, year_month)
    end)

    Cache.setMinuteCache(Cache._monthly_cache, Cache._stale_monthly, key, key .. ":minute", minute, months, base_key .. ":")
    return months
end

local DAYS_SPEC = {
    prefix     = "days:",
    emptyBase  = function() return {} end,
    emptyToday = false,
    loadBase = function(conn, year, today)
        return readMonthMap(conn, string.format([[
            SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS month,
                   COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime')) AS days_read
            FROM page_stat
            WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
              AND date(start_time, 'unixepoch', 'localtime') < '%s'
            GROUP BY month
            ORDER BY month ASC
        ]], tostring(year), today))
    end,
    -- Whether anything was read today (a day counts once, however much).
    loadToday = function(conn, today)
        local has_activity = false
        local day_lo, day_hi = M.dayBounds(today)
        StatsDb.withStatement(conn, string.format([[
            SELECT 1 FROM page_stat
            WHERE start_time >= %d AND start_time < %d
            LIMIT 1
        ]], day_lo, day_hi), function(stmt)
            for _ in stmt:rows() do has_activity = true end
        end)
        return has_activity
    end,
    toEntry = function(base, has_activity, is_current, year_month)
        local days = tonumber(base[year_month]) or 0
        if has_activity and is_current then
            days = days + 1
        end
        return { days = days }
    end,
}

function M.getMonthlyReadingDays(year, shared_conn)
    return monthlyAggregate(DAYS_SPEC, year, shared_conn)
end

local HOURS_SPEC = {
    prefix     = "hours:",
    emptyBase  = function() return {} end,
    emptyToday = 0,
    loadBase = function(conn, year, today)
        return readMonthMap(conn, string.format([[
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
        ]], tostring(year), today))
    end,
    -- Today's seconds, de-duplicated per book and page.
    loadToday = function(conn, today)
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
        return today_seconds
    end,
    toEntry = function(base, today_seconds, is_current, year_month)
        local seconds_raw = tonumber(base[year_month]) or 0
        if is_current then
            seconds_raw = seconds_raw + today_seconds
        end
        local hours = seconds_raw / 3600.0
        if hours >= 1 then
            hours = math.floor(hours)
        elseif hours > 0 then
            hours = (math.floor(hours * 10)) / 10
        end
        return { hours = hours, seconds = math.floor(seconds_raw + 0.5) }
    end,
}

function M.getMonthlyReadingHours(year, shared_conn)
    return monthlyAggregate(HOURS_SPEC, year, shared_conn)
end

local PAGES_SPEC = {
    prefix     = "pages:",
    emptyBase  = function() return {} end,
    emptyToday = 0,
    loadBase = function(conn, year, today)
        return readMonthMap(conn, string.format([[
            SELECT month, COUNT(*) AS pages_read
            FROM (
                SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS month,
                       date(start_time, 'unixepoch', 'localtime') AS day
                FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                  AND date(start_time, 'unixepoch', 'localtime') < '%s'
                GROUP BY id_book, page, day
            )
            GROUP BY month
            ORDER BY month ASC
        ]], tostring(year), today))
    end,
    loadToday = function(conn, today)
        -- date() filter on purpose, like the other today-only queries here
        -- (see the note in getYearlyStats).
        local today_pages = 0
        StatsDb.withStatement(conn, string.format([[
            SELECT id_book, page
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = '%s'
            GROUP BY id_book, page
        ]], today), function(stmt)
            for _row in stmt:rows() do today_pages = today_pages + 1 end
        end)
        return today_pages
    end,
    toEntry = function(base, today_pages, is_current, year_month)
        local pages = tonumber(base[year_month]) or 0
        if is_current then
            pages = pages + today_pages
        end
        return { pages = pages }
    end,
}

-- Pages read per month. A page counts once per book, page and day (the same
-- de-duplication as getYearlyStats, so the twelve months add up to the yearly
-- pages figure).
function M.getMonthlyReadingPages(year, shared_conn)
    return monthlyAggregate(PAGES_SPEC, year, shared_conn)
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

    Cache.setMinuteCache(Cache._yearly_cache, Cache._stale_yearly, key, key .. ":minute", minute, result, base_key .. ":")
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
    local today     = Cache.todayDateStr()
    local cache_key = start_str .. ".." .. end_str

    -- Cached per range, per day - the same on-demand policy as
    -- getDailyReadingData above (the calendar heatmap's data): the
    -- time-of-day heatmap is only built when the heatmap popup is opened and
    -- swiped between periods, so without this every swipe re-scans page_stat
    -- for the whole window. A period ending before today can't change; the
    -- one ending today only grows by the current session, which is fine to
    -- pick up on the next open (a few minutes stale at worst), and the
    -- title-bar "reload data" long press drops it either way.
    if Cache.ENABLE_CACHE and Cache._cache.weekday_hour_data
       and Cache._cache.weekday_hour_data[cache_key]
       and Cache._cache.weekday_hour_data[cache_key].date == today then
        return Cache._cache.weekday_hour_data[cache_key].data
    end

    local data = {}
    -- data.pages[wd][h] = pages read in that weekday/hour slot (the pages
    -- view of the heatmap's bar charts); rows 1..7 stay seconds only.
    data.pages = {}
    for wd = 1, 7 do
        data[wd] = {}
        data.pages[wd] = {}
        for h = 0, 23 do data[wd][h] = 0; data.pages[wd][h] = 0 end
    end

    -- Whether the query actually ran (vs. a transient DB failure that leaves
    -- `data` looking exactly like an empty range). Only a real run is cached,
    -- so a failure can't pin an all-zero heatmap for the rest of the day -
    -- the same trap RecordsData's cache fell into (see StatsDb.withStatement).
    local ran = false

    data = StatsDb.withShared(shared_conn, data, function(conn)
        local sql = string.format([[
            SELECT dow, hour, SUM(dur) AS duration, COUNT(*) AS pages
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

        local _, did_run = StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                local dow_sun0 = tonumber(row[1]) or 0  -- 0=Sun..6=Sat
                local wd = ((dow_sun0 + 6) % 7) + 1     -- 1=Mon..7=Sun
                local hour = tonumber(row[2]) or 0
                data[wd][hour] = tonumber(row[3]) or 0
                data.pages[wd][hour] = tonumber(row[4]) or 0
            end
        end)
        ran = did_run and true or false
        return data
    end)

    if Cache.ENABLE_CACHE and ran then
        Cache._cache.weekday_hour_data = Cache._cache.weekday_hour_data or {}
        Cache._cache.weekday_hour_data[cache_key] = { date = today, data = data }
    end
    return data
end

-- Cheap "did anything change since we last looked" probe: a single
-- MAX(start_time) read, which SQLite answers off page_stat's own rowid
-- order without the group/aggregate work the calendar and day-part queries
-- above do. Used to gate the reading heatmap popup's background refresh -
-- see Heatmap.Popup in views/heatmap_view.lua - so a popup reopened (or
-- left open) with no new reading since never re-runs those heavier queries.
-- Returns the epoch-seconds timestamp of the most recent page_stat row, or
-- 0 if the table is empty or the query can't be read right now.
function M.getMaxStartTime(shared_conn)
    local max_t = 0
    StatsDb.withShared(shared_conn, nil, function(conn)
        StatsDb.withStatement(conn, "SELECT MAX(start_time) FROM page_stat", function(stmt)
            for row in stmt:rows() do
                max_t = tonumber(row[1]) or 0
            end
        end)
    end)
    return max_t
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
    -- Books the reader added by hand (lib/manual_books.lua): read on
    -- paper, in another app, on another device - nothing in the statistics
    -- DB to find, so they are simply added on top of whatever the scan
    -- counted. Done here rather than at each call site because every
    -- return path of getFinishedBookCountForYear (fresh scan, minute
    -- cache, stale cache) goes through this one function.
    local manual = Manual and Manual.count(year_key) or 0
    local overrides = VS.readFinishedOverrides(year_key)
    if not next(overrides) then return count + manual end
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
    return count + adjust + manual
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

-- Book-list cache validity -------------------------------------------
--
-- A short string that changes whenever anything a book list is made of
-- changes; the lists are cached under it (see "Book-list cache" in
-- lib/insights_cache.lua). One pass of plain aggregates over page_stat - no
-- strftime, no grouping, no joins - plus a glance at the small book table
-- (a retitled or re-paginated book alters the rows too).
--
-- lo/hi (epoch seconds, hi exclusive) narrow the page_stat part to one
-- period. That is what lets a past month or year stay cached while new
-- reading goes on: nothing the period's list shows can come from rows
-- outside it, so new rows outside it don't touch the stamp. Without bounds
-- the whole table is covered (all-books list, finished-books list - the
-- latter depends on each book's *last* entry, wherever that falls).
--
-- Returns nil when the probe can't be read, in which case the caller just
-- skips the cache for this call.
function M._bookListStamp(conn, lo, hi)
    local where = ""
    if lo and hi then
        where = string.format(" WHERE start_time >= %d AND start_time < %d",
            math.floor(lo), math.floor(hi))
    end
    local parts = {}
    local _r1, ran1 = StatsDb.withStatement(conn,
        "SELECT COUNT(*), COALESCE(SUM(duration), 0), COALESCE(MAX(start_time), 0) FROM page_stat" .. where,
        function(stmt)
            for row in stmt:rows() do
                parts[1] = tostring(tonumber(row[1]) or 0)
                parts[2] = tostring(tonumber(row[2]) or 0)
                parts[3] = tostring(tonumber(row[3]) or 0)
            end
        end)
    -- Period lists show only a book's id and title, so for those just the
    -- books read in the period count - a new book, or a re-paginated one
    -- elsewhere in the library, must not throw away every past month's list.
    -- The unbounded lists (all books, finished) also depend on page counts
    -- (the 99% rule), so they look at the whole table.
    local book_sql
    if lo and hi then
        book_sql = string.format([[
            SELECT COUNT(*), 0, COALESCE(SUM(LENGTH(title)), 0) FROM book
            WHERE id IN (SELECT DISTINCT id_book FROM page_stat
                         WHERE start_time >= %d AND start_time < %d)
        ]], math.floor(lo), math.floor(hi))
    else
        book_sql = "SELECT COUNT(*), COALESCE(SUM(pages), 0), COALESCE(SUM(LENGTH(title)), 0) FROM book"
    end
    local _r2, ran2 = StatsDb.withStatement(conn, book_sql,
        function(stmt)
            for row in stmt:rows() do
                parts[4] = tostring(tonumber(row[1]) or 0)
                parts[5] = tostring(tonumber(row[2]) or 0)
                parts[6] = tostring(tonumber(row[3]) or 0)
            end
        end)
    if not (ran1 and ran2) or #parts ~= 6 then return nil end
    return table.concat(parts, ":")
end

-- [lo, hi) epoch bounds, in local time, of the period getBooksForPeriod is
-- asked about: "%Y" with "2025", or "%Y-%m" with "2025-03". Anything else
-- gives nil,nil and the list is built uncached.
function M._periodBounds(period_format, period_value)
    if period_format == "%Y" then
        local y = tonumber(period_value)
        if not y then return nil, nil end
        return os.time{ year = y,     month = 1, day = 1, hour = 0, min = 0, sec = 0 },
               os.time{ year = y + 1, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
    elseif period_format == "%Y-%m" then
        local y, m = tostring(period_value):match("^(%d+)-(%d+)$")
        y, m = tonumber(y), tonumber(m)
        if not y or not m then return nil, nil end
        return os.time{ year = y, month = m,     day = 1, hour = 0, min = 0, sec = 0 },
               os.time{ year = y, month = m + 1, day = 1, hour = 0, min = 0, sec = 0 }
    end
    return nil, nil
end

-- Same "last entry >= 99%" definition as getFinishedBookCountForYear above,
-- but returns the book rows themselves (for the goal section's "N book(s)
-- finished" tap → book list). Not cached: only queried on demand, when the
-- list is actually opened.
function M.getFinishedBooksForYear(year)
    local books = {}
    return StatsDb.withDb(books, function(conn)
        local cache_key = "finished2:" .. tostring(year)
        local stamp     = M._bookListStamp(conn)
        local hit       = Cache.getBookList(cache_key, stamp)
        if hit then return hit end

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
                      AND strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s') AS duration_sec,
                   (SELECT COUNT(DISTINCT page) FROM page_stat
                    WHERE id_book = book.id
                      AND strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s') AS pages_read,
                   book.md5 AS md5
            FROM last_page lp
            JOIN book ON book.id = lp.id_book
            WHERE book.pages > 0
              AND CAST(lp.last_page AS REAL) / book.pages >= 0.99
              AND strftime('%%Y', lp.last_time, 'unixepoch', 'localtime') = '%s'
            ORDER BY lp.last_time DESC
        ]], tostring(year), tostring(year), tostring(year))
        local _res, ran = StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    title    = row[1] or _("Unknown"),
                    authors  = "",
                    id_book  = tonumber(row[2]),
                    duration = tonumber(row[4]) or 0,
                    pages    = tonumber(row[5]) or 0,
                    md5      = row[6],
                    last_read = tonumber(row[3]) or 0,
                })
            end
        end)
        if ran then Cache.setBookList(cache_key, stamp, books) end
        return books
    end)
end

-- Every finished book of every year in ONE query: { { id_book, last_read },
-- ... } (newest first). The same "last entry >= 99%" definition as
-- getFinishedBooksForYear above, just without that function's year filter and
-- its per-year duration/pages columns - a book is in exactly one year's list
-- (the year of its last entry), so this is the union of all of them. For the
-- achievements, which used to call getFinishedBooksForYear once per year and
-- so ran the whole-library query (and its cache stamp) once per year. Not
-- cached: the caller holds the result for the run.
function M.getFinishedBooksAllYears(shared_conn)
    local books = {}
    return StatsDb.withShared(shared_conn, books, function(conn)
        local sql = [[
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
            SELECT book.id AS id_book, lp.last_time AS last_time
            FROM last_page lp
            JOIN book ON book.id = lp.id_book
            WHERE book.pages > 0
              AND CAST(lp.last_page AS REAL) / book.pages >= 0.99
            ORDER BY lp.last_time DESC
        ]]
        StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    id_book   = tonumber(row[1]),
                    last_read = tonumber(row[2]) or 0,
                })
            end
        end)
        return books
    end)
end

-- When a book counts as finished, for lists that are not the finished-books
-- list (month, year, all-books, day): the timestamp of the entry it was
-- finished on, or nil when it doesn't count as finished. The same rules as
-- the finished-books list apply - the last entry reached 99% of the book,
-- in the year that entry falls in, unless the reader unticked it there; or
-- the reader ticked it by hand for a year the book has activity in (the
-- date is then the last entry of that year). Overrides are per year, so
-- every year the book was read in is looked at; the latest date wins.
function M.getFinishedTimestamp(id_book)
    id_book = tonumber(id_book)
    if not id_book then return nil end
    return StatsDb.withDb(nil, function(conn)
        local last_time, last_page, pages
        local sql_last = string.format([[
            SELECT le.last_time, MAX(ps.page), book.pages
            FROM (SELECT MAX(start_time) AS last_time
                  FROM page_stat WHERE id_book = %d) le
            JOIN page_stat ps ON ps.id_book = %d AND ps.start_time = le.last_time
            JOIN book ON book.id = %d
        ]], id_book, id_book, id_book)
        StatsDb.withStatement(conn, sql_last, function(stmt)
            for row in stmt:rows() do
                last_time = tonumber(row[1])
                last_page = tonumber(row[2])
                pages     = tonumber(row[3])
            end
        end)

        local auto_year
        local auto = false
        if last_time then
            auto_year = os.date("%Y", last_time)
            auto = (pages or 0) > 0 and (last_page or 0) / pages >= 0.99
        end

        local per_year = {}
        local sql_years = string.format([[
            SELECT strftime('%%Y', start_time, 'unixepoch', 'localtime'),
                   MAX(start_time)
            FROM page_stat WHERE id_book = %d
            GROUP BY 1
        ]], id_book)
        StatsDb.withStatement(conn, sql_years, function(stmt)
            for row in stmt:rows() do
                if row[1] then per_year[tostring(row[1])] = tonumber(row[2]) end
            end
        end)

        local key = tostring(id_book)
        local best
        for year, year_last in pairs(per_year) do
            local v = VS.readFinishedOverrides(year)[key]
            if auto and year == auto_year and v ~= false then
                if not best or last_time > best then best = last_time end
            end
            if v == true and year_last then
                if not best or year_last > best then best = year_last end
            end
        end
        return best
    end)
end

-- Per-day reading totals, cached per DAY (not per week).
--
-- Both weekly views (rolling "Last 7 days" and the paged calendar week) are
-- made of per-day totals: seconds read and de-duplicated pages (one row per
-- book/page/day). A completed day never changes, so each one is worked out
-- once, kept in memory and mirrored to reading_insights_days.lua - after that
-- any week, however far back, is put together from the cache without touching
-- the statistics database. Only the days still missing are queried, in one
-- query over just that range; today is always read fresh (cheap: one day).
-- "Reload data" (clearCalendarWeekCache(true)) drops the lot.
local DAYS_PATH = DataStorage:getSettingsDir() .. "/reading_insights_days.lua"
local days_store = nil         -- "YYYY-MM-DD" -> { seconds, pages }, completed days only
local today_memo = nil         -- { minute = , date = , value = { seconds, pages } }

local function loadDaysStore()
    if days_store then return days_store end
    days_store = {}
    pcall(function()
        local st = require("luasettings"):open(DAYS_PATH)
        local d = st:readSetting("days")
        if type(d) ~= "table" then return end
        for k, v in pairs(d) do
            if type(k) == "string" and type(v) == "table"
               and tonumber(v[1]) and tonumber(v[2]) then
                days_store[k] = { tonumber(v[1]), tonumber(v[2]) }
            end
        end
    end)
    return days_store
end

local function saveDaysStore()
    if not Cache.ENABLE_CACHE or not days_store then return end
    pcall(function()
        local st = require("luasettings"):open(DAYS_PATH)
        st:saveSetting("days", days_store)
        st:flush()
    end)
end

local function dayMidnight(off)
    local t = os.date("*t")
    return os.time{ year = t.year, month = t.month, day = t.day + off, hour = 0, min = 0, sec = 0 }
end

local function dayDate(off)
    return os.date("%Y-%m-%d", dayMidnight(off))
end

-- One-sided "start_time >= from" on purpose - the exact shape the "Last 7
-- days" query always used. A two-sided start_time range on page_stat can make
-- SQLite reorder the view's internal join (the note in getYearlyStats measured
-- that 20x slower), so rows past the wanted span are simply ignored by the
-- caller instead of being cut off in SQL.
local function queryDayTotals(conn, from_ts)
    local out = {}
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
    ]], from_ts)
    local _res, ran = StatsDb.withStatement(conn, sql, function(stmt)
        for row in stmt:rows() do
            out[row[1]] = { tonumber(row[2]) or 0, tonumber(row[3]) or 0 }
        end
    end)
    return out, ran
end

-- Totals for the days first_off..last_off (offsets from today: 0 = today,
-- -1 = yesterday, positive = future, which has no reading). Returns a table
-- date -> { seconds, pages }; days without reading are present as {0, 0}
-- (future days are absent). Second result is false when a query failed - the
-- missing days are then simply absent and nothing wrong is cached.
local function loadDayRange(conn, first_off, last_off, minute)
    local store = Cache.ENABLE_CACHE and loadDaysStore() or {}
    local out, ok = {}, true

    local miss_lo, miss_hi
    for off = first_off, math.min(last_off, -1) do
        local ds = dayDate(off)
        local e = store[ds]
        if e then
            out[ds] = e
        else
            miss_lo = miss_lo or off
            miss_hi = off
        end
    end
    -- One query from the earliest missing day to now serves everything that
    -- is missing AND today: every completed day in that span becomes known
    -- (days without reading as {0, 0}), so nothing in it is asked again.
    local got, ran
    if miss_lo then
        got, ran = queryDayTotals(conn, dayMidnight(miss_lo))
        if ran then
            for off = miss_lo, -1 do
                local ds = dayDate(off)
                local e = got[ds] or { 0, 0 }
                store[ds] = e
                if off >= first_off and off <= last_off then out[ds] = e end
            end
            if Cache.ENABLE_CACHE then saveDaysStore() end
        else
            ok = false
        end
    end

    if first_off <= 0 and last_off >= 0 then
        local today = dayDate(0)
        local m = today_memo
        if ran then
            local e = got[today] or { 0, 0 }
            out[today] = e
            today_memo = { minute = minute, date = today, value = e }
        elseif Cache.ENABLE_CACHE and m and m.minute == minute and m.date == today then
            out[today] = m.value
        else
            local t_got, t_ran = queryDayTotals(conn, dayMidnight(0))
            if t_ran then
                local e = t_got[today] or { 0, 0 }
                out[today] = e
                today_memo = { minute = minute, date = today, value = e }
            else
                ok = false
            end
        end
    end
    return out, ok
end

-- Returns both last-week stats in one DB connection:
--   last_week:       { avg_seconds, avg_pages, prev_seconds, prev_pages }
--                    (prev_* = totals of the 7 days before the last 7 days)
--   last_week_daily: array[7] of { hours, seconds, pages, label, midnight_ts }, index 1 = today
function M.getLastWeekAll(shared_conn)
    local minute = Cache.currentMinute()
    local lw_ok    = Cache.getMinuteCache(Cache._cache, "last_week", "last_week_minute", minute) ~= nil
    local daily_ok = Cache.getMinuteCache(Cache._cache, "last_week_daily", "last_week_daily_minute", minute) ~= nil
    if lw_ok and daily_ok then
        return Cache._cache.last_week, Cache._cache.last_week_daily
    end

    -- Each day's local midnight from calendar components (year/month/day - i),
    -- not today_midnight - i*86400: os.time() normalises the components in
    -- local time, so a 23- or 25-hour DST day still lands exactly on midnight,
    -- whereas the fixed-86400 step would drift onto 23:00/01:00 of the wrong
    -- day and its date_str would then miss the SQL date() grouping entirely
    -- (that day's bar reading as 0). Same reasoning as M.dayBounds.
    local now_t = os.date("*t")
    local function localMidnight(day_offset)
        return os.time{ year = now_t.year, month = now_t.month, day = now_t.day + day_offset,
                        hour = 0, min = 0, sec = 0 }
    end
    -- The query also covers the 7 days before that, for the "compared to
    -- previous 7 days" figures.
    local week_start_ts = localMidnight(-13)

    local DOW_KEYS = { [0]="Sun", [1]="Mon", [2]="Tue", [3]="Wed", [4]="Thu", [5]="Fri", [6]="Sat" }
    local date_info = {}
    for i = 0, 6 do
        local day_midnight = localMidnight(-i)
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
    local prev_dates = {}
    for i = 7, 13 do
        prev_dates[#prev_dates + 1] = os.date("%Y-%m-%d", localMidnight(-i))
    end

    local lw_result    = lw_ok    and Cache._cache.last_week       or { avg_seconds = 0, avg_pages = 0 }
    local daily_result = daily_ok and Cache._cache.last_week_daily or nil

    StatsDb.withShared(shared_conn, nil, function(conn)
        -- Per-day totals for the last 14 days (completed days come from the
        -- per-day cache, see loadDayRange). From this we derive both the
        -- 7-day averages and the per-day chart data.
        local seconds_by_date = {}
        local pages_by_date   = {}
        if not lw_ok or not daily_ok then
            local days = loadDayRange(conn, -13, 0, minute)
            for ds, e in pairs(days) do
                seconds_by_date[ds] = e[1]
                pages_by_date[ds]   = e[2]
            end
        end

        if not lw_ok then
            local total_sec, total_pages = 0, 0
            for i = 1, 7 do
                local ds = date_info[i].date_str
                total_sec   = total_sec   + (seconds_by_date[ds] or 0)
                total_pages = total_pages + (pages_by_date[ds]   or 0)
            end
            local prev_sec, prev_pages = 0, 0
            for _, ds in ipairs(prev_dates) do
                prev_sec   = prev_sec   + (seconds_by_date[ds] or 0)
                prev_pages = prev_pages + (pages_by_date[ds]   or 0)
            end
            lw_result = {
                avg_seconds  = total_sec / 7,
                avg_pages    = total_pages / 7,
                prev_seconds = prev_sec,
                prev_pages   = prev_pages,
            }
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

-- Calendar-week view of the weekly section ("Current week" setting).
--
-- week_offset: 0 = the current calendar week, -1 = the week before, ...
-- The weeks run from the shared "week start day" (Monday / Sunday).
--
-- M.calendarWeekBounds(week_offset) -> start_date, end_date ("YYYY-MM-DD"),
-- the first and last day of that whole week (a current week's end_date is
-- its last day, i.e. in the future, not today). Local midnights are built
-- from calendar components so a 23-/25-hour DST day cannot shift a date.
function M.calendarWeekBounds(week_offset)
    week_offset = math.floor(tonumber(week_offset) or 0)
    local week_wd   = weekStartWday()
    local now_t     = os.date("*t")
    local today_mid = os.time{ year = now_t.year, month = now_t.month, day = now_t.day,
                               hour = 0, min = 0, sec = 0 }
    local today_wday = tonumber(os.date("%w", today_mid))  -- 0=Sun..6=Sat
    local into_week  = (week_wd == 0) and today_wday or ((today_wday + 6) % 7)
    local function localMidnight(day_offset)
        return os.time{ year = now_t.year, month = now_t.month, day = now_t.day + day_offset,
                        hour = 0, min = 0, sec = 0 }
    end
    local start_offset = -into_week + 7 * week_offset
    return os.date("%Y-%m-%d", localMidnight(start_offset)),
           os.date("%Y-%m-%d", localMidnight(start_offset + 6))
end

-- Short-lived memory cache of the weeks already worked out, per week and
-- minute. Not persisted: a week is one small query.
local cal_week_cache = {}

-- Last result per week (kept across popup opens, never cleared by
-- clearCalendarWeekCache): lets the popup paint the weekly section at once
-- from the previous numbers and refresh them right after, instead of
-- blocking the first paint on a database query.
local cal_week_stale = {}

-- Opening the popup drops what is still moving - the current week and today's
-- total - so a freshly flushed session is picked up. Past weeks are
-- immutable and stay; `force` ("Reload data") drops them and the per-day
-- cache (file included) as well.
function M.clearCalendarWeekCache(force)
    today_memo = nil
    if force then
        cal_week_cache = {}
        days_store = {}
        saveDaysStore()
    else
        for k in pairs(cal_week_cache) do
            if k:match("^%d:0:") then cal_week_cache[k] = nil end
        end
    end
end

-- The previously computed week for `week_offset`, only if it was computed
-- today (so "today" / future-day flags are still right); nil otherwise.
function M.getCalendarWeekStale(week_offset)
    week_offset = math.floor(tonumber(week_offset) or 0)
    if week_offset > 0 then week_offset = 0 end
    local e = cal_week_stale[weekStartWday() .. ":" .. week_offset]
    if e and e.date == os.date("%Y-%m-%d") then return e.value end
    return nil
end

-- M.getCalendarWeek(week_offset, shared_conn) -> { stats = ..., daily = ... }
--
--   stats  { total_seconds, total_pages, avg_seconds, avg_pages, days,
--            prev_seconds, prev_pages, start_date, end_date, is_current }
--          `days` is how many days of the week count: 7, or for the
--          current week only the days up to and including today (the
--          averages divide by it). prev_* is the previous week over the
--          same number of days, so a half-finished week is compared with
--          the same stretch of the week before, not with a whole week.
--   daily  7 entries, NEWEST DAY FIRST (index 1 = the week's last day,
--          index 7 = its first day) - the same orientation as the
--          last-7-days series, so the chart code can draw both alike:
--          { hours, seconds, pages, label, midnight_ts, date_str,
--            is_today, future }
--          Labels are weekday abbreviations only. Days after today in the
--          current week have future = true and no reading.
-- Same de-duplication as getLastWeekAll (one row per book/page/day).
function M.getCalendarWeek(week_offset, shared_conn)
    week_offset = math.floor(tonumber(week_offset) or 0)
    if week_offset > 0 then week_offset = 0 end

    local week_wd = weekStartWday()
    local minute  = Cache.currentMinute()
    local ckey    = week_wd .. ":" .. week_offset .. ":" .. os.date("%Y-%m-%d")
    local cached  = cal_week_cache[ckey]
    if Cache.ENABLE_CACHE and cached and (cached.minute == minute or week_offset < 0) then
        return cached.value
    end

    local now_t = os.date("*t")
    local function localMidnight(day_offset)
        return os.time{ year = now_t.year, month = now_t.month, day = now_t.day + day_offset,
                        hour = 0, min = 0, sec = 0 }
    end
    local today_mid  = localMidnight(0)
    local today_wday = tonumber(os.date("%w", today_mid))
    local into_week  = (week_wd == 0) and today_wday or ((today_wday + 6) % 7)

    local is_current   = (week_offset == 0)
    local start_offset = -into_week + 7 * week_offset      -- first day of the week
    local days         = is_current and (into_week + 1) or 7

    local DOW_KEYS = { [0]="Sun", [1]="Mon", [2]="Tue", [3]="Wed", [4]="Thu", [5]="Fri", [6]="Sat" }

    -- date_info[d + 1] for d = 0..6 = the week's d-th day, oldest first.
    local date_info = {}
    for d = 0, 6 do
        local mid = localMidnight(start_offset + d)
        date_info[d + 1] = {
            date_str    = os.date("%Y-%m-%d", mid),
            label       = _(DOW_KEYS[tonumber(os.date("%w", mid))] or ""),
            midnight_ts = mid,
            is_today    = is_current and d == into_week,
            future      = is_current and d > into_week,
        }
    end
    local prev_dates = {}
    for d = 0, days - 1 do
        prev_dates[#prev_dates + 1] = os.date("%Y-%m-%d", localMidnight(start_offset - 7 + d))
    end

    -- The week and the one before it, from the per-day cache; only days not
    -- seen before are queried (see loadDayRange).
    local seconds_by_date, pages_by_date = {}, {}
    local ok = false
    StatsDb.withShared(shared_conn, nil, function(conn)
        local days, ran = loadDayRange(conn, start_offset - 7, start_offset + 6, minute)
        for ds, e in pairs(days) do
            seconds_by_date[ds] = e[1]
            pages_by_date[ds]   = e[2]
        end
        ok = ran
    end)

    local total_sec, total_pages = 0, 0
    local daily = {}
    for d = 0, 6 do
        local di   = date_info[d + 1]
        local secs = seconds_by_date[di.date_str] or 0
        local pgs  = pages_by_date[di.date_str]   or 0
        if not di.future then
            total_sec   = total_sec   + secs
            total_pages = total_pages + pgs
        end
        local h = secs / 3600.0
        if h >= 1 then
            h = math.floor(h + 0.5)
        elseif h > 0 then
            h = math.floor(h * 10 + 0.5) / 10
        end
        -- Newest day first: the week's last day (d = 6) lands at index 1.
        daily[7 - d] = {
            hours       = h,
            seconds     = secs,
            pages       = pgs,
            label       = di.label,
            midnight_ts = di.midnight_ts,
            date_str    = di.date_str,
            is_today    = di.is_today,
            future      = di.future,
        }
    end

    local prev_sec, prev_pages = 0, 0
    for _i, ds in ipairs(prev_dates) do
        prev_sec   = prev_sec   + (seconds_by_date[ds] or 0)
        prev_pages = prev_pages + (pages_by_date[ds]   or 0)
    end

    local result = {
        stats = {
            total_seconds = total_sec,
            total_pages   = total_pages,
            avg_seconds   = total_sec   / days,
            avg_pages     = total_pages / days,
            days          = days,
            prev_seconds  = prev_sec,
            prev_pages    = prev_pages,
            start_date    = date_info[1].date_str,
            end_date      = date_info[7].date_str,
            is_current    = is_current,
        },
        daily = daily,
    }

    -- A failed query (locked DB, ...) is not remembered, so the next call
    -- tries again instead of serving zeros for a minute.
    if ok and Cache.ENABLE_CACHE then
        cal_week_cache[ckey] = { minute = minute, value = result }
        cal_week_stale[week_wd .. ":" .. week_offset] = { date = os.date("%Y-%m-%d"), value = result }
    end
    return result
end

-- Consecutive days (kind = "daily") or calendar weeks (kind = "weekly") up to
-- now in which at least `goal_secs` was read. Today / this week doesn't break
-- the run while it is still short of the goal (it just isn't counted yet).
--
-- Closed periods never change, so the run length ending at the last closed
-- day/week is remembered in the settings (per kind, together with the goal and
-- week start it was computed for). The next call then only queries the
-- periods since then and extends the run, instead of re-scanning the whole
-- history. A different goal or week start setting, or clearTimeGoalCache()
-- ("Reload data"), starts over with one full grouped scan. The goal currently
-- set is applied to the whole history. Returns 0 on any failure.
local TIME_GOAL_CACHE_KEY = "reading_insights_time_goal_cache"

function M.clearTimeGoalCache()
    Prefs.save(TIME_GOAL_CACHE_KEY, nil)
end

function M.getTimeGoalStreak(kind, goal_secs)
    goal_secs = math.floor(tonumber(goal_secs) or 0)
    if goal_secs <= 0 then return 0 end

    local weekly  = (kind == "weekly")
    local week_wd = weekStartWday()
    local step    = weekly and 7 or 1

    local function addDays(date_str, n)
        local y, m, d = M.parseDateYMD(date_str)
        if not y then return nil end
        return os.date("%Y-%m-%d", os.time{ year = y, month = m, day = d + n, hour = 12 })
    end

    local today   = os.date("%Y-%m-%d")
    local current = weekly and M.weekStartDate(today, week_wd) or today
    if not current then return 0 end
    local last_closed = addDays(current, -step)
    if not last_closed then return 0 end

    local all = Prefs.read(TIME_GOAL_CACHE_KEY, nil)
    if type(all) ~= "table" then all = {} end
    local c = all[kind]
    local cache_ok = type(c) == "table"
        and c.goal == goal_secs
        and c.week_wd == (weekly and week_wd or nil)
        and type(c.anchor) == "string" and c.anchor <= last_closed
        and tonumber(c.run) ~= nil

    local from_date = cache_ok and addDays(c.anchor, step) or nil
    local run       = cache_ok and tonumber(c.run) or 0

    local group = weekly and M.weekStartSqlExpr(week_wd)
                          or "date(start_time, 'unixepoch', 'localtime')"
    local where = ""
    if from_date then
        local y, m, d = M.parseDateYMD(from_date)
        if y then
            where = string.format("WHERE start_time >= %d",
                os.time{ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
        end
    end
    local sql = string.format(
        "SELECT %s AS g FROM page_stat %s GROUP BY g HAVING SUM(duration) >= %d",
        group, where, goal_secs)

    local met, ok = {}, false
    StatsDb.withDb(nil, function(conn)
        local _res, ran = StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do met[row[1]] = true end
        end)
        ok = ran
    end)
    if not ok then return 0 end

    -- No cache: start at the earliest period that met the goal (nothing
    -- before it can be part of a run).
    if not cache_ok then
        for date_str in pairs(met) do
            if not from_date or date_str < from_date then from_date = date_str end
        end
        run = 0
    end

    local d = from_date
    while d and d <= last_closed do
        run = met[d] and (run + 1) or 0
        d = addDays(d, step)
    end

    all[kind] = { goal = goal_secs, week_wd = weekly and week_wd or nil,
                  anchor = last_closed, run = run }
    Prefs.save(TIME_GOAL_CACHE_KEY, all)

    return run + (met[current] and 1 or 0)
end

-- Returns an array of 8 weekly buckets (index 1 = oldest of the 8 weeks,
-- index 8 = current week), each { start_date, end_date, seconds, pages, days }.
-- The weeks are whole calendar weeks, starting on the shared "week start day"
-- (Monday / Sunday): seven full weeks plus the current one, which runs from
-- its first day up to today. `days` is how many days the bucket spans (7, or
-- fewer for the current week), so averages divide by the right number.
-- Mirrors the de-duplication logic used by getLastWeekAll, just over a
-- wider window split into weekly chunks.
function M.getLast8WeeksData()
    local week_wd = weekStartWday()
    local minute = Cache.currentMinute()
    local cache_key  = "last8weeks_cal" .. week_wd
    local minute_key = "last8weeks_cal_minute" .. week_wd
    local cached_val = Cache.getMinuteCache(Cache._cache, cache_key, minute_key, minute)
    if cached_val then
        return cached_val
    end

    -- Local midnights from calendar components, not today_midnight - N*86400:
    -- across a 23-/25-hour DST day the fixed step drifts off midnight and the
    -- week's start_date/end_date label would name the wrong day (and the SQL
    -- boundary below would slip by an hour). Same reasoning as M.dayBounds and
    -- getLastWeekAll. The day-bucketing further down stays correct on its own:
    -- it rounds diff_days to the nearest whole day, which absorbs the DST hour.
    local now_t = os.date("*t")
    local function localMidnight(day_offset)
        return os.time{ year = now_t.year, month = now_t.month, day = now_t.day + day_offset,
                        hour = 0, min = 0, sec = 0 }
    end
    local today_midnight = localMidnight(0)

    -- Days since the current week began (0 on its first day).
    local today_wday = tonumber(os.date("%w", today_midnight))  -- 0=Sun..6=Sat
    local into_week  = (week_wd == 0) and today_wday or ((today_wday + 6) % 7)
    local period_start_ts = localMidnight(-into_week - 7 * 7)

    local weeks = {}
    for w = 1, 8 do
        local start_offset = -into_week - (8 - w) * 7
        local is_current   = (w == 8)
        weeks[w] = {
            start_date = os.date("%Y-%m-%d", localMidnight(start_offset)),
            end_date   = os.date("%Y-%m-%d", localMidnight(is_current and 0 or start_offset + 6)),
            seconds    = 0,
            pages      = 0,
            days       = is_current and (into_week + 1) or 7,
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
                    -- 0 = current week, 1 = the week before it, ...
                    local week_from_end = 0
                    if diff_days > into_week then
                        week_from_end = math.ceil((diff_days - into_week) / 7)
                    end
                    local w = 8 - week_from_end
                    if w >= 1 and w <= 8 then
                        weeks[w].seconds = weeks[w].seconds + secs
                        weeks[w].pages   = weeks[w].pages   + pages
                    end
                end
            end
        end)
    end)

    Cache.setMinuteCache(Cache._cache, Cache._stale_cache, cache_key, minute_key, minute, weeks)
    return weeks
end

local BOOKS_SPEC = {
    prefix     = "books:",
    emptyBase  = function() return { counts = {}, current_month_book_ids = {} } end,
    emptyToday = 0,
    -- The base is two things: the distinct books per month, and the ids of the
    -- books read so far this month (so today's books can be told apart from
    -- those already counted).
    loadBase = function(conn, year, today, current_month)
        local counts = readMonthMap(conn, string.format([[
            SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS month,
                   COUNT(DISTINCT id_book) AS book_count
            FROM page_stat
            WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
              AND date(start_time, 'unixepoch', 'localtime') < '%s'
            GROUP BY month
            ORDER BY month ASC
        ]], tostring(year), today))

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

        return { counts = counts, current_month_book_ids = book_ids }
    end,
    -- How many of today's books were not already read earlier this month.
    loadToday = function(conn, today, base)
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
        return new_books_today
    end,
    toEntry = function(base, new_books_today, is_current, year_month)
        local book_count = tonumber(base.counts[year_month]) or 0
        if is_current then
            book_count = book_count + new_books_today
        end
        return { book_count = book_count }
    end,
}

function M.getMonthlyBookCounts(year, shared_conn)
    return monthlyAggregate(BOOKS_SPEC, year, shared_conn)
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
        -- Same period, same stamp -> same list: skip the query entirely.
        local cache_key = "period2:" .. period_format .. ":" .. tostring(period_value)
        local lo, hi    = M._periodBounds(period_format, period_value)
        local stamp     = (lo and hi) and M._bookListStamp(conn, lo, hi) or nil
        local hit       = Cache.getBookList(cache_key, stamp)
        if hit then return hit end

        -- De-duplicated reading time per book for the period.
        -- period_format inserted via concatenation to avoid %% escape conflicts.
        local sql = [[
            SELECT book.title, book.authors,
                   COUNT(DISTINCT ps_dedup.page) AS pages_read,
                   SUM(ps_dedup.period_sum) AS duration_sec,
                   NULL AS finish_time,
                   MAX(ps_dedup.last_read) AS last_read_time,
                   day_counts.days_read,
                   book.id AS id_book,
                   book.md5 AS md5
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
                SELECT id_book,
                       COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime')) AS days_read
                FROM page_stat
                WHERE strftime(']] .. period_format .. [[', start_time, 'unixepoch', 'localtime') = ']] .. period_value .. [['
                GROUP BY id_book
            ) day_counts ON ps_dedup.id_book = day_counts.id_book
            GROUP BY ps_dedup.id_book
            ORDER BY MAX(ps_dedup.last_read) DESC
        ]]

        local _res, ran = StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    title     = row[1] or _("Unknown"),
                    authors   = "",
                    pages     = tonumber(row[3]) or 0,
                    duration  = tonumber(row[4]) or 0,
                    days_read = tonumber(row[7]) or 0,
                    id_book   = tonumber(row[8]),
                    md5       = row[9],
                    -- Last reading entry for this book in the period; what
                    -- the book lists sort on by default.
                    last_read = tonumber(row[6]) or 0,
                })
            end
        end)
        if ran then Cache.setBookList(cache_key, stamp, books) end
        return books
    end)
end

-- The same rows getBooksForPeriod gives for a year, but only for the listed
-- books. The finished-books list needs just the few books the reader ticked
-- by hand that the "99%" rule missed; running the whole year's query (and
-- caching it) for them was what made that list slow to open after a reload.
-- Cached like the other lists (stamp-validated, kept in the book-list file).
function M.getBooksForYearByIds(year, ids)
    local books = {}
    local clean = {}
    for _idx, id in ipairs(ids or {}) do
        id = tonumber(id)
        if id then clean[#clean + 1] = math.floor(id) end
    end
    if #clean == 0 then return books end
    table.sort(clean)
    local id_list = table.concat(clean, ",")
    local period_value = tostring(year)
    return StatsDb.withDb(books, function(conn)
        local cache_key = "yearids2:" .. period_value .. ":" .. id_list
        local lo, hi    = M._periodBounds("%Y", period_value)
        local stamp     = (lo and hi) and M._bookListStamp(conn, lo, hi) or nil
        local hit       = Cache.getBookList(cache_key, stamp)
        if hit then return hit end

        local sql = string.format([[
            SELECT book.title, book.authors,
                   COUNT(DISTINCT ps_dedup.page) AS pages_read,
                   SUM(ps_dedup.period_sum) AS duration_sec,
                   MAX(ps_dedup.last_read) AS last_read_time,
                   day_counts.days_read,
                   book.id AS id_book,
                   book.md5 AS md5
            FROM (
                SELECT id_book, page,
                       SUM(duration) AS period_sum,
                       MAX(start_time) AS last_read
                FROM page_stat
                WHERE id_book IN (%s)
                  AND strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book, page
            ) ps_dedup
            JOIN book ON ps_dedup.id_book = book.id
            LEFT JOIN (
                SELECT id_book,
                       COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime')) AS days_read
                FROM page_stat
                WHERE id_book IN (%s)
                  AND strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book
            ) day_counts ON ps_dedup.id_book = day_counts.id_book
            GROUP BY ps_dedup.id_book
            ORDER BY MAX(ps_dedup.last_read) DESC
        ]], id_list, period_value, id_list, period_value)

        local _res, ran = StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    title     = row[1] or _("Unknown"),
                    authors   = "",
                    pages     = tonumber(row[3]) or 0,
                    duration  = tonumber(row[4]) or 0,
                    days_read = tonumber(row[6]) or 0,
                    id_book   = tonumber(row[7]),
                    md5       = row[8],
                    last_read = tonumber(row[5]) or 0,
                })
            end
        end)
        if ran and stamp then Cache.setBookList(cache_key, stamp, books) end
        return books
    end)
end

function M.getAllBooks()
    local books = {}
    return StatsDb.withDb(books, function(conn)
        local stamp = M._bookListStamp(conn)
        local hit   = Cache.getBookList("all2", stamp)
        if hit then return hit end

        local sql = [[
            SELECT book.title, book.authors,
                   COUNT(DISTINCT ps_dedup.page) AS pages_read,
                   SUM(ps_dedup.period_sum) AS duration_sec,
                   MAX(ps_dedup.last_read) AS last_read_time,
                   book.id AS id_book,
                   book.md5 AS md5
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
        local _res, ran = StatsDb.withStatement(conn, sql, function(stmt)
            for row in stmt:rows() do
                table.insert(books, {
                    title    = row[1] or _("Unknown"),
                    authors  = "",
                    pages    = tonumber(row[3]) or 0,
                    duration = tonumber(row[4]) or 0,
                    id_book  = tonumber(row[6]),
                    md5      = row[7],
                    last_read = tonumber(row[5]) or 0,
                })
            end
        end)
        if ran then Cache.setBookList("all2", stamp, books) end
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
