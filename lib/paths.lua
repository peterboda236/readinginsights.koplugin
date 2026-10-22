--[[
Reading Insights - where the plugin keeps its files.

Everything the plugin writes lives under one folder, <settings>/readinginsights/:

  data/        what the reader would miss if it were gone (and can't be rebuilt)
                 manual_books.lua    the hand-kept finished-books list
                 achievements.lua    unlocked achievements
                 ratings.lua         ratings edited from the book lists
  cache/       everything that is rebuilt on demand - safe to delete
                 insights.lua        the insights popup's stale / base caches
                 booklists.lua       the tap-through book lists
                 days.lua            per-day totals behind the weekly views
                 records.lua         the Records popup
                 ratings_scan.lua    the sidecar scan behind the ratings
                 lastbook.lua        the last book read (sleep screen)
                 covers/thumb/       300 x 450 thumbnails (calendar, shelf)
                 covers/large/       up to 700 x 1050 covers (book info popup)
  wallpapers/  the reader's own sleep-screen pictures (never touched by the
               plugin, not even when its settings are deleted)
  update/      scratch space of the in-app updater

Before this module existed the files were spread over the settings folder
itself under two different prefixes (reading_insights_* and readinginsights_*).
M.migrate() moves those into the layout above; it runs once when this module
is loaded and is harmless to run again. A file that exists in both places
keeps the newer copy.

This module registers itself in package.loaded (main.lua loads it before any
other plugin file), so every other file just does
    local Paths = require("readinginsights_paths")

No dependencies on the rest of the plugin.
]]--

local LOADED_KEY = "readinginsights_paths"
if package.loaded[LOADED_KEY] then return package.loaded[LOADED_KEY] end

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

M.ROOT_NAME = "readinginsights"

-- Files the plugin used to keep directly in the settings folder:
-- old file name -> new path below the plugin folder.
M.LEGACY_FILES = {
    ["reading_insights_manual_books.lua"]   = "data/manual_books.lua",
    ["reading_insights_achievements.lua"]   = "data/achievements.lua",
    ["reading_insights_ratings.lua"]        = "data/ratings.lua",
    ["reading_insights_cache.lua"]          = "cache/insights.lua",
    ["reading_insights_booklists.lua"]      = "cache/booklists.lua",
    ["reading_insights_days.lua"]           = "cache/days.lua",
    ["readinginsights_records_cache.lua"]   = "cache/records.lua",
    ["reading_insights_ratings_cache.lua"]  = "cache/ratings_scan.lua",
}

-- The same for the first version of the plugin folder, where lastbook.lua sat
-- in the folder itself.
M.LEGACY_ROOT_FILES = {
    ["lastbook.lua"] = "cache/lastbook.lua",
}

local function settingsDir()
    return DataStorage:getSettingsDir()
end

function M.root()
    return settingsDir() .. "/" .. M.ROOT_NAME
end

-- Makes sure the folder exists; true when it does.
local function ensure(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then
        pcall(require("util").makePath, dir .. "/")
    end
    return lfs.attributes(dir, "mode") == "directory"
end
M.ensureDir = ensure

function M.dataDir()
    local d = M.root() .. "/data"
    ensure(d)
    return d
end

function M.cacheDir()
    local d = M.root() .. "/cache"
    ensure(d)
    return d
end

-- Full path of a file in data/ or cache/ (the folder is created if needed).
function M.dataFile(name)  return M.dataDir()  .. "/" .. name end
function M.cacheFile(name) return M.cacheDir() .. "/" .. name end

-- kind: "thumb" or "large". The folder, or nil when it cannot be made.
function M.coverDir(kind)
    local d = M.cacheDir() .. "/covers/" .. kind
    if ensure(d) then return d end
    return nil
end

-- Not created here: the sleep screen makes it when the reader opens it.
function M.wallpaperDir()
    return M.root() .. "/wallpapers"
end

-- The updater's download folder (created if needed), nil when it can't be.
function M.updateDir()
    local d = M.root() .. "/update"
    if ensure(d) then return d end
    return nil
end

-- Migration -------------------------------------------------------------

local function mtime(path)
    local a = lfs.attributes(path)
    return a and a.mode == "file" and (a.modification or 0) or nil
end

-- Moves src to dst. When dst exists already the newer of the two stays.
-- The ".old" backup LuaSettings leaves next to a file is dropped.
local function moveFile(src, dst)
    pcall(os.remove, src .. ".old")
    local st = mtime(src)
    if not st then return end
    local dt = mtime(dst)
    if dt then
        if dt >= st then
            pcall(os.remove, src)
            return
        end
        pcall(os.remove, dst)
    end
    local ok, renamed = pcall(os.rename, src, dst)
    if not (ok and renamed) then
        logger.warn("ReadingInsights: could not move " .. src .. " to " .. dst)
    end
end

local function listDir(dir)
    local names = {}
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if ok and iter then
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
    end
    return names
end

-- readinginsights/covercache/ held both kinds of cover: the small ones as
-- <md5>.jpg and the large ones as bi_<hash>.jpg.
local function migrateCovers()
    local old = M.root() .. "/covercache"
    if lfs.attributes(old, "mode") ~= "directory" then return end
    local thumb, large = M.coverDir("thumb"), M.coverDir("large")
    if not (thumb and large) then return end
    for _i, name in ipairs(listDir(old)) do
        local src = old .. "/" .. name
        local big = name:match("^bi_(.+)$")
        local dst = big and (large .. "/" .. big) or (thumb .. "/" .. name)
        if lfs.attributes(dst, "mode") then
            pcall(os.remove, src)
        else
            pcall(os.rename, src, dst)
        end
    end
    pcall(lfs.rmdir, old)   -- (fails, harmlessly, if something is left)
end

function M.migrate()
    local settings, root = settingsDir(), M.root()
    for old, new in pairs(M.LEGACY_FILES) do
        local src = settings .. "/" .. old
        if mtime(src) then
            M.cacheDir(); M.dataDir()
            moveFile(src, root .. "/" .. new)
        else
            pcall(os.remove, src .. ".old")
        end
    end
    for old, new in pairs(M.LEGACY_ROOT_FILES) do
        local src = root .. "/" .. old
        if mtime(src) then
            M.cacheDir()
            moveFile(src, root .. "/" .. new)
        end
    end
    migrateCovers()
    -- The updater's old scratch folder: only a downloaded zip, no reason to move.
    local old_update = settings .. "/readinginsights_cache"
    if lfs.attributes(old_update, "mode") == "directory" then
        pcall(require("ffi/util").purgeDir, old_update)
    end
end

package.loaded[LOADED_KEY] = M
pcall(M.migrate)

return M
