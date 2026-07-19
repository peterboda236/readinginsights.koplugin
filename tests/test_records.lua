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
function StatsDb.withDb(fallback, fn) return fn({}) end
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
    local i = 0
    return fn({ rows = function() return function() i = i + 1; return rows[i] end end })
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

print("\nALL RECORDS TESTS PASSED")
