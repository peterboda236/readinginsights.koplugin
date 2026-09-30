--[[
Book Info Popup (view module).

A small centered box about the book that is open: its cover on the left
(framed, with optional rounded corners and drop shadow - drawn by the same
widget the Book card plugin uses, widgets/coverframe.lua) and, to the right
of it, the title, the author(s) and - when the book is part of one - the
series.

Opened from Tools > Reading insights > "Show Book info", from the
"Reading insights: book info" gesture/dispatcher action, and by tapping the
"This book" header of the Book progress popup (see book_stats_view.lua).
Book-view only: it needs an open document (see main.lua).

`on_close` (optional) is called once when the popup closes; the Book
progress popup uses it to reopen itself, so closing the Book info popup
lands back where it was opened from.

Controls:
  - Tap anywhere / swipe       dismiss

The cover comes in three sizes (Settings > Book info > Cover size): small
(50%), medium (100%, the default) and large (150%).

What is shown, and in which fonts, is set under Settings > Book info and
Settings > Fonts > Book info (font roles bookinfo_title / bookinfo_author /
bookinfo_series in lib/fonts.lua - defaulting to the Book card plugin's own
fonts). The text lines are wrapped (and cut with an ellipsis when very long)
so a long title or a long author list never stretches the box.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, VS, Data, CoverFrame =
    deps.Locale, deps.Colors, deps.Fonts, deps.VS, deps.Data, deps.CoverFrame
local _ = Locale._

local Opt = VS.Opt

local function S(n)
    return Screen:scaleBySize(n)
end

-- Height of `lines` lines of text set in `face` (TextBoxWidget spaces lines
-- by size * 1.3, the same maths the Book card uses for its title box).
local function linesHeight(face, lines)
    return lines * math.floor((1 + 0.3) * face.size + 0.5)
end

-- A wrapped, height-capped text block (ellipsis when it does not fit).
local function textBlock(txt, face, color, width, max_lines)
    return TextBoxWidget:new{
        text = txt,
        face = face,
        width = width,
        height = linesHeight(face, max_lines),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = color,
        bgcolor = Blitbuffer.COLOR_WHITE,
    }
end

local BookInfoPopup = InputContainer:extend{
    modal    = true,
    ui       = nil,
    on_close = nil,
}

function BookInfoPopup:init()
    self.info = Data.gather(self.ui) or { title = "" }
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap",   range = self.dimen },
        }
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end

    self:_buildUI()
end

-- The cover block: a framed cover (real one, or a plain 2:3 placeholder
-- carrying the title) plus its drop shadow. Returns the widget and its
-- on-screen size (shadow included), or nil when the cover is switched off.
function BookInfoPopup:_buildCover(max_w, max_h)
    if not Opt.readBookInfo("cover") then return nil end

    local border = Opt.readBookInfo("border") and math.max(2, S(1)) or 0
    local radius = Opt.readBookInfo("rounded") and S(4) or 0
    local shadow = Opt.readBookInfo("shadow") and S(4) or 0
    local box_w = max_w - shadow - 2 * border
    local box_h = max_h - shadow - 2 * border

    local inner, iw, ih

    local bb = Data.getCover(self.ui)
    if bb then
        local ok, img, w, h = pcall(function()
            local bw, bh = bb:getWidth(), bb:getHeight()
            local scale = math.min(box_w / bw, box_h / bh)
            local w = math.max(1, math.floor(bw * scale))
            local h = math.max(1, math.floor(bh * scale))
            local widget = ImageWidget:new{
                image = bb,
                image_disposable = true,
                width = w,
                height = h,
                scale_factor = 0,
            }
            widget:getSize()
            return widget, w, h
        end)
        if ok then
            inner, iw, ih = img, w, h
        else
            bb:free()
        end
    end

    if not inner then
        ih = box_h
        iw = math.floor(ih * 2 / 3)
        if iw > box_w then
            iw = box_w
            ih = math.floor(iw * 3 / 2)
        end
        inner = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            width = iw, height = ih,
            CenterContainer:new{
                dimen = Geom:new{ w = iw, h = ih },
                TextBoxWidget:new{
                    text = self.info.title or "",
                    face = Fonts.getBoldFace("bookinfo_title"),
                    width = math.max(10, iw - S(16)),
                    height = ih - S(16),
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                    alignment = "center",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    bgcolor = Blitbuffer.COLOR_WHITE,
                },
            },
        }
    end

    local outer_w, outer_h = iw + 2 * border, ih + 2 * border
    local cover_frame = CoverFrame:new{
        inner  = inner,
        width  = outer_w, height = outer_h,
        border = border,  radius = radius,
        bg     = Blitbuffer.COLOR_WHITE,
        fg     = Blitbuffer.COLOR_BLACK,
        shadow_color  = shadow > 0 and CoverFrame.SHADOW_GRAY or nil,
        shadow_offset = shadow,
    }

    local total_w, total_h = outer_w + shadow, outer_h + shadow
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = total_w, h = total_h },
    }
    if shadow > 0 then
        table.insert(group, CoverFrame.Shadow:new{
            width = outer_w, height = outer_h,
            offset = shadow, radius = radius,
            bg = Blitbuffer.COLOR_WHITE,
        })
    end
    table.insert(group, cover_frame)
    return group, total_w, total_h
