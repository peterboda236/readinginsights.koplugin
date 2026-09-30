--[[
Book card - a cover with a frame and (optionally) rounded corners.

KOReader's FrameContainer paints its child as a plain rectangle, so a cover
inside a rounded FrameContainer pokes out past the rounded border. This
widget instead:

  1. fills the whole rectangle with the frame colour,
  2. paints the cover inset by the frame thickness,
  3. for each corner, per pixel of the radius x radius corner square:
       outside the outer arc          -> background colour (cuts the corner)
       between outer and inner arc    -> frame colour (the rounded frame)
       inside the inner arc           -> left alone (the cover)

The two arcs share one centre per corner, so the ring stays clean - the same
technique Bookshelf's rounded cover card uses.

  CoverFrame:new{
      inner        = <widget of size (width - 2*border) x (height - 2*border)>,
      width        = <outer px>, height = <outer px>,
      border       = <frame thickness px>,
      radius       = <corner radius px, 0 = square>,
      bg           = <colour behind the card>,
      fg           = <frame colour>,
      -- optional: shadow behind the card, so BR corner restores shadow
      -- colour instead of bg (eliminates the gap between card and shadow)
      shadow_color  = <Blitbuffer colour or nil>,
      shadow_offset = <px the shadow is shifted right+down, default 0>,
      -- optional: function(bb, x, y, w, h) -> true if it painted something
      -- better than `bg` at that spot (e.g. Wallpaper.restore, putting the
      -- picture's own pixels back there instead of a flat colour). Tried
      -- for every "outside the arc" corner pixel before falling back to
      -- `bg`; a shadow-covered BR pixel always gets shadow_color instead,
      -- restore or not, so the corner still reads as one continuous shadow.
      restore       = nil,
  }
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")

local CoverFrame = Widget:extend{
    inner         = nil,
    width         = 0,
    height        = 0,
    border        = 1,
    radius        = 0,
    bg            = nil,
    fg            = nil,
    shadow_color  = nil,   -- if set, BR corner restores shadow_color
    shadow_offset = 0,     -- how far right+down the shadow is placed
    restore       = nil,   -- optional function(bb, x, y, w, h), see above
}

function CoverFrame:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function CoverFrame:paintTo(bb, x, y)
    local w, h, b, r = self.width, self.height, self.border, self.radius
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }

    bb:paintRect(x, y, w, h, self.fg)
    if self.inner then
        self.inner:paintTo(bb, x + b, y + b)
    end
    if r <= 0 then return end

    r = math.min(r, math.floor(math.min(w, h) / 2))
    local inner_r = r - b
    local shadow_off = self.shadow_offset or 0
    local shadow_col = self.shadow_color
    local restore = self.restore

    -- put(px, py, is_cut, color, forced_color): paints one corner pixel.
    -- `forced_color`, when given, always wins (the BR corner's shadow case).
    -- Otherwise, for a "cut" (outside-the-arc, background) pixel, `restore`
    -- gets first refusal - only once it declines (no wallpaper, or it isn't
    -- one of these full-screen-sized situations) does the flat `color` get
    -- painted, exactly as before this existed.
    local function put(px, py, is_cut, color, forced_color)
        if forced_color then
            bb:paintRect(px, py, 1, 1, forced_color)
            return
        end
        if is_cut and restore and restore(bb, px, py, 1, 1) then return end
        bb:paintRect(px, py, 1, 1, color)
    end

    for i = 0, r - 1 do
        local dx = r - (i + 0.5)
        for j = 0, r - 1 do
            local dy = r - (j + 0.5)
            local d = math.sqrt(dx * dx + dy * dy)
            local color, is_cut
            if d > r then
                color, is_cut = self.bg, true
            elseif d > inner_r then
                color = self.fg
            end
            if color then
                put(x + i,         y + j,         is_cut, color)  -- TL
                put(x + w - 1 - i, y + j,         is_cut, color)  -- TR
                put(x + i,         y + h - 1 - j, is_cut, color)  -- BL
                -- BR corner: if a shadow is behind us, pixels that fall
                -- inside the shadow rect should be restored to shadow_color
                -- rather than bg/wallpaper, so there is no gap between card
                -- and shadow.
                local br_x = w - 1 - i   -- local coords relative to card TL
                local br_y = h - 1 - j
                local in_shadow = shadow_col
                    and shadow_off > 0
                    and br_x >= shadow_off
                    and br_y >= shadow_off
                put(x + br_x, y + br_y, is_cut, color,
                    (in_shadow and is_cut) and shadow_col or nil)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- CoverShadow
-- A drop shadow painted BEFORE the cover so the cover sits on top.
-- Place this widget at (cover_x, cover_y); the shadow paints itself offset
-- down-right by `offset` pixels.  Then place the CoverFrame at the SAME
-- (cover_x, cover_y) — the cover hides all but the exposed L-shaped margin.
--
--   CoverShadow:new{
--       width  = <cover outer width  px>,
--       height = <cover outer height px>,
--       offset = <shadow shift in px>,
--       radius = <corner radius px matching the CoverFrame, 0 = square>,
--       bg     = <background colour behind the whole composition>,
--       restore = <optional function(bb, x, y, w, h), see CoverFrame above>,
--   }
-- ---------------------------------------------------------------------------
local CoverShadow = Widget:extend{
    width   = 0,
    height  = 0,
    offset  = 4,
    radius  = 0,
    bg      = nil,
    restore = nil,
}

-- Shadow grey: mid-grey on a plain page.  The framebuffer is inverted at
-- refresh in night mode so the same value displays dark on both modes.
local SHADOW_GRAY = Blitbuffer.gray(0.65)

function CoverShadow:getSize()
    return Geom:new{ w = self.width + self.offset, h = self.height + self.offset }
end

function CoverShadow:paintTo(bb, x, y)
    local off = self.offset
    local w, h, r = self.width, self.height, self.radius or 0
    local sx, sy = x + off, y + off   -- shadow top-left on screen

    if r > 0 then
        r = math.min(r, math.floor(math.min(w, h) / 2))
        -- Fill the whole shadow rect then cut the four rounded corners.
        bb:paintRect(sx, sy, w, h, SHADOW_GRAY)
        local bg = self.bg or Blitbuffer.COLOR_WHITE
        local restore = self.restore
        local function put(px, py)
            if restore and restore(bb, px, py, 1, 1) then return end
            bb:paintRect(px, py, 1, 1, bg)
        end
        for i = 0, r - 1 do
            local dx = r - (i + 0.5)
            for j = 0, r - 1 do
                local dy = r - (j + 0.5)
                if math.sqrt(dx * dx + dy * dy) > r then
                    put(sx + i,         sy + j)
                    put(sx + w - 1 - i, sy + j)
                    put(sx + i,         sy + h - 1 - j)
                    put(sx + w - 1 - i, sy + h - 1 - j)
                end
            end
        end
    else
        bb:paintRect(sx, sy, w, h, SHADOW_GRAY)
    end
end

CoverFrame.Shadow     = CoverShadow
CoverFrame.SHADOW_GRAY = SHADOW_GRAY

return CoverFrame
