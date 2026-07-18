--[[
Reading Insights - shared localisation & number formatting.

Loaded once by main.lua and handed to both views (insights_view.lua and
book_stats_view.lua), so translation strings live in one place: locale/<lang>.po.

Why not KOReader's own gettext .po loader?
Because these plugin translations need to work as plain "msgid"/"msgstr"
overrides that are looked up before falling back to KOReader's own gettext
(so we don't have to touch KOReader's shipped translations to add strings
this plugin needs). The loader here is intentionally tiny: it only
understands one "msgid" line followed by one "msgstr" line, which is all
these .po files use.

Exposes:
  _(msg)                       translate a string
  N_(singular, plural, n)      translate with plural handling
  getLangBase()                current language's base code ("hu", "en", ...)
  formatNumber(n, decimals)    locale-aware number formatting (HU: space
                                thousands separator + comma decimal;
                                EN: comma thousands separator + period decimal)
  formatCount(value)           formatNumber wrapper that also accepts strings
]]--

local gettext = require("gettext")

-- Shared plugin loader/dir helper, passed in by main.lua (see pluginutil.lua).
-- Shared modules, passed in as one named table by main.lua. Named rather
-- than positional on purpose: the list had grown long enough that
-- inserting one module in the middle would silently shift every module
-- after it, and the resulting nil would only surface far from the cause.
local deps = ...
local PluginUtil =
    deps.PluginUtil
local PLUGIN_DIR = PluginUtil.dir

