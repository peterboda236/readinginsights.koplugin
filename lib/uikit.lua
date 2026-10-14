--[[
Reading Insights - shared layout helpers for the popup views.

The small building blocks every popup in this plugin lays its sections out
with: the two-column grid, the section headers and their separator lines,
and the padding/sizing wrappers around them.

Each view used to carry its own copy of these. The copies had started to
drift apart - same names, slightly different bodies - which is exactly the
kind of divergence that makes a fix in one popup silently miss the other, so
they were merged into the versions here. Where the two copies genuinely
differed, this module keeps the more capable one and makes the extra
behaviour opt-in, so the simpler caller is unaffected:

  - buildLayout also returns content_width (the width inside the horizontal
    padding). Callers that don't want it simply don't read it.
  - fixedCol takes an optional explicit height, defaulting to the widget's
    own as before.
  - buildTwoColRow takes an optional hide_separator, and sizes both columns
    and the separator to the taller of the two widgets rather than to the
    left one. For rows whose two cells are the same height - which is every
    row built with buildValueLine - this is identical to what both copies
    did before.
  - addSectionWithRow takes an options table for the divider lines. With no
    options it draws a top divider and a bottom line; pass
    { no_bottom_line = true } for the header + line + row layout with no
    closing line.

Not shared (deliberately): buildValueLine, which really has diverged - the
book progress view's version handles value/unit tables from its stats
gatherer, the insights one takes a plain value and label. Merging those
would mean one function doing two jobs; they're better left apart until
there's a reason to unify them.

Loaded once by main.lua with the shared Colors module.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors =
    deps.Colors

local M = {}

-- Landscape vs. portrait, used to switch a few sections/popups between a
-- layout tuned for a narrow portrait screen and one that makes better use
-- of the extra horizontal room in landscape (e.g. laying value cells out
-- in one row instead of a grid, or capping a popup by screen height instead
-- of width). Screen:getScreenMode() is the proper KOReader API for this
-- (it accounts for the device's rotation quirks); falling back to a plain
-- width/height comparison keeps this working even if that method is ever
-- unavailable.
function M.isLandscapeScreen()
    local ok, mode = pcall(function() return Screen:getScreenMode() end)
    if ok and mode then
        return mode == "landscape"
    end
    return Screen:getWidth() > Screen:getHeight()
end

-- The horizontal geometry every section is built against: the full screen
-- width, the padding either side of it, the gap+line that separates the two
-- columns, and the resulting width of one column.
function M.buildLayout(screen_w, padding_h, column_gap)
    local separator_width = 2 * column_gap + Size.line.medium
    local content_width = screen_w - 2 * padding_h
    local col_width = math.floor((content_width - separator_width) / 2)
    -- Four-column variant (three separators instead of one), used when a
    -- section is wide enough - e.g. the popup in landscape - to lay four
    -- value cells out side by side instead of stacking them 2x2.
    local separator_width_4 = 3 * separator_width
    local col_width_4 = math.floor((content_width - separator_width_4) / 4)
    return {
        full_width      = screen_w,
        padding_h       = padding_h,
        column_gap      = column_gap,
        separator_width = separator_width,
        content_width   = content_width,
        col_width       = col_width,
        col_width_4     = col_width_4,
    }
end

-- Left/right padding around a widget.
function M.padded(padding_h, widget)
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = padding_h },
        widget,
    }
end

-- A widget pinned into a fixed-width column (and, optionally, a fixed
-- height - by default the widget's own).
function M.fixedCol(widget, width, height)
    height = height or widget:getSize().h
    return LeftContainer:new{
        dimen  = Geom:new{ w = width, h = height },
        widget,
    }
end

-- The vertical line between the two columns, with a little breathing room
-- above and below it.
function M.buildColumnSeparator(column_gap, height)
    local v_padding = Size.padding.default
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = column_gap },
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ height = v_padding },
            Colors.newBar(Size.line.medium, height - 2 * v_padding, Colors.separator()),
            VerticalSpan:new{ height = v_padding },
        },
        HorizontalSpan:new{ width = column_gap },
    }
end

