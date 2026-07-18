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

Loaded by main.lua with the shared Colors module as its chunk argument.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

-- Shared modules, passed in as one named table by main.lua. Named rather
-- than positional on purpose: the list had grown long enough that
-- inserting one module in the middle would silently shift every module
-- after it, and the resulting nil would only surface far from the cause.
local deps = ...
local Colors =
    deps.Colors

local M = {}

-- The horizontal geometry every section is built against: the full screen
-- width, the padding either side of it, the gap+line that separates the two
-- columns, and the resulting width of one column.
function M.buildLayout(screen_w, padding_h, column_gap)
    local separator_width = 2 * column_gap + Size.line.medium
    local content_width = screen_w - 2 * padding_h
    local col_width = math.floor((content_width - separator_width) / 2)
    return {
        full_width      = screen_w,
        padding_h       = padding_h,
        column_gap      = column_gap,
        separator_width = separator_width,
        content_width   = content_width,
        col_width       = col_width,
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

-- A section title, left-aligned across the full width.
function M.buildSectionHeader(font_section, text, width, left_padding)
    left_padding = left_padding or Size.padding.large
    local text_widget = TextWidget:new{ text = text, face = font_section, fgcolor = Colors.section() }
    return FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
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
--   pad_row        = false  row is inserted without the horizontal padding
--   add_divider    = false  no divider or closing line at all
--   no_top_line    = true   skip the thin divider under the header
--   no_bottom_line = true   skip the thick line under the row
-- Anything other than a table is ignored, so an older call that passed a
-- stray extra argument can't turn into an indexing error here.
function M.addSectionWithRow(sections, header_widget, row, layout, opts)
    local pad_row        = true
    local add_divider    = true
    local no_bottom_line = false
    local no_top_line    = false
    if type(opts) == "table" then
        if opts.pad_row        == false then pad_row        = false end
        if opts.add_divider    == false then add_divider    = false end
        if opts.no_bottom_line == true  then no_bottom_line = true  end
        if opts.no_top_line    == true  then no_top_line    = true  end
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
        table.insert(sections, M.padded(layout.padding_h,
            Colors.newBar(layout.content_width, Size.line.thick, Colors.separator())))
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
