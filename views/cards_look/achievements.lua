--[[
Reading Insights - the "Cards" look of the achievements list
(Settings > Appearance > Look).

The list (views/achievements_view.lua, drawn by widgets/booklistwidget.lua)
keeps its title bar, sort / filter menu, paging and taps; in the Cards look
every page starts with a summary card ("37 / 81 earned", a bar, "★ new") and
each achievement is a card of its own: card border color when earned, light
gray when still locked. A card shows the name (with "★" and the unlock date)
on top and how to earn it below, so it needs no tap to read.

Loaded once by main.lua and handed to the achievements view as `deps.AchievementsCards`.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
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

local function smallFace()
    return Fonts.getFace("records_small")
end

-- The summary card, `width` wide.
function M.summary(width, earned, total, has_new)
    local inner_w = UI.cardInnerWidth(width)
    local gap = Size.padding.default
    local small = smallFace()

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

local function lineHeight(face, bold)
    local probe = TextWidget:new{ text = " ", face = face, bold = bold }
    local h = probe:getSize().h
    probe:free()
    return h
end

-- The height of one achievement card for the list's row `face`.
function M.rowHeight(face)
    return 2 * (UI.cardBorder() + Size.padding.small)
        + lineHeight(face, true) + lineHeight(smallFace())
end

-- One achievement as a card exactly `width` x `height`: the glyph in a
-- fixed column; the name, "★" for a new one and the unlock date on the
-- first line; the description (cut with "…" when too long) below.
function M.row(item, width, height, face, fgcolor)
    local border = UI.cardBorder()
    local pad = Size.padding.default
    local gap = Size.padding.default
    local inner_w = width - 2 * (border + pad)
    local inner_h = height - 2 * border
    local small = smallFace()
    local sub_color = item.dim and fgcolor or Colors.label()

    local right = HorizontalGroup:new{ align = "center" }
    if item.is_new then
        table.insert(right, UI.buildPill(STAR, small))
        table.insert(right, HorizontalSpan:new{ width = gap })
    end
    if item.mandatory and item.mandatory ~= "" then
        table.insert(right, TextWidget:new{ text = item.mandatory, face = small, fgcolor = sub_color })
    end
    local right_w = right:getSize().w

    local icon = TextWidget:new{ text = item.icon or "", face = face, fgcolor = fgcolor, bold = item.bold }
    local icon_col = icon:getSize().h
    local text_w = math.max(1, inner_w - icon_col - gap)
    local title_w = math.max(1, text_w - (right_w > 0 and right_w + gap or 0))

    local title = TextWidget:new{
        text = item.text, face = face, fgcolor = fgcolor, bold = item.bold,
        max_width = title_w,
    }
    local top = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = title_w, h = title:getSize().h }, title },
    }
    if right_w > 0 then
        table.insert(top, HorizontalSpan:new{ width = gap })
        table.insert(top, right)
    end

    local lines = VerticalGroup:new{ align = "left", top }
    if item.desc and item.desc ~= "" then
        table.insert(lines, TextWidget:new{
            text = item.desc, face = small, fgcolor = sub_color, max_width = text_w,
        })
    end

    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = icon_col, h = inner_h }, icon },
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{ dimen = Geom:new{ w = text_w, h = inner_h }, lines },
    }

    return UI.cardFrame{
        background    = Blitbuffer.COLOR_WHITE,
        bordersize    = border,
        color         = Colors.cardsColor(item.dim and "divider" or "card_border"),
        radius        = UI.cardRadius(),
        padding       = 0,
        padding_left  = pad,
        padding_right = pad,
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, row },
    }
end

return M