-- ---------------------------------------------------------------------
-- Thin progress bar under a row of value cells (Book progress popup: under
-- "This chapter" and under the book percentage). Drawn in the chart's active
-- (done) / inactive (remaining) bar colors. The gap around it is the empty
-- space under the day labels of the weekly bar chart (small-font label height
-- minus its baseline): that is the whole gap below the bar; above it the
-- value text already has its own descent, so only the remainder is added.
-- NB: VerticalSpan only honors `width` (it is the vertical size); `height`
-- is silently ignored.
-- ---------------------------------------------------------------------
M.CELL_BAR_HEIGHT = 5

local function descentOf(widget)
    local ok, d = pcall(function() return widget:getSize().h - widget:getBaseline() end)
    return (ok and d and d > 0) and d or 0
end

function M.buildCellBar(ratio, width, height)
    height = height or M.CELL_BAR_HEIGHT
    ratio = tonumber(ratio) or 0
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end
    -- Same as Bookends' bar fill: floored, no forced minimum. A tiny ratio
    -- that rounds down to 0 px draws no read part at all.
    local done_w = math.floor(width * ratio)
    if done_w < 0 then done_w = 0 end
    if done_w > width then done_w = width end
    local rest_w = width - done_w
    local bar = HorizontalGroup:new{ align = "top" }
    if done_w > 0 then
        table.insert(bar, Colors.newBar(done_w, height, Colors.activeBar()))
    end
    if rest_w > 0 then
        table.insert(bar, Colors.newBar(rest_w, height, Colors.inactiveBar()))
    end
    bar.dimen = Geom:new{ w = width, h = height }
    return bar
end

-- Returns gap_above, gap_below (pixels) for a bar under text set in value_face,
-- measured against small_face (the chart label font).
function M.cellBarGaps(value_face, small_face)
    local small = TextWidget:new{ text = "0", face = small_face }
    local below = descentOf(small)
    small:free()
    if below <= 0 then below = Size.padding.default end
    local value = TextWidget:new{ text = "0", face = value_face }
    local value_descent = descentOf(value)
    value:free()
    return math.max(0, below - value_descent), below
end

-- A bar of `width` pixels with the gap above and below it, to be placed
-- directly under a row of value cells (see M.cellBarGaps). `width` is the
-- bar's own width: one column, or the whole row.
-- `placement`: nil = bar under its row (small gap above, bigger below);
-- "even" = the same gap above and below it (not used by the popup now).
function M.buildRowBar(ratio, width, value_face, small_face, placement, height)
    local above, below = M.cellBarGaps(value_face, small_face)
    if placement == "even" then
        local g = math.max(above, Size.padding.small)
        above, below = g, g
    end
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = above },
        M.buildCellBar(ratio, width, height),
        VerticalSpan:new{ width = below },
    }
end

-- `cell` with the bar under it (so the row's column separator runs down past
-- the bar too). Returns the new widget and the extra height it added, so the
-- row's other cell can be padded to the same height (see M.padBottom).
function M.withCellBar(cell, ratio, width, value_face, small_face)
    local above, below = M.cellBarGaps(value_face, small_face)
    local group = VerticalGroup:new{
        align = "left",
        cell,
        VerticalSpan:new{ width = above },
        M.buildCellBar(ratio, width),
        VerticalSpan:new{ width = below },
    }
    return group, above + M.CELL_BAR_HEIGHT + below
end

-- `cell` kept at its own position (top) but made `extra` pixels taller, so the
-- other cell of a row (which got a bar) doesn't push it down by centering.
function M.padBottom(cell, extra)
    if not extra or extra <= 0 then return cell end
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        padding_bottom = extra,
        cell,
    }
end

-- One row of the two-column grid. `hide_separator` keeps the columns where
-- they are but leaves the gap between them empty.
function M.buildTwoColRow(left_widget, right_widget, layout, hide_separator)
    local row_height = math.max(left_widget:getSize().h, right_widget:getSize().h)
    local separator = hide_separator
        and HorizontalSpan:new{ width = layout.separator_width }
        or  M.buildColumnSeparator(layout.column_gap, row_height)
    return HorizontalGroup:new{
        align = "center",
        M.fixedCol(left_widget,  layout.col_width, row_height),
        separator,
        M.fixedCol(right_widget, layout.col_width, row_height),
    }
