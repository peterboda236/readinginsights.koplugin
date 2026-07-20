--[[
Reading Insights - shared access to KOReader's statistics.sqlite3.

All three data-backed views (insights_view.lua, record_view.lua and the
per-book stats/calendar views) read from the same statistics database, and
each used to carry its own near-identical copy of:

  - the db path (DataStorage:getSettingsDir() .. "/statistics.sqlite3")
  - a "does the file exist, open it, set the connection PRAGMAs" opener
  - a withStatsDb(fallback, fn) "open, run, always close, return result or
    fallback" wrapper
  - a withStatement(conn, sql, fn) "prepare, run, always close" wrapper

This module is the single source of truth for all of them:

  StatsDb.path()                  the database file path
  StatsDb.exists()                true if the database file is present
  StatsDb.open()                  a persistent connection (PRAGMAs applied),
                                  or nil; CALLER must conn:close()
  StatsDb.withDb(fallback, fn)    open -> pcall(fn, conn) -> close; returns
                                  fn's result, or `fallback` on any failure
  StatsDb.withStatement(conn, sql, fn)
                                  prepare -> pcall(fn, stmt) -> close;
                                  returns fn's result (nil on failure),
                                  plus true/false for "the query ran"
  StatsDb.withConn(conn, fallback, fn)
                                  like withDb, but on a connection the
                                  caller already owns (not closed here)
  StatsDb.withShared(shared_conn, fallback, fn)
                                  withConn when shared_conn is given,
                                  withDb when it is nil
]]--

local DataStorage = require("datastorage")
local SQ3         = require("lua-ljsqlite3/init")
local logger      = require("logger")

local M = {}

local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

-- Connection settings only. Every one of these applies to the handle we
-- just opened and to nothing else, which is the whole point: this plugin
-- never writes a row to the statistics database - it is KOReader's, and we
-- only ever SELECT from it - so it has no business changing the file.
--
-- That is why journal_mode is not here, though it used to be. Unlike the
-- three below, journal_mode is a persistent property of the database file
-- rather than of a connection: setting it rewrites the header for every
-- future opener, KOReader's own statistics plugin included. Forcing WAL
-- from here overrode both KOReader's own Device:canUseWAL() check (false
-- on, say, a Kindle 2, whose kernel can't mmap /mnt/us) and the deliberate
-- choice of anyone who keeps the database out of WAL so they can sync it
-- as a single file - WAL keeps recent transactions in a -wal sidecar, so
-- copying the .sqlite3 alone silently loses them. We gain nothing by
-- setting it either: if the database is already in WAL, readers get the
-- benefit without asking. Switching it also needs the write lock, so with
-- busy_timeout below it could stall an open for seconds on a database
-- someone else is writing.
--
-- busy_timeout is the deliberate addition: KOReader's statistics plugin
-- writes here while we read (every page turn, every book close), and
-- without a timeout SQLite gives up the instant it meets a writer instead
-- of waiting for it. The full-history scans behind the Records popup are
-- exactly the long readers that lose that race.
local PRAGMAS = "PRAGMA busy_timeout=3000; PRAGMA cache_size=2000; PRAGMA temp_store=MEMORY;"

function M.path()
    return db_path
end

function M.exists()
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(db_path, "mode") == "file"
end

-- Persistent connection for batch use. Returns nil if the DB file does not
-- exist or cannot be opened. The caller owns the connection and must close it.
function M.open()
    if not M.exists() then return nil end
    local conn = SQ3.open(db_path)
    if not conn then return nil end
    pcall(function()
        conn:exec(PRAGMAS)
    end)
    return conn
end

-- Open, run fn(conn), always close, and return fn's result. On any failure
-- (missing DB, open error, or fn erroring) returns `fallback` instead.
function M.withDb(fallback, fn)
    local conn = M.open()
    if not conn then return fallback end
    local ok, result = pcall(fn, conn)
    conn:close()
    if ok then return result end
    return fallback
end

-- Prepare a statement on an already-open connection, run fn(stmt), always
-- close the statement, and return fn's result (nil on any failure). The
-- connection is left open; the caller owns it.
--
-- Returns fn's result, plus a second value saying whether the statement
-- actually ran. That second value matters: fn typically reports its rows by
-- filling in a table the caller owns, so a query that fails halfway leaves
-- that table looking exactly like a query that honestly found nothing.
-- Callers that would go on to *store* the result (RecordsData's cache) have
-- to be able to tell those apart - see lib/records_data.lua, where writing
-- "no reading at all" to the cache pinned the Records popup to zeros for
-- good. Callers that only display what they got can keep ignoring it.
--
-- The prepare is inside the pcall as well: ljsqlite3 raises on a statement
-- it can't prepare rather than returning nil, so the old guard below it
-- never actually caught anything, and the error escaped to whatever enclosing
-- pcall happened to be there.
function M.withStatement(conn, sql, fn)
    if not conn then return nil, false end
    local ok, result = pcall(function()
        local stmt = conn:prepare(sql)
        if not stmt then error("prepare returned no statement") end
        local ran, res = pcall(fn, stmt)
        pcall(function() stmt:close() end)
        if not ran then error(res, 0) end
        return res
    end)
    if ok then return result, true end
    logger.warn("ReadingInsights: statistics query failed:", result, "--", sql)
    return nil, false
end

-- Run fn(conn) on an already-open connection the caller owns: never opens
-- and never closes anything, it only adds the same pcall/fallback safety
-- net M.withDb gives a connection of its own.
function M.withConn(conn, fallback, fn)
    if not conn then return fallback end
    local ok, result = pcall(fn, conn)
    if ok then return result end
    return fallback
end

-- The "either way" form used by the views' data getters, which are all
-- called both standalone and as part of a batch that already holds one
-- shared connection: reuses `shared_conn` when there is one (leaving it
-- open for the rest of the batch), and otherwise opens and closes a
-- connection of its own, so callers don't have to branch on which case
-- they're in.
function M.withShared(shared_conn, fallback, fn)
    if shared_conn then
        return M.withConn(shared_conn, fallback, fn)
    end
    return M.withDb(fallback, fn)
end

return M
