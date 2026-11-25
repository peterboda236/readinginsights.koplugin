--[[
Reading Insights - lib/achievements: the goal-based checks built from each
entry's metric/goal, and the progress of the still-locked ones that
recompute() keeps for the list.

Run from the plugin root: lua5.1 tests/test_achievements.lua
]]--

local files = {}
package.preload["readinginsights_paths"] = function()
    return { dataFile = function(name) return "/tmp/ach/" .. name end }
end
package.preload["luasettings"] = function()
    local LS = {}; LS.__index = LS
    function LS:open(p) files[p] = files[p] or {}; return setmetatable({ data = files[p] }, LS) end
    function LS:readSetting(k) return self.data[k] end
    function LS:saveSetting(k, v) self.data[k] = v end
    function LS:flush() end
    return LS
end
package.preload["logger"] = function()
    return { warn = function() end, info = function() end, dbg = function() end }
end

local fp = { 100, 7 }
local StatsDb = {
    withDb = function() return { fp[1], fp[2] } end,
}
local Locale = { _ = function(s) return s end }

local Achievements = assert(loadfile("lib/achievements.lua"))({
    StatsDb = StatsDb, RecordsData = {}, Data = {}, Locale = Locale, DateUtil = {},
})

local failed = 0
local function check(label, cond)
    print(string.format("%-60s %s", label, cond and "ok" or "FAIL"))
    if not cond then failed = failed + 1 end
end

local function byId(id)
    for _idx, a in ipairs(Achievements.CATALOGUE) do
        if a.id == id then return a end
    end
end

-- Catalogue ------------------------------------------------------------
local n_goal, all_built = 0, true
for _idx, a in ipairs(Achievements.CATALOGUE) do
    if a.metric then
        n_goal = n_goal + 1
        if type(a.goal) ~= "number" or type(a.check) ~= "function" then all_built = false end
    elseif type(a.check) ~= "function" then
        all_built = false
    end
end
check("every entry has a check", all_built)
check("goal-based entries exist", n_goal > 0)

local pages = byId("pages_total_1000")
check("pages_total_1000 reads total_pages towards 1000",
      pages.metric == "total_pages" and pages.goal == 1000)
check("one below the goal is not earned", not pages.check({ total_pages = 999 }))
check("the goal itself is earned", pages.check({ total_pages = 1000 }))
check("a missing metric counts as 0", not pages.check({}))

local used = {}
for _idx, a in ipairs(Achievements.CATALOGUE) do
    if a.metric then used[a.metric] = true end
end
local units_ok = true
for metric in pairs(Achievements.METRIC_SECONDS) do
    if not used[metric] then units_ok = false end
end
check("every duration unit belongs to a catalogue metric", units_ok)

-- recompute() keeps the locked ones' progress --------------------------
Achievements.computeMetrics = function()
    return { total_pages = 5000, total_hours = 2.5 }
end
Achievements.findEarnDates = function() return {} end
Achievements.recompute()

local earned = Achievements.getEarned()
check("pages_total_1000 earned at 5000 pages", earned.pages_total_1000 ~= nil)
check("pages_total_10000 still locked", earned.pages_total_10000 == nil)

local items = {}
for _idx, it in ipairs(Achievements.list()) do items[it.def.id] = it end
check("locked pages_total_10000 has progress 5000", items.pages_total_10000.progress == 5000)
check("locked hours_5 has progress 2.5", items.hours_5.progress == 2.5)
check("earned pages_total_1000 has no progress", items.pages_total_1000.progress == nil)
check("a yes/no achievement has no progress",
      byId("finished_same_day").metric == nil and items.finished_same_day.progress == nil)

-- refreshIfChanged(): a file without progress gets one full run --------
local store = files["/tmp/ach/achievements.lua"]
check("daily refresh skips when evaluated today",
      Achievements.refreshIfChanged("daily") == false)
store.progress = nil
check("a file without progress is re-evaluated", Achievements.refreshIfChanged("daily") == true)
check("...and has progress afterwards", type(store.progress) == "table")
check("then it is skipped again", Achievements.refreshIfChanged("daily") == false)

if failed > 0 then
    print("\n" .. failed .. " ACHIEVEMENTS TEST(S) FAILED")
    os.exit(1)
end
print("\nALL ACHIEVEMENTS TESTS PASSED")
