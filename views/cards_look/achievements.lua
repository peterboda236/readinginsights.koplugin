--[[
Reading Insights - the "Cards" look of the achievements list
(Settings > Appearance > Look).

The list (views/achievements_view.lua, drawn by widgets/booklistwidget.lua)
keeps its title bar, sort / filter menu, paging and taps; in the Cards look
every page starts with a summary card ("37 / 81 earned", a bar, "★ new") and
each achievement is a card of its own: black border when earned, light gray
when still locked.

Loaded once by main.lua and handed to the achievements view as `deps.AchievementsCards`.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, UI = deps.Locale, deps.Colors, deps.Fonts, deps.UI

local _           = Locale._
local formatCount = Locale.formatCount

local STAR = "\u{2605}"

local M = {}

local function borderColor(name)
    local c = Colors.cardsColor(name)
    return Blitbuffer.isColor8(c) and c or c:getColor8()
end

-- The summary card, `width` wide.
function M.summary(width, earned, total, has_new)
    local inner_w = UI.cardInnerWidth(width)
    local gap = Size.padding.default
    local small = Fonts.getFace("records_small")

    local v = TextWidget:new{ text = formatCount(earned), face = Fonts.getFace("records_value"), fgcolor = Colors.value() }
    local pill = has_new and UI.buildPill(STAR .. " " .. _("new"), small) or nil
    local pill_w = pill and (pill:getSize().w + gap) or 0
    local label = TextWidget:new{
        text = "/ " .. formatCount(total) .. " " .. _("earned"),
        face = Fonts.getFace("records_label"), fgcolor = Colors.label(),
        max_width = math.max(1, inner_w - v:getSize().w - gap - pill_w),
    }
    local line = HorizontalGroup:new{ align = "center", v, HorizontalSpan:new{ width = gap }, label }
    if pill then
        table.insert(line, HorizontalSpan:new{ width = inner_w - v:getSize().w - gap - label:getSize().w - pill:getSize().w })
        table.insert(line, pill)
    end

    return UI.buildCard(VerticalGroup:new{
        align = "left",
        UI.cardHeader("trophy", _("Achievements"), Fonts.getBoldFace("records_small"), inner_w),
        VerticalSpan:new{ width = Size.padding.small },
        line,
        VerticalSpan:new{ width = gap },
        UI.buildRoundBar(total > 0 and earned / total or 0, inner_w, Screen:scaleBySize(6)),
        VerticalSpan:new{ width = Size.padding.small },
    }, width)
end

-- One achievement as a card exactly `width` x `height`: the glyph in a
-- fixed column, the name, "★" for a new one and the unlock date on the right.
function M.row(item, width, height, face, fgcolor)
    local border = UI.cardBorder()
    local pad = Size.padding.default
    local gap = Size.padding.default
    local inner_w = width - 2 * (border + pad)
    local inner_h = height - 2 * border

    local right = HorizontalGroup:new{ align = "center" }
    if item.is_new then
        table.insert(right, UI.buildPill(STAR, Fonts.getFace("records_small")))
        table.insert(right, HorizontalSpan:new{ width = gap })
    end
    if item.mandatory and item.mandatory ~= "" then
        table.insert(right, TextWidget:new{ text = item.mandatory, face = face, fgcolor = fgcolor })
    end
    local right_w = right:getSize().w

    local icon = TextWidget:new{ text = item.icon or "", face = face, fgcolor = fgcolor, bold = item.bold }
    local icon_col = icon:getSize().h
    local title_w = inner_w - icon_col - gap - (right_w > 0 and right_w + gap or 0)

    local title = TextWidget:new{
        text = item.text, face = face, fgcolor = fgcolor, bold = item.bold,
        max_width = math.max(1, title_w),
    }
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = icon_col, h = inner_h }, icon },
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{ dimen = Geom:new{ w = math.max(1, title_w), h = inner_h }, title },
    }
    if right_w > 0 then
        table.insert(row, HorizontalSpan:new{ width = gap })
        table.insert(row, right)
    end

    return FrameContainer:new{
        background    = Blitbuffer.COLOR_WHITE,
        bordersize    = border,
        color         = borderColor(item.dim and "divider" or "border"),
        radius        = Size.radius.button,
        padding       = 0,
        padding_left  = pad,
        padding_right = pad,
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, row },
    }
end

return M
