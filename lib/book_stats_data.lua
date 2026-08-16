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

-- Single DB connection, all stats fetched at once. Every read goes through
-- StatsDb.withDb/withStatement (pcall-guarded, always closes the connection):
-- KOReader's own statistics plugin writes to this file on every page turn and
-- book close, so a query here can lose that race and raise SQLITE_BUSY - and a
-- raw conn:rowexec would then leak the connection and fail the whole popup.
-- On any such failure a field is simply left nil, which the caller already
-- treats as "no data yet".
function M.getBookAndTodayStats(book_id)
    if not book_id then return nil, nil, nil, nil, nil, nil, nil end

    local r = StatsDb.withDb(nil, function(conn)
        -- Reads the first row of `sql` into out[k1] (col 1) and, when k2 is
        -- given, out[k2] (col 2), as numbers. A query that returns no row or
        -- loses the race with KOReader's writer simply leaves them nil, which
        -- the caller already treats as "no data yet".
        local out = {}
        local function readRow(sql, k1, k2)
            StatsDb.withStatement(conn, sql, function(stmt)
                for row in stmt:rows() do
                    out[k1] = tonumber(row[1])
                    if k2 then out[k2] = tonumber(row[2]) end
                    break
                end
            end)
        end

        readRow(string.format([[
            SELECT count(*)
            FROM (
                SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates
                FROM   page_stat
                WHERE  id_book = %d
                GROUP  BY dates
            );
        ]], book_id), "total_days")

        readRow(string.format([[
            SELECT count(*), sum(duration)
            FROM (
                SELECT page, sum(duration) AS duration
                FROM   page_stat
                WHERE  strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime')
                       = strftime('%%Y-%%m-%%d', 'now', 'localtime')
                AND    id_book = %d
                GROUP  BY page
            );
        ]], book_id), "today_pages", "today_time")

        readRow([[
            SELECT count(*), sum(duration)
            FROM (
                SELECT page, sum(duration) AS duration
                FROM   page_stat
                WHERE  strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')
                       = strftime('%Y-%m-%d', 'now', 'localtime')
                GROUP  BY id_book, page
            );
        ]], "today_pages_all", "today_time_all")

        -- Days elapsed since this book's very first page_stat entry (i.e. since
        -- reading it was started). Used for the "N days since started" cell.
        readRow(string.format([[
            SELECT start_time,
                   CAST(julianday('now', 'localtime')
                        - julianday(date(start_time, 'unixepoch', 'localtime')) AS INTEGER)
            FROM   page_stat
            WHERE  id_book = %d
            ORDER  BY start_time ASC
            LIMIT  1
        ]], book_id), "started_timestamp", "days_since_start")

        return out
    end)

    r = r or {}
    return r.total_days, r.today_pages, r.today_time, r.today_pages_all,
           r.today_time_all, r.days_since_start, r.started_timestamp
end

return M
