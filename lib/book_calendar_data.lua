--[[
Reading Insights - the data behind the Book progress calendar.

The queries the calendar popup fills its month grid from: per-day pages and
time for one book in one month, the cumulative progress through the book as
of each day, how many percentage points each day added, which month to open on, when the book was first opened, and
whether a given month has any reading in it at all (which is what decides
how far the arrows can page).

Split out of book_calendar_view.lua to match the other popups - queries and
caching in lib/, widgets in views/. Nothing here builds or measures a
widget, so it can be exercised without KOReader's UI.

  CalendarData.getBookDailyStatsForMonth(book_id, year, month)
  CalendarData.getBookCumulativeProgressForMonth(book_id, year, month, total_pages, live_page)
  CalendarData.getBookDailyProgressDeltaForMonth(book_id, year, month, total_pages, live_page)
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
--
-- Goes through StatsDb.withDb/withStatement (pcall-guarded, always closes)
-- rather than a raw conn:rowexec: KOReader's statistics plugin writes to this
-- file on every page turn, so a read here can lose that race and raise
-- SQLITE_BUSY - which a raw rowexec would turn into a leaked connection and a
-- failed popup. On any such failure this just falls back to "no reading yet".
function M.getBookLastReadYearMonth(book_id)
    if not book_id then return nil, nil end
    local r = StatsDb.withDb(nil, function(conn)
        local ym = {}
        StatsDb.withStatement(conn, string.format([[
            SELECT strftime('%%Y', start_time, 'unixepoch', 'localtime'),
                   strftime('%%m', start_time, 'unixepoch', 'localtime')
            FROM   page_stat
            WHERE  id_book = %d
            ORDER  BY start_time DESC
            LIMIT  1
        ]], book_id), function(stmt)
            for row in stmt:rows() do
                ym.y, ym.m = tonumber(row[1]), tonumber(row[2])
                break
            end
        end)
        return ym
    end)
    if not r or not r.y or not r.m then return nil, nil end
    return r.y, r.m
end

-- This book's first-ever page_stat start_time (when reading started), or
-- nil if there's no reading data yet. Same pcall-guarded access as above.
function M.getBookStartedTimestamp(book_id)
    if not book_id then return nil end
    return StatsDb.withDb(nil, function(conn)
        local ts
        StatsDb.withStatement(conn, string.format([[
            SELECT start_time
            FROM   page_stat
            WHERE  id_book = %d
            ORDER  BY start_time ASC
            LIMIT  1
        ]], book_id), function(stmt)
            for row in stmt:rows() do
                ts = tonumber(row[1])
                break
            end
        end)
        return ts
    end)
end

-- Whether this book has any page_stat entry in the given year/month, used
-- to stop paging back into empty months. Same pcall-guarded access as above;
-- a lost race falls back to "no data" (the arrows just won't page there).
function M.bookCalendarMonthHasData(book_id, year, month)
    if not book_id then return false end
    local year_month = string.format("%04d-%02d", year, month)
    return StatsDb.withDb(false, function(conn)
        local has = false
        StatsDb.withStatement(conn, string.format([[
            SELECT 1 FROM page_stat
            WHERE  id_book = %d
            AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
            LIMIT  1
        ]], book_id, year_month), function(stmt)
            for _row in stmt:rows() do
                has = true
                break
            end
        end)
        return has
    end)
end

-- Shared by the two progress queries below: for each day of the month that
-- has reading recorded, the page of the chronologically LAST page_stat entry
-- (ASC order, last write per day wins - no window function needed), plus
-- `baseline`, the last page reached before the month began (nil if the book
-- was not read before it).
--
-- live_page (optional, only meaningful for the current month): the page the
-- reader is on right now. KOReader's statistics plugin only writes a page to
-- page_stat once you turn away from it, so today's recorded last page is
-- always one page behind the live position. When given, it replaces today's
-- last page (if today has reading recorded), so the numbers agree with the
-- Book progress popup.
local function dayLastPages(conn, book_id, year, month, live_page)
    local year_month = string.format("%04d-%02d", year, month)

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

    local baseline_sql = string.format([[
        SELECT page
        FROM   page_stat
        WHERE  id_book = %d
        AND    strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') < '%s'
        ORDER  BY start_time DESC
        LIMIT  1
    ]], book_id, year_month)

    local baseline
    StatsDb.withStatement(conn, baseline_sql, function(stmt)
        for row in stmt:rows() do
            baseline = tonumber(row[1])
            break
        end
    end)

    if live_page then
        local now = os.date("*t")
        if now.year == year and now.month == month and day_last_page[now.day] then
            day_last_page[now.day] = live_page
        end
    end

    return day_last_page, baseline
end

-- "How far into the book had I gotten as of the last page reached this day"
-- ratio (0..1), from each day's chronologically LAST page_stat entry /
-- total_pages. Deliberately not MAX(page) (avoids end-of-book glossary
-- jumps spiking it) and not a running ratchet across days. Only fills in
-- days that actually have reading recorded.
function M.getBookCumulativeProgressForMonth(book_id, year, month, total_pages, live_page)
    local ratios = {}
    if not book_id or not total_pages or total_pages <= 0 then return ratios end

    local conn = StatsDb.open()
    if not conn then return ratios end
    local day_last_page = dayLastPages(conn, book_id, year, month, live_page)
    conn:close()

    for day, page in pairs(day_last_page) do
        local ratio = page / total_pages
        if ratio > 1 then ratio = 1 end
        if ratio < 0 then ratio = 0 end
        ratios[day] = ratio
    end

    return ratios
end

local function roundPercent(ratio)
    return math.floor(100 * ratio + 0.5)
end

-- How many percentage points each day moved the reader forward in the book:
-- that day's position (last page reached, as a rounded percent of the book)
-- minus the position at the end of the previous reading day. The first
-- reading day starts from 0, so it equals the Book progress figure, and the
-- daily values add up to it. Rounding is done on the running positions
-- rather than on each day's difference, so the sum never drifts by a point.
-- Going backwards (re-reading, jumping to an earlier chapter) counts as 0,
-- never negative. Returns { [day] = integer }, only for days with reading.
function M.getBookDailyProgressDeltaForMonth(book_id, year, month, total_pages, live_page)
    local deltas = {}
    if not book_id or not total_pages or total_pages <= 0 then return deltas end

    local conn = StatsDb.open()
    if not conn then return deltas end
    local day_last_page, baseline = dayLastPages(conn, book_id, year, month, live_page)
    conn:close()

    local function positionPercent(page)
        local ratio = page / total_pages
        if ratio > 1 then ratio = 1 end
        if ratio < 0 then ratio = 0 end
        return roundPercent(ratio)
    end

    local prev = baseline and positionPercent(baseline) or 0
    local days = {}
    for day in pairs(day_last_page) do days[#days + 1] = day end
    table.sort(days)

    for _, day in ipairs(days) do
        local pos = positionPercent(day_last_page[day])
        deltas[day] = math.max(0, pos - prev)
        prev = pos
    end

    return deltas
end

return M
