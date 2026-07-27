--[[
Reading Insights - reading achievements (globális, minden évre közös).

A megszerzett achievementek listája a reading goal szekció mellett jelenik
meg egy "N earned" cellában, és egy külön listapopupban (megszerzettek felül,
megszerzés ideje szerint csökkenő sorrendben; a hátralévők alul, szürkén).

Perzisztálás: a megszerzett achievementek a manual_books.lua mintájára a
KOReader settings mappájában, saját fájlban élnek
(reading_insights_achievements.lua), { [id] = megszerzés_unix_ideje } alakban.
Egy egyszer megszerzett achievement onnantól a fájlból jön - a normál
popup-nyitás csak a darabszámot olvassa ki (olcsó, csak fájl). A tényleges
kiértékelés (a DB-lekérdezésekkel) csak akkor fut, amikor a teljes adat
újratöltődik: a title-bar hosszú nyomására (Cache.clearAllCache útvonal),
illetve egyszeri bootstrapként, ha a fájl még soha nem készült el.

Az achievementek soha nem "veszíthetők el": ha egy mögöttes szám később
csökken (törölt könyv, egy másik eszközről bemásolt/összefésült DB), a már
megszerzett achievement megmarad.

  Achievements.CATALOGUE          a definíciók (sorrend = zárolt megjelenési sorrend)
  Achievements.getEarned()        { [id] = ts } a fájlból
  Achievements.earnedCount()      hány katalógusbeli achievement van megszerezve
  Achievements.list()             a listapopup sorai: megszerzettek (ts szerint
                                  csökkenő) elöl, zároltak hátul
  Achievements.recompute()        friss kiértékelés a DB-ből + perzisztálás;
                                  visszaadja az aktuális darabszámot
  Achievements.refreshIfChanged() olcsó, feltételes kiértékelés: csak akkor
                                  fut teljes recompute, ha változott az adat
                                  az utolsó kiértékelés óta (nyitásonként
                                  egy pehelysúlyú ujjlenyomat-lekérdezés)
]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

-- Megosztott modulok, a main.lua adja át egy named table-ként (lásd ott).
local deps = ...
local StatsDb, RecordsData, Data, Locale =
    deps.StatsDb, deps.RecordsData, deps.Data, deps.Locale
local _ = Locale._

local M = {}

local STORE_PATH = DataStorage:getSettingsDir() .. "/reading_insights_achievements.lua"

-- Az achievement-katalógus. Minden bejegyzés:
--   id     stabil kulcs, ez kerül a fájlba - egyszer kiadva SOHA ne
--          nevezd/számozd át, különben a réginek megszerzett bejegyzés
--          "elárvul" és a felhasználó látszólag elveszti
--   icon   a sor elején megjelenő jel. Szándékosan sima BMP Unicode
--          szimbólum (geometriai alakzat / kártyaszín / csillag / nyíl),
--          nem emoji: a színes emojik e-inken nem, vagy dobozként
--          renderelődnek, ezek viszont a NotoSans/NotoSansSymbols készletből
--          jól kijönnek. Minden achievementnek saját, egyedi jele van.
--   title  rövid név (fordítható)
--   desc   egysoros leírás a feltételről (fordítható)
--   check  function(metrics) -> boolean, a M.computeMetrics() adta táblán
-- A sorrend itt a ZÁROLT megjelenési sorrend; a megszerzetteket a lista a
-- megszerzés ideje szerint rendezi újra.
M.CATALOGUE = {
    -- Befejezett könyvek (darab, összesen) -------------------------------
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
    -- Befejezett könyvek (időszaki / egyéb) ------------------------------
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

    -- Olvasási idő (összesen) - a Records milestone-létrája ---------------
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
    -- Olvasási idő (időszaki) --------------------------------------------
    { id = "hours_month_50", icon = "◇", title = _("Intense month"),
      desc = _("Read for 50 hours in one calendar month"),
      check = function(m) return m.hours_max_month >= 50 end },
    { id = "hours_year_100", icon = "❖", title = _("100 hours in a year"),
      desc = _("Read for 100 hours in one year"),
      check = function(m) return m.hours_max_year >= 100 end },
    { id = "hours_year_500", icon = "▣", title = _("500 hours in a year"),
      desc = _("Read for 500 hours in one year"),
      check = function(m) return m.hours_max_year >= 500 end },

    -- Oldalak (összesen) -------------------------------------------------
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
    -- Oldalak (egy nap) --------------------------------------------------
    { id = "pages_300",  icon = "△", title = _("Page turner"),
      desc = _("Read 300 pages in a single day"),
      check = function(m) return m.max_day_pages >= 300 end },
    { id = "pages_500",  icon = "▲", title = _("Devourer"),
      desc = _("Read 500 pages in a single day"),
      check = function(m) return m.max_day_pages >= 500 end },
    { id = "pages_1000", icon = "▼", title = _("Unstoppable"),
      desc = _("Read 1000 pages in a single day"),
      check = function(m) return m.max_day_pages >= 1000 end },

    -- Napi sorozatok -----------------------------------------------------
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
    -- Heti sorozatok / kitartás ------------------------------------------
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

    -- Egy nap / egy ülés -------------------------------------------------
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

    -- Napszak / naptár ---------------------------------------------------
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

    -- Tempó / mélység ----------------------------------------------------
    { id = "fast_reader",  icon = "➣", title = _("Speed reader"),
      desc = _("Average over 60 pages per hour in a book"),
      check = function(m) return m.max_book_pace_pph >= 60 end },
    { id = "devoted_book", icon = "❤", title = _("Devoted"),
      desc = _("Spend over 20 hours on a single book"),
      check = function(m) return m.max_book_secs >= 20 * 3600 end },

    -- Változatosság ------------------------------------------------------
    { id = "authors_5",   icon = "♥", title = _("Well-read"),
      desc = _("Finish books by 5 different authors"),
      check = function(m) return m.distinct_finished_authors >= 5 end },
    { id = "authors_25",  icon = "♡", title = _("Literary"),
      desc = _("Finish books by 25 different authors"),
      check = function(m) return m.distinct_finished_authors >= 25 end },
    { id = "distinct_books_50", icon = "❦", title = _("Explorer"),
      desc = _("Open 50 different books"),
      check = function(m) return m.distinct_books >= 50 end },

    -- Bővített szintek / új témák (+20) -----------------------------------
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

-- Gyors "ez a kulcs a katalógus tagja-e" halmaz, hogy egy időközben
-- eltávolított achievement elárvult, fájlban maradt bejegyzése ne számítson
-- bele a darabszámba.
local CATALOGUE_IDS = {}
for _idx, a in ipairs(M.CATALOGUE) do CATALOGUE_IDS[a.id] = true end

-- ---------------------------------------------------------------------
-- Perzisztálás
-- ---------------------------------------------------------------------
local store

local function openStore()
    if store == nil then
        local ok, settings = pcall(function() return LuaSettings:open(STORE_PATH) end)
        store = ok and settings or false
    end
    return store or nil
end

-- { [id] = megszerzés_ts }. A hiányzó/rossz alakú tartalom üres táblaként jön
-- vissza, hogy egy régi vagy kézzel szerkesztett fájl se tudjon elszállni.
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

-- Az összes (katalógusbeli) achievement száma.
function M.totalCount()
    return #M.CATALOGUE
end

-- Az "új" (még nem nyugtázott) achievementek halmaza: amiket a legutóbbi
-- lista-megnyitás ÓTA szereztél meg. A recompute() teszi bele az újonnan
-- megszerzetteket, a markAllSeen() (a lista megnyitásakor) üríti.
function M.getNew()
    local s = openStore()
    if not s then return {} end
    local raw = s:readSetting("new")
    if type(raw) ~= "table" then return {} end
    return raw
end

-- Hány megszerzett, de még nem nyugtázott achievement van (ennyi jelzi az
-- insight cellán a ★-ot).
function M.newCount()
    local earned  = M.getEarned()
    local new_set = M.getNew()
    local n = 0
    for id in pairs(new_set) do
        if CATALOGUE_IDS[id] and earned[id] then n = n + 1 end
    end
    return n
end

-- A lista megnyitásakor hívjuk: mostantól minden eddig megszerzett
-- achievement "látott", tehát a ★-jelölés eltűnik a következő nézetnél.
function M.markAllSeen()
    local s = openStore()
    if not s then return end
    s:saveSetting("new", {})
    pcall(function() s:flush() end)
end

-- ---------------------------------------------------------------------
-- Kiértékeléshez használt Lua-segédek (a distinct-napok halmazán)
-- ---------------------------------------------------------------------

-- Egy adott hónap napjainak száma (a következő hónap 0. napja = ennek a
-- hónapnak az utolsó napja).
local function daysInMonth(y, mo)
    local t = os.time({ year = y, month = mo + 1, day = 0, hour = 12 })
    return tonumber(os.date("%d", t)) or 31
end

-- Van-e olyan naptári hónap, amelynek MINDEN napján volt olvasás.
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

-- Van-e 4 egymást követő hétvége, amikor szombaton ÉS vasárnap is olvastál.
-- Egy hétvégét a szombatja azonosít; a "következő" hétvége szombatja pontosan
-- 7 nappal később van.
local function anyWeekendStreak(day_set, day_list)
    local good = {}  -- "jó" hétvégék szombat-dátumai
    for _idx, d in ipairs(day_list) do
        local y, mo, da = d:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            local ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
            if ts and tonumber(os.date("%w", ts)) == 6 then  -- szombat
                if day_set[os.date("%Y-%m-%d", ts + 86400)] then  -- vasárnap is
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

-- Van-e olyan naptári hét (hétfőtől vasárnapig), amelynek mind a 7 napján
-- volt olvasás.
local function anyFullWeek(day_set, day_list)
    for _idx, d in ipairs(day_list) do
        local y, mo, da = d:match("^(%d+)-(%d+)-(%d+)$")
        if y then
            local ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
            if ts and tonumber(os.date("%w", ts)) == 1 then  -- hétfő
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

-- Volt-e legalább 30 napos szünet két egymást követő olvasási nap között
-- (aztán újra olvastál) - a "visszatérő" achievementhez. A day_list növekvő
-- sorrendű.
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

-- Az adatbázis olcsó "ujjlenyomata": a legutolsó olvasási időbélyeg és a
-- sorok száma. Ez a kettő együtt olcsón megmondja, változott-e a page_stat a
-- legutóbbi kiértékelés óta (ugyanaz az ötlet, mint a RecordsData
-- cache-fingerprintje). { max_start_time, row_count }.
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
-- Kiértékelés (teljes reloadkor, illetve refreshIfChanged() nyomán, ha
-- változott az adat az utolsó kiértékelés óta)
-- ---------------------------------------------------------------------

-- A checkeknek átadott friss mérőszámok. A könnyű aggregátumokat a meglévő
-- modulokból veszi (RecordsData a rekordokat, ugyanazt az össz-időt, amit a
-- Records popup mutat; InsightsData az all-time oldalt/könyvet és a heti
-- sorozatot), a többit egyetlen kapcsolaton futó lekérdezésekből.
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
        -- Bővített mérőszámok (a +20 achievementhez)
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

    -- Befejezett könyvek: az évek befejezett-darabszámainak összege (ugyanaz
    -- a definíció, mint a goal-cellánál), plusz a nyers befejezett-lista az
    -- évenkénti/havi maximumhoz és a könyv-ID-khez.
    local finished_ids = {}          -- id_book -> befejezés_ts
    local finished_by_month = {}     -- "YYYY-MM" -> darab
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
        -- Év/hó összegek -> óra/év, óra/hó, oldal/hó, "minden hónap egy
        -- évben", "mind a négy évszak".
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
            -- Évszakok: tél (12,1,2), tavasz (3,4,5), nyár (6,7,8), ősz (9,10,11).
            local function seasonHit(a, b, c)
                return all_months[a] or all_months[b] or all_months[c]
            end
            m.all_seasons = seasonHit(12, 1, 2) and seasonHit(3, 4, 5)
                and seasonHit(6, 7, 8) and seasonHit(9, 10, 11) or false
        end)

        -- Heti időösszegek (ISO-hét) -> leghosszabb hét.
        StatsDb.withStatement(conn, [[
            SELECT strftime('%Y-%W', start_time, 'unixepoch', 'localtime') AS wk,
                   SUM(duration) AS dur
            FROM page_stat GROUP BY wk
        ]], function(stmt)
            for row in stmt:rows() do
                local dur = tonumber(row[2]) or 0
                if dur / 3600 > m.max_week_hours then m.max_week_hours = dur / 3600 end
            end
        end)

        -- Az olvasott napok listája -> teljes hónap, hétvégi sorozat.
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
        -- Évforduló: hány nap telt el az első olvasási nap óta.
        if day_list[1] then
            local y, mo, da = day_list[1]:match("^(%d+)-(%d+)-(%d+)$")
            if y then
                local first_ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
                if first_ts then
                    m.history_span_days = math.floor((os.time() - first_ts) / 86400)
                end
            end
        end

        -- Óra-lefedettség + napszak-jelzők.
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

        -- Hétköznap-lefedettség.
        StatsDb.withStatement(conn, [[
            SELECT DISTINCT strftime('%w', start_time, 'unixepoch', 'localtime') FROM page_stat
        ]], function(stmt)
            local n = 0
            for _row in stmt:rows() do n = n + 1 end
            m.distinct_weekdays = n
        end)

        -- Speciális naptári napok.
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

        -- Könyvenkénti összegek -> leghosszabb idő egy könyvön, legjobb tempó.
        StatsDb.withStatement(conn, [[
            SELECT id_book, SUM(duration) AS secs, COUNT(DISTINCT page) AS pages
            FROM page_stat GROUP BY id_book
        ]], function(stmt)
            for row in stmt:rows() do
                local secs  = tonumber(row[2]) or 0
                local pages = tonumber(row[3]) or 0
                if secs > m.max_book_secs then m.max_book_secs = secs end
                -- Csak legalább félórányi olvasásra számolunk tempót, hogy egy
                -- pár másodperces "belenézés" ne adjon irreális oldal/óra-t.
                if secs >= 1800 and pages > 0 then
                    local pph = pages / (secs / 3600)
                    if pph > m.max_book_pace_pph then m.max_book_pace_pph = pph end
                end
            end
        end)

        -- Befejezett könyvek: oldalszám + szerzők + első olvasás napja.
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

        -- Folyamatos olvasási ülések (10 perces szünet-küszöb): leghosszabb
        -- ülés hossza + éjfélen átnyúló ülés.
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

-- Minden még meg nem szerzett achievement újraértékelése friss mérőszámokkal,
-- és az újonnan megszerzettek kiírása. Sosem von vissza. A fájlt akkor is
-- kiírja (evaluated_ts + ujjlenyomat), ha semmi nem változott, hogy a
-- refreshIfChanged() onnantól átugorja. Visszaadja az aktuális darabszámot.
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
                new_set[a.id] = true   -- frissen megszerzett -> "új"
            end
        end
    end

    local s = openStore()
    if s then
        s:saveSetting("earned", earned)
        s:saveSetting("new", new_set)
        s:saveSetting("evaluated_ts", now)
        s:saveSetting("evaluated_date", os.date("%Y-%m-%d", now))
        -- Az adatbázis "ujjlenyomata" a kiértékelés pillanatában, hogy a
        -- refreshIfChanged() olcsón el tudja dönteni, változott-e azóta.
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

-- Olcsó automatikus frissítés a háttérben. `mode`:
--   "daily" (alapértelmezett): naponta legfeljebb egyszer értékel újra - ha
--     ma már volt kiértékelés, meg sem nézi az ujjlenyomatot;
--   "every_open": minden nyitáskor megnézi az ujjlenyomatot.
-- Mindkét esetben a teljes recompute() csak akkor fut, ha tényleg változott
-- az adat a legutóbbi kiértékelés óta (vagy még soha nem volt). Így az
-- achievementek maguktól frissülnek olvasás után, de a nyitás nem lassul.
-- Visszaadja, hogy futott-e teljes újraértékelés.
function M.refreshIfChanged(mode)
    local s = openStore()
    if mode == "daily" and s
       and s:readSetting("evaluated_date") == os.date("%Y-%m-%d") then
        return false  -- ma már volt kiértékelés
    end
    local fp = queryFingerprint()
    if s and s:readSetting("evaluated_ts") ~= nil
       and s:readSetting("fp_max_time")  == fp[1]
       and s:readSetting("fp_row_count") == fp[2] then
        return false  -- semmi nem változott
    end
    M.recompute()
    return true
end

-- ---------------------------------------------------------------------
-- Lista a popuphoz
-- ---------------------------------------------------------------------
-- Megszerzettek elöl, megszerzés ideje szerint csökkenő sorrendben, majd a
-- zároltak katalógus-sorrendben. Minden elem:
-- { def = <katalógus-bejegyzés>, earned = bool, earned_ts = ts|nil }.
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
