--[[
Reading Insights - shared popup font settings.

Centralises the font choices used by both views (insights_view.lua and
stats_view.lua), so there is exactly one "Fonts" menu and one set of
settings driving every text role in the plugin:

  insights_section  "Reading insights" section headers (Last week, Streaks,
                    year header, Monthly chart, Total read, ...)
  insights_value    "Reading insights" big numbers (hours/pages/streak values)
  insights_label    "Reading insights" unit/description labels next to a value
  insights_small    "Reading insights" chart axis/value labels, small print

  stats_section     "Book progress" section headers (Progress, Pace, ...)
  stats_value       "Book progress" big numbers
  stats_label       "Book progress" unit/description labels
  stats_arrow       "Book progress" chapter-bar prev/next arrow glyphs

  records_value     "Records" popup row values (session/pages/streak/...)
  records_label     "Records" popup row labels (left-hand side of each row)
  records_small     "Records" popup sub-values (date / book title under a value)

Each role has its own font *name* and *size*, independently configurable -
unlike Colors (colors.lua), section/value/label/small are NOT shared
between the two popups here, since the full-screen insights popup and the
compact stats overlay want different sizes for what is conceptually the
same role.

A role's font is tried in this order:
  1. the user's custom font (name set via the Fonts menu), at the user's
     custom size (if set)
  2. this role's original hard-coded default: a specific bundled font file
     (e.g. "NotoSans-Bold.ttf") at its original default size
  3. this role's fallback font *key* from KOReader's own Font.fontmap
     (e.g. "tfont"), at whatever size was being requested
  4. Font.fontmap.cfont, KOReader's own default font, as a last resort

so a missing/renamed font file (a device without that exact bundled font)
can never leave a role without a usable face - it just silently falls back
towards KOReader's own default fonts instead of erroring.

Loaded by main.lua via loadfile(...)( L10N ) and handed straight to both
view modules as their third chunk argument (alongside L10N and Colors), so
`local L10N, Colors, Fonts = ...` at the top of each view is all they need.

Exposes:
  getFace(role)          ready-to-use Font face for TextWidget/TextBoxWidget
                          "face =" (cached per role/name/size combination)
  getName(key) / getSize(key)
                          current custom values (nil if unset -> default)
  getDefaultName(key) / getDefaultSize(key)
                          the original in-code defaults, unaffected by
                          settings
  setName(key, name) / setSize(key, size)
                          validate + persist; return true/false
  resetToDefault(key)    restore the original in-code defaults (both name
                          and size) for one role
  buildMenu(on_change)   KOReader sub_item_table for the "Fonts" menu;
                         on_change() is called after any font is changed
                         or reset, so the caller can refresh open popups
]]--

local ConfirmBox  = require("ui/widget/confirmbox")
local Font        = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu        = require("ui/widget/menu")
local SpinWidget  = require("ui/widget/spinwidget")
local UIManager   = require("ui/uimanager")

local L10N = ...
local _ = L10N._

-- Order (and grouping) the "Fonts" menu is built in.
local INSIGHTS_KEYS = { "insights_section", "insights_value", "insights_label", "insights_small" }
local STATS_KEYS     = { "stats_section", "stats_value", "stats_label", "stats_arrow" }
local RECORDS_KEYS   = { "records_value", "records_label", "records_small" }
local KEY_ORDER = {}
for _, k in ipairs(INSIGHTS_KEYS) do table.insert(KEY_ORDER, k) end
for _, k in ipairs(STATS_KEYS)     do table.insert(KEY_ORDER, k) end
for _, k in ipairs(RECORDS_KEYS)   do table.insert(KEY_ORDER, k) end

-- These match what was previously hard-coded directly in insights_view.lua
-- (its own local getSerifFace(file, fallback_key, size) helper), so
-- upgrading the plugin changes nothing visually until the user opens the
-- new Fonts menu and picks something else.
--
-- stats_view.lua's four roles never had a dedicated setting before (they
-- were part of the same hard-coded call sites as insights_view.lua's), so
-- their defaults here are new, chosen a little smaller to fit the compact
-- overlay - feel free to change them below, or via the Fonts menu.
local DEFAULTS = {
    insights_section = { file = "NotoSans-Bold.ttf",    fallback = "tfont",             size = 22 },
    insights_value   = { file = "NotoSans-Bold.ttf",    fallback = "tfont",             size = 26 },
    insights_label   = { file = "NotoSans-Regular.ttf", fallback = "x_smallinfofont",   size = 20 },
    insights_small   = { file = "NotoSans-Regular.ttf", fallback = "xx_smallinfofont",  size = 15 },

    stats_section    = { file = "NotoSans-Bold.ttf",    fallback = "tfont",             size = 22 },
    stats_value      = { file = "NotoSans-Bold.ttf",    fallback = "tfont",             size = 26 },
    stats_label      = { file = "NotoSans-Regular.ttf", fallback = "x_smallinfofont",   size = 20 },
    stats_arrow      = { file = "NotoSans-Bold.ttf",    fallback = "tfont",             size = 22 },

    records_value    = { file = "NotoSans-Bold.ttf",    fallback = "tfont",             size = 22 },
    records_label    = { file = "NotoSans-Regular.ttf", fallback = "x_smallinfofont",   size = 20 },
    records_small    = { file = "NotoSans-Regular.ttf", fallback = "xx_smallinfofont",  size = 15 },
}

