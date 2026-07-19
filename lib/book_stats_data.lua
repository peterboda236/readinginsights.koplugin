--[[
Reading Insights - the data behind the book progress overlay.

One query, but the one that feeds most of the overlay: for a given book it
returns how many distinct days it has been read, today's pages and time for
that book, today's pages and time across *all* books (the overlay can show
either), how long ago it was started, and when.

Split out of book_stats_view.lua so every popup in the plugin follows the
same shape - queries in lib/, widgets in views/ - and so this one is
reachable from a test without KOReader's UI. The rest of that view's numbers
come from lib/bookprogress.lua (positions and page counts) and
lib/chapterinfo.lua (chapters), which were already separate.

  BookStatsData.getBookAndTodayStats(book_id)
      -> total_days, today_pages, today_time, today_pages_all,
         today_time_all, days_since_start, started_timestamp
]]--

local deps = ...
local StatsDb = deps.StatsDb

local M = {}

-- Single DB connection, all stats fetched at once.
function M.getBookAndTodayStats(book_id)
    if not book_id then return nil, nil, nil, nil, nil, nil, nil end

    local conn = StatsDb.open()
    if not conn then return nil, nil, nil, nil, nil, nil, nil end

    local days_sql = string.format([[
        SELECT count(*)
        FROM (
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates
            FROM   page_stat
            WHERE  id_book = %d
            GROUP  BY dates
        );
    ]], book_id)
    local total_days = conn:rowexec(days_sql)
    total_days = total_days and tonumber(total_days) or nil

    local today_book_sql = string.format([[
        SELECT count(*), sum(duration)
        FROM (
            SELECT page, sum(duration) AS duration
            FROM   page_stat
            WHERE  strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime')
                   = strftime('%%Y-%%m-%%d', 'now', 'localtime')
            AND    id_book = %d
            GROUP  BY page
        );
    ]], book_id)
    local today_pages, today_time = conn:rowexec(today_book_sql)
    today_pages = tonumber(today_pages)
    today_time  = tonumber(today_time)

    local today_all_sql = [[
        SELECT count(*), sum(duration)
        FROM (
            SELECT page, sum(duration) AS duration
            FROM   page_stat
            WHERE  strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')
                   = strftime('%Y-%m-%d', 'now', 'localtime')
            GROUP  BY id_book, page
        );
    ]]
    local today_pages_all, today_time_all = conn:rowexec(today_all_sql)
    today_pages_all = tonumber(today_pages_all)
    today_time_all  = tonumber(today_time_all)

    -- Days elapsed since this book's very first page_stat entry (i.e. since
    -- reading it was started). Used for the "N days since started" cell.
    local first_read_sql = string.format([[
        SELECT start_time,
               CAST(julianday('now', 'localtime')
                    - julianday(date(start_time, 'unixepoch', 'localtime')) AS INTEGER)
        FROM   page_stat
        WHERE  id_book = %d
        ORDER  BY start_time ASC
        LIMIT  1
    ]], book_id)
    local started_timestamp, days_since_start = conn:rowexec(first_read_sql)
    started_timestamp = started_timestamp and tonumber(started_timestamp) or nil
    days_since_start  = days_since_start  and tonumber(days_since_start)  or nil

    conn:close()
    return total_days, today_pages, today_time, today_pages_all, today_time_all, days_since_start, started_timestamp
end

return M
