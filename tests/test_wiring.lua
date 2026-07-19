--[[
Reading Insights - loads every module the way main.lua does, with KOReader's
UI layer stubbed, and checks the wiring itself.

This is the test that catches a module receiving nil where it expected
another module: a renamed deps key, a load order that puts a module after
its user, an export that doesn't exist under the name its caller uses.

Run from the plugin root: lua5.1 tests/test_wiring.lua
]]--

local stub_meta = {}
stub_meta.__index = function(t, k)
    local v = setmetatable({}, stub_meta)
    rawset(t, k, v)
    return v
end
stub_meta.__call = function() return setmetatable({}, stub_meta) end
local function stub() return setmetatable({}, stub_meta) end

local widget_stub
widget_stub = setmetatable({
    new = function(self, o) o = o or {}; return setmetatable(o, { __index = widget_stub, __call = function() return {} end }) end,
    extend = function(self, o) o = o or {}; o.new = widget_stub.new; o.extend = widget_stub.extend; return o end,
    getSize = function() return { w = 10, h = 10 } end,
    free = function() end,
}, stub_meta)

local names = {
  "ffi/blitbuffer","ffi/util","datastorage","logger","luasettings","device","ui/size","ui/geometry",
  "ui/font","ui/uimanager","ui/gesturerange","ui/widget/widget","ui/widget/textwidget",
  "ui/widget/textboxwidget","ui/widget/horizontalgroup","ui/widget/verticalgroup",
  "ui/widget/horizontalspan","ui/widget/verticalspan","ui/widget/linewidget","ui/widget/titlebar",
  "ui/widget/infomessage","ui/widget/overlapgroup","ui/widget/container/framecontainer",
  "ui/widget/container/centercontainer","ui/widget/container/leftcontainer",
  "ui/widget/container/bottomcontainer","ui/widget/container/inputcontainer",
  "ui/widget/container/widgetcontainer","gettext","ui/trapper","socket","socket/http","ltn12",
  "lua-ljsqlite3/init","libs/libkoreader-lfs","ui/screensaver","apps/reader/modules/readerui",
  "ui/widget/buttondialog","ui/widget/confirmbox","ui/widget/spinwidget","ui/widget/menu",
  "ui/widget/checkbutton","ui/widget/inputdialog","ui/widget/keyvaluepage","ui/quickstart","optmath","ffi","ffi/blitbuffer_h","ui/widget/imagewidget","ui/widget/progresswidget","ui/widget/iconwidget","ui/widget/closebutton","ui/rendertext","ui/bidi","ui/widget/scrollablecontainer","ui/widget/container/rightcontainer","ui/widget/frontlightwidget","ui/network/manager","ui/widget/notification",
}
for _, n in ipairs(names) do
  package.preload[n] = function()
    if n == "ffi/util" then return { template = function(s) return s end, realpath = function(p) return p end } end
    if n == "datastorage" then return { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end } end
    if n == "logger" then return { warn = function() end, info = function() end, dbg = function() end, err = function() end } end
    if n == "luasettings" then
      local LS = {}; LS.__index = LS
      local files = {}
      function LS:open(p) files[p] = files[p] or {}; return setmetatable({ data = files[p] }, LS) end
      function LS:readSetting(k) return self.data[k] end
      function LS:saveSetting(k, v) self.data[k] = v end
      function LS:flush() end
      return LS
    end
    if n == "device" then
      return { screen = setmetatable({ getWidth = function() return 1072 end, getHeight = function() return 1448 end,
                                       scaleBySize = function(_, x) return math.floor((x or 0) * 1.4) end }, stub_meta),
               isTouchDevice = function() return true end, hasKeys = function() return false end,
               hasFrontlight = function() return false end, isAndroid = function() return false end }
    end
    if n == "optmath" then return { round = function(x) return math.floor((x or 0)+0.5) end } end
    if n == "ui/size" then
      return { padding = { small = 2, default = 4, large = 8 }, line = { thin = 1, medium = 2, thick = 3 },
               border = { default = 1 }, span = { horizontal_default = 4 } }
    end
    if n == "ui/geometry" then return { new = function(_, o) return o or {} end } end
    if n == "gettext" then return setmetatable({ getText = function(_, s) return s end }, { __call = function(_, s) return s end }) end
    if n:match("^ui/widget") or n == "ui/widget/widget" then return widget_stub end
    return stub()
  end
