--[[
Reading Insights - "skim bar" widget for the book progress view.

An alternative to the per-chapter bar chart (widgets/chapterbarwidget.lua),
picked in Settings > Book progress popup > "Chapter bar
style". It is drawn exactly like the progress bar in KOReader's own "Skim
to" dialog (frontend/ui/widget/skimtowidget.lua, which uses
frontend/ui/widget/progresswidget.lua): a rounded, black-bordered bar filled
from the left up to the current page, with a thin vertical line at the start
of every chapter, and the position marker - the small triangle pointing down
from the top and the one pointing up from the bottom - sitting at the
current page.

What differs from the stock widget is the colors:

  * the filled (already read) part and the rest of the bar use their own two
    colors from Settings > Colors > Skim bar (Read / Unread portion color),
    instead of KOReader's fixed dark/light gray;
  * each chapter separator is drawn black or white, whichever contrasts with
    the color it lies on (the read color left of the current page, the
    unread one right of it), so it stays visible whatever colors are set;
  * the position marker is KOReader's own "position.marker" icon, drawn
    with alpha exactly like the stock widget (the same 80% black triangles
    at the top and bottom, the bar showing through them).

  SkimBar.readHeightSetting() / SkimBar.saveHeightSetting(v) / SkimBar.DEFAULT_HEIGHT
      the bar's height in "points" (Settings > Advanced
      settings > Bar chart height > "Book progress: Skim bar"), read on
      every build
  SkimBar.build(skim, full_width)
      skim         { percentage = 0..1, ticks = { page, ... }, last = page count }
                   (see gatherStats in views/book_stats_view.lua)
      full_width   total width of the widget, in pixels
      Returns a widget with getSize() == { w = full_width, h = <height> },
      or nil if there is nothing usable to draw.
]]--

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Widget = require("ui/widget/widget")
local Screen = require("device").screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors = deps.Colors

local M = {}

local SETTINGS_KEY_HEIGHT = "reading_insights_skim_bar_height"
-- The height KOReader's Skim dialog uses in its compact layout.
M.DEFAULT_HEIGHT = 36
M.MIN_HEIGHT = 12
M.MAX_HEIGHT = 200

function M.readHeightSetting()
    if G_reader_settings and G_reader_settings.readSetting then
        local v = G_reader_settings:readSetting(SETTINGS_KEY_HEIGHT)
        if type(v) ~= "number" then return M.DEFAULT_HEIGHT end
        return v
    end
    return M.DEFAULT_HEIGHT
end

function M.saveHeightSetting(value)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(SETTINGS_KEY_HEIGHT, value)
    end
end

-- Paints a solid rectangle in any Blitbuffer color: native gray colors go
-- through paintRect, the RGB32 objects Colors.getColor() hands out through
-- paintRectRGB32 (see the long comment on ColorBar in lib/colors.lua - the
-- plain call silently misrenders them on a grayscale framebuffer).
local function fillRect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if Blitbuffer.isColor8(color) then
        bb:paintRect(x, y, w, h, color)
    else
        bb:paintRectRGB32(x, y, w, h, color)
    end
end

-- 0 (black) .. 255 (white) brightness of any Blitbuffer color.
local function brightness(color)
    local ok, gray = pcall(function() return color:getColor8().a end)
    if ok and type(gray) == "number" then return gray end
    return 0
end

-- The separator/outline color that stands out against `background`.
local function contrastColor(background)
    if brightness(background) < 128 then
        return Blitbuffer.COLOR_WHITE
    end
    return Blitbuffer.COLOR_BLACK
end

local SkimBarWidget = Widget:extend{
    width       = nil,
    height      = nil,
    percentage  = 0,
    ticks       = nil,
    last        = nil,
    -- Same proportions as ProgressWidget's default ("thick") style.
    margin_h    = nil,
    margin_v    = nil,
    radius      = nil,
    bordersize  = nil,
    tick_width  = nil,
    bordercolor = Blitbuffer.COLOR_BLACK,
    bgcolor     = Blitbuffer.COLOR_WHITE,
}

function SkimBarWidget:init()
    self.margin_h   = self.margin_h   or Screen:scaleBySize(3)
    self.margin_v   = self.margin_v   or Screen:scaleBySize(1)
    self.radius     = self.radius     or Screen:scaleBySize(2)
    self.bordersize = self.bordersize or Screen:scaleBySize(1)
    self.tick_width = self.tick_width or Size.line.medium

    -- Like ProgressWidget:setHeight(): keep at least one pixel of actual
    -- bar inside the margins and border, whatever the height setting is.
    local min_inner = 2 * self.bordersize + 1
    self.margin_v = math.max(0, math.min(self.margin_v, math.floor((self.height - min_inner) / 2)))
    self.bordersize = math.max(1, math.min(self.bordersize,
        math.floor((self.height - 2 * self.margin_v - 1) / 2)))
end

function SkimBarWidget:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

-- A filled isosceles triangle, one horizontal line at a time (Blitbuffer
-- has no polygon call). (cx, y) is the middle of the base edge, `dir` is
-- 1 for a triangle hanging down from y (base on top, tip below) and -1
-- for one standing up from y (base at the bottom, tip above).
local function paintTriangle(bb, cx, y, base_w, tri_h, dir, color)
    for row = 0, tri_h - 1 do
        local w = math.floor(base_w * (1 - row / tri_h) + 0.5)
        if w > 0 then
            local ry = (dir == 1) and (y + row) or (y - row - 1)
            fillRect(bb, cx - math.floor(w / 2), ry, w, 1, color)
        end
    end
