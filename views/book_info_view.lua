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
  - Tap the description        full description in a viewer window
  - Tap anywhere else / swipe  dismiss

With Settings > Book info > "Show description" on (the default) the book's
description is set under the author / series, one large padding below them,
down to the bottom of the cover (shadow included). It is cut at a word
boundary with an ellipsis when it does not fit, and the popup then always
takes its maximum width.

The cover comes in three sizes (Settings > Book info > Cover size): small
(50%), medium (100%, the default) and large (150%).

What is shown, and in which fonts, is set under Settings > Book info and
Settings > Fonts > Book info (font roles bookinfo_title / bookinfo_author /
bookinfo_series in lib/fonts.lua - defaulting to the Book card plugin's own
fonts). The text lines are wrapped (and cut with an ellipsis when very long)
so a long title or a long author list never stretches the box. The box is
at most 94% of the (portrait) width, and narrower when the title, the
author(s) and the series each fit on a single line.
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
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
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

-- Width of `txt` set on a single line in `face` (0 for empty text).
local function naturalWidth(txt, face)
    if not txt or txt == "" then return 0 end
    local ok, size = pcall(RenderText.sizeUtf8Text, RenderText, 0, math.huge,
        face, txt, true, false)
    if ok and size and size.x then return size.x end
    return math.huge
end

-- Greedy word-wrap of `text` (whitespace collapsed) into at most `max_lines`
-- lines of at most `width` pixels in `face`. When words are left over, the
-- last line is cut back to whole words and closed with an ellipsis right
-- after its final word (a trailing comma / colon etc. is dropped first).
-- Returns the list of lines.
local function wrapPreview(text, face, width, max_lines)
    local words = {}
    for w in tostring(text or ""):gmatch("%S+") do words[#words + 1] = w end
    local n = #words
    local lines = {}
    local i = 1
    while i <= n and #lines < max_lines do
        local line = words[i]
        i = i + 1
        while i <= n do
            local cand = line .. " " .. words[i]
            if naturalWidth(cand, face) <= width then
                line = cand
                i = i + 1
            else
                break
            end
        end
        lines[#lines + 1] = line
    end

    if i <= n and #lines > 0 then
        local lw = {}
        for w in lines[#lines]:gmatch("%S+") do lw[#lw + 1] = w end
        while true do
            local base = table.concat(lw, " "):gsub("[,;:%-]+$", "")
            local cand = base .. "\226\128\166" -- U+2026 ellipsis
            if #lw <= 1 or naturalWidth(cand, face) <= width then
                lines[#lines] = cand
                break
            end
            lw[#lw] = nil
        end
    end
    return lines
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
    local cover, cover_w, cover_h = self:_buildCover(
        math.floor(content_w * 0.34 * scale),
        math.floor(screen_h * 0.30 * scale))
    if cover then
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{ width = gap })
        text_w = math.max(S(80), content_w - cover_w - gap)
    end

    local title_face  = Fonts.getFace("bookinfo_title")
    local author_face = Fonts.getFace("bookinfo_author")
    local series_face = Fonts.getFace("bookinfo_series")
    local show_author = Opt.readBookInfo("author") and self.info.authors
    local series_line = Opt.readBookInfo("series") and Data.seriesLine(self.info) or nil

    -- The box is only as wide as it has to be: if the title, the author(s)
    -- and the series all fit on one line each, the text column shrinks to
    -- the widest of them; otherwise it keeps the full (maximum) width and
    -- the long lines wrap as before.
    local needed = naturalWidth(self.info.title, title_face)
    if show_author then
        needed = math.max(needed, naturalWidth(self.info.authors, author_face))
    end
    if series_line then
        needed = math.max(needed, naturalWidth(series_line, series_face))
    end
    -- With the description on, the box always keeps its maximum width so the
    -- description has room to breathe.
    local show_desc = Opt.readBookInfo("description")
    if not show_desc and needed < text_w then
        -- a few pixels of slack so a line that just fits never wraps
        text_w = math.max(S(80), math.ceil(needed) + S(4))
    end

    local text_col = VerticalGroup:new{ align = "left" }
    table.insert(text_col, textBlock(
        self.info.title or "", title_face, Colors.value(), text_w, 4))

    if show_author then
        table.insert(text_col, VerticalSpan:new{ width = S(6) })
        table.insert(text_col, textBlock(
            self.info.authors, author_face, Colors.label(), text_w, 3))
    end

    if series_line then
        table.insert(text_col, VerticalSpan:new{ width = S(4) })
        table.insert(text_col, textBlock(
            series_line, series_face, Colors.label(), text_w, 2))
    end

    -- Description: starts one "large padding" below the author / series and
    -- runs down to the bottom of the cover (its shadow included, when on),
    -- as many whole lines as fit. Tapping it opens the full text.
    self.desc_frame = nil
    self.desc_full = nil
    if show_desc and self.info.description then
        local region_h = cover_h or math.floor(screen_h * 0.30 * scale)
        local desc_face = Fonts.getFace("bookinfo_description")
        local probe = TextWidget:new{ text = "Ag", face = desc_face }
        local line_h = probe:getSize().h
        probe:free()
        -- Sum the children by hand: VerticalGroup:getSize() caches its size
        -- and offsets, which would go stale once the description is added.
        local used_h = 0
        for _idx, child in ipairs(text_col) do
            used_h = used_h + child:getSize().h
        end
        local avail = region_h - used_h - pad
        local max_lines = line_h > 0 and math.floor(avail / line_h) or 0
        if max_lines >= 1 then
            local lines = wrapPreview(self.info.description, desc_face, text_w, max_lines)
            local desc_col = VerticalGroup:new{ align = "left" }
            for _idx, line in ipairs(lines) do
                table.insert(desc_col, TextWidget:new{
                    text = line,
                    face = desc_face,
                    max_width = text_w,
                    fgcolor = Colors.label(),
                })
            end
            table.insert(text_col, VerticalSpan:new{ width = pad })
            self.desc_frame = FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                width = text_w,
                height = max_lines * line_h,
                desc_col,
            }
            table.insert(text_col, self.desc_frame)
            self.desc_full = self.info.description
        end
    end
    if text_col.resetLayout then text_col:resetLayout() end
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

-- Full description in a scrollable viewer on top of this popup.
-- This popup (and the Book progress popup under it) is modal, and modal
-- widgets are stacked above non-modal ones. So the viewer itself is made
-- modal, and so is every dialog it opens (its hamburger menu, the search /
-- font dialogs ...): while the viewer is open, UIManager:show is wrapped to
-- flag whatever gets shown as modal; the wrapper is removed when it closes.
function BookInfoPopup:_showFullDescription()
    local TextViewer = require("ui/widget/textviewer")
    local viewer = TextViewer:new{
        title = _("Description"),
        text = self.desc_full,
        justified = false,
        modal = true,
    }

    local orig_show = UIManager.show
    local function modal_show(um, widget, ...)
        if widget then widget.modal = true end
        return orig_show(um, widget, ...)
    end
    UIManager.show = modal_show

    local orig_close = viewer.onCloseWidget
    function viewer:onCloseWidget(...)
        if UIManager.show == modal_show then
            UIManager.show = orig_show
        end
        if orig_close then return orig_close(self, ...) end
    end

    UIManager:show(viewer)
end

function BookInfoPopup:onTapClose(arg, ges)
    local d = self.desc_frame and self.desc_frame.dimen
    if d and self.desc_full and ges and ges.pos and ges.pos:intersectWith(d) then
        self:_showFullDescription()
        return true
    end
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
