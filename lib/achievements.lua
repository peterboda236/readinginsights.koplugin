--[[
Reading Insights - reading achievements (global, shared across all years).

The list of earned achievements shows up next to the reading goal section in
an "N earned" cell, and in a separate list popup (earned ones on top, sorted
by earn time descending; the remaining locked ones below, in gray).

Persistence: earned achievements live in their own file in the KOReader
settings folder, mirroring manual_books.lua's approach
(reading_insights_achievements.lua), shaped as { [id] = earned_unix_time }.
Once earned, an achievement is read from that file from then on - a normal
popup open only reads the count (cheap, file-only). The actual evaluation
(with the DB queries) only runs when the full data is reloaded: on a long
press of the title bar (the Cache.clearAllCache path), or as a one-time
bootstrap if the file has never been created yet.

Achievements can never be "un-earned": if an underlying number later drops
(a deleted book, a DB copied/merged in from another device), an already
earned achievement stays earned.

  Achievements.CATALOGUE          the definitions (order = locked display order)
  Achievements.getEarned()        { [id] = ts } from the file
  Achievements.earnedCount()      how many catalogue achievements are earned
  Achievements.list()             the list popup's rows: earned ones (sorted
                                  by ts descending) first, locked ones after
  Achievements.recompute()        fresh evaluation from the DB + persistence;
                                  returns the current count
  Achievements.refreshIfChanged() cheap, conditional evaluation: only runs a
                                  full recompute if the data has changed
                                  since the last evaluation (one lightweight
                                  fingerprint query per open)
]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local StatsDb, RecordsData, Data, Locale =
    deps.StatsDb, deps.RecordsData, deps.Data, deps.Locale
local _ = Locale._

local M = {}

local STORE_PATH = DataStorage:getSettingsDir() .. "/reading_insights_achievements.lua"

