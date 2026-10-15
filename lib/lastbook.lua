--[[
Reading Insights - the last book read, kept for the sleep screen.

The book popups (Book progress, Book progress calendar, Book info) are built
from the open book: the live reader, its TOC, the statistics plugin. From the
file manager there is no open book, so the sleep screen could not draw them.
This module keeps a snapshot of the last book's data - taken when a book is
closed - so those popups can be drawn from the file manager too, exactly as
they looked when the book was left.

  LastBook.capture(ui)   take the snapshot of the open book (pcall-guarded;
                         called from main.lua's onCloseDocument)
  LastBook.get()         -> the snapshot, or nil when there is none or it is
                            not the last book read any more:

      file      path of the book
      book_id   its id in the statistics DB (nil when it has no statistics)
      md5       its checksum (the key its rating is filed under)
      title, authors
      stats     what the Book progress popup gathered (plain data)

The snapshot is kept in memory and in
<KOReader settings dir>/readinginsights/lastbook.lua, so it survives a restart.
]]--

local deps = ...
local StatsPopup   = deps.StatsPopup
local BookInfoData = deps.BookInfoData

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local M = {}

local SUBDIR = "readinginsights"
local KEY    = "lastbook"

-- nil = not read from disk yet, false = nothing saved
local memo

local function dir()  return DataStorage:getSettingsDir() .. "/" .. SUBDIR end
local function path() return dir() .. "/lastbook.lua" end

-- A copy of `v` holding only what can be written to a settings file: no
-- functions or userdata, no NaN / infinity, no cycles, bounded depth.
local MAX_DEPTH = 8
local function clean(v, depth, seen)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return v
    elseif t == "string" or t == "boolean" then
        return v
    elseif t == "table" then
        if depth > MAX_DEPTH or seen[v] then return nil end
        seen[v] = true
        local out = {}
        for k, x in pairs(v) do
            local kt = type(k)
            if kt == "string" or kt == "number" then
                local c = clean(x, depth + 1, seen)
                if c ~= nil then out[k] = c end
            end
        end
        seen[v] = nil
        return out
    end
    return nil
end

function M.capture(ui)
    local file = ui and ui.document and ui.document.file
    if not file then return end
    local ok, err = pcall(function()
        local stats = StatsPopup.gatherStats{ ui = ui }
        if not stats then return end
        local info = BookInfoData.gather(ui) or {}
        local snap = clean({
            file     = file,
            book_id  = stats.book_id,
            md5      = BookInfoData.md5(ui),
            title    = info.title,
            authors  = info.authors,
            stats    = stats,
            saved_at = os.time(),
        }, 0, {})
        if not snap then return end
        memo = snap

        if lfs.attributes(dir(), "mode") ~= "directory" then
            require("util").makePath(dir() .. "/")
        end
        local settings = require("luasettings"):open(path())
        settings:saveSetting(KEY, snap)
        settings:flush()
    end)
    if not ok then
        logger.warn("ReadingInsights: last book snapshot failed:", tostring(err))
    end
end

function M.get()
    if memo == nil then
        local ok, v = pcall(function()
            if lfs.attributes(path(), "mode") ~= "file" then return false end
            return require("luasettings"):open(path()):readSetting(KEY) or false
        end)
        memo = (ok and type(v) == "table") and v or false
    end
    if not memo then return nil end

    local file = memo.file
    if type(file) ~= "string" or lfs.attributes(file, "mode") ~= "file" then
        return nil
    end
    -- Only while it is still the last book read: the cover behind the popup
    -- (core's "last file") has to be the same book.
    local last = G_reader_settings and G_reader_settings:readSetting("lastfile")
    if last and last ~= file then return nil end
    return memo
end

return M