end

-- The marker is the stock "position.marker" icon (a downward triangle from
-- the top edge and an upward one from the bottom edge of a square as high as
-- the bar), painted with alpha on top of the bar like ProgressWidget does, so
-- it looks and blends exactly like in KOReader's Skim dialog. The stock
-- widget switches to the top-only "position.marker.top" below a height
-- threshold; here the full marker is always used.
function SkimBarWidget:getMarkerIcon()
    if self._marker_icon == nil then
        local ok, icon = pcall(function()
            local IconWidget = require("ui/widget/iconwidget")
            return IconWidget:new{
                icon   = "position.marker",
                width  = self.height,
                height = self.height,
                alpha  = true,
            }
        end)
        self._marker_icon = ok and icon or false
    end
    return self._marker_icon
end

function SkimBarWidget:free()
    if self._marker_icon then
        self._marker_icon:free()
    end
    self._marker_icon = nil
end

-- Fallback if the icon can't be loaded: two flat triangles in the icon's
-- shade (80% black on white = 0x33).
function SkimBarWidget:paintFallbackMarker(bb, marker_x, y)
    local h      = self.height
    local tri_h  = math.max(3, math.floor(h * 15 / 48 + 0.5))
    local base_w = math.max(3, math.floor(h * 17.3 / 48 + 0.5))
    local color  = Blitbuffer.COLOR_GRAY_3 or Blitbuffer.Color8(0x33)
    paintTriangle(bb, marker_x, y, base_w, tri_h, 1, color)
    paintTriangle(bb, marker_x, y + h, base_w, tri_h, -1, color)
end

function SkimBarWidget:paintMarker(bb, marker_x, y)
    local icon = self:getMarkerIcon()
    if icon then
        icon:paintTo(bb, math.floor(marker_x - self.height / 2 + 0.5), y)
    else
        self:paintFallbackMarker(bb, marker_x, y)
    end
end

function SkimBarWidget:paintTo(bb, x, y)
    local size = self:getSize()
    if not self.dimen then
        self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    else
        self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h = x, y, size.w, size.h
    end
    if size.w <= 0 or size.h <= 0 then return end

    local mirrored = BD.mirroredUILayout()
    local active, inactive = Colors.skimBarRead(), Colors.skimBarUnread()

    local fill_x      = x + self.margin_h + self.bordersize
    local fill_y      = y + self.margin_v + self.bordersize
    local fill_width  = size.w - 2 * (self.margin_h + self.bordersize)
    local fill_height = size.h - 2 * (self.margin_v + self.bordersize)
    if fill_width <= 0 or fill_height <= 0 then return end

    -- White rounded background, then the black border around it - the same
    -- two calls ProgressWidget makes.
    bb:paintRoundedRect(x, y, size.w, size.h, self.bgcolor, self.radius)
    bb:paintBorder(math.floor(x), math.floor(y), size.w, size.h,
        self.bordersize, self.bordercolor, self.radius)

    -- The unread part (inactive color) over the whole inner area, and the
    -- read part (active color) from the left (right when mirrored) up to
    -- the current page.
    local pct = math.max(0, math.min(1, self.percentage or 0))
    fillRect(bb, fill_x, fill_y, math.ceil(fill_width), math.ceil(fill_height), inactive)

    local read_w = math.ceil(fill_width * pct)
    local read_x = fill_x
    if mirrored then read_x = math.floor(fill_x + fill_width * (1 - pct)) end
    fillRect(bb, read_x, fill_y, read_w, math.ceil(fill_height), active)

    -- Chapter separators: black or white, whichever shows against the
    -- color under them.
    local on_active   = contrastColor(active)
    local on_inactive = contrastColor(inactive)
    if self.ticks and self.last and self.last > 0 then
        for _idx, tick in ipairs(self.ticks) do
            local ratio  = tick / self.last
            local tick_x = fill_width * ratio
            -- Keep a separator that sits at the very end inside the bar.
            tick_x = math.min(tick_x, fill_width - self.tick_width)
            if mirrored then tick_x = fill_width - tick_x - self.tick_width end
            tick_x = math.floor(math.max(0, tick_x))
            local read_part = (ratio <= pct)
            fillRect(bb, fill_x + tick_x, fill_y, self.tick_width, math.ceil(fill_height),
                read_part and on_active or on_inactive)
        end
    end

    -- Position marker at the current page, on top of everything else.
    local marker_x
    if mirrored then
        marker_x = fill_x + math.ceil(fill_width - fill_width * pct)
    else
        marker_x = fill_x + math.ceil(fill_width * pct)
    end
    self:paintMarker(bb, marker_x, y)
end

function M.build(skim, full_width)
    if not skim or not full_width or full_width <= 0 then return nil end
    local height = Screen:scaleBySize(M.readHeightSetting())
    if height < 1 then return nil end
    return SkimBarWidget:new{
        width      = full_width,
        height     = height,
        percentage = tonumber(skim.percentage) or 0,
        ticks      = skim.ticks,
        last       = skim.last,
    }
end

return M
