--[[
Reading Insights - lib/records_data, the queries and cache behind the
Records popup, against a stub statistics DB.

Covers the milestone ladder's edges, the three record queries, streak
boundaries, an empty history, and - the part with real teeth - the DB
fingerprint deciding between serving from cache and recomputing from
scratch after rows disappear.

Run from the plugin root: lua5.1 tests/test_records.lua
]]--

local files = {}
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/tmp/rec" end } end
package.preload["luasettings"] = function()
    local LS = {}; LS.__index = LS
    function LS:open(p) files[p] = files[p] or {}; return setmetatable({ data = files[p] }, LS) end
    function LS:readSetting(k) return self.data[k] end
    function LS:saveSetting(k, v) self.data[k] = v end
    function LS:flush() self.flushed = true end
    return LS
end

-- A tiny in-memory stand-in for the statistics DB: the module only ever
-- runs SQL through StatsDb, so the fixture answers by pattern.
local db = { rows = {} }   -- rows: { date, seconds, pages }
local function dayTotals()
    local by = {}
    for _, r in ipairs(db.rows) do
        by[r.date] = by[r.date] or { sec = 0, pages = 0 }
        by[r.date].sec = by[r.date].sec + r.seconds
        by[r.date].pages = by[r.date].pages + r.pages
    end
    return by
end
local function sortedDates()
    local d = {}
    for k in pairs(dayTotals()) do d[#d+1] = k end
    table.sort(d)
    return d
end

local StatsDb = {}
-- db.no_conn stands for a database that can't be opened at all (missing
-- file, storage unmounted, SQLite refusing the handle): withDb then hands
-- back the fallback without ever running fn.
function StatsDb.withDb(fallback, fn)
    if db.no_conn then return fallback end
    return fn({})