end

-- One row of a four-column grid, laid out the same way buildTwoColRow does
-- its two - fixed-width cells separated by the same vertical bar - just
-- three of them instead of one. Used where four value cells fit better
-- side by side (e.g. a wide/landscape popup) than stacked 2x2.
function M.buildFourColRow(w1, w2, w3, w4, layout, hide_separator)
    local row_height = math.max(
        w1:getSize().h, w2:getSize().h, w3:getSize().h, w4:getSize().h)
    local function separator()
        return hide_separator
            and HorizontalSpan:new{ width = layout.separator_width }
            or  M.buildColumnSeparator(layout.column_gap, row_height)
    end
    return HorizontalGroup:new{
        align = "center",
        M.fixedCol(w1, layout.col_width_4, row_height),
        separator(),
        M.fixedCol(w2, layout.col_width_4, row_height),
        separator(),
        M.fixedCol(w3, layout.col_width_4, row_height),
        separator(),
        M.fixedCol(w4, layout.col_width_4, row_height),
    }
end

-- A section title, left-aligned across the full width. `background`
-- optionally overrides the default white fill behind the header text (e.g.
-- a light gray to visually group a header with the section above it).
function M.buildSectionHeader(font_section, text, width, left_padding, background)
    left_padding = left_padding or Size.padding.large
    local text_widget = TextWidget:new{ text = text, face = font_section, fgcolor = Colors.section() }
    return FrameContainer:new{
        background     = background or Blitbuffer.COLOR_WHITE,
        bordersize     = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = left_padding,
        padding_right  = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = width - left_padding, h = text_widget:getSize().h },
            text_widget,
        },
    }
end

-- Appends "header, thin divider, row, closing line" to a sections list.
-- opts (all optional):
--   pad_row          = false  row is inserted without the horizontal padding
--   add_divider      = false  no divider or closing line at all
--   no_top_line      = true   skip the thin divider under the header
--   no_bottom_line   = true   skip the thick line under the row
--   bottom_line_thin = true   draw the line under the row thin instead of
--                             thick (ignored if no_bottom_line is set)
-- Anything other than a table is ignored, so an older call that passed a
-- stray extra argument can't turn into an indexing error here.
function M.addSectionWithRow(sections, header_widget, row, layout, opts)
    local pad_row          = true
    local add_divider      = true
    local no_bottom_line   = false
    local no_top_line      = false
    local bottom_line_thin = false
    if type(opts) == "table" then
        if opts.pad_row          == false then pad_row          = false end
        if opts.add_divider      == false then add_divider      = false end
        if opts.no_bottom_line   == true  then no_bottom_line   = true  end
        if opts.no_top_line      == true  then no_top_line      = true  end
        if opts.bottom_line_thin == true  then bottom_line_thin = true  end
    end

    table.insert(sections, header_widget)
    table.insert(sections, VerticalSpan:new{ height = Size.padding.default })
    if add_divider and not no_top_line then
        table.insert(sections, M.padded(layout.padding_h,
            Colors.newBar(layout.content_width, Size.line.thin, Colors.separator())))
    end
    table.insert(sections, pad_row and M.padded(layout.padding_h, row) or row)
    table.insert(sections, VerticalSpan:new{ height = Size.padding.large })
    if add_divider and not no_bottom_line then
        local bottom_line_size = bottom_line_thin and Size.line.thin or Size.line.thick
        table.insert(sections, M.padded(layout.padding_h,
            Colors.newBar(layout.content_width, bottom_line_size, Colors.separator())))
    end
end

-- Is (x, y) inside this widget's laid-out area? Used by the popups' own tap
-- dispatch, where one handler decides which of several regions was hit.
function M.hitTest(widget, x, y)
    local d = widget and widget.dimen
    if not d then return false end
    return x >= d.x and x <= d.x + d.w and y >= d.y and y <= d.y + d.h
end

-- The "nothing to show" placeholder for a value/unit pair.
function M.emptyValue()
    return { value = "", unit = "" }
end

return M