local SETTINGS_NAME_PREFIX = "reading_insights_font_name_"
local SETTINGS_SIZE_PREFIX = "reading_insights_font_size_"

local MIN_SIZE, MAX_SIZE = 8, 60

local function readSetting(key)
    if G_reader_settings and G_reader_settings.readSetting then
        return G_reader_settings:readSetting(key)
    end
    return nil
end

local function saveSetting(key, value)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(key, value)
    end
end

local function normalizeName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    return name
end

local function normalizeSize(size)
    size = tonumber(size)
    if not size then return nil end
    size = math.floor(size + 0.5)
    if size < MIN_SIZE or size > MAX_SIZE then return nil end
    return size
end

local M = {}

function M.getDefaultName(key) return DEFAULTS[key].file end
function M.getDefaultSize(key) return DEFAULTS[key].size end

-- nil (not just the default) is returned when unset, so callers/menu code
-- can tell "using the default" apart from "explicitly set to the same
-- value as the default" if that distinction ever matters.
function M.getName(key)
    return normalizeName(readSetting(SETTINGS_NAME_PREFIX .. key))
end

function M.getSize(key)
    return normalizeSize(readSetting(SETTINGS_SIZE_PREFIX .. key))
end

function M.setName(key, name)
    local n = normalizeName(name)
    if not n then return false end
    saveSetting(SETTINGS_NAME_PREFIX .. key, n)
    M._invalidate(key)
    return true
end

function M.setSize(key, size)
    local n = normalizeSize(size)
    if not n then return false end
    saveSetting(SETTINGS_SIZE_PREFIX .. key, n)
    M._invalidate(key)
    return true
end

function M.resetToDefault(key)
    saveSetting(SETTINGS_NAME_PREFIX .. key, nil)
    saveSetting(SETTINGS_SIZE_PREFIX .. key, nil)
    M._invalidate(key)
end

function M.isDefault(key)
    return M.getName(key) == nil and M.getSize(key) == nil
end

-- Small cache of built Font faces: getFace() is called a good number of
-- times on every single popup rebuild, so avoid re-hitting Freetype/
-- G_reader_settings that often. Invalidated whenever the relevant font
-- setting changes (setName/setSize/resetToDefault above).
local _face_cache = {}

function M._invalidate(key)
    _face_cache[key] = nil
    _face_cache[key .. "__bold"] = nil
end

-- Tries, in order: the given font (name/file or Font.fontmap key) at the
-- given size, then this role's fallback Font.fontmap key at the same
-- size, then KOReader's own default content font. Never errors.
local function buildFace(defaults, font, size)
    local ok, face = pcall(Font.getFace, Font, font, size)
    if ok and face then return face end

    ok, face = pcall(Font.getFace, Font, defaults.fallback, size)
    if ok and face then return face end

    ok, face = pcall(Font.getFace, Font, Font.fontmap and Font.fontmap.cfont or "cfont", size)
    if ok and face then return face end

    return Font:getFace("cfont")
end

function M.getFace(key)
    local defaults = DEFAULTS[key]
    local name = M.getName(key) or defaults.file
    local size = M.getSize(key) or defaults.size

    local cache_key = name .. "@" .. size
    local cached = _face_cache[key]
    if cached and cached.cache_key == cache_key then
        return cached.face
    end

    local face = buildFace(defaults, name, size)
    _face_cache[key] = { cache_key = cache_key, face = face }
    return face
end

