--[[
Reading Insights - the star rating popup.

Five stars side by side in one row, set by touch the way the Bookshelf
plugin's rating row works: tap a star to give that rating, or put a finger
on the row and slide it left/right to adjust (the stars follow the finger).
Tapping the star that is already the rating clears it, like KOReader's own
book status page. Below the stars: "Clear rating", "Cancel" and "Save".

  RatingDialog.show{
      title   = "Book title",        -- optional, shown above the stars
      rating  = 3,                   -- current rating, 0..5 (0 = none)
      on_save = function(n) end,     -- called with the chosen 0..5
  }

The stars are drawn as text glyphs (U+2605 filled / U+2606 outlined) rather
than icons: they stay readable at this size on e-ink. Every cell has the
same width whichever glyph is in it, so the row doesn't shift while the
rating changes.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

local deps = ...
local Locale = deps.Locale
local _ = Locale._

local STAR_FILLED  = "\xe2\x98\x85"   -- U+2605 BLACK STAR
local STAR_OUTLINE = "\xe2\x98\x86"   -- U+2606 WHITE STAR
local STAR_COUNT   = 5

local RatingDialog = InputContainer:extend{
    modal   = true,
    title   = nil,
    rating  = 0,
    on_save = nil,
}

function RatingDialog:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    self.rating = math.max(0, math.min(STAR_COUNT, math.floor((tonumber(self.rating) or 0) + 0.5)))
    self.original = self.rating

    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self.ges_events.Tap        = { GestureRange:new{ ges = "tap",         range = full } }
        self.ges_events.Pan        = { GestureRange:new{ ges = "pan",         range = full } }
        self.ges_events.PanRelease = { GestureRange:new{ ges = "pan_release", range = full } }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local box_w     = math.min(math.floor(screen_w * 0.84), Screen:scaleBySize(460))
    local padding   = Size.padding.large
    local content_w = box_w - 2 * padding - 2 * Size.border.window

    -- Stars. Measure both glyphs and give every cell the wider one (plus a
    -- little air), so swapping filled/outlined never moves the row.
    local face = Font:getFace("cfont", 34)
    local probe_a = TextWidget:new{ text = STAR_FILLED,  face = face, bold = true }
    local probe_b = TextWidget:new{ text = STAR_OUTLINE, face = face, bold = true }
    local glyph_w = math.max(probe_a:getSize().w, probe_b:getSize().w)
    local glyph_h = math.max(probe_a:getSize().h, probe_b:getSize().h)
    probe_a:free()
    probe_b:free()
    local cell_w = glyph_w + Screen:scaleBySize(10)
    local cell_h = glyph_h + Screen:scaleBySize(8)
    self.cell_w = cell_w

    self.star_widgets = {}
    local row = HorizontalGroup:new{ align = "center" }
    for i = 1, STAR_COUNT do
        local tw = TextWidget:new{
            text    = i <= self.rating and STAR_FILLED or STAR_OUTLINE,
            face    = face,
            bold    = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        self.star_widgets[i] = tw
        row[#row + 1] = CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            tw,
        }
    end
    -- A frame with no border or padding: it hugs the row, and (as every
    -- FrameContainer does) records where it was painted, which is what the
    -- touch handlers measure against.
    self.star_frame = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        row,
    }

    local content = VerticalGroup:new{ align = "center" }
    if self.title and self.title ~= "" then
        content[#content + 1] = TextBoxWidget:new{
            text      = self.title,
            face      = Font:getFace("infofont", 20),
            bold      = true,
            width     = content_w,
            alignment = "center",
        }
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
    end
    content[#content + 1] = CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = cell_h },
        self.star_frame,
    }
    content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
    content[#content + 1] = ButtonTable:new{
        width       = content_w,
        show_parent = self,
        buttons = {
            {
                { text = _("Clear rating"), callback = function() self:setRating(0) end },
            },
            {
                { text = _("Cancel"), callback = function() self:onClose() end },
                { text = _("Save"),   callback = function() self:save() end },
            },
        },
    }

    self.box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding        = padding,
        padding_top    = padding,
        padding_bottom = padding,
        content,
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.box,
    }
end

-- Which star (1..5) is under screen position x: the row's own cells,
-- clamped, so a finger that slides past either end still lands on the
-- first / last star.
function RatingDialog:starAt(x)
    local d = self.star_frame.dimen
    if not d then return nil end
    local idx = math.floor((x - d.x) / self.cell_w) + 1
    return math.max(1, math.min(STAR_COUNT, idx))
end

-- Whether a touch is on the row. The band is a little taller than the stars
-- (they're small targets for a fingertip), and on the pan the horizontal
-- extent is left open so the finger can wander off the ends.
function RatingDialog:onStarRow(pos, any_x)
    local d = self.star_frame.dimen
    if not d or not pos then return false end
    local slack = Screen:scaleBySize(12)
    if pos.y < d.y - slack or pos.y > d.y + d.h + slack then return false end
    return any_x or (pos.x >= d.x and pos.x < d.x + d.w)
end

function RatingDialog:setRating(n)
    n = math.max(0, math.min(STAR_COUNT, n))
    if n == self.rating then return end
    self.rating = n
    for i, tw in ipairs(self.star_widgets) do
        tw:setText(i <= n and STAR_FILLED or STAR_OUTLINE)
    end
    UIManager:setDirty(self, function()
        return "ui", self.star_frame.dimen
    end)
end

function RatingDialog:onTap(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    if self:onStarRow(pos, false) then
        local i = self:starAt(pos.x)
        -- the star that is already the rating clears it
        self:setRating((i == self.rating) and 0 or i)
        return true
    end
    -- outside the box: dismiss
    local b = self.box.dimen
    if b and not b:contains(pos) then
        self:onClose()
    end
    return true
end

function RatingDialog:onPan(_arg, ges)
    local pos = ges and ges.pos
    if pos and self:onStarRow(pos, true) then
        self:setRating(self:starAt(pos.x))
        return true
    end
end

function RatingDialog:onPanRelease()
    return false
end

function RatingDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.box.dimen
    end)
end

function RatingDialog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.box.dimen
    end)
end

function RatingDialog:onClose()
    UIManager:close(self)
    return true
end

function RatingDialog:save()
    UIManager:close(self)
    if self.on_save then self.on_save(self.rating) end
end

local M = {}

function M.show(opts)
    UIManager:show(RatingDialog:new{
        title   = opts and opts.title,
        rating  = opts and opts.rating,
        on_save = opts and opts.on_save,
    })
end

return M