-- The achievement catalogue. Every entry:
--   id     stable key, this is what goes into the file - once shipped,
--          NEVER rename/renumber it, or the previously earned entry becomes
--          "orphaned" and the user appears to lose it
--   icon   the glyph shown at the start of the row. Deliberately a plain
--          BMP Unicode symbol (geometric shape / card suit / star / arrow),
--          not an emoji: colored emoji either don't render on e-ink or show
--          up as boxes, whereas these come through fine from the
--          NotoSans/NotoSansSymbols font set. Every achievement has its own
--          unique glyph.
--   title  short name (translatable)
--   desc   one-line description of the condition (translatable)
--   check  function(metrics) -> boolean, given the table from M.computeMetrics()
-- The order here is the LOCKED display order; the list re-sorts earned ones
-- by earn time.
M.CATALOGUE = {
    -- Finished books (count, total) --------------------------------------
    { id = "first_book",     icon = "★", title = _("First book"),
      desc = _("Finish your first book"),
      check = function(m) return m.finished_books >= 1 end },
    { id = "books_5",        icon = "☆", title = _("Five books"),
      desc = _("Finish 5 books"),
      check = function(m) return m.finished_books >= 5 end },
    { id = "bookworm_10",    icon = "✩", title = _("Bookworm"),
      desc = _("Finish 10 books"),
      check = function(m) return m.finished_books >= 10 end },
    { id = "books_25",       icon = "✪", title = _("Collector"),
      desc = _("Finish 25 books"),
      check = function(m) return m.finished_books >= 25 end },
    { id = "bibliophile_50", icon = "✫", title = _("Bibliophile"),
      desc = _("Finish 50 books"),
      check = function(m) return m.finished_books >= 50 end },
    { id = "books_100",      icon = "✬", title = _("Century of books"),
      desc = _("Finish 100 books"),
      check = function(m) return m.finished_books >= 100 end },
    { id = "books_250",      icon = "✭", title = _("Library"),
      desc = _("Finish 250 books"),
      check = function(m) return m.finished_books >= 250 end },
    -- Finished books (time-bound / other) --------------------------------
    { id = "finished_month_3", icon = "✮", title = _("Prolific month"),
      desc = _("Finish 3 books in one calendar month"),
      check = function(m) return m.finished_max_month >= 3 end },
    { id = "finished_year_10", icon = "✯", title = _("Ten a year"),
      desc = _("Finish 10 books in one year"),
      check = function(m) return m.finished_max_year >= 10 end },
    { id = "finished_year_50", icon = "❂", title = _("Fifty a year"),
      desc = _("Finish 50 books in one year"),
      check = function(m) return m.finished_max_year >= 50 end },
    { id = "finished_same_day", icon = "✓", title = _("In one sitting"),
      desc = _("Finish a book on the day you started it"),
      check = function(m) return m.finished_same_day end },
    { id = "long_book_500",  icon = "▮", title = _("Brick"),
      desc = _("Finish a book of 500+ pages"),
      check = function(m) return m.finished_book_max_pages >= 500 end },
    { id = "long_book_1000", icon = "▬", title = _("Tome"),
      desc = _("Finish a book of 1000+ pages"),
      check = function(m) return m.finished_book_max_pages >= 1000 end },

    -- Reading time (total) - the Records milestone ladder -----------------
    { id = "hours_1",     icon = "○", title = _("First hour"),
      desc = _("Read for 1 hour in total"),
      check = function(m) return m.total_hours >= 1 end },
    { id = "hours_5",     icon = "◔", title = _("Five hours"),
      desc = _("Read for 5 hours in total"),
      check = function(m) return m.total_hours >= 5 end },
    { id = "hours_10",    icon = "◑", title = _("Ten hours"),
      desc = _("Read for 10 hours in total"),
      check = function(m) return m.total_hours >= 10 end },
    { id = "hours_25",    icon = "◕", title = _("Twenty-five hours"),
      desc = _("Read for 25 hours in total"),
      check = function(m) return m.total_hours >= 25 end },
    { id = "hours_50",    icon = "●", title = _("Fifty hours"),
      desc = _("Read for 50 hours in total"),
      check = function(m) return m.total_hours >= 50 end },
    { id = "hours_100",   icon = "◉", title = _("100 hours"),
      desc = _("Read for 100 hours in total"),
      check = function(m) return m.total_hours >= 100 end },
    { id = "hours_250",   icon = "◎", title = _("250 hours"),
      desc = _("Read for 250 hours in total"),
      check = function(m) return m.total_hours >= 250 end },
    { id = "hours_500",   icon = "⊙", title = _("500 hours"),
      desc = _("Read for 500 hours in total"),
      check = function(m) return m.total_hours >= 500 end },
    { id = "hours_1000",  icon = "⊕", title = _("1000 hours"),
      desc = _("Read for 1000 hours in total"),
      check = function(m) return m.total_hours >= 1000 end },
    { id = "hours_2500",  icon = "⊗", title = _("2500 hours"),
      desc = _("Read for 2500 hours in total"),
      check = function(m) return m.total_hours >= 2500 end },
    { id = "hours_5000",  icon = "◆", title = _("5000 hours"),
      desc = _("Read for 5000 hours in total"),
      check = function(m) return m.total_hours >= 5000 end },
    { id = "hours_10000", icon = "◈", title = _("10000 hours"),
      desc = _("Read for 10000 hours in total"),
      check = function(m) return m.total_hours >= 10000 end },
    -- Reading time (time-bound) -------------------------------------------
    { id = "hours_month_50", icon = "◇", title = _("Intense month"),
      desc = _("Read for 50 hours in one calendar month"),
      check = function(m) return m.hours_max_month >= 50 end },
    { id = "hours_year_100", icon = "❖", title = _("100 hours in a year"),
      desc = _("Read for 100 hours in one year"),
      check = function(m) return m.hours_max_year >= 100 end },
    { id = "hours_year_500", icon = "▣", title = _("500 hours in a year"),
      desc = _("Read for 500 hours in one year"),
      check = function(m) return m.hours_max_year >= 500 end },

    -- Pages (total) --------------------------------------------------------
    { id = "pages_total_1000",   icon = "▤", title = _("1000 pages"),
      desc = _("Read 1000 pages in total"),
      check = function(m) return m.total_pages >= 1000 end },
    { id = "pages_total_10000",  icon = "▦", title = _("10000 pages"),
      desc = _("Read 10000 pages in total"),
      check = function(m) return m.total_pages >= 10000 end },
    { id = "pages_total_50000",  icon = "▩", title = _("50000 pages"),
      desc = _("Read 50000 pages in total"),
      check = function(m) return m.total_pages >= 50000 end },
    { id = "pages_total_100000", icon = "▧", title = _("100000 pages"),
      desc = _("Read 100000 pages in total"),
      check = function(m) return m.total_pages >= 100000 end },
    -- Pages (single day) ----------------------------------------------------
    { id = "pages_300",  icon = "△", title = _("Page turner"),
      desc = _("Read 300 pages in a single day"),
      check = function(m) return m.max_day_pages >= 300 end },
    { id = "pages_500",  icon = "▲", title = _("Devourer"),
      desc = _("Read 500 pages in a single day"),
      check = function(m) return m.max_day_pages >= 500 end },
    { id = "pages_1000", icon = "▼", title = _("Unstoppable"),
      desc = _("Read 1000 pages in a single day"),
      check = function(m) return m.max_day_pages >= 1000 end },

    -- Daily streaks ---------------------------------------------------------
    { id = "streak_3",   icon = "▷", title = _("Getting into it"),
      desc = _("Read on 3 days in a row"),
      check = function(m) return m.best_streak_days >= 3 end },
    { id = "streak_7",   icon = "▶", title = _("Weekly streak"),
      desc = _("Read on 7 days in a row"),
      check = function(m) return m.best_streak_days >= 7 end },
    { id = "streak_14",  icon = "◀", title = _("Two weeks"),
      desc = _("Read on 14 days in a row"),
      check = function(m) return m.best_streak_days >= 14 end },
    { id = "streak_30",  icon = "◁", title = _("Monthly streak"),
      desc = _("Read on 30 days in a row"),
      check = function(m) return m.best_streak_days >= 30 end },
    { id = "streak_100", icon = "➤", title = _("Hundred-day streak"),
      desc = _("Read on 100 days in a row"),
      check = function(m) return m.best_streak_days >= 100 end },
    { id = "streak_365", icon = "➜", title = _("A full year"),
      desc = _("Read on 365 days in a row"),
      check = function(m) return m.best_streak_days >= 365 end },
    -- Weekly streaks / persistence -------------------------------------------
    { id = "weekly_4",   icon = "♪", title = _("Monthly rhythm"),
      desc = _("A 4-week reading streak"),
      check = function(m) return m.best_weekly_streak >= 4 end },
    { id = "weekly_12",  icon = "♫", title = _("Quarter"),
      desc = _("A 12-week reading streak"),
      check = function(m) return m.best_weekly_streak >= 12 end },
    { id = "month_all_days", icon = "♬", title = _("Perfect month"),
      desc = _("Read on every day of a calendar month"),
      check = function(m) return m.month_all_days end },
    { id = "weekend_warrior", icon = "♩", title = _("Weekend warrior"),
      desc = _("Read on both weekend days, 4 weekends in a row"),
      check = function(m) return m.weekend_warrior end },

    -- Single day / single session --------------------------------------------
    { id = "marathon_3h", icon = "♦", title = _("Marathon"),
      desc = _("Read for 3 hours in a single day"),
      check = function(m) return m.max_day_secs >= 3 * 3600 end },
    { id = "day_5h",      icon = "♢", title = _("Absorbed"),
      desc = _("Read for 5 hours in a single day"),
      check = function(m) return m.max_day_secs >= 5 * 3600 end },
    { id = "day_6h",      icon = "♠", title = _("Marathon day"),
      desc = _("Read for 6 hours in a single day"),
      check = function(m) return m.max_day_secs >= 6 * 3600 end },
    { id = "session_1h",  icon = "♤", title = _("One sitting"),
      desc = _("Read for 1 hour without a break"),
      check = function(m) return m.max_session_secs >= 3600 end },
    { id = "session_2h",  icon = "♣", title = _("Deep session"),
      desc = _("Read for 2 hours without a break"),
      check = function(m) return m.max_session_secs >= 2 * 3600 end },
    { id = "midnight_crossing", icon = "♧", title = _("Past midnight"),
      desc = _("Read on both sides of midnight in one session"),
      check = function(m) return m.midnight_crossing end },

    -- Time of day / calendar --------------------------------------------------
    { id = "night_owl",   icon = "☾", title = _("Night owl"),
      desc = _("Read between midnight and 4 a.m."),
      check = function(m) return m.night_owl end },
    { id = "early_bird",  icon = "☀", title = _("Early bird"),
      desc = _("Read between 5 and 7 a.m."),
      check = function(m) return m.read_early end },
    { id = "lunch_reader", icon = "❋", title = _("Lunch break"),
      desc = _("Read between noon and 1 p.m."),
      check = function(m) return m.read_lunch end },
    { id = "all_hours",   icon = "✺", title = _("Around the clock"),
      desc = _("Read in every hour of the day at some point"),
      check = function(m) return m.distinct_hours >= 24 end },
    { id = "all_weekdays", icon = "✷", title = _("Full week"),
      desc = _("Read on every day of the week at some point"),
      check = function(m) return m.distinct_weekdays >= 7 end },
    { id = "dec31",       icon = "❄", title = _("New Year's Eve reader"),
      desc = _("Read on 31 December"),
      check = function(m) return m.read_dec31 end },
    { id = "jan1",        icon = "✳", title = _("New Year's resolution"),
      desc = _("Read on 1 January"),
      check = function(m) return m.read_jan1 end },

    -- Pace / depth ------------------------------------------------------------
    { id = "fast_reader",  icon = "➣", title = _("Speed reader"),
      desc = _("Average over 60 pages per hour in a book"),
      check = function(m) return m.max_book_pace_pph >= 60 end },
    { id = "devoted_book", icon = "❤", title = _("Devoted"),
      desc = _("Spend over 20 hours on a single book"),
      check = function(m) return m.max_book_secs >= 20 * 3600 end },

    -- Variety -------------------------------------------------------------------
    { id = "authors_5",   icon = "♥", title = _("Well-read"),
      desc = _("Finish books by 5 different authors"),
      check = function(m) return m.distinct_finished_authors >= 5 end },
    { id = "authors_25",  icon = "♡", title = _("Literary"),
      desc = _("Finish books by 25 different authors"),
      check = function(m) return m.distinct_finished_authors >= 25 end },
    { id = "distinct_books_50", icon = "❦", title = _("Explorer"),
      desc = _("Open 50 different books"),
      check = function(m) return m.distinct_books >= 50 end },

    -- Extended tiers / new themes (+20) ---------------------------------------
    { id = "books_500", icon = "✦", title = _("Grand library"),
      desc = _("Finish 500 books"),
      check = function(m) return m.finished_books >= 500 end },
    { id = "distinct_books_100", icon = "✧", title = _("Adventurer"),
      desc = _("Open 100 different books"),
      check = function(m) return m.distinct_books >= 100 end },
    { id = "distinct_books_250", icon = "✤", title = _("Cartographer"),
      desc = _("Open 250 different books"),
      check = function(m) return m.distinct_books >= 250 end },
    { id = "authors_50", icon = "✥", title = _("Well-versed"),
      desc = _("Finish books by 50 different authors"),
      check = function(m) return m.distinct_finished_authors >= 50 end },
    { id = "days_100", icon = "◒", title = _("100 reading days"),
      desc = _("Read on 100 different days"),
      check = function(m) return m.total_reading_days >= 100 end },
    { id = "days_365", icon = "◓", title = _("365 reading days"),
      desc = _("Read on 365 different days"),
      check = function(m) return m.total_reading_days >= 365 end },
    { id = "days_1000", icon = "⊘", title = _("1000 reading days"),
      desc = _("Read on 1000 different days"),
      check = function(m) return m.total_reading_days >= 1000 end },
    { id = "every_month", icon = "⊞", title = _("Every month"),
      desc = _("Read in every month of one year"),
      check = function(m) return m.any_year_all_months end },
    { id = "four_seasons", icon = "⊠", title = _("Four seasons"),
      desc = _("Read in all four seasons"),
      check = function(m) return m.all_seasons end },
    { id = "complete_week", icon = "⊟", title = _("Complete week"),
      desc = _("Read every day of one calendar week (Mon-Sun)"),
      check = function(m) return m.full_week_mon_sun end },
    { id = "veteran_years", icon = "⊡", title = _("Veteran"),
      desc = _("Your reading history spans 5 calendar years"),
      check = function(m) return m.span_years >= 5 end },
    { id = "reading_anniversary", icon = "❁", title = _("Reading anniversary"),
      desc = _("One year since your first reading"),
      check = function(m) return m.history_span_days >= 365 end },
    { id = "session_3h", icon = "▻", title = _("Iron focus"),
      desc = _("Read for 3 hours without a break"),
      check = function(m) return m.max_session_secs >= 3 * 3600 end },
    { id = "session_pages_100", icon = "◅", title = _("Sprint"),
      desc = _("Read 100 pages in one session"),
      check = function(m) return m.max_session_pages >= 100 end },
    { id = "pages_month_5000", icon = "◧", title = _("Big month"),
      desc = _("Read 5000 pages in one calendar month"),
      check = function(m) return m.pages_max_month >= 5000 end },
    { id = "hours_week_20", icon = "◨", title = _("Big week"),
      desc = _("Read 20 hours in one week"),
      check = function(m) return m.max_week_hours >= 20 end },
    { id = "comeback", icon = "↺", title = _("Comeback"),
      desc = _("Read again after a 30-day break"),
      check = function(m) return m.had_comeback end },
    { id = "author_loyalty", icon = "❧", title = _("Author loyalty"),
      desc = _("Finish 5 books by the same author"),
      check = function(m) return m.max_books_one_author >= 5 end },
}

