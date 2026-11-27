--[[
Reading Insights - radar chart of the "Last 7 days" section (Cards look,
Settings > Reading insights popup > Chart style = Radar).

One spoke per day, clockwise from the top. A day's point sits on its spoke
between the centre (nothing read) and the outer ring (the week's highest
value). Around the chart every
spoke carries its label lines and, under them, the day's value. Today's
point is hatched and its label bold. Only the existing colors are used:
the grid in the cards' divider color, the area in the inactive bar color,
its outline and the points in the active bar color.

  Radar.build(opts)
      opts.width       widget width in pixels; the height follows from it
      opts.ratios      per spoke 0..1, false for a day still to come (no point)
      opts.labels      per spoke a list of label lines (e.g. { "11-20" })
      opts.values      per spoke the value text, under the label lines
      opts.highlight   spoke index of today, or nil
      opts.face        font face of the labels and values
      opts.on_tap      per spoke a callback for a tap on its label, or nil
      opts.on_widget   function(spoke, widget), called with every label's
                       tappable widget
      Returns a widget, or nil if the width is not usable.

Lines, the area and the points are painted with bb:paintRect runs only (as
the trend chart's LineChartWidget), so no diagonal-line primitive is needed.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Screen = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors = deps.Colors

-- Rings of the grid (the outer one included).
local GRID_RINGS = 3

local function painter(bb, color)
    return Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32
end

local function spokeDir(k, n)
    local a = -math.pi / 2 + 2 * math.pi * (k - 1) / n
    return math.cos(a), math.sin(a)
end

local RadarPlot = Widget:extend{
    width  = nil,
    height = nil,
}

function RadarPlot:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

local function stampLine(bb, paint, color, x0, y0, x1, y1, th)
    local half = math.floor(th / 2)
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy), 1)
    local last_px, last_py
    for s = 0, steps do
        local t  = s / steps
        local px = math.floor(x0 + dx * t + 0.5)
        local py = math.floor(y0 + dy * t + 0.5)
        if px ~= last_px or py ~= last_py then
            paint(bb, px - half, py - half, th, th, color)
            last_px, last_py = px, py
        end
    end
end

local function stampPolygon(bb, paint, color, pts, th)
    for k = 1, #pts do
        local p, q = pts[k], pts[k % #pts + 1]
        stampLine(bb, paint, color, p.x, p.y, q.x, q.y, th)
    end
end

-- Scanline fill: every pixel row between the crossings of the outline.
local function fillPolygon(bb, paint, color, pts)
    local min_y, max_y = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p.y < min_y then min_y = p.y end
        if p.y > max_y then max_y = p.y end
    end
    for row = math.floor(min_y), math.ceil(max_y) do
        local sy = row + 0.5
        local xs = {}
        for k = 1, #pts do
            local p, q = pts[k], pts[k % #pts + 1]
            if (p.y <= sy and q.y > sy) or (q.y <= sy and p.y > sy) then
                xs[#xs + 1] = p.x + (sy - p.y) * (q.x - p.x) / (q.y - p.y)
            end
        end
        table.sort(xs)
        for k = 1, #xs - 1, 2 do
            local x0, x1 = math.floor(xs[k] + 0.5), math.floor(xs[k + 1] + 0.5)
            if x1 > x0 then paint(bb, x0, row, x1 - x0, 1, color) end
        end
    end
end

local function discRows(cx, cy, r, fn)
    for dy = -r, r do
        local half = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
        fn(cx - half, cy + dy, 2 * half + 1, dy)
    end
end

local function paintDisc(bb, paint, color, cx, cy, r)
    discRows(cx, cy, r, function(x, y, w) paint(bb, x, y, w, 1, color) end)
end

-- Today's point: a ring in `color` with diagonal stripes inside, like the
-- hatched bar of the Cards look's bar chart.
local function paintHatchedDisc(bb, paint, color, cx, cy, r, ring)
    paintDisc(bb, painter(bb, Blitbuffer.COLOR_WHITE), Blitbuffer.COLOR_WHITE, cx, cy, r)
    local sw  = math.max(1, math.ceil(Size.line.thick))
    local sw2 = 2 * sw
    discRows(cx, cy, r - ring, function(x, y, w)
        for px = x, x + w - 1 do
            if (px + y) % sw2 < sw then paint(bb, px, y, 1, 1, color) end
        end
    end)
    for dy = -r, r do
        local outer = math.sqrt(math.max(0, r * r - dy * dy))
        local ri    = r - ring
        local inner = (math.abs(dy) <= ri) and math.sqrt(ri * ri - dy * dy) or -1
        local o, i  = math.floor(outer + 0.5), math.floor(inner + 0.5)
        if i < 0 then
            paint(bb, cx - o, cy + dy, 2 * o + 1, 1, color)
        elseif o > i then
            paint(bb, cx - o, cy + dy, o - i, 1, color)
            paint(bb, cx + i + 1, cy + dy, o - i, 1, color)
        end
    end
end

-- Where every day's point sits when the plot is painted at (x, y): on its
-- spoke, ratio * radius from the centre (a day still to come at the centre).
function RadarPlot:shapePoints(x, y)
    local n, cx, cy, r = #self.ratios, x + self.cx, y + self.cy, self.radius
    local shape = {}
    for k = 1, n do
        local c, s = spokeDir(k, n)
        local d = r * (self.ratios[k] or 0)
        shape[k] = { x = cx + c * d, y = cy + s * d }
    end
    return shape
end

function RadarPlot:paintTo(bb, x, y)
    local n, cx, cy, r = #self.ratios, x + self.cx, y + self.cy, self.radius
    local grid, fill, line = self.grid_color, self.fill_color, self.line_color
    local grid_paint, fill_paint, line_paint = painter(bb, grid), painter(bb, fill), painter(bb, line)

    local shape = self:shapePoints(x, y)

    fillPolygon(bb, fill_paint, fill, shape)

    local grid_th = math.max(1, Size.line.thin)
    for ring = 1, GRID_RINGS do
        local rr, pts = r * ring / GRID_RINGS, {}
        for k = 1, n do
            local c, s = spokeDir(k, n)
            pts[k] = { x = cx + c * rr, y = cy + s * rr }
        end
        stampPolygon(bb, grid_paint, grid, pts, grid_th)
    end
    for k = 1, n do
        local c, s = spokeDir(k, n)
        stampLine(bb, grid_paint, grid, cx, cy, cx + c * r, cy + s * r, grid_th)
    end

    stampPolygon(bb, line_paint, line, shape, self.line_thickness)

    for k = 1, n do
        if self.ratios[k] then
            local px, py = math.floor(shape[k].x + 0.5), math.floor(shape[k].y + 0.5)
            if k == self.highlight then
                paintHatchedDisc(bb, line_paint, line, px, py, self.today_radius, self.line_thickness)
            else
                paintDisc(bb, line_paint, line, px, py, self.dot_radius)
            end
        end
    end
end

local M = {}

function M.build(opts)
    local width = math.floor(opts.width or 0)
    local n = #opts.ratios
    if width <= 0 or n < 3 then return nil end
    local face = opts.face

    -- One block per spoke: its label lines, then the value in bold.
    local blocks = {}
    for k = 1, n do
        local group = VerticalGroup:new{ align = "center" }
        for _, text in ipairs(opts.labels[k] or {}) do
            table.insert(group, TextWidget:new{
                text = text, face = face, fgcolor = Colors.small(),
                bold = (k == opts.highlight) and true or false,
            })
        end
        if opts.values[k] and opts.values[k] ~= "" then
            table.insert(group, TextWidget:new{ text = opts.values[k], face = face, fgcolor = Colors.value(), bold = true })
        end
        blocks[k] = group
    end

    -- The largest radius with every block still inside the width; a block
    -- sits just outside its spoke's end, pushed out by half its own size and
    -- clear of a point on the outer ring.
    local today_radius = math.floor(Screen:scaleBySize(12) / 2)
    local gap = Size.padding.small + today_radius
    local radius = math.floor(width * 0.36)
    local sizes = {}
    for k = 1, n do
        local sz = blocks[k]:getSize()
        sizes[k] = sz
        local c = math.abs((spokeDir(k, n)))
        if c > 0.01 then
            local fit = (width / 2 - sz.w / 2 * (1 + c)) / c - gap
            if fit < radius then radius = math.floor(fit) end
        end
    end
    if radius < Screen:scaleBySize(20) then return nil end

    local offsets, top, bottom = {}, 0, 0
    for k = 1, n do
        local c, s = spokeDir(k, n)
        local sz = sizes[k]
        local bx = (radius + gap) * c + c * sz.w / 2
        local by = (radius + gap) * s + s * sz.h / 2
        offsets[k] = { bx - sz.w / 2, by - sz.h / 2 }
        top    = math.min(top, by - sz.h / 2)
        bottom = math.max(bottom, by + sz.h / 2)
    end
    local cx, cy = math.floor(width / 2), math.ceil(-top)
    local height = cy + math.ceil(bottom)

    local plot = RadarPlot:new{
        width = width, height = height, cx = cx, cy = cy, radius = radius,
        ratios = opts.ratios, highlight = opts.highlight,
        grid_color = Colors.cardsColor("divider"),
        fill_color = Colors.inactiveBar(),
        line_color = Colors.activeBar(),
        line_thickness = math.max(2, Size.line.thick),
        dot_radius   = math.floor(Screen:scaleBySize(8) / 2),
        today_radius = today_radius,
    }
    local chart = OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, plot }
    for k = 1, n do
        local sz = sizes[k]
        local cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h },
            blocks[k],
        }
        local on_tap = opts.on_tap and opts.on_tap[k]
        if on_tap then
            cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
            cell.onTap = function() on_tap(); return true end
        end
        if opts.on_widget then opts.on_widget(k, cell) end
        cell.overlap_offset = { cx + math.floor(offsets[k][1] + 0.5), cy + math.floor(offsets[k][2] + 0.5) }
        table.insert(chart, cell)
    end
    return chart
end

return M
