--[[
Reading Insights - the data behind the general Reading calendar.

The all-books counterpart to lib/book_calendar_data.lua: where that module
answers "how much of *this* book did I read each day", these queries answer
"how much did I read *in total* each day" and "which books did I read on
this day". Nothing here is scoped to a single book - every page_stat row
counts, whatever book it belongs to.

Used by views/reading_calendar_view.lua to fill its month grid (per-day
total time + pages) and, when a day is tapped, the book list behind it
(one row per book read that day, with that day's time and pages).

  ReadingCalendarData.getDailyStatsForMonth(year, month)
  ReadingCalendarData.getBooksForDay(year, month, day)
  ReadingCalendarData.getLastReadYearMonth()
  ReadingCalendarData.monthHasData(year, month)
]]--

local deps = ...
local StatsDb = deps.StatsDb
local Locale  = deps.Locale
local _ = Locale and Locale._ or function(s) return s end

local M = {}

-- Per-day { pages, duration } for one month across *all* books, plus that
-- month's max daily duration (kept for symmetry with the per-book version,
-- and available if the view ever wants to shade cells by it).
--   pages    = distinct (book, page) pairs touched that day
--   duration = total seconds read that day
function M.getDailyStatsForMonth(year, month)
    local daily_map = {}

    local conn = StatsDb.open()
    if not conn then return daily_map, 0 end

    local year_month = string.format("%04d-%02d", year, month)
    -- Inner query de-duplicates by (day, book, page) so a page re-read
    -- several times in a day counts once towards the page total but keeps
    -- all of its reading time; the outer query then rolls each day up.
    local sql = string.format([[
        SELECT day, count(*), sum(duration)
        FROM (
            SELECT strftime('%%d', start_time, 'unixepoch', 'localtime') AS day,
                   id_book,
                   page,
                   sum(duration) AS duration
            FROM   page_stat
            WHERE  strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
            GROUP  BY day, id_book, page
        )
        GROUP BY day
        ORDER BY day;
    ]], year_month)

    local max_duration = 0
    StatsDb.withStatement(conn, sql, function(stmt)
        for row in stmt:rows() do
            local day      = tonumber(row[1])
            local pages    = tonumber(row[2]) or 0
            local duration = tonumber(row[3]) or 0
            if day then
                daily_map[day] = { pages = pages, duration = duration }
                if duration > max_duration then max_duration = duration end
            end
        end
    end)

    conn:close()
    return daily_map, max_duration
end

-- One row per book read on the given day, ordered by time spent (most read
-- first). Each row: { title, id_book, pages, duration, last_read }.
--   pages     = distinct pages of that book touched that day
--   duration  = seconds spent on that book that day
--   last_read = that book's last page_stat start_time on this day (used by
--               the book list's sort menu)
function M.getBooksForDay(year, month, day)
    local books = {}

    local conn = StatsDb.open()
    if not conn then return books end

    local date_str = string.format("%04d-%02d-%02d", year, month, day)
    local sql = string.format([[
        SELECT book.title,
               COUNT(DISTINCT ps_dedup.page) AS pages_read,
               SUM(ps_dedup.day_sum) AS duration_sec,
               MAX(ps_dedup.last_read) AS last_read_time,
               book.id AS id_book
        FROM (
            SELECT id_book, page,
                   SUM(duration) AS day_sum,
                   MAX(start_time) AS last_read
            FROM   page_stat
            WHERE  strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') = '%s'
            GROUP  BY id_book, page
        ) ps_dedup
        JOIN book ON ps_dedup.id_book = book.id
        GROUP BY ps_dedup.id_book
        ORDER BY duration_sec DESC, last_read_time DESC;
    ]], date_str)

    StatsDb.withStatement(conn, sql, function(stmt)
        for row in stmt:rows() do
            table.insert(books, {
                title     = row[1] or _("Unknown"),
                pages     = tonumber(row[2]) or 0,
                duration  = tonumber(row[3]) or 0,
                last_read = tonumber(row[4]) or 0,
                id_book   = tonumber(row[5]),
            })
        end
    end)

    conn:close()
    return books
end

-- Year/month of the most recent page_stat entry across all books, so the
-- calendar opens on the month last actually read in. nil, nil if there's
-- no reading recorded at all.
function M.getLastReadYearMonth()
    local conn = StatsDb.open()
    if not conn then return nil, nil end

    local sql = [[
        SELECT strftime('%Y', start_time, 'unixepoch', 'localtime'),
               strftime('%m', start_time, 'unixepoch', 'localtime')
        FROM   page_stat
        ORDER  BY start_time DESC
        LIMIT  1
    ]]
    local y, m = conn:rowexec(sql)
    conn:close()
    if not y or not m then return nil, nil end
    return tonumber(y), tonumber(m)
end

-- The newest page_stat start_time across all books, or 0 if there's no
-- reading yet. A cheap read the calendar's stale-while-revalidate uses to
-- decide whether the current month is worth re-querying: if this hasn't
-- moved since the last fetch (Cache._reading_calendar_watermark), nothing
-- has been read since, so the background refresh is skipped.
function M.getMaxStartTime()
    local conn = StatsDb.open()
    if not conn then return 0 end
    local max_ts = conn:rowexec("SELECT MAX(start_time) FROM page_stat")
    conn:close()
    return tonumber(max_ts) or 0
end

-- Whether any book has a page_stat entry in the given year/month, used to
-- stop paging back into empty months.
function M.monthHasData(year, month)
    local conn = StatsDb.open()
    if not conn then return false end

    local year_month = string.format("%04d-%02d", year, month)
    local sql = string.format([[
        SELECT EXISTS(
            SELECT 1 FROM page_stat
            WHERE  strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
            LIMIT  1
        );
    ]], year_month)
    local exists = conn:rowexec(sql)
    conn:close()
    return tonumber(exists) == 1
end

return M