end
-- A G_reader_settings that actually stores what it is given, so settings
-- round-trips behave the way they do on device.
local prefs_store = {}
_G.G_reader_settings = {
    readSetting = function(_, k, d) local v = prefs_store[k]; if v == nil then return d end; return v end,
    saveSetting = function(_, k, v) prefs_store[k] = v end,
    delSetting  = function(_, k) prefs_store[k] = nil end,
    isTrue      = function(_, k) return prefs_store[k] == true end,
    nilOrTrue   = function(_, k) return prefs_store[k] == nil or prefs_store[k] == true end,
    has         = function(_, k) return prefs_store[k] ~= nil end,
}

-- Catch-all: any KOReader module not explicitly stubbed above resolves to a
-- permissive stub, so the wiring test doesn't need the whole UI toolkit
-- enumerated by hand.
local real_require = require
require = function(n)
    local ok, mod = pcall(real_require, n)
    if ok then return mod end
    if n:match("widget") or n:match("^ui/") then return widget_stub end
    return stub()
end

local PluginUtil = assert(loadfile("pluginutil.lua"))()
local function load(path, deps) return assert(loadfile(path))(deps) end

local Prefs        = load("lib/prefs.lua")
local StatsDb      = load("lib/statsdb.lua")
local PopupUtil    = load("lib/popuputil.lua")
local BookProgress = load("lib/bookprogress.lua")
local ChapterInfo  = load("lib/chapterinfo.lua")
local BookStatsData    = load("lib/book_stats_data.lua",    { StatsDb = StatsDb })
local BookCalendarData = load("lib/book_calendar_data.lua", { StatsDb = StatsDb })
local Locale = load("lib/locale.lua", { PluginUtil = PluginUtil })
local Colors = load("lib/colors.lua", { Locale = Locale, PluginUtil = PluginUtil, Prefs = Prefs })
local Fonts  = load("lib/fonts.lua",  { Locale = Locale, PluginUtil = PluginUtil, Prefs = Prefs })
local UI     = load("lib/uikit.lua",  { Colors = Colors })
local ViewSettings  = load("lib/insights_settings.lua", { Prefs = Prefs })
local InsightsCache = load("lib/insights_cache.lua")
local ChapterBar = load("widgets/chapterbarwidget.lua", { Colors = Colors, Fonts = Fonts, UI = UI })
local InsightsData = load("lib/insights_data.lua",
    { Locale = Locale, StatsDb = StatsDb, Cache = InsightsCache, VS = ViewSettings })
local Trend   = load("views/trend_view.lua",   { Colors = Colors, Locale = Locale, VS = ViewSettings })
local Heatmap = load("views/heatmap_view.lua", { Colors = Colors, Fonts = Fonts,
    Locale = Locale, VS = ViewSettings, UI = UI, Data = InsightsData })
local BookList = load("views/booklist_view.lua",
    { Colors = Colors, Locale = Locale, VS = ViewSettings, UI = UI, Data = InsightsData })
local Menu    = load("lib/menu.lua", { Locale = Locale })

-- The three view files themselves. Loading these exercises the bind() calls
-- insights_view.lua makes at load time, and every top-level statement in the
-- biggest files in the plugin.
local Insights = load("views/insights_view.lua", {
    Locale = Locale, Colors = Colors, Fonts = Fonts,
    PopupUtil = PopupUtil, VS = ViewSettings, Cache = InsightsCache, UI = UI,
    Trend = Trend, Heatmap = Heatmap, BookList = BookList, Data = InsightsData,
})
local BookCalendar = load("views/book_calendar_view.lua", {
    Locale = Locale, Colors = Colors, Fonts = Fonts, Prefs = Prefs,
    BookProgress = BookProgress, UI = UI, CalendarData = BookCalendarData,
})
local StatsPopup = load("views/book_stats_view.lua", {
    Locale = Locale, Colors = Colors, Fonts = Fonts, Prefs = Prefs,
    BookProgress = BookProgress, BookCalendar = BookCalendar,
    ChapterInfo = ChapterInfo, ChapterBar = ChapterBar, UI = UI,
    BookStatsData = BookStatsData,
})
local RecordsData = load("lib/records_data.lua", { StatsDb = StatsDb })
local Records = load("views/records_view.lua", {
    Locale = Locale, Colors = Colors, Fonts = Fonts, PopupUtil = PopupUtil,
    RecordsData = RecordsData,
})
-- updater.lua uses `goto continue`, which LuaJIT (KOReader) accepts but
-- plain Lua 5.1 doesn't parse, so it is stubbed rather than loaded here.
local Updater = { checkForUpdates = function() end }
local About   = load("views/about.lua", { Locale = Locale, Updater = Updater, PopupUtil = PopupUtil })

