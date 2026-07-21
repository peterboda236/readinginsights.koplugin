--[[
Reading Insights - the data behind the Book progress calendar.

The queries the calendar popup fills its month grid from: per-day pages and
time for one book in one month, the cumulative progress through the book as
of each day, which month to open on, when the book was first opened, and
whether a given month has any reading in it at all (which is what decides
how far the arrows can page).

Split out of book_calendar_view.lua to match the other popups - queries and
caching in lib/, widgets in views/. Nothing here builds or measures a
widget, so it can be exercised without KOReader's UI.

  CalendarData.getBookDailyStatsForMonth(book_id, year, month)
  CalendarData.getBookCumulativeProgressForMonth(book_id, year, month, total_pages)
  CalendarData.getBookLastReadYearMonth(book_id)
  CalendarData.getBookStartedTimestamp(book_id)
  CalendarData.bookCalendarMonthHasData(book_id, year, month)
]]--

local deps = ...
local StatsDb = deps.StatsDb

local M = {}

-- Per-day { pages, duration } for one month, plus that month's max daily
-- duration (for heatmap scaling). pages = distinct pages touched that day.
function M.getBookDailyStatsForMonth(book_id, year, month)
    local daily_map = {}
    if not book_id then return daily_map, 0 end

    local conn = StatsDb.open()
    if not conn then return daily_map, 0 end

    local year_month = string.format("%04d-%02d", year, month)
    local sql = string.format([[
        SELECT day, count(*), sum(duration)
        FROM (
            SELECT strftime('%%d', start_time, 'unixepoch', 'localtime') AS day,
                   page,
                   sum(duration) AS duration
            FROM   page_stat
            WHERE  id_book = %d
            AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
            GROUP  BY day, page
        )
        GROUP BY day
        ORDER BY day;
    ]], book_id, year_month)

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

-- Year/month of this book's most recent page_stat entry, so the calendar
-- opens on the month last actually read in. nil, nil if no reading yet.
function M.getBookLastReadYearMonth(book_id)
    if not book_id then return nil, nil end
    local conn = StatsDb.open()
    if not conn then return nil, nil end

    local sql = string.format([[
        SELECT strftime('%%Y', start_time, 'unixepoch', 'localtime'),
               strftime('%%m', start_time, 'unixepoch', 'localtime')
        FROM   page_stat
        WHERE  id_book = %d
        ORDER  BY start_time DESC
        LIMIT  1
    ]], book_id)
    local y, m = conn:rowexec(sql)
    conn:close()
    if not y or not m then return nil, nil end
    return tonumber(y), tonumber(m)
end

-- This book's first-ever page_stat start_time (when reading started), or
-- nil if there's no reading data yet.
function M.getBookStartedTimestamp(book_id)
    if not book_id then return nil end
    local conn = StatsDb.open()
    if not conn then return nil end

    local sql = string.format([[
        SELECT start_time
        FROM   page_stat
        WHERE  id_book = %d
        ORDER  BY start_time ASC
        LIMIT  1
    ]], book_id)
    local started_timestamp = conn:rowexec(sql)
    conn:close()
    return started_timestamp and tonumber(started_timestamp) or nil
end

-- Whether this book has any page_stat entry in the given year/month, used
-- to stop paging back into empty months.
function M.bookCalendarMonthHasData(book_id, year, month)
    if not book_id then return false end
    local conn = StatsDb.open()
    if not conn then return false end

    local year_month = string.format("%04d-%02d", year, month)
    local sql = string.format([[
        SELECT EXISTS(
            SELECT 1 FROM page_stat
            WHERE  id_book = %d
            AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
            LIMIT  1
        );
    ]], book_id, year_month)
    local exists = conn:rowexec(sql)
    conn:close()
    return tonumber(exists) == 1
end

-- "How far into the book had I gotten as of the last page reached this day"
-- ratio (0..1), from each day's chronologically LAST page_stat entry /
-- total_pages. Deliberately not MAX(page) (avoids end-of-book glossary
-- jumps spiking it) and not a running ratchet across days. Only fills in
-- days that actually have reading recorded.
function M.getBookCumulativeProgressForMonth(book_id, year, month, total_pages)
    local ratios = {}
    if not book_id or not total_pages or total_pages <= 0 then return ratios end

    local conn = StatsDb.open()
    if not conn then return ratios end

    local year_month = string.format("%04d-%02d", year, month)

    -- Ordered ASC so the last write per day wins - each day's value ends up
    -- being its chronologically last page, no window function needed.
    local day_rows_sql = string.format([[
        SELECT strftime('%%d', start_time, 'unixepoch', 'localtime') AS day, page
        FROM   page_stat
        WHERE  id_book = %d
        AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
        ORDER  BY start_time ASC
    ]], book_id, year_month)

    local day_last_page = {}
    StatsDb.withStatement(conn, day_rows_sql, function(stmt)
        for row in stmt:rows() do
            local day  = tonumber(row[1])
            local page = tonumber(row[2])
            if day and page then day_last_page[day] = page end
        end
    end)
    conn:close()

    for day, page in pairs(day_last_page) do
        local ratio = page / total_pages
        if ratio > 1 then ratio = 1 end
        if ratio < 0 then ratio = 0 end
        ratios[day] = ratio
    end

    return ratios
end

return M
