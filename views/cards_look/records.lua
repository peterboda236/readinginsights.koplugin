--[[
Reading Insights - the "Cards" look of the Records popup
(Settings > Appearance > Look).

The popup (views/records_view.lua) keeps its centred window and the "Records"
title; in the Cards look the rows become cards: the two best days side by
side, the best daily streak, and the last / next milestone in one card with
a bar from the last milestone to the next.

Loaded once by main.lua and handed to the records view as `deps.Cards`.
]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, UI = deps.Locale, deps.Colors, deps.Fonts, deps.UI

local _           = Locale._
local N_          = Locale.N_
local formatCount = Locale.formatCount
local formatDate  = Locale.formatDate

local DASH = "\xE2\x80\x93"

local M = {}

-- Icon + title; the title wraps instead of being cut (the half-width cards
-- have long titles), the icon stays on the first line.
local function header(icon, title, face, width)
    local probe = TextWidget:new{ text = "A", face = face }
    local icon_sz = math.floor(probe:getSize().h * 0.7)
    probe:free()
    local gap = Size.padding.default
    local text = TextBoxWidget:new{
        text = title, face = face, fgcolor = Colors.section(),
        width = math.max(1, width - icon_sz - gap), alignment = "left",
    }
    -- Centred on the text box's own line height (taller than a TextWidget's),
    -- which is where its first line's glyphs are centred.
    return HorizontalGroup:new{
        align = "top",
        CenterContainer:new{
            dimen = Geom:new{ w = icon_sz, h = text.line_height_px },
            UI.icon(icon, icon_sz),
        },
        HorizontalSpan:new{ width = gap },
        text,
    }
end

-- "142 pages": the number in the value font, the unit in the label color.
local function valueUnit(fonts, value, unit)
    local group = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = value, face = fonts.value, fgcolor = Colors.value() },
    }
    if unit and unit ~= "" then
        table.insert(group, HorizontalSpan:new{ width = Size.padding.small })
        table.insert(group, TextWidget:new{ text = unit, face = fonts.label, fgcolor = Colors.label() })
    end
    return group
end

local function small(fonts, text, width)
    return TextBoxWidget:new{
        text = text, face = fonts.small, fgcolor = Colors.small(), width = width, alignment = "left",
    }
end

-- `left` and `right` on one line (right-aligned), or the two stacked when
-- they don't fit `width`.
local function spread(left, right, width)
    local lw, rw = left:getSize().w, right:getSize().w
    local gap = Size.padding.large
    if lw + gap + rw <= width then
        return HorizontalGroup:new{
            align = "center",
            left,
            HorizontalSpan:new{ width = width - lw - rw },
            right,
        }
    end
    return VerticalGroup:new{ align = "left", left, VerticalSpan:new{ width = Size.padding.tiny }, right }
end

local function cardBody(...)
    local body = VerticalGroup:new{ align = "left" }
    for _i, w in ipairs({ ... }) do table.insert(body, w) end
    table.insert(body, VerticalSpan:new{ width = Size.padding.small })
    return body
end

-- A best-day card: icon + title, the value, the date under it.
local function bestDayBody(fonts, head_face, icon, title, value, unit, date, inner_w)
    return cardBody(
        header(icon, title, head_face, inner_w),
        VerticalSpan:new{ width = Size.padding.small },
        valueUnit(fonts, value, unit),
        small(fonts, date, inner_w))
end