local function check(label, cond)
    print(string.format("%-52s %s", label, cond and "ok" or "FAILED"))
    assert(cond, label)
end

check("all modules load without error", true)
check("uikit exports the layout helpers", type(UI.buildLayout) == "function")
check("uikit exports the merged row helpers",
      type(UI.buildTwoColRow) == "function" and type(UI.addSectionWithRow) == "function")
check("trend exposes Popup + chart builders",
      Trend.Popup ~= nil and type(Trend.buildLine8WeekChart) == "function"
      and type(Trend.trendTitle) == "function" and type(Trend.totalForMetric) == "function")
check("heatmap exposes Popup, builders and bind",
      Heatmap.Popup ~= nil and type(Heatmap.bind) == "function"
      and type(Heatmap.buildRangeHeatmapWidget) == "function"
      and type(Heatmap.getHeatmapPeriodRange) == "function")
check("booklist exposes Checklist, lists and bind",
      BookList.Checklist ~= nil and type(BookList.bind) == "function"
      and type(BookList.showBooksForPeriod) == "function")
check("chapter bar exposes build + settings",
      type(ChapterBar.build) == "function" and type(ChapterBar.readHeightSetting) == "function"
      and ChapterBar.PAGE_SIZE == 25)
check("menu exposes build", type(Menu.build) == "function")
check("insights data exposes its queries and batch helper",
      type(InsightsData.withBatchConnection) == "function"
      and type(InsightsData.getBooksForPeriod) == "function"
      and type(InsightsData.getAllBooks) == "function")
check("insights data exposes its queries",
      type(InsightsData.getYearlyStats) == "function"
      and type(InsightsData.calculateStreaks) == "function"
      and type(InsightsData.getFinishedBookCountForYear) == "function"
      and type(InsightsData.getLastWeekAll) == "function")
check("book data modules expose their queries",
      type(BookStatsData.getBookAndTodayStats) == "function"
      and type(BookCalendarData.getBookDailyStatsForMonth) == "function"
      and type(BookCalendarData.bookCalendarMonthHasData) == "function")
check("records data exposes load + milestones",
      type(RecordsData.load) == "function" and type(RecordsData.getMilestones) == "function")
check("insights settings reachable through Prefs key", ViewSettings.readReadingGoal(2026) ~= nil)
check("insights cache seeded itself from disk", type(InsightsCache._goal_finished_books) == "table")
check("chapterinfo + bookprogress + statsdb load",
      type(ChapterInfo.getCachedChapterInfo) == "function" and BookProgress ~= nil
      and type(StatsDb.withShared) == "function")
check("popuputil loads", PopupUtil ~= nil)

-- bind() wiring: the calls insights_view.lua makes at load time
Heatmap.bind{ getCachedFonts = function() return {} end, parseDateYMD = function() return 2026, 1, 1 end }
BookList.bind{ popup_class = {}, getCachedFonts = function() return {} end,
               getCachedLayout = function() return {} end,
               getFinishedBooksForYear = function() return {} end,
               formatHHMMSS = function() return "" end }
check("bind() accepted by both modules", true)
check("every view loads and exports its popup",
      Insights.Popup ~= nil and BookCalendar ~= nil and StatsPopup ~= nil
      and Records ~= nil and About ~= nil and Updater ~= nil)

-- auto bar height: one shared value for both charts
ViewSettings.Opt.auto_height = 42
check("both charts get the identical auto height",
      ViewSettings.Opt.weeklyBarHeight() == ViewSettings.Opt.monthlyBarHeight()
      and ViewSettings.Opt.weeklyBarHeight() == 42)
ViewSettings.Opt.saveBarHeightAuto(false)
check("manual mode still uses the two separate settings",
      ViewSettings.Opt.weeklyBarHeight() == ViewSettings.readWeeklyBarHeightSetting())
ViewSettings.Opt.saveBarHeightAuto(true)


-- The streak popup builds its two columns by asking uikit for a layout of a
-- width it derived from the columns themselves; that round-trip has to give
-- the column width back unchanged, or the popup would drift wider or
-- narrower every time it is opened.
local Size = require("ui/size")
local gap = 8
for _, col in ipairs{ 120, 233, 480 } do
    local full = 2 * col + 2 * gap + Size.line.medium
    local lay = UI.buildLayout(full, 0, gap)
    check("layout round-trip keeps col_width " .. col, lay.col_width == col)
    check("layout content width matches for " .. col, lay.content_width == full)
end

print("\nALL WIRING TESTS PASSED")
