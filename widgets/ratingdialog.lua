--[[
Reading Insights - the star rating popup.

A stock KOReader ButtonDialog (same frame, title, separator and button grid
as the plugin's other popups) with one extra widget in it: five stars side
by side in one row, set by touch the way the Bookshelf plugin's rating row
works - tap a star to give that rating, or put a finger on the row and slide
it left/right to adjust (the stars follow the finger). Tapping the star that
is already the rating clears it, like KOReader's own book status page.
Below the stars: "Clear rating", "Cancel" and "Save".

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
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local Screen          = Device.screen

local deps = ...
local Locale = deps.Locale
local _ = Locale._

local STAR_FILLED  = "\xe2\x98\x85"   -- U+2605 BLACK STAR
local STAR_OUTLINE = "\xe2\x98\x86"   -- U+2606 WHITE STAR
local STAR_COUNT   = 5

local function clampRating(n)
    return math.max(0, math.min(STAR_COUNT, math.floor((tonumber(n) or 0) + 0.5)))
end

-- The row of stars, added to the ButtonDialog as an extra widget. It handles
-- its own touches (children get gestures before the dialog's tap-outside-
-- to-close does), so a tap on the stars never dismisses the dialog.
local StarRow = InputContainer:extend{
    width         = 0,      -- available width (the dialog tells us)
    rating        = 0,
    dialog        = nil,    -- the ButtonDialog, for repaint requests
    not_focusable = true,   -- not a D-pad target; keep ButtonDialog's layout as is
}

function StarRow:init()
    -- Measure both glyphs and give every cell the wider one (plus a little
    -- air), so swapping filled/outlined never moves the row.
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
    -- A frame with no border or padding: it hugs the row and (as every
    -- FrameContainer does) records where it was painted, which is what the
    -- touch handlers measure against.
    self.star_frame = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        row,
    }

    self.dimen = Geom:new{ w = self.width, h = cell_h }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = cell_h },
        self.star_frame,
    }

    if Device:isTouchDevice() then
        self.ges_events.Tap = { GestureRange:new{
            ges = "tap", range = function() return self:touchBand(false) end } }
        self.ges_events.Pan = { GestureRange:new{
            ges = "pan", range = function() return self:touchBand(true) end } }
    end
end

-- The area that reacts to touch: a little taller than the stars (they're
-- small targets for a fingertip), and for the pan the full screen width, so
-- the finger can wander off the ends of the row.
function StarRow:touchBand(any_x)
    local d = self.star_frame.dimen
    if not d then return Geom:new{ x = 0, y = 0, w = 0, h = 0 } end
    local slack = Screen:scaleBySize(12)
    return Geom:new{
        x = any_x and 0 or d.x,
        y = d.y - slack,
        w = any_x and Screen:getWidth() or d.w,
        h = d.h + 2 * slack,
    }
end

-- Which star (1..5) is under screen position x: the row's own cells,
-- clamped, so a finger that slides past either end still lands on the
-- first / last star.
function StarRow:starAt(x)
    local d = self.star_frame.dimen
    local idx = math.floor((x - d.x) / self.cell_w) + 1
    return math.max(1, math.min(STAR_COUNT, idx))
end

function StarRow:setRating(n)
    n = math.max(0, math.min(STAR_COUNT, n))
    if n == self.rating then return end
    self.rating = n
    for i, tw in ipairs(self.star_widgets) do
        tw:setText(i <= n and STAR_FILLED or STAR_OUTLINE)
    end
    UIManager:setDirty(self.dialog or self, function()
        return "ui", self.star_frame.dimen
    end)
end

function StarRow:onTap(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    local i = self:starAt(pos.x)
    -- the star that is already the rating clears it
    self:setRating((i == self.rating) and 0 or i)
    return true
end

function StarRow:onPan(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    self:setRating(self:starAt(pos.x))
    return true
end

local M = {}

function M.show(opts)
    opts = opts or {}
    local title = opts.title
    if title == "" then title = nil end

    local dialog, stars
    dialog = ButtonDialog:new{
        -- Same as the plugin's other chooser dialogs: the insights popup that
        -- spawns this one is modal, and a non-modal window would open
        -- underneath it.
        modal       = true,
        title       = title,
        title_align = "center",
        buttons = {
            {
                { text = _("Clear rating"), callback = function() stars:setRating(0) end },
            },
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Save"),   callback = function()
                    local n = stars.rating
                    UIManager:close(dialog)
                    if opts.on_save then opts.on_save(n) end
                end },
            },
        },
    }
    -- The dialog knows how wide its content area is only once it is built.
    stars = StarRow:new{
        width  = dialog:getAddedWidgetAvailableWidth(),
        rating = clampRating(opts.rating),
        dialog = dialog,
    }
    dialog:addWidget(stars)
    UIManager:show(dialog)
end

return M
