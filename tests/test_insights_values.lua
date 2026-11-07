--[[
Reading Insights - lib/insights_values, the values the Reading insights
popup shows in both looks (Classic and Cards).

Covers the year row in each mode (days of the year so far vs. a whole leap
year), the average-pages rounding, the week figures, the daily / weekly time
goal against either first day of the week, the reading goal's percentage and
pace, the streak and all-time texts, and the empty-data fallbacks.

The date is pinned to Saturday 2026-11-07 (day 311 of the year), and Locale
is a plain stand-in, so the texts are the module's own and not KOReader's
duration format.

Run from the plugin root: lua5.1 tests/test_insights_values.lua
]]--

local real_date = os.date
local NOW = os.time{ year = 2026, month = 11, day = 7, hour = 12 }
os.date = function(fmt, t) return real_date(fmt, t or NOW) end

local function hm(secs)
    secs = math.floor(secs + 0.5)
    return string.format("%d:%02d", math.floor(secs / 3600), math.floor(secs % 3600 / 60))
end
local Locale = {
    _  = function(s) return s end,
    N_ = function(s, p, n) return n == 1 and s or p end,
    formatCount  = function(n) return tostring(n) end,
    formatNumber = function(n, d) return string.format("%." .. d .. "f", n) end,
    splitDurationValueUnit = function(secs, label) return hm(secs), label end,
    formatDuration = function(secs) return hm(secs) end,
}
local VS = {
    INSIGHTS_MODE_HOURS = "hours", INSIGHTS_MODE_PAGES = "pages", INSIGHTS_MODE_BOOKS = "books",
    readDailyGoalMinutes  = function() return 30 end,
    readWeeklyGoalMinutes = function() return 300 end,
}
local V = assert(loadfile("lib/insights_values.lua"))({ Locale = Locale, VS = VS })

local function check(label, got, want)
    local ok = got == want
    print(string.format("%-46s %-24s %s", label, tostring(got), ok and "ok" or ("EXPECTED " .. tostring(want))))
    assert(ok, label)
end
local function pack(...) return { ... } end

-- Streaks -----------------------------------------------------------------
local s = pack(V.streakValues({ current_days = 1, current_weeks = 3, best_days = 21, best_weeks = 2 }))
check("streak < 2 days -> no number", s[1], "")
check("...and 'No streak'", s[2], "No streak")
check("3 weeks", s[3] .. " " .. s[4], "3 weeks")
check("best 21 days", s[5] .. " " .. s[6], "21 days")
check("best 2 weeks", s[7] .. " " .. s[8], "2 weeks")

-- Year row ----------------------------------------------------------------
local y = pack(V.yearlyValues(2024, "hours", { duration = 366 * 3600 }))
check("leap year: total time", y[1], "366:00")
check("leap year: daily avg over 366 days", y[3], "1:00")
y = pack(V.yearlyValues(2026, "pages", { pages = 3110 }))
check("this year: pages read", y[1] .. " " .. y[2], "3110 pages read")
check("this year: avg over day 311 (>= 10 whole)", y[3], "10")
y = pack(V.yearlyValues(2026, "pages", { pages = 1000 }))
check("avg below 10 -> one decimal", y[3], "3.2")
y = pack(V.yearlyValues(nil, "pages", { pages = 311 }))
check("nil year = this year", y[3] .. " " .. y[4], "1 daily avg page")
y = pack(V.yearlyValues(2025, "books", { books_started = 1, avg_days_per_book = 9 }))
check("books mode", y[1] .. " " .. y[2] .. " | " .. y[3] .. " " .. y[4], "1 book | 9 days/book avg")
y = pack(V.yearlyValues(2025, "days", { days = 73 }))
check("days mode: % of 365", y[3] .. " " .. y[4], "20% of days read")

-- Average pages -------------------------------------------------------------
check("round 12.6 -> 13", V.roundAvgPages(12.6), 13)
check("round 7.26 -> 7.3", V.roundAvgPages(7.26), 7.3)
check("format whole number without decimal", V.formatAvgPages(7), "7")
check("format 7.3", V.formatAvgPages(7.3), "7.3")

