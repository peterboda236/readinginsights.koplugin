--[[
Reading Insights - shared localisation & number formatting.

Loaded once by main.lua and handed to both views (insights_view.lua and
book_stats_view.lua), so translation strings live in one place: locale/<lang>.po.

Why not KOReader's own gettext .po loader?
Because these plugin translations need to work as plain "msgid"/"msgstr"
overrides that are looked up before falling back to KOReader's own gettext
(so we don't have to touch KOReader's shipped translations to add strings
this plugin needs). The loader here is intentionally tiny: one "msgid"
paired with one "msgstr", each of which may be wrapped across several
quoted continuation lines the way translation tools emit long strings.
It does not handle gettext plural forms (msgid_plural / msgstr[0]); this
plugin's plurals are stored as two independent msgid entries instead (see
N_ below), so a flat msgid->msgstr map is all the .po files need.

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
-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local PluginUtil =
    deps.PluginUtil
local PLUGIN_DIR = PluginUtil.dir

local function unescapePO(s)
    return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

local function loadPOFile(path)
    local map = {}
    local f = io.open(path, "r")
    if not f then return map end

    -- A .po entry can spell its msgid or msgstr across several quoted lines
    -- (Loco and other tools wrap long strings that way, and the file header
    -- always does), so an entry isn't committed the moment its msgstr is
    -- seen: continuation lines - a bare "..." on their own line - are folded
    -- into whichever of key/value is currently open, and the pair is stored
    -- only once the entry ends: at a blank line, a comment, the next msgid,
    -- or end of file. The empty-msgid header entry (key == "") is dropped.
    local key, value = nil, nil
    local in_key, in_value = false, false

    local function commit()
        if key and value and key ~= "" then
            map[key] = value
        end
        key, value, in_key, in_value = nil, nil, false, false
    end

    for raw in f:lines() do
        local line = raw:match("^%s*(.-)%s*$")
        local msgid = line:match('^msgid%s+"(.*)"$')
        local msgstr = line:match('^msgstr%s+"(.*)"$')
        local cont = line:match('^"(.*)"$')
        if msgid ~= nil then
            commit()
            key, in_key, in_value = unescapePO(msgid), true, false
        elseif msgstr ~= nil then
            value, in_value, in_key = unescapePO(msgstr), true, false
        elseif cont ~= nil then
            local piece = unescapePO(cont)
            if in_value then
                value = (value or "") .. piece
            elseif in_key then
                key = (key or "") .. piece
            end
        elseif line == "" or line:match("^#") then
            commit()
        end
    end
    commit()
    f:close()
    return map
end

-- Finds a .po whose language matches `base` but whose region differs, so a
-- language KOReader reports with a region we don't ship a file for still
-- lands on a same-language translation instead of dropping to English:
-- pt_BR borrows pt_PT, a future zh_TW borrows zh_CN, and so on. Pure guess
-- work from the code alone can't do this (there's no pt.po to fall back to),
-- so we actually look at what locale/ contains. Returns the base name (no
-- ".po", no dir) of the first match, or nil - including whenever lfs isn't
-- available (e.g. the test harness), where the caller's other candidates
-- still cover every language that ships an exact or base-code file.
--
-- When several regions of the same language exist (pt_BR.po + pt_PT.po, and
-- the reader is some third pt_XX), the pick is made deterministic by sorting
-- and taking the first, so the borrowed translation is at least stable and
-- predictable rather than dependent on the order lfs.dir() happens to return.
local function findSiblingLocale(base)
    if not base or base == "" then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs then return nil end
    local matches = {}
    -- lfs.dir()'s error only surfaces once its iterator is called, so the
    -- whole loop runs inside pcall (see lib/fonts.lua for the same guard).
    pcall(function()
        for entry in lfs.dir(PLUGIN_DIR .. "locale") do
            local name = entry:match("^(.+)%.po$")
            -- Same base language ("pt" of "pt_BR"/"pt_PT"), any region.
            if name and name:match("^[a-z]+") == base then
                matches[#matches + 1] = name
            end
        end
    end)
    if #matches == 0 then return nil end
    table.sort(matches)
    return matches[1]
end

local _locale_cache = {}
local function getLocaleMap()
    local lang = "en"
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language") or "en"
    end
    local lang_base = lang:match("^([a-z]+)") or lang
    -- Cache by the full language code, so "pt_PT" and a hypothetical "pt_BR"
    -- don't share one entry just because their base ("pt") matches.
    if _locale_cache[lang] ~= nil then
        return _locale_cache[lang]
    end
    -- KOReader stores the language as e.g. "pt_PT" (sometimes "pt-PT"); a
    -- region-specific .po like locale/pt_PT.po must win over the base
    -- locale/pt.po, so try the full code first and only fall back to the
    -- base when there's no region file. Two-letter codes ("hu", "de", "en")
    -- have full == base, so the first load already finds them.
    -- Try, in order: the full region code (pt_PT.po, en_GB.po, zh_CN.po),
    -- the bare base code (en.po for en_GB, zh.po for zh_CN), then any
    -- same-language sibling on disk (pt_PT.po for pt_BR). The first file
    -- that actually loads wins; an empty result just means _() falls
    -- through to KOReader's own gettext. Two-letter codes ("hu", "de",
    -- "en") have full == base, so the first load already finds them.
    local full = lang:gsub("-", "_")
    local candidates = { full }
    if full ~= lang_base then
        candidates[#candidates + 1] = lang_base
    end
    local sibling = findSiblingLocale(lang_base)
    if sibling then
        candidates[#candidates + 1] = sibling
    end
    local map = {}
    for i = 1, #candidates do
        map = loadPOFile(PLUGIN_DIR .. "locale/" .. candidates[i] .. ".po")
        if next(map) ~= nil then break end
    end
    _locale_cache[lang] = map
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

-- Date display format (Settings ▸ Advanced settings ▸ Date & time ▸ "Date
-- format").
-- Every numeric date this plugin prints goes through formatDate() /
-- formatDateFromTS() below, so one setting covers the book lists, the
-- streak/records/stats popups and the Book progress calendar's day detail,
-- instead of each of them guessing the pattern from the interface language.
-- Places that don't print a numeric date - weekday names, month names, the
-- 8-week chart's axis labels - are deliberately left alone.
--
-- No stored value means "what this plugin always did": YYYY.MM.DD. for
-- Hungarian, DD/MM/YYYY everywhere else, so nobody's dates change shape
-- until they pick a format themselves.
local SETTINGS_KEY_DATE_FORMAT = "reading_insights_date_format"

local DATE_FORMAT_YMD_DASH = "ymd_dash"   -- 2026-07-20
local DATE_FORMAT_YMD_DOT  = "ymd_dot"    -- 2026.07.20.
local DATE_FORMAT_DMY      = "dmy_slash"  -- 20/07/2026
local DATE_FORMAT_MDY      = "mdy_slash"  -- 07/20/2026

local VALID_DATE_FORMATS = {
    [DATE_FORMAT_YMD_DASH] = true,
    [DATE_FORMAT_YMD_DOT]  = true,
    [DATE_FORMAT_DMY]      = true,
    [DATE_FORMAT_MDY]      = true,
}

-- The pattern spelled out, as the settings menu lists it and as the manual
-- book list's date field hints it.
local DATE_FORMAT_HINTS = {
    [DATE_FORMAT_YMD_DASH] = "YYYY-MM-DD",
    [DATE_FORMAT_YMD_DOT]  = "YYYY.MM.DD.",
    [DATE_FORMAT_DMY]      = "DD/MM/YYYY",
    [DATE_FORMAT_MDY]      = "MM/DD/YYYY",
}

local function defaultDateFormat()
    return (getLangBase() == "hu") and DATE_FORMAT_YMD_DOT or DATE_FORMAT_DMY
end

local function readDateFormatSetting()
    local v
    if G_reader_settings and G_reader_settings.readSetting then
        v = G_reader_settings:readSetting(SETTINGS_KEY_DATE_FORMAT)
    end
    if not VALID_DATE_FORMATS[v] then return defaultDateFormat() end
    return v
end

local function saveDateFormatSetting(value)
    if not VALID_DATE_FORMATS[value] then return end
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(SETTINGS_KEY_DATE_FORMAT, value)
    end
end

local function dateFormatHint()
    return DATE_FORMAT_HINTS[readDateFormatSetting()]
end

-- no_trailing_dot drops the closing dot of the "2026.07.20." pattern, so
-- the first date of a range reads "2026.07.13 - 2026.07.20."; the other
-- three patterns have no trailing dot to drop and ignore it.
local function formatYMDAs(fmt, y, m, d, no_trailing_dot)
    if fmt == DATE_FORMAT_YMD_DASH then
        return string.format("%04d-%02d-%02d", y, m, d)
    elseif fmt == DATE_FORMAT_YMD_DOT then
        return string.format("%04d.%02d.%02d%s", y, m, d, no_trailing_dot and "" or ".")
    elseif fmt == DATE_FORMAT_MDY then
        return string.format("%02d/%02d/%04d", m, d, y)
    end
    return string.format("%02d/%02d/%04d", d, m, y)
end

local function formatYMD(y, m, d, no_trailing_dot)
    return formatYMDAs(readDateFormatSetting(), y, m, d, no_trailing_dot)
end

-- One date in a format other than the configured one, for the settings
-- menu's "YYYY-MM-DD - 2026-07-20" entries: they show today's date as an
-- example of each pattern, without having to store the pattern first.
local function formatDateSample(fmt, ts)
    local t = os.date("*t", ts or os.time())
    return formatYMDAs(fmt, t.year, t.month, t.day)
end

-- A "YYYY-MM-DD" string (the shape the statistics DB and this plugin's own
-- stores keep dates in) in the configured display format. Anything that
-- isn't a date in that shape is handed back untouched, so a caller passing
-- a DB value through can't turn a surprise into a crash.
local function formatDate(date_str, no_trailing_dot)
    if date_str == nil then return "" end
    local s = tostring(date_str)
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    if not y then return s end
    return formatYMD(tonumber(y), tonumber(m), tonumber(d), no_trailing_dot)
end

-- Same, from a timestamp. Empty string for "no date" (nil / 0), so callers
-- that fill a table column with it leave the cell blank rather than
-- printing the epoch.
local function formatDateFromTS(ts, no_trailing_dot)
    if not ts or ts <= 0 then return "" end
    local t = os.date("*t", ts)
    return formatYMD(t.year, t.month, t.day, no_trailing_dot)
end

-- The reverse, for the one place a date is typed in rather than shown (the
-- manual book list's date field): returns the "YYYY-MM-DD" the store keeps,
-- or nil if the string isn't a date in any accepted pattern. Only the shape
-- is checked here - whether the day exists is settled by the caller
-- (ManualBooks.parseDate), which does the round trip anyway.
--
-- ISO is accepted whatever the setting is: it's unambiguous, and it's what
-- earlier versions asked for, so old habits keep working. DD/MM vs MM/DD
-- can't be told apart from the text alone, so those follow the setting.
local function parseDateInput(str)
    local s = tostring(str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    if not y then
        y, m, d = s:match("^(%d%d%d%d)%.(%d%d?)%.(%d%d?)%.?$")
    end
    if not y then
        local a, b, c = s:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)$")
        if a then
            y = c
            if readDateFormatSetting() == DATE_FORMAT_MDY then
                m, d = a, b
            else
                d, m = a, b
            end
        end
    end
    if not y then return nil end
    return string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
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
    formatDate                 = formatDate,
    formatDateFromTS           = formatDateFromTS,
    formatDateSample           = formatDateSample,
    parseDateInput             = parseDateInput,
    dateFormatHint             = dateFormatHint,
    readDateFormatSetting      = readDateFormatSetting,
    saveDateFormatSetting      = saveDateFormatSetting,
    DATE_FORMATS               = {
        DATE_FORMAT_YMD_DASH,
        DATE_FORMAT_YMD_DOT,
        DATE_FORMAT_DMY,
        DATE_FORMAT_MDY,
    },
    DATE_FORMAT_HINTS          = DATE_FORMAT_HINTS,
}