-- Bold-weight variant of an existing role's face, at that role's current
-- (possibly user-overridden) size. Used e.g. for the expected-finish day
-- number in the per-book calendar (stats_view.lua), so that one occasional
-- bold day number doesn't need a whole separate font role/menu entry of
-- its own - it just piggybacks on whatever size the caller's role is set
-- to, forcing NotoSans-Bold.ttf instead of that role's own file.
function M.getBoldFace(key)
    local defaults = DEFAULTS[key]
    local size = M.getSize(key) or defaults.size

    local cache_key = "bold@" .. size
    local bold_key = key .. "__bold"
    local cached = _face_cache[bold_key]
    if cached and cached.cache_key == cache_key then
        return cached.face
    end

    local face = buildFace(defaults, "NotoSans-Bold.ttf", size)
    _face_cache[bold_key] = { cache_key = cache_key, face = face }
    return face
end

-- Menu ---------------------------------------------------------------

-- Forward declaration: showFontPickerMenu (below) needs labelFor for its
-- title, but is defined before labelFor for readability (discovery/picker
-- helpers grouped together, ahead of the rest of the menu-building code).
local labelFor

-- Font-file discovery, so the menu can offer a pick-from-list option
-- instead of forcing the user to type an exact file name/alias.
local FONT_EXTENSIONS = { ttf = true, otf = true, ttc = true, otc = true }

local function pluginRootDir()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.*/)") or "./"
end

-- The plugin lives at <koreader_root>/plugins/<name>.koplugin/, so two
-- levels up is KOReader's own bundled "fonts" directory.
local function koreaderFontsDir()
    return pluginRootDir() .. "../../fonts/"
end

-- Scans KOReader's bundled fonts dir plus the user data dir's "fonts"
-- folder (where sideloaded/custom fonts usually live) for font files.
-- Never errors: if lfs or a directory isn't available, just returns
-- whatever was found up to that point (possibly nothing).
local function scanDirForFonts(lfs, dir, found, seen)
    -- lfs.dir() itself normally doesn't error even for a missing directory -
    -- the error only surfaces once the returned iterator is actually
    -- called - so the whole loop (not just the initial lfs.dir() call)
    -- has to run inside pcall.
    pcall(function()
        for entry in lfs.dir(dir) do
            local ext = entry:match("%.([%a]+)$")
            if ext and FONT_EXTENSIONS[ext:lower()] and not seen[entry] then
                seen[entry] = true
                table.insert(found, entry)
            end
        end
    end)
end

local function scanFontFiles()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs then return {} end

    local dirs = { koreaderFontsDir() }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage.getDataDir then
        table.insert(dirs, DataStorage:getDataDir() .. "/fonts/")
    end

    local found, seen = {}, {}
    for _, dir in ipairs(dirs) do
        -- Skip directories that don't exist/aren't readable, so we never
        -- even attempt to iterate them.
        local ok_attr, attr = pcall(lfs.attributes, dir, "mode")
        if ok_attr and attr == "directory" then
            scanDirForFonts(lfs, dir, found, seen)
        end
    end
    table.sort(found, function(a, b) return a:lower() < b:lower() end)
    return found
end

-- Builds the list of selectable names for one role's picker menu: this
-- role's own default file first, then every font file found on disk -
-- de-duplicated, in that priority order. KOReader's internal font-alias
-- keys (Font.fontmap, e.g. "tfont", "cfont") are deliberately left out of
-- this list - they're only used as silent fallbacks in buildFace, not
-- meant to be picked directly, and would just clutter/confuse the top of
-- the list with cryptic short names.
local function getPickerEntries(key)
    local entries, seen = {}, {}

    local default_file = M.getDefaultName(key)
    table.insert(entries, default_file)
    seen[default_file] = true

    for _, file in ipairs(scanFontFiles()) do
        if not seen[file] then
            seen[file] = true
            table.insert(entries, file)
        end
    end

    return entries
end

-- Pick-from-list font chooser: shows every discoverable font file
-- (this role's default plus every font file found on disk) as a
-- checkable Menu, so the user usually never has to type a font name by
-- hand. The free-text InputDialog (showNameInputDialog below) is kept as
-- a separate "Custom" entry for names this scan can't find (e.g. unusual
-- install locations, or a KOReader font alias like "tfont"/"cfont").
local function showFontPickerMenu(key, touchmenu_instance, on_change)
    local entries = getPickerEntries(key)
    local item_table = {}
    for _, name in ipairs(entries) do
        table.insert(item_table, {
            text = name,
            checked_func = function()
                return (M.getName(key) or M.getDefaultName(key)) == name
            end,
        })
    end

    local picker
    picker = Menu:new{
        title = labelFor(key) .. ": " .. _("Choose a font"),
        item_table = item_table,
        single_line = true,
        is_popout = false,
        is_borderless = true,
        onMenuSelect = function(_, item)
            M.setName(key, item.text)
            UIManager:close(picker)
            if touchmenu_instance then touchmenu_instance:updateItems() end
            if on_change then on_change() end
        end,
    }
    UIManager:show(picker)
