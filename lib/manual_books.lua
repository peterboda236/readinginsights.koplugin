--[[
Reading Insights - the hand-kept list of finished books.

Books read somewhere else (on paper, in another app, on another device
whose statistics never made it here) have no rows in statistics.sqlite3 at
all, so no query can find them - but they still count towards the reading
goal. This module is where the reader's own list of those books lives:
added, edited and deleted by hand from the manual list popup (long press
the reading goal's "N book(s) finished" cell), one list per year, and
counted into the goal alongside the books the statistics DB knows about
(see insights_data.lua's applyFinishedOverrides).

Stored in its own file next to KOReader's settings, not in
G_reader_settings: this is reader-entered content rather than a setting,
it can grow to a few hundred entries, and keeping it separate means it
survives - and can be backed up or copied to another device - on its own.

  ManualBooks.list(year)              array of entries, most recently read first
  ManualBooks.count(year)             how many entries that year has
  ManualBooks.add(year, fields)       returns the new entry
  ManualBooks.update(year, id, fields)
  ManualBooks.remove(year, id)
  ManualBooks.parseDate(str)          "YYYY-MM-DD" -> timestamp, normalised
                                      string (nil if it isn't a valid date)

An entry is { id = <number>, title = <string>, authors = <string>,
date = "YYYY-MM-DD", read_ts = <that date as a timestamp>, ts = <unix time
it was added> }. read_ts is what the book lists sort "by last reading entry"
on - a hand-added book has no reading entries, so the day the reader says
they read it stands in for one; entries saved before dates existed (or with
the date left empty) fall back to the time they were added.
]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local M = {}

local STORE_PATH = DataStorage:getSettingsDir() .. "/reading_insights_manual_books.lua"

local store

local function openStore()
    if store == nil then
        local ok, settings = pcall(function() return LuaSettings:open(STORE_PATH) end)
        store = ok and settings or false
    end
    return store or nil
end

-- "YYYY-MM-DD" -> (timestamp at midday that day, normalised string), or nil
-- if the string isn't a date. Midday rather than midnight so a daylight
-- saving shift can't move the entry onto the previous day.
function M.parseDate(str)
    local y, m, d = tostring(str or ""):match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 or d > 31 then return nil end
    local ts = os.time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 })
    if not ts then return nil end
    -- Rejects the days a month doesn't have (31 April, 30 February): os.time
    -- normalises those into the next month, so the round trip won't match.
    local back = os.date("*t", ts)
    if back.year ~= y or back.month ~= m or back.day ~= d then return nil end
    return ts, string.format("%04d-%02d-%02d", y, m, d)
end

local function yearKey(year)
    return "year_" .. tostring(year)
end

-- The stored array for a year, as held in the settings file (mutating it
-- and calling saveYear() writes it back).
local function readYear(year)
    local s = openStore()
    if not s then return {} end
    local raw = s:readSetting(yearKey(year))
    if type(raw) ~= "table" then return {} end
    return raw
end

local function saveYear(year, entries)
    local s = openStore()
    if not s then return end
    s:saveSetting(yearKey(year), entries)
    -- Written out immediately: entries are typed in one at a time, and a
    -- crash or battery death between two of them shouldn't lose the lot.
    pcall(function() s:flush() end)
end

function M.list(year)
    local entries = readYear(year)
    local out = {}
    for _idx, e in ipairs(entries) do
        if type(e) == "table" and e.title then
            local added_ts = tonumber(e.ts) or 0
            local read_ts  = tonumber(e.read_ts)
            if not read_ts and e.date then
                read_ts = M.parseDate(e.date)
            end
            table.insert(out, {
                id      = e.id,
                title   = e.title,
                authors = e.authors or "",
                date    = e.date or "",
                read_ts = read_ts or added_ts,
                ts      = added_ts,
            })
        end
    end
    table.sort(out, function(a, b)
        if a.read_ts == b.read_ts then return (a.id or 0) > (b.id or 0) end
        return a.read_ts > b.read_ts
    end)
    return out
end

function M.count(year)
    local n = 0
    for _idx, e in ipairs(readYear(year)) do
        if type(e) == "table" and e.title then n = n + 1 end
    end
    return n
end

local function nextId(entries)
    local max_id = 0
    for _idx, e in ipairs(entries) do
        local id = tonumber(e.id) or 0
        if id > max_id then max_id = id end
    end
    return max_id + 1
end

function M.add(year, fields)
    local title = fields and fields.title
    if not title or title == "" then return nil end
    local entries = readYear(year)
    local read_ts, date = M.parseDate(fields.date)
    local entry = {
        id      = nextId(entries),
        title   = title,
        authors = fields.authors or "",
        date    = date or "",
        read_ts = read_ts,
        ts      = os.time(),
    }
    table.insert(entries, entry)
    saveYear(year, entries)
    return entry
end

function M.update(year, id, fields)
    if not id then return false end
    local entries = readYear(year)
    for _idx, e in ipairs(entries) do
        if e.id == id then
            if fields.title and fields.title ~= "" then e.title = fields.title end
            if fields.authors ~= nil then e.authors = fields.authors end
            if fields.date ~= nil then
                local read_ts, date = M.parseDate(fields.date)
                e.date    = date or ""
                e.read_ts = read_ts
            end
            saveYear(year, entries)
            return true
        end
    end
    return false
end

function M.remove(year, id)
    if not id then return false end
    local entries = readYear(year)
    for i = #entries, 1, -1 do
        if entries[i].id == id then
            table.remove(entries, i)
            saveYear(year, entries)
            return true
        end
    end
    return false
end

return M