-- Quick "is this key in the catalogue" set, so a stale entry left in the
-- file for an achievement that's since been removed doesn't get counted.
local CATALOGUE_IDS = {}
for _idx, a in ipairs(M.CATALOGUE) do CATALOGUE_IDS[a.id] = true end

-- ---------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------
local store

local function openStore()
    if store == nil then
        local ok, settings = pcall(function() return LuaSettings:open(STORE_PATH) end)
        store = ok and settings or false
    end
    return store or nil
end

-- { [id] = earn_ts }. Missing/malformed content comes back as an empty
-- table, so an old or hand-edited file can't crash this.
function M.getEarned()
    local s = openStore()
    if not s then return {} end
    local raw = s:readSetting("earned")
    if type(raw) ~= "table" then return {} end
    return raw
end

function M.earnedCount()
    local earned = M.getEarned()
    local n = 0
    for id in pairs(earned) do
        if CATALOGUE_IDS[id] then n = n + 1 end
    end
    return n
end

-- The total number of (catalogue) achievements.
function M.totalCount()
    return #M.CATALOGUE
end

-- The set of "new" (not yet acknowledged) achievements: the ones earned
-- SINCE the last time the list was opened. recompute() adds newly earned
-- ones to it, markAllSeen() (called when the list opens) clears it.
function M.getNew()
    local s = openStore()
    if not s then return {} end
    local raw = s:readSetting("new")
    if type(raw) ~= "table" then return {} end
    return raw
