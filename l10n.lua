--[[
Reading Insights - shared localisation & number formatting.

Loaded once by main.lua and handed to both views (insights_view.lua and
stats_view.lua), so translation strings live in one place: l10n/<lang>.po.

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

local function pluginDir()
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*/)")
    return dir or "./"
end

local PLUGIN_DIR = pluginDir()

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

local _l10n_cache = {}
local function getL10NMap()
    local lang = "en"
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language") or "en"
    end
    local lang_base = lang:match("^([a-z]+)") or lang
    if _l10n_cache[lang_base] ~= nil then
        return _l10n_cache[lang_base]
    end
    local map = loadPOFile(PLUGIN_DIR .. "l10n/" .. lang_base .. ".po")
    _l10n_cache[lang_base] = map
    return map
end

local function l10nLookup(msg)
    local map = getL10NMap()
    return map[msg]
end

local function _(msg)
    return l10nLookup(msg) or gettext(msg)
end

local function N_(singular, plural, n)
    local singular_override = l10nLookup(singular)
    local plural_override = l10nLookup(plural)
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
local function formatDuration(seconds, without_seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then seconds = 0 end
    local duration_format = "classic"
    if G_reader_settings and G_reader_settings.readSetting then
        duration_format = G_reader_settings:readSetting("duration_format", "classic")
    end
    local datetime = require("datetime")
    return datetime.secondsToClockDuration(duration_format, seconds, without_seconds, false, false)
end

return {
    pluginDir      = pluginDir,
    _              = _,
    N_             = N_,
    getLangBase    = getLangBase,
    formatNumber   = formatNumber,
    formatCount    = formatCount,
    formatDuration = formatDuration,
}
