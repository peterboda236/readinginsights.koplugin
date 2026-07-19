--[[
Reading Insights - lib/insights_data's day-bounds helper.

The queries that used to filter with date(start_time,'localtime') now use a
plain start_time range so SQLite can use its index, which moves the
local-midnight arithmetic from SQLite into Lua. This checks that arithmetic
against the cases that break naive implementations: the two days a year that
are 23 or 25 hours long, month and year boundaries, and a leap day.

Run from the plugin root, ideally under a DST-observing timezone:
    TZ=Europe/Budapest lua5.1 tests/test_daybounds.lua
]]--

-- Verifies M.dayBounds: the [lo, hi) range must cover exactly one local
-- calendar day, including the days a DST change makes 23 or 25 hours long.
package.preload["optmath"] = function()
    return { round = function(x) return math.floor((x or 0) + 0.5) end }
end

local StatsDb = { withDb = function(fb) return fb end, withShared = function(_, fb) return fb end,
                  withStatement = function() end }
local Data = assert(loadfile("lib/insights_data.lua"))({
    Locale = { _ = function(s) return s end, N_ = function(a) return a end,
               formatNumber = tostring, formatCount = tostring, getLangBase = function() return "en" end },
    StatsDb = StatsDb, Cache = { ENABLE_CACHE = false }, VS = {},
})

local fails = 0
local function check(label, cond)
    if not cond then fails = fails + 1; print("  FAIL  " .. label) else print("  ok    " .. label) end
end

local dates = {
    "2026-01-01", "2026-02-28", "2026-06-15", "2026-12-31",
    "2026-03-29",  -- CET -> CEST in Europe/Budapest: a 23-hour day
    "2026-10-25",  -- CEST -> CET: a 25-hour day
    "2024-02-29",  -- leap day
}
for _, d in ipairs(dates) do
    local lo, hi = Data.dayBounds(d)
    check(d .. ": lo is that day's midnight",
          os.date("%Y-%m-%d %H:%M:%S", lo) == d .. " 00:00:00")
    check(d .. ": last second still that day",
          os.date("%Y-%m-%d", hi - 1) == d)
    check(d .. ": hi is the next day's midnight",
          os.date("%H:%M:%S", hi) == "00:00:00" and os.date("%Y-%m-%d", hi) ~= d)
end

local lo, hi = Data.dayBounds("2026-03-29")
check("DST spring day is 23 hours", (hi - lo) == 23 * 3600)
lo, hi = Data.dayBounds("2026-10-25")
check("DST autumn day is 25 hours", (hi - lo) == 25 * 3600)
lo, hi = Data.dayBounds("2026-06-15")
check("ordinary day is 24 hours", (hi - lo) == 24 * 3600)
check("garbage input returns nil", Data.dayBounds("not-a-date") == nil)

print(fails == 0 and "\nALL DAY-BOUNDS TESTS PASSED" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
