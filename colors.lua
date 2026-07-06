--[[
Reading Insights - shared chart/text color settings.

Centralises the color choices used by both views (insights_view.lua and
stats_view.lua), so there is exactly one "Colors" menu and one set of
settings driving every chart/diagram and label in the plugin:

  active_bar    "current" bar/point in a chart (today's bar, the current
                month, the current chapter's read portion, the trend dot)
  inactive_bar  every other bar/point, and chart baselines
  trend_line    the connecting line in the "last 8 weeks" trend chart
  label         "label" font role   (units/descriptions next to a value)
  value         "value" font role   (the big numbers)
  section       "section" font role (section headers, year header)
  small         "small" font role   (chart axis/value labels, small print)

Colors are stored as "#RRGGBB" hex strings in G_reader_settings - the same
format KOReader itself accepts (see Blitbuffer.colorFromString), so any
hex code the user can look up (a website color picker, another app, ...)
works here too.

Loaded by main.lua via loadfile(...)( L10N ) and handed straight to both
view modules as their second chunk argument (alongside L10N), so
`local L10N, Colors = ...` at the top of each view is all they need.

Exposes:
  getColor(key)         Blitbuffer color object, ready to use as
                         fgcolor/background/line_color/etc.
  activeBar() / inactiveBar() / label() / value() / section() / small()
                         same as getColor(key), one shorthand per key
  getHex(key)            current "#RRGGBB" value
  getDefaultHex(key)      the original in-code default, unaffected by settings
  setHex(key, hex)       validate + persist; returns true/false
  resetToDefault(key)    restore the original in-code default
  buildMenu(on_change)   KOReader sub_item_table for the "Colors" menu;
                         on_change() is called after any color is changed
                         or reset, so the caller can refresh open popups
]]--

local Blitbuffer  = require("ffi/blitbuffer")
local ConfirmBox  = require("ui/widget/confirmbox")
local Geom        = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget  = require("ui/widget/linewidget")
local UIManager    = require("ui/uimanager")
local Widget      = require("ui/widget/widget")

local L10N = ...
local _ = L10N._

-- ---------------------------------------------------------------------
-- Custom hex colors need bb:paintRectRGB32, not bb:paintRect.
--
-- Blitbuffer.colorFromString("#RRGGBB") always returns a 32bit RGB color
-- object, even for plain black/white/gray. LineWidget:paintTo (the
-- widget used for every bar, dot and baseline in both popups) always
-- calls bb:paintRect(), which only handles the handful of native 8bit
-- grayscale colors (Blitbuffer.COLOR_BLACK/GRAY/WHITE/...) correctly -
-- on an actual (typically 8bit/grayscale) e-ink framebuffer, feeding it
-- an arbitrary RGB32 color silently misrenders (usually as black),
-- which is why custom colors otherwise look like they "don't work".
-- Patching paintTo to fall back to bb:paintRectRGB32() for genuinely
-- non-8bit colors fixes this, while leaving every other LineWidget in
-- KOReader (and our own native-color usages) untouched.
-- Guarded so re-loading this module never wraps paintTo twice.
if not LineWidget._reading_insights_rgb_patch then
    local original_paintTo = LineWidget.paintTo

    function LineWidget:paintTo(bb, x, y)
        if self.style == "none" then return end
        if not self.background or Blitbuffer.isColor8(self.background) then
            return original_paintTo(self, bb, x, y)
        end

        local function paintRect(px, py, w, h, color)
            bb:paintRectRGB32(px, py, w, h, color)
        end

        if self.style == "dashed" then
            for i = 0, self.dimen.w - 20, 20 do
                paintRect(x + i, y, 16, self.dimen.h, self.background)
            end
        elseif self.empty_segments then
            paintRect(x, y, self.empty_segments[1].s, self.dimen.h, self.background)
            paintRect(x + self.empty_segments[1].e, y,
                self.dimen.w - self.empty_segments[1].e, self.dimen.h, self.background)
        else
            paintRect(x, y, self.dimen.w, self.dimen.h, self.background)
        end
    end

    LineWidget._reading_insights_rgb_patch = true
end
-- ---------------------------------------------------------------------

-- A small solid-color rectangle widget, used everywhere a bar/dot/
-- baseline needs one of *our* user-configurable colors (active_bar,
-- inactive_bar, ...). Deliberately independent from the LineWidget
-- patch above (belt-and-braces): it always picks the right bb paint
-- call itself, rather than relying on a monkey-patched shared class,
-- so bar colors can't silently keep rendering black/gray if that patch
-- ever fails to apply for any reason.
local ColorBar = Widget:extend{
    width  = nil,
    height = nil,
    color  = nil,
}

function ColorBar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ColorBar:paintTo(bb, x, y)
    if not self.color then return end
    if Blitbuffer.isColor8(self.color) then
        bb:paintRect(x, y, self.width, self.height, self.color)
    else
        bb:paintRectRGB32(x, y, self.width, self.height, self.color)
    end
end

-- Order the "Colors" menu is built in.
local KEY_ORDER = { "active_bar", "inactive_bar", "trend_line", "label", "value", "section", "small" }

-- These match what was previously hard-coded directly in the two view
-- files (Blitbuffer.COLOR_BLACK = "#000000", Blitbuffer.COLOR_GRAY = "#AAAAAA"),
-- so upgrading the plugin changes nothing visually until the user opens
-- the new Colors menu and picks something else.
local DEFAULTS = {
    active_bar   = "#000000",
    inactive_bar = "#AAAAAA",
    trend_line   = "#000000",
    label        = "#000000",
    value        = "#000000",
    section      = "#000000",
    small        = "#000000",
}

local SETTINGS_PREFIX = "reading_insights_color_"

local function normalizeHex(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("%s+", "")
    if hex == "" then return nil end
    if hex:sub(1, 1) ~= "#" then hex = "#" .. hex end
    hex = hex:upper()
    if hex:match("^#%x%x%x%x%x%x$") then return hex end
    return nil
end

local function readHex(key)
    if G_reader_settings and G_reader_settings.readSetting then
        local n = normalizeHex(G_reader_settings:readSetting(SETTINGS_PREFIX .. key))
        if n then return n end
    end
    return DEFAULTS[key]
end

local function saveHex(key, hex)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(SETTINGS_PREFIX .. key, hex)
    end
end

-- Small cache of built Blitbuffer color objects: getColor() is called a
-- couple dozen times on every single popup rebuild, so avoid reparsing the
-- hex string and hitting G_reader_settings that often. Invalidated
-- whenever the relevant color changes (setHex/resetToDefault below).
local _color_cache = {}

local function buildColor(hex)
    local ok, color = pcall(Blitbuffer.colorFromString, hex)
    if ok and color then return color end
    return Blitbuffer.COLOR_BLACK
end

local M = {}

function M.getDefaultHex(key)
    return DEFAULTS[key]
end

function M.getHex(key)
    return readHex(key)
end

function M.getColor(key)
    local hex = readHex(key)
    local cached = _color_cache[key]
    if cached and cached.hex == hex then
        return cached.color
    end
    local color = buildColor(hex)
    _color_cache[key] = { hex = hex, color = color }
    return color
end

-- Solid-color rectangle (bar segment, baseline, trend dot, ...) that
-- always renders the given color correctly - see the ColorBar widget
-- above. `color` is a Blitbuffer color object, e.g. from getColor()/
-- activeBar()/inactiveBar().
function M.newBar(width, height, color)
    return ColorBar:new{ width = width, height = height, color = color }
end

function M.setHex(key, hex)
    local n = normalizeHex(hex)
    if not n then return false end
    saveHex(key, n)
    _color_cache[key] = nil
    return true
end

function M.resetToDefault(key)
    saveHex(key, DEFAULTS[key])
    _color_cache[key] = nil
end

function M.isDefault(key)
    return readHex(key) == DEFAULTS[key]
end

-- One shorthand accessor per key - reads more naturally than
-- Colors.getColor("active_bar") at the many call sites in both views.
function M.activeBar()   return M.getColor("active_bar")   end
function M.inactiveBar() return M.getColor("inactive_bar") end
function M.trendLine()   return M.getColor("trend_line")   end
function M.label()       return M.getColor("label")        end
function M.value()       return M.getColor("value")        end
function M.section()     return M.getColor("section")      end
function M.small()       return M.getColor("small")        end

-- Menu ---------------------------------------------------------------

local function labelFor(key)
    local labels = {
        active_bar   = _("Active column color"),
        inactive_bar = _("Inactive column color"),
        trend_line   = _("Trend chart line color"),
        label        = _("Label color"),
        value        = _("Value color"),
        section      = _("Section color"),
        small        = _("Chart label color"),
    }
    return labels[key] or key
end

local function showHexInputDialog(key, touchmenu_instance, on_change)
    local dialog
    dialog = InputDialog:new{
        title   = labelFor(key),
        input   = M.getHex(key),
        input_hint = "#RRGGBB",
        description = _("Enter a hex color code (e.g. #1E90FF), the way KOReader expects it."),
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
                        M.resetToDefault(key)
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
                        if M.setHex(key, text) then
                            UIManager:close(dialog)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                            if on_change then on_change() end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Not a valid hex color code, e.g. #1E90FF."),
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

-- Returns the sub_item_table for a "Colors" menu entry. on_change (optional)
-- is invoked every time a color is changed or reset, so the caller can e.g.
-- close/refresh any currently open popup. The menu itself is always kept
-- in sync via the touchmenu_instance KOReader passes into every callback.
function M.buildMenu(on_change)
    local sub_item_table = {}
    for _, key in ipairs(KEY_ORDER) do
        table.insert(sub_item_table, {
            text_func = function()
                return labelFor(key) .. ": " .. M.getHex(key)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showHexInputDialog(key, touchmenu_instance, on_change)
            end,
        })
    end
    table.insert(sub_item_table, {
        text = _("Reset all colors to default"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance)
            UIManager:show(ConfirmBox:new{
                text = _("Reset all colors to their default values?"),
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