end

-- How many earned-but-not-yet-acknowledged achievements there are (this
-- is what drives the ★ shown on the insight cell).
function M.newCount()
    local earned  = M.getEarned()
    local new_set = M.getNew()
    local n = 0
    for id in pairs(new_set) do
        if CATALOGUE_IDS[id] and earned[id] then n = n + 1 end
    end
    return n
end

-- Called when the list opens: from now on every achievement earned so
-- far is "seen", so the ★ marker disappears on the next view.
function M.markAllSeen()
    local s = openStore()
    if not s then return end
    s:saveSetting("new", {})
    pcall(function() s:flush() end)
end

-- ---------------------------------------------------------------------
-- Lua helpers used for evaluation (operating on the set of distinct days)
-- ---------------------------------------------------------------------

-- Number of days in a given month (day 0 of the next month = the last
-- day of this month).
local function daysInMonth(y, mo)
    local t = os.time({ year = y, month = mo + 1, day = 0, hour = 12 })
    return tonumber(os.date("%d", t)) or 31
end

-- Whether there's a calendar month with reading on EVERY one of its days.
local function anyFullMonth(day_set, months)
    for ym in pairs(months) do
        local y  = tonumber(ym:sub(1, 4))
        local mo = tonumber(ym:sub(6, 7))
        if y and mo then
            local all = true
            for day = 1, daysInMonth(y, mo) do
                if not day_set[string.format("%04d-%02d-%02d", y, mo, day)] then
                    all = false
                    break
                end
            end
            if all then return true end
        end
    end
    return false
