--[[
Reading Insights - the "Cards" look of the Book progress calendar
(Settings > Appearance > Look).

Builds the same box as book_calendar_view.lua's build() (the Classic look):
the month header with chevron icons, then one card with the cell-content
title (tap: the progress / time / pages list), the weekday row and the day
grid. The grid is the Classic one, given round-ended day bars in the Cards
colors and an outline around today. It returns the same table as build(), so
the popup's landscape fit and tap handling serve both looks.

Loaded once by main.lua and handed to the calendar view as `deps.Cards`. The
view passes its own helpers (`H`) on each build.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors, UI = deps.Colors, deps.UI

local M = {}

-- H: { buildGrid, cellModeCaption, readCellMode } from book_calendar_view.lua.
-- grid_args: buildBookCalendarGrid's arguments (content_width left nil; it is
-- set here to the inside of the card).
function M.build(H, content_width, inner_padding, title_str, section_font, prev_available, next_available, grid_args)
    local card_w = UI.cardInnerWidth(content_width)

    local header, left_frame, right_frame, left_w, right_w, header_h =
        UI.buildNavHeader(title_str, content_width, section_font, prev_available, next_available)

    local args = { unpack(grid_args, 1, 12) }
    args[6] = card_w
    args[13] = {
        bar = function(ratio, w, h) return UI.buildRoundBar(ratio, w, h) end,
        active   = Colors.cardsColor("active_bar"),
        inactive = Colors.cardsColor("inactive_bar"),
        outline  = function(w, h) return UI.buildOutline(w, h) end,
    }
    local grid, day_cells = H.buildGrid(unpack(args, 1, 13))

    -- The card's title: tap opens the cell-content list (onTap hit-tests
    -- _caption_frame).
    local title = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        UI.cardHeader("calendar", H.cellModeCaption(H.readCellMode()), section_font, card_w, "menu"),
    }
    local card = UI.buildCard(VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{ width = Size.padding.default },
        grid,
    }, content_width)

    local box_content = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = Size.padding.small },
            card,
        },
    }

    return {
        content_width     = content_width,
        box_content       = box_content,
        day_cells         = day_cells,
        caption_frame     = title,
        title_row         = header,
        left_arrow_frame  = left_frame,
        right_arrow_frame = right_frame,
        left_w            = left_w,
        right_w           = right_w,
        header_h          = header_h,
    }
end

return M
