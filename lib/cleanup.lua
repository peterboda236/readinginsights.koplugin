--[[
Reading Insights - removing what the plugin wrote, for "Also delete plugin
settings" in KOReader's Plugin management.

main.lua loads this module when the plugin starts and keeps it: by the time
KOReader calls ReadingInsights:deletePluginSettings() the plugin folder has
already been deleted, so nothing can be loaded from it any more.

What goes:
  - the plugin folder <settings>/readinginsights/ (data, caches, covers,
    updater scratch) - except wallpapers/, which holds the reader's own
    pictures; that folder is removed only if it is empty
  - anything left in the flat layout of older versions: every file or folder
    in the settings folder whose name starts with reading_insights or
    readinginsights (a sweep by prefix, so a file this version does not know
    about is caught too)
  - the picture the image export wrote (readinginsights_wallpaper.*) and its
    folder, if that is empty then
  - every G_reader_settings key of the plugin (same two prefixes), and core's
    sleep screen type when it points at this plugin

Needs only Paths (which main.lua loads first).
]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local Paths = require("readinginsights_paths")

local M = {}

local WALLPAPERS = "wallpapers"
local EXPORT_DIR = "screensaver/readinginsights_png"
local EXPORT_FILE = "readinginsights_wallpaper"
local EXPORT_EXTS = { "png", "jpg", "bmp" }

local function hasOurPrefix(name)
    return type(name) == "string"
        and (name:find("^reading_insights") or name:find("^readinginsights")) and true or false
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

local function remove(path)
    if lfs.attributes(path, "mode") == "directory" then
        pcall(require("ffi/util").purgeDir, path)
    else
        pcall(os.remove, path)
    end
end

-- Everything under the plugin folder except the reader's wallpapers.
local function removePluginFolder()
    local root = Paths.root()
    if lfs.attributes(root, "mode") ~= "directory" then return end
    for _i, name in ipairs(listDir(root)) do
        if name ~= WALLPAPERS then remove(root .. "/" .. name) end
    end
    -- Both only work on an empty folder: wallpapers/ goes when the reader
    -- kept no pictures in it, and the plugin folder when that was the last thing.
    pcall(lfs.rmdir, root .. "/" .. WALLPAPERS)
    pcall(lfs.rmdir, root)
end

-- The flat layout of older versions.
local function removeLegacyFiles()
    local settings = DataStorage:getSettingsDir()
    for _i, name in ipairs(listDir(settings)) do
        -- (the plugin folder itself was dealt with above - it may keep wallpapers)
        if name ~= Paths.ROOT_NAME and hasOurPrefix(name) then
            remove(settings .. "/" .. name)
        end
    end
end

local function removeExportedImage()
    local dir = DataStorage:getDataDir() .. "/" .. EXPORT_DIR
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for _i, ext in ipairs(EXPORT_EXTS) do
        pcall(os.remove, dir .. "/" .. EXPORT_FILE .. "." .. ext)
    end
    pcall(lfs.rmdir, dir)   -- only if nothing else is in it
end

-- Every G_reader_settings key the plugin wrote. Sweeping by prefix also
-- clears the per-year keys (reading goals, finished-book overrides) whose
-- names aren't known up front. Keys are collected first and deleted after, so
-- the table is not changed while it is being walked.
local function removeSettingsKeys(screensaver_type)
    if not (G_reader_settings and G_reader_settings.delSetting) then return end
    local to_delete = {}
    for key in pairs(G_reader_settings.data or {}) do
        if hasOurPrefix(key) then to_delete[#to_delete + 1] = key end
    end
    for _i, key in ipairs(to_delete) do
        G_reader_settings:delSetting(key)
    end
    -- If this plugin is the current sleep screen, that is core's own
    -- "screensaver_type" (not one of our keys): reset it so it does not point
    -- at a plugin that no longer exists.
    if screensaver_type and G_reader_settings:readSetting("screensaver_type") == screensaver_type then
        G_reader_settings:saveSetting("screensaver_type", "disable")
    end
end

-- `screensaver_type` is the value the plugin registers in core's
-- "screensaver_type" setting.
function M.deletePluginSettings(screensaver_type)
    pcall(removePluginFolder)
    pcall(removeLegacyFiles)
    pcall(removeExportedImage)
    pcall(removeSettingsKeys, screensaver_type)
end

return M