-- Week --------------------------------------------------------------------
local lw, daily, has = V.weekData(false, nil, nil, nil)
check("rolling week, no data -> hidden", has, false)
check("...with zero averages", lw.avg_seconds, 0)
lw, daily, has = V.weekData(true, nil, nil, nil)
check("calendar week is always shown", has, true)
check("...empty calendar week has 7 days", lw.days, 7)
local cal = { stats = { avg_seconds = 60, avg_pages = 1, total_seconds = 300, total_pages = 5, days = 5 }, daily = { 1 } }
lw, daily, has = V.weekData(true, cal, nil, nil)
check("calendar week uses its own stats", lw.total_seconds, 300)
check("...and its own days", #daily, 1)
local w = pack(V.weekValues({ avg_seconds = 1200, avg_pages = 7.26, total_seconds = 8400, total_pages = 50.6 }))
check("week total seconds", w[1], 8400)
check("week total pages rounded", w[2], 51)
check("time cells", table.concat(w[3], "|"), "2:20|reading time|time_total|0:20|daily avg time|time_avg")
check("pages cells", table.concat(w[4], "|"), "51|pages read|pages_total|7.3|daily avg pages|pages_avg")
w = pack(V.weekValues({ avg_seconds = 600, avg_pages = 12 }))
check("no totals -> 7 x the average", w[1] .. " / " .. w[2], "4200 / 84")

-- Time goals --------------------------------------------------------------
local days = {}
for i = 1, 7 do days[i] = { seconds = 600 * i } end   -- today first
local g = pack(V.timeGoalValues(days, 1))
check("today", g[1], 600)
check("week from Monday: 6 days on a Saturday", g[2], 600 * (1 + 2 + 3 + 4 + 5 + 6))
check("goals in seconds", g[3] .. " / " .. g[4], "1800 / 18000")
g = pack(V.timeGoalValues(days, 0))
check("week from Sunday: all 7 days", g[2], 600 * 28)
g = pack(V.timeGoalValues(nil, nil))
check("no data -> 0 / 0", g[1] .. " / " .. g[2], "0 / 0")
check("goal text", V.timeGoalText(600, 1800), "0:10 / 0:30")
check("goal met -> check mark", V.timeGoalText(1800, 1800):sub(-3), "\226\156\147")

-- Reading goal ------------------------------------------------------------
check("percent", V.goalPercent(12, 30), 40)
check("percent above 100 is kept", V.goalPercent(35, 30), 117)
check("no goal -> 0%", V.goalPercent(5, 0), 0)
check("past year reached", V.goalPace(30, 30, 2025), "reached")
check("past year not reached", V.goalPace(10, 30, 2025), "not_reached")
check("future year -> nil", V.goalPace(0, 30, 2027), nil)
check("no goal -> nil", V.goalPace(3, 0, 2026), nil)
-- goal 365 on day 311 of a 365-day year: 311 books expected so far
check("on track", V.goalPace(311, 365, 2026), "on_track")
local st, n = V.goalPace(300, 365, 2026)
check("behind", st .. " " .. n, "behind 11")
st, n = V.goalPace(320, 365, 2026)
check("ahead", st .. " " .. n, "ahead 9")
check("goal reached this year", V.goalPace(365, 365, 2026), "reached")

-- All time ----------------------------------------------------------------
local a = pack(V.allTimeValues({ duration = 5400, hours = 9, pages = 1 }))
check("exact duration wins over hours", a[1], "1:30")
check("1 page read", a[3] .. " " .. a[4], "1 page read")
a = pack(V.allTimeValues({ hours = 2, pages = 978 }))
check("hours when the duration is missing", a[1], "2:00")
a = pack(V.allTimeValues(nil))
check("no data", a[1] .. " | " .. a[3] .. " " .. a[4], "0:00 | 0 pages read")

os.date = real_date
print("\nALL INSIGHTS VALUES TESTS PASSED")
