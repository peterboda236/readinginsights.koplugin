--[[
Reading Insights - shared settings access.

Thin, nil-guarded wrappers around KOReader's global G_reader_settings, so
the "if G_reader_settings and G_reader_settings.readSetting then ..." dance
that used to be copy-pasted into fonts.lua, colors.lua, book_stats_view.lua,
insights_view.lua and main.lua now lives in exactly one place.

  Settings.read(key, default)   read a raw value, `default` if unset/missing
  Settings.readBool(key, def)   read a boolean (only literal true counts)
  Settings.readNum(key, def)    read a number-ish value (same as read; named
                                for call-site clarity)
  Settings.save(key, value)     write a value
  Settings.isTrue(key)          G_reader_settings:isTrue(key)
  Settings.makeTrue(key)        G_reader_settings:makeTrue(key)
  Settings.makeFalse(key)       G_reader_settings:makeFalse(key)

Also the single source of truth for the shared "week start day" setting,
which both the reading heatmaps (insights_view.lua) and the per-book
reading calendar (book_calendar_view.lua) read - previously each derived
it from the same key with its own private helper:

  Settings.readWeekStart()      "monday" (default) or "sunday"
  Settings.saveWeekStart(v)
  Settings.weekStartWday()      0 = Sunday, 1 = Monday (os.date("%w") convention)
]]--

local M = {}

local function store()
    return G_reader_settings
end

function M.read(key, default)
    local s = store()
    if s and s.readSetting then
        local v = s:readSetting(key)
        if v == nil then return default end
        return v
    end
    return default
end

function M.readBool(key, default)
    local s = store()
    if s and s.readSetting then
        local v = s:readSetting(key)
        if v == nil then return default end
        return v == true
    end
    return default
end

-- Numbers are read the same way as any other value; the separate name just
-- documents intent at the call site.
M.readNum = M.read

function M.save(key, value)
    local s = store()
    if s and s.saveSetting then
        s:saveSetting(key, value)
    end
end

function M.isTrue(key)
    local s = store()
    if s and s.isTrue then
        return s:isTrue(key)
    end
    return false
end

function M.makeTrue(key)
    local s = store()
    if s and s.makeTrue then
        s:makeTrue(key)
    end
end

function M.makeFalse(key)
    local s = store()
    if s and s.makeFalse then
        s:makeFalse(key)
    end
end

-- ---------------------------------------------------------------------
-- Shared "week start day" setting.
-- The reading heatmaps and the per-book reading calendar both key their
-- Monday/Sunday layout off this one global setting.
-- ---------------------------------------------------------------------
local WEEK_START_KEY   = "reading_insights_heatmap_week_start"
local DEFAULT_WEEK_START = "monday"
local VALID_WEEK_START = { monday = true, sunday = true }

function M.readWeekStart()
    local v = M.read(WEEK_START_KEY, nil)
    if not VALID_WEEK_START[v] then return DEFAULT_WEEK_START end
    return v
end

function M.saveWeekStart(value)
    M.save(WEEK_START_KEY, value)
end

-- 0 = Sunday, 1 = Monday (os.date("%w") convention).
function M.weekStartWday()
    return M.readWeekStart() == "sunday" and 0 or 1
end

return M