end
function StatsDb.withShared(_, fallback, fn) return fn({}) end
function StatsDb.withStatement(conn, sql, fn)
    local totals, dates = dayTotals(), sortedDates()
    local rows = {}
    if sql:match("MAX%(start_time%)") and sql:match("COUNT") then
        rows = { { db.max_time or 0, #db.rows } }
    elseif sql:match("SUM%(duration%)") and sql:match("GROUP BY day") and sql:match("ORDER BY") then
        local best, bd = 0, nil
        for d, t in pairs(totals) do if t.sec > best then best, bd = t.sec, d end end
        rows = { { bd, best } }
    elseif sql:match("COUNT") and sql:match("GROUP BY day") then
        local best, bd = 0, nil
        for d, t in pairs(totals) do if t.pages > best then best, bd = t.pages, d end end
        rows = { { bd, best } }
    elseif sql:match("DISTINCT date") then
        for _, d in ipairs(dates) do rows[#rows+1] = { d } end
    elseif sql:match("SUM%(duration%)") then
        local s = 0
        for _, r in ipairs(db.rows) do s = s + r.seconds end
        rows = { { s } }
    end
    -- db.fail makes every statement report "did not run", the way the real
    -- StatsDb.withStatement does when a query loses the race with KOReader's
    -- own statistics writer: no rows, no error, just a false second return.
    if db.fail then return nil, false end
    local i = 0
    return fn({ rows = function() return function() i = i + 1; return rows[i] end end }), true
end

local RecordsData = assert(loadfile("lib/records_data.lua"))({ StatsDb = StatsDb })

local function check(label, got, want)
    print(string.format("%-50s %-12s %s", label, tostring(got), got == want and "ok" or ("EXPECTED " .. tostring(want))))
    assert(got == want, label)
end

-- milestone ladder
local last, nxt = RecordsData.getMilestones(0);    check("0 h -> no milestone reached", last, nil)
check("0 h -> next is 1", nxt, 1)
last, nxt = RecordsData.getMilestones(7);          check("7 h -> last reached 5", last, 5)
check("7 h -> next 10", nxt, 10)
last, nxt = RecordsData.getMilestones(1);          check("exactly 1 h counts as reached", last, 1)
last, nxt = RecordsData.getMilestones(99999);      check("beyond the ladder -> top", last, 10000)
check("beyond the ladder -> no next", nxt, nil)

-- records over a fixture: three days, a 2-day streak, then a gap
db.rows = {
    { date = "2026-01-01", seconds = 3600, pages = 40 },
    { date = "2026-01-02", seconds = 7200, pages = 30 },
    { date = "2026-01-05", seconds = 1800, pages = 90 },
}
db.max_time = 1000
local d = RecordsData.load()
check("most reading time in a day", d.longest.duration_sec, 7200)
check("...on the right date", d.longest.date, "2026-01-02")
check("most pages in a day", d.best_day.pages, 90)
check("...on the right date", d.best_day.date, "2026-01-05")
check("best streak length", d.streak.days, 2)
check("streak start", d.streak.start_date, "2026-01-01")
check("streak end", d.streak.end_date, "2026-01-02")
check("total seconds", d.total_secs, 12600)

-- the cache is written, and a second call with an unchanged DB reuses it
check("cache file written", files["/tmp/rec/readinginsights_records_cache.lua"] ~= nil, true)
local stored = files["/tmp/rec/readinginsights_records_cache.lua"]
check("fingerprint stored: row count", stored.hw_row_count, 3)
check("fingerprint stored: watermark", stored.hw_max_time, 1000)
stored.longest_sec = 424242            -- tamper: proves the read came from cache
local d2 = RecordsData.load()
check("unchanged DB -> served from cache", d2.longest.duration_sec, 424242)

-- rows removed behind our back -> fingerprint fails -> full recompute
table.remove(db.rows)
local d3 = RecordsData.load()
check("deleted rows force a recompute", d3.longest.duration_sec, 7200)
check("recompute rewrote the row count", files["/tmp/rec/readinginsights_records_cache.lua"].hw_row_count, 2)

-- an empty history must not blow up
db.rows = {}; db.max_time = 0
local d4 = RecordsData.load()
check("empty history: no records", d4.longest.duration_sec, 0)
check("empty history: no streak", d4.streak.days, 0)

-- A failed read must never be cached as "nothing was ever read". It used to
-- be, alongside a fingerprint that stayed valid, so the Records popup went
-- to zeros and stayed there for good while the insights popup kept working.
files["/tmp/rec/readinginsights_records_cache.lua"] = nil
db.rows = {
    { date = "2026-03-01", seconds = 600, pages = 10 },
    { date = "2026-03-02", seconds = 900, pages = 20 },
}
db.max_time = 2000
db.fail = true
local d5 = RecordsData.load()
check("failed read reports nothing", d5.total_secs, 0)
-- Nothing was written: the fixture's LuaSettings:open creates the entry as
-- soon as loadCache looks at it, so it is the stored fingerprint - the thing
-- that would make the zeros stick - that has to be absent, not the table.
check("...and is not cached",
      (files["/tmp/rec/readinginsights_records_cache.lua"] or {}).hw_max_time, nil)
db.fail = false
local d6 = RecordsData.load()
check("next open recovers the real total", d6.total_secs, 1500)
check("...and the real streak", d6.streak.days, 2)

-- A cache poisoned by an older version heals itself: zeros stored against a
-- fingerprint that still matches a database which plainly has rows.
local poisoned = files["/tmp/rec/readinginsights_records_cache.lua"]
poisoned.total_secs, poisoned.longest_sec = 0, 0
poisoned.best_day_pages, poisoned.streak_days = 0, 0
local d7 = RecordsData.load()
check("poisoned cache is recomputed", d7.total_secs, 1500)
check("...and overwritten on disk", files["/tmp/rec/readinginsights_records_cache.lua"].total_secs, 1500)

-- A genuinely empty database with a matching all-zero cache stays cached:
-- the heal above must key off the row count, not off the zeros alone.
files["/tmp/rec/readinginsights_records_cache.lua"] = nil
db.rows = {}; db.max_time = 0
RecordsData.load()
local empty_cache = files["/tmp/rec/readinginsights_records_cache.lua"]
check("empty history is cached", empty_cache ~= nil, true)
empty_cache.longest_sec = 424242       -- tamper: proves the read came from cache
check("empty history stays cached", RecordsData.load().longest.duration_sec, 424242)

-- An unreadable database must not throw away records already on disk. This
-- is what actually emptied the popup in the field: the cache was read inside
-- the database call, so a database that wouldn't open took the good cached
-- records down with it and every row showed a dash.
files["/tmp/rec/readinginsights_records_cache.lua"] = nil
db.rows = {
    { date = "2026-05-01", seconds = 1200, pages = 30 },
    { date = "2026-05-02", seconds = 1800, pages = 40 },
}
db.max_time = 5000
RecordsData.load()                       -- populate the cache from a healthy DB
db.no_conn = true
local d9 = RecordsData.load()
check("unreadable DB falls back to the cache", d9.total_secs, 3000)
check("...with the cached records intact", d9.longest.duration_sec, 1800)
check("...and the cached streak", d9.streak.days, 2)
check("...and the cached dates", d9.best_day.date, "2026-05-02")
db.no_conn = false

-- ...but with no cache at all there is still nothing to show, and no crash.
files["/tmp/rec/readinginsights_records_cache.lua"] = nil
db.no_conn = true
local d10 = RecordsData.load()
check("unreadable DB, no cache -> zeros", d10.total_secs, 0)
check("...and no streak", d10.streak.days, 0)
db.no_conn = false

-- clearCache (the Records popup's "hold the title to reload") drops the
-- stored fingerprint, so the next load recounts instead of trusting it.
files["/tmp/rec/readinginsights_records_cache.lua"] = nil
db.rows = { { date = "2026-06-01", seconds = 2400, pages = 50 } }
db.max_time = 6000
RecordsData.load()
local kept = files["/tmp/rec/readinginsights_records_cache.lua"]
kept.longest_sec = 424242              -- tamper: a plain load would serve this
check("tampered cache is served before clearing", RecordsData.load().longest.duration_sec, 424242)
RecordsData.clearCache()
check("clearCache drops the fingerprint",
      files["/tmp/rec/readinginsights_records_cache.lua"].hw_max_time, nil)
check("clearCache drops the values too",
      files["/tmp/rec/readinginsights_records_cache.lua"].longest_sec, nil)
check("next load recounts from the DB", RecordsData.load().longest.duration_sec, 2400)

-- An unparseable date can't take the whole popup down with it.
files["/tmp/rec/readinginsights_records_cache.lua"] = nil
db.rows = {
    { date = "2026-04-01", seconds = 300, pages = 5 },
    { date = "not-a-date", seconds = 300, pages = 5 },
}
db.max_time = 3000
local d8 = RecordsData.load()
check("junk date does not crash the load", d8.total_secs, 600)
check("...and is left out of the streak", d8.streak.days, 1)

print("\nALL RECORDS TESTS PASSED")