local function unescapePO(s)
    return (s:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

local function loadPOFile(path)
    local map = {}
    local f = io.open(path, "r")
    if not f then return map end
    local pending_key = nil
    for line in f:lines() do
        local msgid = line:match('^msgid%s+"(.*)"%s*$')
        local msgstr = line:match('^msgstr%s+"(.*)"%s*$')
        if msgid ~= nil then
            pending_key = unescapePO(msgid)
        elseif msgstr ~= nil and pending_key ~= nil then
            if pending_key ~= "" then
                map[pending_key] = unescapePO(msgstr)
            end
            pending_key = nil
        end
    end
    f:close()
    return map
end

local _locale_cache = {}
local function getLocaleMap()
    local lang = "en"
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language") or "en"
    end
    local lang_base = lang:match("^([a-z]+)") or lang
    if _locale_cache[lang_base] ~= nil then
        return _locale_cache[lang_base]
    end
    local map = loadPOFile(PLUGIN_DIR .. "locale/" .. lang_base .. ".po")
    _locale_cache[lang_base] = map
    return map
end

local function localeLookup(msg)
    local map = getLocaleMap()
    return map[msg]
end

local function _(msg)
    return localeLookup(msg) or gettext(msg)
end

local function N_(singular, plural, n)
    local singular_override = localeLookup(singular)
    local plural_override = localeLookup(plural)
    if singular_override or plural_override then
        if n == 1 then
            return singular_override or plural_override
        end
        return plural_override or singular_override
    end
    return gettext.ngettext(singular, plural, n)
end

local _cached_lang_base = nil
local function getLangBase()
    if not _cached_lang_base then
        local lang = "en"
        if G_reader_settings and G_reader_settings.readSetting then
            lang = G_reader_settings:readSetting("language") or "en"
        end
        _cached_lang_base = lang:match("^([a-z]+)") or lang
    end
    return _cached_lang_base
end

local function formatNumber(n, decimals)
    if n == nil then return "" end
    decimals = decimals or 0
    local is_hu = (getLangBase() == "hu")

    -- fast path for small integers
    if decimals == 0 and n >= 0 and n < 10000 then
        return tostring(math.floor(n))
    end

    local fmt = "%." .. decimals .. "f"
    local s = string.format(fmt, n)
    local int, frac = s:match("^(%-?%d+)%.*(%d*)$")
    if not int then return s end

    local absInt = int:gsub("^%-", "")
    local threshold = is_hu and 5 or 4  -- HU: from 10 000 (5 digits); EN: from 1,000 (4 digits)
    if #absInt >= threshold then
        if is_hu then
            int = int:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
        else
            int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        end
    end

    if frac ~= "" then
        return int .. (is_hu and "," or ".") .. frac
    end
    return int
end

local function formatCount(value)
    if value == nil then return "" end
    if type(value) == "number" then
        return formatNumber(value, 0)
    end
    return tostring(value)
end

-- Long-duration display (Settings ▸ Advanced settings ▸ "Show long
-- durations as days"). Off by default (existing "51:03"-style clock
-- format is unchanged); when the user turns it on, any duration this
-- plugin formats that reaches 24h or more is shown as a day count instead
-- ("2.1 days" / "2,1 nap"). Read by formatDuration() every time a
-- duration is formatted, so a change takes effect immediately.
local SETTINGS_KEY_DURATION_DAYS = "reading_insights_duration_over_24h_as_days"
local DEFAULT_DURATION_DAYS      = false
local SECONDS_PER_DAY            = 86400

local function readDurationDaysSetting()
    if G_reader_settings and G_reader_settings.has and G_reader_settings.isTrue then
        if G_reader_settings:has(SETTINGS_KEY_DURATION_DAYS) then
            return G_reader_settings:isTrue(SETTINGS_KEY_DURATION_DAYS)
        end
    end
    return DEFAULT_DURATION_DAYS
end

local function saveDurationDaysSetting(value)
    if G_reader_settings and G_reader_settings.saveSetting then
        if value then
            G_reader_settings:makeTrue(SETTINGS_KEY_DURATION_DAYS)
        else
            G_reader_settings:makeFalse(SETTINGS_KEY_DURATION_DAYS)
        end
    end
end

-- Truncates (never rounds up) n to the given number of decimal places, so
-- e.g. 2.99 days at 0 decimals reads "2 days", not "3 days" - a duration
-- isn't a full extra day until it's actually elapsed.
local function floorToDecimals(n, decimals)
    local mult = 10 ^ decimals
    return math.floor(n * mult) / mult
end

-- Formats a duration (in seconds) as "HH:MM" (without_seconds = true) or
-- "HH:MM:SS" (without_seconds = false / omitted), honouring KOReader's
-- global "duration_format" setting (Settings ▸ Time and date ▸ Duration
-- format) - the same setting the built-in statistics plugin uses:
--   "classic"  -> "1:30:10" / "1:30"
--   "modern"   -> "1h30'10\"" / "1h30'"
--   "letters"  -> "1h 30m 10s" / "1h 30m"
-- This is what makes clock-style time displays in this plugin (chapter/book
-- time left, time spent, etc.) match whatever format the user picked for
-- the rest of KOReader, instead of always showing a hardcoded "HH:MM".
--
-- If "Show long durations as days" is enabled and seconds reaches 24h or
-- more, this instead returns a day count with one decimal place
-- ("2.1 days" / "2,1 nap"), rounded down rather than to the nearest,
-- since "51:03" stops being a useful clock reading once it crosses a day.
--
-- Returns { value = "<number part>", unit = "<trailing word, or \"\">" }
-- so callers that render the value/unit in different styles (e.g. the
-- stats popup's bold-number + plain-label layout) can keep "7,3" bold
-- without also bolding "nap". Plain formatDuration() below just joins
-- the two back into a single string for callers that don't need that
-- split.
local function formatDaysParts(seconds)
    local decimals = 1
    local days = floorToDecimals(seconds / SECONDS_PER_DAY, decimals)
    local value_str = formatNumber(days, decimals)
    local unit_str = N_("day", "days", (days == 1) and 1 or 2)
    return { value = value_str, unit = unit_str }
end

local function formatDurationParts(seconds, without_seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then seconds = 0 end

    if seconds >= SECONDS_PER_DAY and readDurationDaysSetting() then
        return formatDaysParts(seconds)
    end

    local duration_format = "classic"
    if G_reader_settings and G_reader_settings.readSetting then
        duration_format = G_reader_settings:readSetting("duration_format", "classic")
    end
    local datetime = require("datetime")
    local clock_str = datetime.secondsToClockDuration(duration_format, seconds, without_seconds, false, false)
    return { value = clock_str, unit = "" }
end

-- Duration as value/unit parts with the seconds dropped, and an empty
-- placeholder for "no data" (nil) or a NaN that slipped out of a division.
-- Both the book progress view and its calendar formatted times this way with
-- their own identical copies of this wrapper.
local function formatTimeHHMM(seconds)
    if not seconds or seconds ~= seconds then
        return { value = "", unit = "" }
    end
    return formatDurationParts(seconds, true)
end

local function formatDuration(seconds, without_seconds)
    local parts = formatDurationParts(seconds, without_seconds)
    if parts.unit == "" then
        return parts.value
    end
    return parts.value .. " " .. parts.unit
end

return {
    pluginDir                  = pluginDir,
    _                          = _,
    N_                         = N_,
    getLangBase                = getLangBase,
    formatNumber               = formatNumber,
    formatCount                = formatCount,
    formatDuration             = formatDuration,
    formatDurationParts        = formatDurationParts,
    formatTimeHHMM             = formatTimeHHMM,
    readDurationDaysSetting    = readDurationDaysSetting,
    saveDurationDaysSetting    = saveDurationDaysSetting,
}
