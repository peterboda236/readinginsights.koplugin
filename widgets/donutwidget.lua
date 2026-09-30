--[[
Reading Insights - donut (ring) chart widget for the book progress view.

A ring filled clockwise from 12 o'clock with the already-read portion, the
rest of the ring in the unread color, and a short text (normally the
percentage, e.g. "23%") centered in the hole. Shown in the "This book"
section when Settings > Book progress popup > "Book
section style" is set to "Donut chart" (see views/book_stats_view.lua and
lib/insights_settings.lua, Opt.readBookSectionStyle). The colors are the donut's own pair, Colors.donutRead() /
Colors.donutUnread(), set under Settings > Colors > Donut chart.

  Donut.build(opts)
      opts.ratio         0.0..1.0 fraction of the book already read
      opts.diameter      outer diameter in pixels
      opts.thickness     ring thickness in pixels (default ~16% of diameter)
      opts.text          text centered in the hole (optional)
      opts.face          font face for that text (optional; if the text
                         would not fit inside the hole, a smaller bold face
                         is used instead)
      opts.text_color    Blitbuffer color for the text (optional)
      opts.read_color / opts.unread_color   Blitbuffer colors (optional,
                         default to the shared progress-bar colors)
      Returns a widget with getSize() == { w = diameter, h = diameter },
      or nil if the diameter is not usable.

The ring is painted pixel-row by pixel-row in horizontal runs (not one call
per pixel), with the outer and inner edges anti-aliased against the white
popup background so it does not look jagged on high-DPI e-ink screens.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors = deps.Colors

local M = {}

local TWO_PI = 2 * math.pi

local DonutWidget = Widget:extend{
    ratio        = 0,
    diameter     = 0,
    thickness    = 0,
    read_color   = nil,
    unread_color = nil,
    text_widget  = nil,
}

function DonutWidget:getSize()
    return Geom:new{ w = self.diameter, h = self.diameter }
end

-- A color mixed toward white by (1 - coverage): what an edge pixel that is
-- only partly covered by the ring looks like on a white background.
local function edgeColor(color, coverage)
    if Blitbuffer.isColor8(color) then
        local g = color.a
        return Blitbuffer.Color8(math.floor(255 - coverage * (255 - g) + 0.5))
    end
    local c = color:getColorRGB32()
    local function mix(v) return math.floor(255 - coverage * (255 - v) + 0.5) end
    return Blitbuffer.ColorRGB32(mix(c.r), mix(c.g), mix(c.b), 0xFF)
end

local function paintSolid(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if Blitbuffer.isColor8(color) then
        bb:paintRect(x, y, w, h, color)
    else
        bb:paintRectRGB32(x, y, w, h, color)
    end
end

function DonutWidget:paintTo(bb, x, y)
    local d = self.diameter
    if d <= 0 then return end
    self.dimen = Geom:new{ x = x, y = y, w = d, h = d }

    local outer_r = d / 2
    local inner_r = math.max(0, outer_r - self.thickness)
    local cx, cy  = outer_r, outer_r
    local ratio   = math.max(0, math.min(1, self.ratio or 0))
    local read_angle = ratio * TWO_PI
    local colors = { self.read_color, self.unread_color }

    for row = 0, d - 1 do
        local dy = (row + 0.5) - cy
        -- Pixel run of the current color, painted as one rectangle once the
        -- color changes (or the row ends / an anti-aliased edge pixel comes).
        local run_start, run_len, run_idx = nil, 0, nil
        local function flush()
            if run_start and run_len > 0 then
                paintSolid(bb, x + run_start, y + row, run_len, 1, colors[run_idx])
            end
            run_start, run_len, run_idx = nil, 0, nil
        end

        for col = 0, d - 1 do
            local dx = (col + 0.5) - cx
            local dist = math.sqrt(dx * dx + dy * dy)
            local coverage = math.min(outer_r - dist + 0.5, dist - inner_r + 0.5, 1)
            if coverage > 0 then
                local angle = math.atan2(dx, -dy)   -- 0 at 12 o'clock, clockwise
                if angle < 0 then angle = angle + TWO_PI end
                local idx = (angle < read_angle) and 1 or 2
                local color = colors[idx]
                if coverage >= 1 then
                    if run_idx == idx and run_start and run_start + run_len == col then
                        run_len = run_len + 1
                    else
                        flush()
                        run_start, run_len, run_idx = col, 1, idx
                    end
                else
                    flush()
                    paintSolid(bb, x + col, y + row, 1, 1, edgeColor(color, coverage))
                end
            else
                flush()
            end
        end
        flush()
    end

    local tw = self.text_widget
    if tw then
        local sz = tw:getSize()
        tw:paintTo(bb, x + math.floor((d - sz.w) / 2), y + math.floor((d - sz.h) / 2))
    end
end

function DonutWidget:free()
    if self.text_widget and self.text_widget.free then self.text_widget:free() end
end

-- Builds the text shown in the hole, shrinking the font until it fits
-- inside the ring's inner circle (with a little margin).
local function buildCenterText(text, face, color, hole_diameter)
    local max_w = math.floor(hole_diameter * 0.86)
    local widget = TextWidget:new{ text = text, face = face, fgcolor = color }
    if widget:getSize().w <= max_w then return widget end
    widget:free()

    local size = (face and face.orig_size) or 26
    while size > 8 do
        size = size - 2
        local ok, smaller = pcall(Font.getFace, Font, "NotoSans-Bold.ttf", size)
        if ok and smaller then
            local w = TextWidget:new{ text = text, face = smaller, fgcolor = color }
            if w:getSize().w <= max_w then return w end
            w:free()
        end
    end
    return TextWidget:new{ text = text, face = Font:getFace("cfont", 8), fgcolor = color }
end

function M.build(opts)
    opts = opts or {}
    local diameter = math.floor(tonumber(opts.diameter) or 0)
    if diameter <= 8 then return nil end

    local thickness = math.floor(tonumber(opts.thickness) or (diameter * 0.16) + 0.5)
    if thickness < 3 then thickness = 3 end
    if thickness > diameter / 2 - 2 then thickness = math.max(2, math.floor(diameter / 2 - 2)) end

    local text_widget
    if opts.text and opts.text ~= "" and opts.face then
        local hole = diameter - 2 * thickness
        text_widget = buildCenterText(opts.text, opts.face, opts.text_color or Colors.value(), hole)
    end

    return DonutWidget:new{
        ratio        = tonumber(opts.ratio) or 0,
        diameter     = diameter,
        thickness    = thickness,
        read_color   = opts.read_color   or Colors.donutRead(),
        unread_color = opts.unread_color or Colors.donutUnread(),
        text_widget  = text_widget,
    }
end

return M