-- The content of the Records window in the Cards look, `width` wide. `d` is
-- RecordsData.load()'s table. Returns the content and the title row (the
-- popup's hold target).
function M.build(fonts, width, d, tot_hours, last_ms, next_ms)
    local head_face = Fonts.getBoldFace("records_small")
    local gap = Size.padding.default
    local inner_w = UI.cardInnerWidth(width)

    local title_w = TextWidget:new{ text = _("Records"), face = fonts.value, fgcolor = Colors.value() }
    local title_row = LeftContainer:new{
        dimen = Geom:new{ w = width, h = title_w:getSize().h },
        title_w,
    }

    local content = VerticalGroup:new{
        align = "left",
        title_row,
        VerticalSpan:new{ width = Size.padding.default },
    }
    local function add(card)
        table.insert(content, card)
        table.insert(content, VerticalSpan:new{ width = gap })
    end

    -- Most reading time / most pages in a day: side by side when the values
    -- fit half a card, else one under the other.
    local sess_val = (d.longest.duration_sec or 0) > 0
        and Locale.formatDuration(d.longest.duration_sec, true) or DASH
    local sess_date = d.longest.date and formatDate(d.longest.date) or ""
    local pages = d.best_day.pages or 0
    local pages_val  = pages > 0 and formatCount(pages) or DASH
    local pages_unit = pages > 0 and N_("page", "pages", pages) or ""
    local pages_date = d.best_day.date and formatDate(d.best_day.date) or ""

    local half_w = math.floor((width - gap) / 2)
    local half_inner = UI.cardInnerWidth(half_w)
    local function fitsHalf(value, unit, date)
        local v = valueUnit(fonts, value, unit)
        local dt = TextWidget:new{ text = date, face = fonts.small }
        local ok = v:getSize().w <= half_inner and dt:getSize().w <= half_inner
        v:free()
        dt:free()
        return ok
    end
    if fitsHalf(sess_val, "", sess_date) and fitsHalf(pages_val, pages_unit, pages_date) then
        local b1 = bestDayBody(fonts, head_face, "clock", _("Most reading time in a day"), sess_val, "", sess_date, half_inner)
        local b2 = bestDayBody(fonts, head_face, "book", _("Most pages in a day"), pages_val, pages_unit, pages_date, half_inner)
        local h = math.max(b1:getSize().h, b2:getSize().h)
        add(HorizontalGroup:new{
            align = "top",
            UI.buildCard(UI.fixedCol(b1, half_inner, h), half_w),
            HorizontalSpan:new{ width = width - 2 * half_w },
            UI.buildCard(UI.fixedCol(b2, half_inner, h), half_w),
        })
    else
        add(UI.buildCard(bestDayBody(fonts, head_face, "clock", _("Most reading time in a day"),
            sess_val, "", sess_date, inner_w), width))
        add(UI.buildCard(bestDayBody(fonts, head_face, "book", _("Most pages in a day"),
            pages_val, pages_unit, pages_date, inner_w), width))
    end

    -- Best daily streak: length left, date range right.
    local days = d.streak.days or 0
    local range = ""
    if d.streak.start_date and d.streak.end_date then
        range = formatDate(d.streak.start_date) .. " " .. DASH .. " " .. formatDate(d.streak.end_date)
    end
    add(UI.buildCard(cardBody(
        header("flame", _("Best daily streak"), head_face, inner_w),
        VerticalSpan:new{ width = Size.padding.small },
        spread(valueUnit(fonts, days > 0 and formatCount(days) or DASH, days > 0 and N_("day", "days", days) or ""),
            TextWidget:new{ text = range, face = fonts.small, fgcolor = Colors.small(), max_width = inner_w },
            inner_w)
    ), width))

    -- Milestones: next one with the hours left, a bar from the last one to
    -- the next (full once every milestone is reached), the last one under it.
    local next_left = valueUnit(fonts, next_ms and formatCount(next_ms) or DASH,
        next_ms and N_("hour", "hours", next_ms) or "")
    local hours_left = next_ms and (next_ms - tot_hours) or 0
    local next_line = next_left
    if hours_left > 0 then
        next_line = spread(next_left,
            UI.buildPill(string.format(N_("%d hour left", "%d hours left", hours_left), hours_left), fonts.small, false, inner_w),
            inner_w)
    end
    local from = last_ms or 0
    local ratio = next_ms and (tot_hours - from) / math.max(1, next_ms - from) or 1

    local last_val = valueUnit(fonts, last_ms and formatCount(last_ms) or DASH,
        last_ms and N_("hour", "hours", last_ms) or "")
    local last_right = last_val
    if last_ms and d.last_ms_date then
        last_right = HorizontalGroup:new{
            align = "center",
            last_val,
            TextWidget:new{ text = " \u{00B7} " .. formatDate(d.last_ms_date), face = fonts.small, fgcolor = Colors.small() },
        }
    end

    add(UI.buildCard(cardBody(
        header("trophy", _("Next milestone"), head_face, inner_w),
        VerticalSpan:new{ width = Size.padding.small },
        next_line,
        VerticalSpan:new{ width = Size.padding.default },
        UI.buildRoundBar(ratio, inner_w, Screen:scaleBySize(6)),
        VerticalSpan:new{ width = Size.padding.default },
        Colors.vLine(inner_w, Size.line.thin, Colors.cardsColor("divider")),
        VerticalSpan:new{ width = Size.padding.small },
        spread(TextWidget:new{ text = _("Last milestone"), face = fonts.label, fgcolor = Colors.label() },
            last_right, inner_w)
    ), width))
    table.remove(content)

    return content, title_row
end

return M