end

function BookInfoPopup:_buildUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local border_w = Size.border.window
    local pad      = Size.padding.large
    -- 94% of the width in portrait (the same as the centered Book progress
    -- popup); in landscape the box stays as narrow as it would be there
    -- rather than stretching across the whole screen.
    local frame_w   = math.floor(math.min(screen_w, screen_h) * 0.94)
    local content_w = frame_w - 2 * border_w - 2 * pad
    local gap       = S(14)

    -- Top-aligned: the title starts level with the top of the cover.
    local row = HorizontalGroup:new{ align = "top" }
    local text_w = content_w

    -- Cover box: 34% of the content width x 30% of the screen height at the
    -- "medium" size (Settings > Book info > Cover size); "small" is half
    -- and "large" one and a half times that.
    local scale = Opt.BOOK_INFO_COVER_SCALE[Opt.readBookInfoCoverSize()] or 1
    local cover, cover_w = self:_buildCover(
        math.floor(content_w * 0.34 * scale),
        math.floor(screen_h * 0.30 * scale))
    if cover then
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{ width = gap })
        text_w = math.max(S(80), content_w - cover_w - gap)
    end

    local text_col = VerticalGroup:new{ align = "left" }
    table.insert(text_col, textBlock(
        self.info.title or "", Fonts.getFace("bookinfo_title"),
        Colors.value(), text_w, 4))

    if Opt.readBookInfo("author") and self.info.authors then
        table.insert(text_col, VerticalSpan:new{ width = S(6) })
        table.insert(text_col, textBlock(
            self.info.authors, Fonts.getFace("bookinfo_author"),
            Colors.label(), text_w, 3))
    end

    local series_line = Opt.readBookInfo("series") and Data.seriesLine(self.info) or nil
    if series_line then
        table.insert(text_col, VerticalSpan:new{ width = S(4) })
        table.insert(text_col, textBlock(
            series_line, Fonts.getFace("bookinfo_series"),
            Colors.label(), text_w, 2))
    end
    table.insert(row, text_col)

    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border_w,
        radius     = Size.radius.window,
        padding    = pad,
        row,
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        self.popup_frame,
    }
end

function BookInfoPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

function BookInfoPopup:onCloseWidget()
    UIManager:setDirty(nil, "ui")
    local cb = self.on_close
    self.on_close = nil
    if cb then cb() end
end

function BookInfoPopup:onTapClose()
    UIManager:close(self)
    return true
end

function BookInfoPopup:onSwipe()
    UIManager:close(self)
    return true
end

function BookInfoPopup:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

return BookInfoPopup
