--[[
Reading Insights - lib/prefs, lib/insights_settings, lib/insights_cache and
lib/statsdb, exercised for real with KOReader's file/settings layer stubbed.

Covers the default values and round-trips of every insights setting, the
per-minute and per-day cache behaviour including the stale mirror, the disk
round-trip of the reading-goal state, and the shared-connection wrappers.

Run from the plugin root: lua5.1 tests/test_modules.lua
]]--

local store = {}
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end
package.preload["logger"] = function()
    return { warn = function(...) print("[warn]", ...) end, info = function() end, dbg = function() end }
end
package.preload["luasettings"] = function()
    local LS = {}
    LS.__index = LS
    local files = {}   -- one persistent store per path, like a real file
    function LS:open(path)
        files[path] = files[path] or {}
        return setmetatable({ data = files[path], path = path }, LS)
    end
    function LS:readSetting(k) return self.data[k] end
    function LS:saveSetting(k, v) self.data[k] = v end
    function LS:flush() self.flushed = (self.flushed or 0) + 1 end
    return LS
end
package.preload["lua-ljsqlite3/init"] = function() return { open = function() return nil end } end
package.preload["libs/libkoreader-lfs"] = function() return { attributes = function() return nil end } end

-- Stub of lib/settings.lua's surface used by insightssettings.lua
local Settings = {
    read     = function(k, d) local v = store[k]; if v == nil then return d end; return v end,
    readBool = function(k, d) local v = store[k]; if v == nil then return d end; return v end,
    readNum  = function(k, d) local v = store[k]; if v == nil then return d end; return v end,
    save     = function(k, v) store[k] = v end,
    readWeekStart = function() return "monday" end,
    saveWeekStart = function(v) store.week_start = v end,
    weekStartWday = function() return 1 end,
}

local function load(name, ...) return assert(loadfile(name))(...) end

local VS    = load("lib/insights_settings.lua", { Prefs = Settings })
local Cache = load("lib/insights_cache.lua")
local Db    = load("lib/statsdb.lua")

local function check(label, got, want)
    local ok = (got == want)
    print(string.format("%-42s %-10s %s", label, tostring(got), ok and "ok" or ("EXPECTED " .. tostring(want))))
    assert(ok, label)
end

-- settings: defaults
check("full refresh default (false)",      VS.readFullRefreshSetting(), false)
check("8-week ascending default (true)",   VS.readAscendingSetting(), true)
check("weekly bar height default",         VS.readWeeklyBarHeightSetting(), 30)
check("auto bar height default (true)",    VS.Opt.readBarHeightAuto(), true)
check("reading goal section default (on)", VS.Opt.readShowReadingGoal(), true)
check("reading goal default",              VS.readReadingGoal(2026), 12)
check("heatmap months default",            VS.readHeatmapMonthsSetting(), 6)
check("heatmap hour format default",       VS.readHeatmapHourFormatSetting(), "24")
check("weekly chart mode default",         VS.normalizeWeeklyChartMode(nil), VS.WEEKLY_CHART_MODE_TIME)
check("insights mode normalize garbage",   VS.normalizeInsightsMode("nonsense"), VS.INSIGHTS_MODE_HOURS)

-- settings: round-trips
VS.saveReadingGoal(2026, 42);          check("reading goal round-trip", VS.readReadingGoal(2026), 42)
VS.Opt.saveBarHeightAuto(false);       check("auto off round-trip", VS.Opt.readBarHeightAuto(), false)
check("manual height used when auto off", VS.Opt.weeklyBarHeight(), 30)
VS.Opt.saveBarHeightAuto(true)
VS.Opt.auto_height = 77;               check("auto height used when auto on", VS.Opt.weeklyBarHeight(), 77)
check("both charts share that one height", VS.Opt.monthlyBarHeight(), 77)
VS.Opt.saveShowReadingGoal(false);     check("goal section off round-trip", VS.Opt.readShowReadingGoal(), false)
VS.saveFinishedOverrides(2026, { ["7"] = true })
check("finished overrides round-trip",  VS.readFinishedOverrides(2026)["7"], true)
check("invalid heatmap months -> default", (function() store["reading_insights_heatmap_months_per_period"] = 5; return VS.readHeatmapMonthsSetting() end)(), 6)

-- cache: minute cache + stale mirror
local c, stale = {}, {}
local minute = Cache.currentMinute()
check("cold miss",              Cache.getMinuteCache(c, "k", "k:minute", minute), nil)
Cache.setMinuteCache(c, stale, "k", "k:minute", minute, 123)
check("hit same minute",        Cache.getMinuteCache(c, "k", "k:minute", minute), 123)
check("miss next minute",       Cache.getMinuteCache(c, "k", "k:minute", minute + 1), nil)
check("stale copy kept",        stale["k"], 123)

-- cache: per-day base entries
local today = Cache.todayDateStr()
check("base entry hit",   Cache.getCachedBase({ b = Cache.makeCachedBase(today, "D") }, "b", today), "D")
check("base entry stale", Cache.getCachedBase({ b = Cache.makeCachedBase("1999-01-01", "D") }, "b", today), nil)

-- cache: prefix lookups pick the newest key
local sm = { ["books:2026:2026-01-01"] = "old", ["books:2026:2026-07-18"] = "new", ["books:2025:2025-01-01"] = "other" }
check("newest stale by prefix",  Cache.findStaleByPrefix(sm, "books:2026:"), "new")
check("session cache wins",      Cache.bestKnownFullResult({ x = "live" }, "x", sm, "books:2026:"), "live")
check("falls back to stale",     Cache.bestKnownFullResult({}, "x", sm, "books:2026:"), "new")

-- cache: goal state survives a disk round-trip, and clearAllCache wipes it
Cache._goal_finished_books["2026"] = { ["1"] = 111 }
Cache._goal_scan_watermark["2026"] = { time = 999, rows = 5 }
Cache._stale_cache.all_time = { hours = 3 }
Cache.saveDiskCache()
Cache.clearAllCache()
check("clearAllCache wipes goal list",  next(Cache._goal_finished_books), nil)
check("clearAllCache wipes stale",      Cache._stale_cache.all_time, nil)
Cache.loadDiskCache()
check("goal list restored from disk",   Cache._goal_finished_books["2026"]["1"], 111)
check("watermark restored (new shape)", Cache._goal_scan_watermark["2026"].time, 999)
check("stale restored from disk",       Cache._stale_cache.all_time.hours, 3)

-- statsdb: the new shared-connection wrappers
check("withShared uses shared conn",  Db.withShared({ tag = "conn" }, "fallback", function(c) return c.tag end), "conn")
check("withShared falls back to open", Db.withShared(nil, "fallback", function() return "unused" end), "fallback")
check("withConn nil conn -> fallback", Db.withConn(nil, "fallback", function() return "x" end), "fallback")
check("withConn swallows errors",      Db.withConn({}, "fallback", function() error("boom") end), "fallback")

print("\nALL MODULE TESTS PASSED")