end

-- Whether there are 4 consecutive weekends with reading on both Saturday
-- AND Sunday. A weekend is identified by its Saturday; the "next" weekend's
-- Saturday is exactly 7 days later.
local function anyWeekendStreak(day_set, day_list)
    local good = {}  -- Saturday dates of "good" weekends
    for _idx, d in ipairs(day_list) do
        local y, mo, da = d:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            local ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
            if ts and tonumber(os.date("%w", ts)) == 6 then  -- Saturday
                if day_set[os.date("%Y-%m-%d", ts + 86400)] then  -- Sunday too
                    good[os.date("%Y-%m-%d", ts)] = ts
                end
            end
        end
    end
    for _ds, ts in pairs(good) do
        local ok = true
        for k = 1, 3 do
            if not good[os.date("%Y-%m-%d", ts + k * 7 * 86400)] then
                ok = false
                break
            end
        end
        if ok then return true end
    end
    return false
end

-- Whether there's a calendar week (Monday to Sunday) with reading on all
-- 7 of its days.
local function anyFullWeek(day_set, day_list)
    for _idx, d in ipairs(day_list) do
        local y, mo, da = d:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            local ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
            if ts and tonumber(os.date("%w", ts)) == 1 then  -- Monday
                local all = true
                for k = 1, 6 do
                    if not day_set[os.date("%Y-%m-%d", ts + k * 86400)] then
                        all = false
                        break
                    end
                end
                if all then return true end
            end
        end
    end
    return false
end

-- Whether there was a gap of at least 30 days between two consecutive
-- reading days (and then reading resumed) - for the "comeback"
-- achievement. day_list is in ascending order.
local function anyLongGap(day_list)
    local prev_ts
    for _idx, d in ipairs(day_list) do
        local y, mo, da = d:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            local ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
            if ts then
                if prev_ts and (ts - prev_ts) > 30 * 86400 then return true end
                prev_ts = ts
            end
        end
    end
    return false
end

