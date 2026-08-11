--[[
Reading Insights - weekly-streak week adjacency (lib/insights_data).

The weekly streak groups reading by SQLite's strftime('%Y-%W'): week 01
starts on the year's first Monday, and the days before it are week 00.
M.isConsecutiveWeek decides whether two such labels are neighbouring weeks,
and the New-Year boundary is the part with teeth - especially the years
whose Jan 1 is itself a Monday, where there is no week 00 at all and 52/53
connects straight to week 01.

Run from the plugin root: lua5.1 tests/test_streaks.lua
]]--

package.preload["optmath"] = function() return { round = function(x) return x end } end

local Data = assert(loadfile("lib/insights_data.lua"))({
    Locale  = { _ = function(s) return s end },
    StatsDb = {},
    Cache   = {},
    VS      = {},
    Manual  = {},
})

local pass = 0
local function check(label, got, want)
    print(string.format("%-56s %-7s %s", label, tostring(got), got == want and "ok" or ("EXPECTED " .. tostring(want))))
    assert(got == want, label)
    pass = pass + 1
end

local consec = Data.isConsecutiveWeek

-- Ordinary weeks within one year (prev is the newer label).
check("same year, adjacent",         consec("2025-05", "2025-04"), true)
check("same year, one-week gap",     consec("2025-05", "2025-03"), false)
check("same year, same week",        consec("2025-05", "2025-05"), false)

-- New Year, Jan 1 NOT a Monday (2025-01-01 is a Wednesday): the year opens
-- with a real week 00, so that is the link across the boundary.
check("Jan1=Wed: 52 -> 00 adjacent", consec("2025-00", "2024-52"), true)
check("Jan1=Wed: 00 -> 01 adjacent", consec("2025-01", "2025-00"), true)
-- ...and skipping that week 00 (52 straight to 01) is a genuine break.
check("Jan1=Wed: 52 -> 01 is a gap", consec("2025-01", "2024-52"), false)

-- New Year, Jan 1 IS a Monday (2024-01-01): no week 00 exists, the year
-- starts at week 01, so 52 of the old year connects directly to it. This is
-- the case the fix is about - it used to reset the streak here.
check("Jan1=Mon: 52 -> 01 adjacent", consec("2024-01", "2023-52"), true)
check("Jan1=Mon: 53 -> 01 adjacent", consec("2024-01", "2023-53"), true)
-- The week-01 boundary must still reject a non-final old-year week.
check("Jan1=Mon: 51 -> 01 is a gap", consec("2024-01", "2023-51"), false)

-- Malformed labels never count as a streak.
check("nil label",                   consec(nil, "2025-04"), false)
check("junk label",                  consec("2025-05", "garbage"), false)

-- End to end through computeStreaksWithDates, newest-first, no current week.
local never_current = function() return false end

-- Four weeks straddling the Jan1=Monday boundary form one run of 4.
local _, best4 = Data.computeStreaksWithDates(
    { "2024-02", "2024-01", "2023-52", "2023-51" }, consec, never_current)
check("Mon boundary: best run length", best4, 4)

-- Across a Jan1=Wed boundary with week 00 missing, the run breaks in two.
local _, best_gap = Data.computeStreaksWithDates(
    { "2025-01", "2024-52" }, consec, never_current)
check("Wed boundary, no week 00: broken", best_gap, 1)

-- With week 00 present it is one unbroken run of 3.
local _, best_full = Data.computeStreaksWithDates(
    { "2025-01", "2025-00", "2024-52" }, consec, never_current)
check("Wed boundary, week 00 present: whole", best_full, 3)

print(string.format("\nALL %d STREAK ASSERTIONS PASSED", pass))