end

function labelFor(key)
    local labels = {
        insights_section = _("Section headers"),
        insights_value   = _("Values (big numbers)"),
        insights_label   = _("Labels"),
        insights_small   = _("Chart/axis labels"),

        stats_section    = _("Section headers"),
        stats_value      = _("Values (big numbers)"),
        stats_label      = _("Labels"),
        stats_arrow      = _("Chapter-bar arrows"),

        records_value    = _("Values (big numbers)"),
        records_label    = _("Labels"),
        records_small    = _("Sub-values (date / book title)"),
    }
    return labels[key] or key
end

local function showNameInputDialog(key, touchmenu_instance, on_change)
    local dialog
    dialog = InputDialog:new{
        title = labelFor(key) .. ": " .. _("Font name"),
        input = M.getName(key) or M.getDefaultName(key),
        input_hint = "NotoSans-Regular.ttf",
        description = _("Enter a bundled font file name (e.g. NotoSans-Bold.ttf) or a KOReader font alias (e.g. tfont, cfont). If it can't be found, this role falls back to its default font."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id   = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Default"),
                    callback = function()
                        saveSetting(SETTINGS_NAME_PREFIX .. key, nil)
                        M._invalidate(key)
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        if on_change then on_change() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        if M.setName(key, text) then
                            UIManager:close(dialog)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            if on_change then on_change() end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a non-empty font name."),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function showSizeSpinner(key, touchmenu_instance, on_change)
    UIManager:show(SpinWidget:new{
        title_text    = labelFor(key) .. ": " .. _("Font size"),
        value         = M.getSize(key) or M.getDefaultSize(key),
        value_min     = MIN_SIZE,
        value_max     = MAX_SIZE,
        value_step    = 1,
        value_hold_step = 4,
        default_value = M.getDefaultSize(key),
        ok_text       = _("Set"),
        callback      = function(spin)
            M.setSize(key, spin.value)
            if touchmenu_instance then touchmenu_instance:updateItems() end
            if on_change then on_change() end
        end,
    })
end

local function roleSubItemTable(key, on_change)
    return {
        {
            text_func = function()
                return _("Font") .. ": " .. (M.getName(key) or M.getDefaultName(key))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showFontPickerMenu(key, touchmenu_instance, on_change)
            end,
        },
        {
            text = _("Custom font name (type manually)"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showNameInputDialog(key, touchmenu_instance, on_change)
            end,
        },
        {
            text_func = function()
                return _("Font size") .. ": " .. tostring(M.getSize(key) or M.getDefaultSize(key))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showSizeSpinner(key, touchmenu_instance, on_change)
            end,
        },
        {
            text = _("Reset to default"),
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                M.resetToDefault(key)
                if touchmenu_instance then touchmenu_instance:updateItems() end
                if on_change then on_change() end
            end,
        },
    }
end

local function groupSubItemTable(keys, on_change)
    local sub_item_table = {}
    for _, key in ipairs(keys) do
        table.insert(sub_item_table, {
            text_func = function()
                local name = M.getName(key) or M.getDefaultName(key)
                local size = M.getSize(key) or M.getDefaultSize(key)
                return labelFor(key) .. ": " .. name .. " @ " .. tostring(size)
            end,
            keep_menu_open = true,
            sub_item_table = roleSubItemTable(key, on_change),
        })
    end
    return sub_item_table
end

-- Returns the sub_item_table for a "Fonts" menu entry. on_change (optional)
-- is invoked every time a font is changed or reset, so the caller can e.g.
-- close/refresh any currently open popup. The menu itself is always kept
-- in sync via the touchmenu_instance KOReader passes into every callback.
function M.buildMenu(on_change)
    local sub_item_table = {
        {
            text = _("Reading insights"),
            keep_menu_open = true,
            sub_item_table = groupSubItemTable(INSIGHTS_KEYS, on_change),
        },
        {
            text = _("Book progress"),
            keep_menu_open = true,
            sub_item_table = groupSubItemTable(STATS_KEYS, on_change),
        },
        {
            text = _("Records"),
            keep_menu_open = true,
            sub_item_table = groupSubItemTable(RECORDS_KEYS, on_change),
        },
    }
    table.insert(sub_item_table, {
        text = _("Reset all fonts to default"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance)
            UIManager:show(ConfirmBox:new{
                text = _("Reset all fonts to their default values?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    for _, key in ipairs(KEY_ORDER) do
                        M.resetToDefault(key)
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    if on_change then on_change() end
                end,
            })
        end,
    })
    return sub_item_table
end

return M