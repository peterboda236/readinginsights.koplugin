--[[
Reading Insights - shared access to KOReader's statistics.sqlite3.

All three data-backed views (insights_view.lua, record_view.lua and the
per-book stats/calendar views) read from the same statistics database, and
each used to carry its own near-identical copy of:

  - the db path (DataStorage:getSettingsDir() .. "/statistics.sqlite3")
  - a "does the file exist, open it, set the WAL/cache PRAGMAs" opener
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
                                  returns fn's result (nil on failure)
]]--

local DataStorage = require("datastorage")
local SQ3         = require("lua-ljsqlite3/init")

local M = {}

local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

-- Same PRAGMAs every opener used before: WAL journalling, a modest page
-- cache, and in-memory temp tables, for snappy read-mostly access.
local PRAGMAS = "PRAGMA journal_mode=WAL; PRAGMA cache_size=2000; PRAGMA temp_store=MEMORY;"

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
function M.withStatement(conn, sql, fn)
    if not conn then return end
    local stmt = conn:prepare(sql)
    if not stmt then return end
    local ok, result = pcall(fn, stmt)
    stmt:close()
    if ok then return result end
end

return M