-- The database's cheap "fingerprint": the latest reading timestamp and
-- the row count. Together these cheaply tell whether page_stat has changed
-- since the last evaluation (same idea as RecordsData's cache fingerprint).
-- { max_start_time, row_count }.
local function queryFingerprint()
    return StatsDb.withDb({ 0, 0 }, function(conn)
        local mx, cnt = 0, 0
        StatsDb.withStatement(conn, "SELECT MAX(start_time), COUNT(*) FROM page_stat", function(stmt)
            for row in stmt:rows() do
                mx  = tonumber(row[1]) or 0
                cnt = tonumber(row[2]) or 0
            end
        end)
        return { mx, cnt }
    end)
end

-- ---------------------------------------------------------------------
-- Evaluation (on a full reload, or via refreshIfChanged() when the data
-- has changed since the last evaluation)
-- ---------------------------------------------------------------------

-- The fresh metrics passed to the checks. The lightweight aggregates come
-- from the existing modules (RecordsData for the records, the same total
-- time the Records popup shows; InsightsData for the all-time pages/books
-- and the weekly streak), the rest from queries run on a single connection.
function M.computeMetrics()
    local records = RecordsData.load() or {}
    local total_secs       = records.total_secs or 0
    local max_day_secs     = (records.longest  and records.longest.duration_sec) or 0
    local max_day_pages    = (records.best_day and records.best_day.pages) or 0
    local best_streak_days = (records.streak   and records.streak.days) or 0

    local all_time = Data.getAllTimeStats() or {}
    local streaks  = Data.calculateStreaks() or {}

    local m = {
        finished_books   = 0,
        finished_max_year  = 0,
        finished_max_month = 0,
        finished_same_day  = false,
        finished_book_max_pages   = 0,
        distinct_finished_authors = 0,
        total_hours      = total_secs / 3600,
        hours_max_year   = 0,
        hours_max_month  = 0,
        total_pages      = all_time.pages or 0,
        distinct_books   = all_time.book_count or 0,
        max_day_secs     = max_day_secs,
        max_day_pages    = max_day_pages,
        best_streak_days = best_streak_days,
        best_weekly_streak = streaks.best_weeks or 0,
        month_all_days   = false,
        weekend_warrior  = false,
        max_session_secs = 0,
        midnight_crossing = false,
        read_early   = false,
        read_lunch   = false,
        night_owl    = false,
        distinct_hours    = 0,
        distinct_weekdays = 0,
        read_dec31   = false,
        read_jan1    = false,
        max_book_pace_pph = 0,
        max_book_secs     = 0,
        -- Extended metrics (for the +20 achievements)
        total_reading_days   = 0,
        any_year_all_months  = false,
        all_seasons          = false,
        full_week_mon_sun    = false,
        span_years           = 0,
        history_span_days    = 0,
        max_session_pages    = 0,
        pages_max_month      = 0,
        max_week_hours       = 0,
        had_comeback         = false,
        max_books_one_author = 0,
    }

    -- Finished books: the sum of each year's finished-count (same
    -- definition as the goal cell), plus the raw finished-book list for the
    -- per-year/per-month maximum and the book IDs.
    local finished_ids = {}          -- id_book -> finish_ts
    local finished_by_month = {}     -- "YYYY-MM" -> count
    local range = Data.getYearRange()
    if range and range.min_year and range.max_year then
        m.span_years = range.max_year - range.min_year + 1
        for y = range.min_year, range.max_year do
            local cnt = Data.getFinishedBookCountForYear(y) or 0
            m.finished_books = m.finished_books + cnt
            if cnt > m.finished_max_year then m.finished_max_year = cnt end
            for _i, b in ipairs(Data.getFinishedBooksForYear(y) or {}) do
                if b.id_book then finished_ids[b.id_book] = b.last_read or 0 end
                if b.last_read and b.last_read > 0 then
                    local mk = os.date("%Y-%m", b.last_read)
                    finished_by_month[mk] = (finished_by_month[mk] or 0) + 1
                end
            end
        end
    end
    for _k, c in pairs(finished_by_month) do
        if c > m.finished_max_month then m.finished_max_month = c end
    end

    StatsDb.withDb(nil, function(conn)
        -- Year/month totals -> hours/year, hours/month, pages/month,
        -- "every month in a year", "all four seasons".
        StatsDb.withStatement(conn, [[
            SELECT strftime('%Y', start_time, 'unixepoch', 'localtime') AS y,
                   strftime('%m', start_time, 'unixepoch', 'localtime') AS mo,
                   SUM(duration) AS dur,
                   COUNT(*) AS cnt
            FROM page_stat GROUP BY y, mo
        ]], function(stmt)
            local year_sum, year_months, all_months = {}, {}, {}
            for row in stmt:rows() do
                local y   = row[1]
                local mo  = tonumber(row[2])
                local dur = tonumber(row[3]) or 0
                local cnt = tonumber(row[4]) or 0
                if y then year_sum[y] = (year_sum[y] or 0) + dur end
                if dur / 3600 > m.hours_max_month then m.hours_max_month = dur / 3600 end
                if cnt > m.pages_max_month then m.pages_max_month = cnt end
                if y and mo then
                    year_months[y] = year_months[y] or {}
                    year_months[y][mo] = true
                    all_months[mo] = true
                end
            end
            for _y, s in pairs(year_sum) do
                if s / 3600 > m.hours_max_year then m.hours_max_year = s / 3600 end
            end
            for _y, mset in pairs(year_months) do
                local n = 0
                for _mo in pairs(mset) do n = n + 1 end
                if n >= 12 then m.any_year_all_months = true end
            end
            -- Seasons: winter (12,1,2), spring (3,4,5), summer (6,7,8), autumn (9,10,11).
            local function seasonHit(a, b, c)
                return all_months[a] or all_months[b] or all_months[c]
            end
            m.all_seasons = seasonHit(12, 1, 2) and seasonHit(3, 4, 5)
                and seasonHit(6, 7, 8) and seasonHit(9, 10, 11) or false
        end)

        -- Weekly time totals -> the week with the most reading. The week's
        -- start day comes from the shared setting (Mon/Sun), the same way the
        -- weekly streak counts it.
        StatsDb.withStatement(conn, string.format([[
            SELECT %s AS wk,
                   SUM(duration) AS dur
            FROM page_stat GROUP BY wk
        ]], Data.weekStartSqlExpr(Data.weekStartWday())), function(stmt)
            for row in stmt:rows() do
                local dur = tonumber(row[2]) or 0
                if dur / 3600 > m.max_week_hours then m.max_week_hours = dur / 3600 end
            end
        end)

        -- The list of days read -> full month, weekend streak.
        local day_list, day_set, months = {}, {}, {}
        StatsDb.withStatement(conn, [[
            SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d
            FROM page_stat ORDER BY d
        ]], function(stmt)
            for row in stmt:rows() do
                local d = row[1]
                if d then
                    day_list[#day_list + 1] = d
                    day_set[d] = true
                    months[d:sub(1, 7)] = true
                end
            end
        end)
        m.month_all_days  = anyFullMonth(day_set, months)
        m.weekend_warrior = anyWeekendStreak(day_set, day_list)
        m.full_week_mon_sun = anyFullWeek(day_set, day_list)
        m.total_reading_days = #day_list
        m.had_comeback = anyLongGap(day_list)
        -- Anniversary: how many days have passed since the first reading day.
        if day_list[1] then
            local y, mo, da = day_list[1]:match("^(%d+)-(%d+)-(%d+)$")
            if y then
                local first_ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
                if first_ts then
                    m.history_span_days = math.floor((os.time() - first_ts) / 86400)
                end
            end
        end

        -- Hour coverage + time-of-day flags.
        StatsDb.withStatement(conn, [[
            SELECT DISTINCT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER)
            FROM page_stat
        ]], function(stmt)
            local hset, n = {}, 0
            for row in stmt:rows() do
                local h = tonumber(row[1])
                if h and not hset[h] then hset[h] = true; n = n + 1 end
            end
            m.distinct_hours = n
            m.night_owl  = hset[0] or hset[1] or hset[2] or hset[3] or false
            m.read_early = hset[5] or hset[6] or false
            m.read_lunch = hset[12] or false
        end)

        -- Weekday coverage.
        StatsDb.withStatement(conn, [[
            SELECT DISTINCT strftime('%w', start_time, 'unixepoch', 'localtime') FROM page_stat
        ]], function(stmt)
            local n = 0
            for _row in stmt:rows() do n = n + 1 end
            m.distinct_weekdays = n
        end)

        -- Special calendar days.
        StatsDb.withStatement(conn, [[
            SELECT
              MAX(CASE WHEN strftime('%m-%d', start_time, 'unixepoch', 'localtime') = '12-31' THEN 1 ELSE 0 END),
              MAX(CASE WHEN strftime('%m-%d', start_time, 'unixepoch', 'localtime') = '01-01' THEN 1 ELSE 0 END)
            FROM page_stat
        ]], function(stmt)
            for row in stmt:rows() do
                m.read_dec31 = (tonumber(row[1]) or 0) == 1
                m.read_jan1  = (tonumber(row[2]) or 0) == 1
            end
        end)

        -- Per-book totals -> longest time spent on one book, best pace.
        StatsDb.withStatement(conn, [[
            SELECT id_book, SUM(duration) AS secs, COUNT(DISTINCT page) AS pages
            FROM page_stat GROUP BY id_book
        ]], function(stmt)
            for row in stmt:rows() do
                local secs  = tonumber(row[2]) or 0
                local pages = tonumber(row[3]) or 0
                if secs > m.max_book_secs then m.max_book_secs = secs end
                -- Only compute pace for at least half an hour of reading, so a
                -- few-second "peek" doesn't produce an unrealistic pages/hour.
                if secs >= 1800 and pages > 0 then
                    local pph = pages / (secs / 3600)
                    if pph > m.max_book_pace_pph then m.max_book_pace_pph = pph end
                end
            end
        end)

        -- Finished books: page count + authors + first reading day.
        local ids = {}
        for id in pairs(finished_ids) do ids[#ids + 1] = id end
        if #ids > 0 then
            local in_list = table.concat(ids, ",")
            StatsDb.withStatement(conn, string.format([[
                SELECT id, pages, authors FROM book WHERE id IN (%s)
            ]], in_list), function(stmt)
                local authors, na = {}, 0
                for row in stmt:rows() do
                    local pages = tonumber(row[2]) or 0
                    if pages > m.finished_book_max_pages then m.finished_book_max_pages = pages end
                    local a = row[3]
                    if a and a ~= "" then
                        if not authors[a] then na = na + 1 end
                        authors[a] = (authors[a] or 0) + 1
                        if authors[a] > m.max_books_one_author then
                            m.max_books_one_author = authors[a]
                        end
                    end
                end
                m.distinct_finished_authors = na
            end)
            StatsDb.withStatement(conn, string.format([[
                SELECT id_book, MIN(start_time) FROM page_stat WHERE id_book IN (%s) GROUP BY id_book
            ]], in_list), function(stmt)
                for row in stmt:rows() do
                    local id     = tonumber(row[1])
                    local first  = tonumber(row[2]) or 0
                    local finish = (id and finished_ids[id]) or 0
                    if first > 0 and finish > 0
                       and os.date("%Y-%m-%d", first) == os.date("%Y-%m-%d", finish) then
                        m.finished_same_day = true
                    end
                end
            end)
        end

        -- Continuous reading sessions (10-minute gap threshold): longest
        -- session length + a session that crosses midnight.
        StatsDb.withStatement(conn, [[
            SELECT start_time, duration FROM page_stat ORDER BY start_time
        ]], function(stmt)
            local GAP = 600
            local sess_start, sess_end, sess_pages
            local function closeSession()
                if sess_start then
                    local len = sess_end - sess_start
                    if len > m.max_session_secs then m.max_session_secs = len end
                    if sess_pages > m.max_session_pages then m.max_session_pages = sess_pages end
                    if os.date("%Y-%m-%d", sess_start) ~= os.date("%Y-%m-%d", sess_end) then
                        m.midnight_crossing = true
                    end
                end
            end
            for row in stmt:rows() do
                local st  = tonumber(row[1]) or 0
                local dur = tonumber(row[2]) or 0
                if not sess_start then
                    sess_start, sess_end, sess_pages = st, st + dur, 1
                elseif st - sess_end <= GAP then
                    if st + dur > sess_end then sess_end = st + dur end
                    sess_pages = sess_pages + 1
                else
                    closeSession()
                    sess_start, sess_end, sess_pages = st, st + dur, 1
                end
            end
            closeSession()
        end)

        return nil
    end)

    return m
end

-- Re-evaluates every not-yet-earned achievement with fresh metrics, and
-- records the newly earned ones. Never un-earns anything. Writes the file
-- (evaluated_ts + fingerprint) even if nothing changed, so
-- refreshIfChanged() can skip it from then on. Returns the current count.
function M.recompute()
    local ok_m, m = pcall(M.computeMetrics)
    if not ok_m or type(m) ~= "table" then
        return M.earnedCount()
    end

    local earned  = M.getEarned()
    local new_set = M.getNew()
    local now = os.time()
    for _idx, a in ipairs(M.CATALOGUE) do
        if not earned[a.id] then
            local ok_c, got = pcall(a.check, m)
            if ok_c and got then
                earned[a.id]  = now
                new_set[a.id] = true   -- freshly earned -> "new"
            end
        end
    end

    local s = openStore()
    if s then
        s:saveSetting("earned", earned)
        s:saveSetting("new", new_set)
        s:saveSetting("evaluated_ts", now)
        s:saveSetting("evaluated_date", os.date("%Y-%m-%d", now))
        -- The database's "fingerprint" at the moment of evaluation, so
        -- refreshIfChanged() can cheaply tell whether it's changed since.
        local fp = queryFingerprint()
        s:saveSetting("fp_max_time",  fp[1])
        s:saveSetting("fp_row_count", fp[2])
        pcall(function() s:flush() end)
    end

    local n = 0
    for id in pairs(earned) do
        if CATALOGUE_IDS[id] then n = n + 1 end
    end
    return n
end

-- Cheap automatic background refresh. `mode`:
--   "daily" (default): re-evaluates at most once a day - if there's
--     already been an evaluation today, it doesn't even check the fingerprint;
--   "every_open": checks the fingerprint on every open.
-- Either way, the full recompute() only runs if the data has actually
-- changed since the last evaluation (or there's never been one). So
-- achievements update themselves after reading, without slowing down
-- opening. Returns whether a full re-evaluation ran.
function M.refreshIfChanged(mode)
    local s = openStore()
    if mode == "daily" and s
       and s:readSetting("evaluated_date") == os.date("%Y-%m-%d") then
        return false  -- already evaluated today
    end
    local fp = queryFingerprint()
    if s and s:readSetting("evaluated_ts") ~= nil
       and s:readSetting("fp_max_time")  == fp[1]
       and s:readSetting("fp_row_count") == fp[2] then
        return false  -- nothing changed
    end
    M.recompute()
    return true
end

-- ---------------------------------------------------------------------
-- List for the popup
-- ---------------------------------------------------------------------
-- Earned ones first, sorted by earn time descending, then the locked
-- ones in catalogue order. Each item:
-- { def = <catalogue entry>, earned = bool, earned_ts = ts|nil }.
function M.list()
    local earned  = M.getEarned()
    local new_set = M.getNew()
    local earned_items, locked_items = {}, {}
    for _idx, a in ipairs(M.CATALOGUE) do
        local ts = earned[a.id]
        if ts then
            table.insert(earned_items, {
                def = a, earned = true, earned_ts = ts,
                is_new = new_set[a.id] and true or false,
            })
        else
            table.insert(locked_items, { def = a, earned = false })
        end
    end
    table.sort(earned_items, function(x, y)
        if x.earned_ts == y.earned_ts then return x.def.id < y.def.id end
        return x.earned_ts > y.earned_ts
    end)
    local out = {}
    for _idx, it in ipairs(earned_items) do table.insert(out, it) end
    for _idx, it in ipairs(locked_items) do table.insert(out, it) end
    return out
end

return M
