--[[
Book Info Popup (view module).

A small centered box about the book that is open: its cover on the left
(framed, with optional rounded corners and drop shadow - drawn by the same
widget the Book card plugin uses, widgets/coverframe.lua) and, to the right
of it, the title, the author(s) and - when the book is part of one - the
series.

Opened from Tools > Reading insights > "Book info", from the
"Reading insights: book info" gesture/dispatcher action, and by tapping the
"This book" header of the Book progress popup (see book_stats_view.lua).
Book-view only: it needs an open document (see main.lua).

`on_close` (optional) is called once when the popup closes; the Book
progress popup uses it to reopen itself, so closing the Book info popup
lands back where it was opened from.

Also opened from a row of the book lists (tap a book): `book` is then that
list row (title, authors, md5, id_book) and `file` its file when known, and
the popup describes that book instead of the open one.

Above the title sit the book's star rating; at the bottom of the text
column, one left-aligned line with the pages read and the reading time
("860 pages · 12:56 reading time"). The line is always there for a book
with statistics, level with the bottom of the cover (its shadow included);
without a cover it follows the text one large padding below it. The
description gets that much fewer lines. A book without a cover image gets
an empty frame with a diagonal line through it in the cover's place. `save_rating` (optional)
replaces how a rating is stored (hand-added books keep theirs in their own
list).

Controls:
  - Tap / long press the stars set / change / clear the rating
  - Tap the description        full description in a viewer window
  - Tap anywhere else / swipe  dismiss

With Settings > Book info > "Show description" on (the default) the book's
description is set under the author / series, one large padding below them,
down to the bottom of the cover (shadow included). It is cut at a word
boundary with an ellipsis when it does not fit, and the popup then always
takes its maximum width.

The cover comes in three sizes (Settings > Book info > Cover size):
  - small   the cover is only as tall as the text beside it (rating, title,
            author, series, pages / reading time); no description
  - medium  the default: a box of 34% of the content width x 30% of the
            screen height
  - large   the biggest cover the popup allows (never wider than 94% of the
            screen width, never taller than the screen) with all the text
            still fitting beside it; the description gets what is left
When no small / large cover can hold the text (e.g. one huge word), the
medium box is used.

What is shown, and in which fonts, is set under Settings > Book info and
Settings > Fonts > Book info (font roles bookinfo_title / bookinfo_author /
bookinfo_series in lib/fonts.lua - defaulting to the Book card plugin's own
fonts). The text lines are wrapped (and cut with an ellipsis when very long)
so a long title or a long author list never stretches the box. The box is
at most 94% of the (portrait) width. Without a cover (switched off, or the
book has none) it is only as wide as its longest line needs; with a cover
and no description it is narrower when the title, the author(s) and the
series each fit on a single line.
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
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Widget = require("ui/widget/widget")
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
local Locale, Colors, Fonts, VS, Data, CoverFrame, Ratings, RatingDialog =
    deps.Locale, deps.Colors, deps.Fonts, deps.VS, deps.Data, deps.CoverFrame,
    deps.Ratings, deps.RatingDialog
local _ = Locale._

local Opt = VS.Opt

local function S(n)
    return Screen:scaleBySize(n)
end

-- Height of one line of text set in `face` (TextBoxWidget spaces lines by
-- size * 1.3, the same maths the Book card uses for its title box).
local function lineHeight(face)
    return math.floor((1 + 0.3) * face.size + 0.5)
end

-- Height of `lines` lines of text set in `face`.
local function linesHeight(face, lines)
    return lines * lineHeight(face)
end

-- Width of `txt` set on a single line in `face` (0 for empty text).
local function naturalWidth(txt, face)
    if not txt or txt == "" then return 0 end
    local ok, size = pcall(RenderText.sizeUtf8Text, RenderText, 0, math.huge,
        face, txt, true, false)
    if ok and size and size.x then return size.x end
    return math.huge
end

-- The words of `text` with their widths in `face`, measured once, so the
-- number of lines the text needs at any width can be worked out cheaply
-- (countLines) without building a widget per try. Used to size the cover to
-- the text beside it.
local function measureWords(text, face)
    local m = { widths = {}, widest = 0, space = naturalWidth(" ", face) }
    if m.space <= 0 or m.space == math.huge then
        m.space = math.floor(face.size * 0.28)
    end
    for w in tostring(text or ""):gmatch("%S+") do
        local ww = naturalWidth(w, face)
        if ww == math.huge then ww = 0 end
        m.widths[#m.widths + 1] = ww
        if ww > m.widest then m.widest = ww end
    end
    return m
end

-- Lines the measured text needs in a column `width` wide. A couple of pixels
-- are kept back so the estimate is never lower than what TextBoxWidget
-- really makes of it; a word wider than the column counts as several lines
-- (TextBoxWidget breaks it).
local function countLines(m, width)
    if #m.widths == 0 then return 1 end
    width = math.max(1, width - S(2))
    local lines, used = 1, 0
    for i = 1, #m.widths do
        local ww = m.widths[i]
        if used == 0 then
            used = ww
        elseif used + m.space + ww <= width then
            used = used + m.space + ww
        else
            lines = lines + 1
            used = ww
        end
        if used > width then
            local extra = math.ceil(used / width) - 1
            lines = lines + extra
            used = used - extra * width
        end
    end
    return lines
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

-- The stand-in for a missing cover: white, with one line from the bottom
-- left corner to the top right one (drawn pixel column by pixel column, so
-- it needs nothing from Blitbuffer but paintRect).
local NoCover = Widget:extend{
    width  = 0,
    height = 0,
}

function NoCover:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function NoCover:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local w, h = self.width, self.height
    if w < 2 or h < 2 then return end
    local thick = math.max(2, S(1))
    local function line_y(i)
        return y + h - 1 - math.floor(i * (h - 1) / (w - 1))
    end
    for i = 0, w - 2 do
        local y0, y1 = line_y(i), line_y(i + 1)
        local top = math.min(y0, y1)
        bb:paintRect(x + i, top, thick, math.abs(y0 - y1) + 1, Blitbuffer.COLOR_BLACK)
    end
end

local BookInfoPopup = InputContainer:extend{
    modal    = true,
    ui       = nil,
    on_close = nil,
    -- A book of a list instead of the open one (see the header): the list
    -- row, its file when known, and a callback told the new rating.
    book     = nil,
    file     = nil,
    on_rate  = nil,
    save_rating = nil,
    -- Timestamp the book was finished on (finished-books list only); shown
    -- right-aligned beside the stars as "Finished: <date>".
    finished_ts = nil,
}

function BookInfoPopup:init()
    if self.book then
        self.info = Data.gatherForFile(self.file, self.book)
        self.md5 = self.book.md5
        self.id_book = self.book.id_book
        -- a file that was only guessed from the title is shown (cover,
        -- description) but never used for the rating
        self.rating_file = (not self.file_guessed) and self.file or nil
    else
        self.info = Data.gather(self.ui) or { title = "" }
        self.md5 = Data.md5(self.ui)
        self.id_book = self.ui and self.ui.statistics and self.ui.statistics.id_curr_book
        self.rating_file = self.ui and self.ui.document and self.ui.document.file
    end
    if self.md5 == "" then self.md5 = nil end
    if self.save_rating then
        -- a hand-added book: its rating lives in the book row itself
        self.rating = tonumber(self.book and self.book.rating) or 0
    else
        -- With the book's file known its sidecar is read directly: cheap and
        -- always current. Otherwise the quick map answers; its TTL keeps it
        -- fresh enough and Ratings.save updates it, so no refresh() here.
        self.rating = (self.md5 and Ratings.get(self.md5, self.rating_file)) or 0
    end
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
        self.ges_events.Hold = {
            GestureRange:new{ ges = "hold",  range = self.dimen },
        }
    end

    self:_buildUI()
end

-- Frame, corner radius and shadow of the cover, as set under Settings >
-- Appearance > Covers (0 when switched off; shared with the Reading calendar
-- and the Reading shelf).
function BookInfoPopup:_coverDecor()
    return Opt.coverDecor()
end

-- Size of the cover block (shadow and frame included) that fits the box
-- max_w x max_h for an image of bw x bh pixels (a book without a cover is
-- drawn 2 : 3). Returns the block's width and height, then the picture's.
-- One function for both the maths that sizes the cover to the text and the
-- widget that is finally built, so the two always agree.
local function coverGeom(decor, max_w, max_h, bw, bh)
    local extra = decor.shadow + 2 * decor.border
    local box_w = math.max(1, max_w - extra)
    local box_h = math.max(1, max_h - extra)
    local scale = math.min(box_w / bw, box_h / bh)
    local iw = math.max(1, math.floor(bw * scale))
    local ih = math.max(1, math.floor(bh * scale))
    return iw + extra, ih + extra, iw, ih
end

-- The cover image (a blitbuffer the caller owns), or nil when the book has
-- none. `cover_diag` says why, for the long press on a missing cover.
function BookInfoPopup:_loadCover()
    -- A list row only ever shows its own cover (read from its file); asking
    -- for the open book's cover there would show the wrong one.
    local bb
    self.cover_diag = nil
    if self.book then
        bb = self.file and Data.getCover(nil, self.file) or nil
        if not bb then
            self.cover_diag = string.format("md5: %s\nfile: %s\n%s",
                tostring(self.md5), tostring(self.file or "not found"),
                tostring(self.file and Data.last_cover_error or "no file to read the cover from"))
        end
    else
        bb = Data.getCover(self.ui)
        if not bb then
            self.cover_diag = "no cover image: " .. tostring(Data.last_cover_error)
        end
    end
    return bb
end

-- The cover block: the framed cover (a book without one gets an empty frame
-- with a diagonal line through it) plus its drop shadow, sized by coverGeom
-- to the box max_w x max_h. Returns the widget and its on-screen size
-- (shadow included).
function BookInfoPopup:_buildCover(decor, max_w, max_h, bb, bw, bh)
    local border, radius, shadow = decor.border, decor.radius, decor.shadow
    local total_w, total_h, iw, ih = coverGeom(decor, max_w, max_h, bw, bh)

    local inner
    if bb then
        local ok, img = pcall(function()
            local widget = ImageWidget:new{
                image = bb,
                image_disposable = true,
                width = iw,
                height = ih,
                scale_factor = 0,
            }
            widget:getSize()
            return widget
        end)
        if ok then
            inner = img
        else
            bb:free()
        end
    end
    if not inner then
        inner = NoCover:new{ width = iw, height = ih }
    end

    local outer_w, outer_h = iw + 2 * border, ih + 2 * border
    local cover_frame = CoverFrame:new{
        inner  = inner,
        width  = outer_w, height = outer_h,
        border = border,  radius = radius,
        bg     = Blitbuffer.COLOR_WHITE,
        fg     = Blitbuffer.COLOR_BLACK,
        shadow_color  = shadow > 0 and CoverFrame.shadowColor() or nil,
        shadow_offset = shadow,
    }

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

-- Large cover: the text column keeps at least this share of the content
-- width, and the popup never grows taller than this share of the screen.
local LARGE_MIN_TEXT_FRAC   = 0.36
local LARGE_MAX_HEIGHT_FRAC = 0.85

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

    local title_face  = Fonts.getFace("bookinfo_title")
    local author_face = Fonts.getFace("bookinfo_author")
    local series_face = Fonts.getFace("bookinfo_series")
    local desc_face   = Fonts.getFace("bookinfo_description")
    local stats_face  = Fonts.getFace("bookinfo_stats")
    local show_author = Opt.readBookInfo("author") and self.info.authors
    local series_line = Opt.readBookInfo("series") and Data.seriesLine(self.info) or nil

    -- Star rating, above the title (tap or long press it to edit).
    self.stars_widget = TextWidget:new{
        text    = Ratings.stars(self.rating),
        face    = author_face,
        fgcolor = Colors.value(),
    }
    local stars_w = self.stars_widget:getSize().w
    local stars_h = self.stars_widget:getSize().h

    -- "Finished: 2026-10-07", the date in the format chosen under Settings >
    -- Settings > Date & time; right-aligned on the stars' row.
    local finished_text
    if self.finished_ts and tonumber(self.finished_ts) and tonumber(self.finished_ts) > 0 then
        local d = Locale.formatDateFromTS(tonumber(self.finished_ts))
        if d and d ~= "" then
            finished_text = _("Finished") .. ": " .. d
        end
    end
    local finished_gap = S(12)
    local finished_w = finished_text and naturalWidth(finished_text, author_face) or 0

    -- "860 pages · 12:56 reading time", over the whole history of the book:
    -- always shown for a book that has statistics (zeros when it has no
    -- reading entries yet), left-aligned under the description.
    local stats_text
    if self.id_book then
        local pages, secs = Data.totals(self.ui, self.id_book)
        pages = math.floor(tonumber(pages) or 0)
        secs  = math.floor(tonumber(secs) or 0)
        -- same formatter (and rounding) as the Book progress popup
        stats_text = string.format("%d %s \194\183 %s %s",
            pages, _("pages read"), Locale.formatTimeHHMM(secs).value, _("reading time"))
    end
    local stats_w = stats_text and naturalWidth(stats_text, stats_face) or 0
    local stats_gap = S(6)
    local stats_h = 0
    if stats_text then
        local probe = TextWidget:new{ text = stats_text, face = stats_face }
        stats_h = probe:getSize().h
        probe:free()
    end

    -- Cover. Medium is a fixed box (34% of the content width x 30% of the
    -- screen height). Small and large are fitted to the text instead:
    --   small  the cover is only as tall as the text beside it - stars,
    --          title, author, series and the pages / time line, no
    --          description - so it is the smallest cover that holds them;
    --   large  the cover is made as big as it can be while the popup stays
    --          within 94% of the width, all of that text still fits beside
    --          it (no cut-off lines) and the popup fits the screen.
    -- When no such cover exists the medium box is used.
    local size_mode  = Opt.readBookInfoCoverSize()
    local is_small   = size_mode == Opt.BOOK_INFO_COVER_SIZE_SMALL
    local is_large   = size_mode == Opt.BOOK_INFO_COVER_SIZE_LARGE
    local show_cover = Opt.readBookInfo("cover") and true or false
    local decor      = self:_coverDecor()
    self.cover_diag  = nil
    local bb = show_cover and self:_loadCover() or nil
    local bw, bh = 2, 3
    if bb then
        local okd, w_, h_ = pcall(function() return bb:getWidth(), bb:getHeight() end)
        if okd and w_ and h_ and w_ > 0 and h_ > 0 then bw, bh = w_, h_ end
    end

    local cover_box_w, cover_box_h
    local fitted = false
    if show_cover and (is_small or is_large) then
        local title_m  = measureWords(self.info.title or "", title_face)
        local author_m = show_author and measureWords(self.info.authors, author_face) or nil
        local series_m = series_line and measureWords(series_line, series_face) or nil

        -- Height of everything in the text column for a column `w` wide.
        local function textNeed(w)
            local h = stars_h + Size.padding.small
                + countLines(title_m, w) * lineHeight(title_face)
            if author_m then
                h = h + Size.padding.default + countLines(author_m, w) * lineHeight(author_face)
            end
            if series_m then
                h = h + Size.padding.small + countLines(series_m, w) * lineHeight(series_face)
            end
            if stats_text then h = h + stats_gap + stats_h end
            return h
        end

        -- The narrowest column everything can still be set in: its longest
        -- word, the stars (with the finished date) and the pages / time
        -- line, which stays on one line.
        local widest = title_m.widest
        if author_m then widest = math.max(widest, author_m.widest) end
        if series_m then widest = math.max(widest, series_m.widest) end
        local min_w = math.max(widest + S(6),
            (finished_text and (stars_w + finished_gap + finished_w) or stars_w) + S(4),
            stats_w + S(4))

        if min_w <= math.floor(content_w * 0.65) then
            if is_small then
                -- from a tiny cover upwards: the taller the cover the
                -- narrower the text column and the more the text needs
                local h = S(60)
                for _try = 1, 40 do
                    local cw, ch = coverGeom(decor, content_w, h, bw, bh)
                    local tw = content_w - cw - gap
                    if tw < min_w then break end
                    local need = textNeed(tw)
                    if ch >= need then
                        cover_box_w, cover_box_h = content_w, h
                        fitted = true
                        break
                    end
                    h = h + math.max(1, need - ch)
                end
            else
                -- from the biggest cover the width / height budget allows
                -- downwards, in small steps, to the first one the text fits
                local min_large = math.max(min_w, math.floor(content_w * LARGE_MIN_TEXT_FRAC))
                local h_cap = math.floor(screen_h * LARGE_MAX_HEIGHT_FRAC) - 2 * (border_w + pad)
                local _tw, top_h = coverGeom(decor, content_w - gap - min_large, h_cap, bw, bh)
                local _mw, med_h = coverGeom(decor, math.floor(content_w * 0.34),
                    math.floor(screen_h * 0.30), bw, bh)
                local step = math.max(2, S(3))
                local h = top_h
                while h >= med_h do
                    local cw, ch = coverGeom(decor, content_w, h, bw, bh)
                    local tw = content_w - cw - gap
                    if tw >= min_large and ch >= textNeed(tw) then
                        cover_box_w, cover_box_h = content_w, h
                        fitted = true
                        break
                    end
                    h = h - step
                end
            end
        end
    end
    if not fitted then
        cover_box_w = math.floor(content_w * 0.34)
        cover_box_h = math.floor(screen_h * 0.30)
    end

    local cover, cover_w, cover_h
    if show_cover then
        cover, cover_w, cover_h = self:_buildCover(decor, cover_box_w, cover_box_h, bb, bw, bh)
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{ width = gap })
        text_w = math.max(S(80), content_w - cover_w - gap)
    end

    -- A fitted small cover has no room for the description (and is not
    -- meant to show it).
    local show_desc = Opt.readBookInfo("description")
    if fitted and is_small then show_desc = false end

    -- The box is only as wide as it has to be: if the title, the author(s),
    -- the series, the stars and the pages / time row all fit on one line
    -- each, the text column shrinks to the widest of them; otherwise it keeps
    -- the full (maximum) width and the long lines wrap. That applies without
    -- a cover always, and with one while the description is off (with the
    -- description on next to a cover the box keeps its maximum width so the
    -- description has room to breathe). A fitted large cover always keeps
    -- the maximum width: the cover is as big as it can be.
    local needed = math.max(naturalWidth(self.info.title, title_face),
        finished_text and (stars_w + finished_gap + finished_w) or stars_w, stats_w)
    if show_author then
        needed = math.max(needed, naturalWidth(self.info.authors, author_face))
    end
    if series_line then
        needed = math.max(needed, naturalWidth(series_line, series_face))
    end
    if (not cover or not show_desc) and not (fitted and is_large) and needed < text_w then
        -- a few pixels of slack so a line that just fits never wraps
        text_w = math.max(S(80), math.ceil(needed) + S(4))
    end

    -- Lines the text may take. Fitted covers were sized to the text, so
    -- nothing is cut short; otherwise a long title / author list / series is
    -- cut with an ellipsis (the blocks only take the height they need).
    local title_lines, author_lines, series_lines = 4, 3, 2
    if fitted then title_lines, author_lines, series_lines = 8, 6, 4 end

    local text_col = VerticalGroup:new{ align = "left" }
    self.stars_frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.stars_widget,
    }
    if finished_text then
        local date_widget = TextWidget:new{
            text      = finished_text,
            face      = author_face,
            max_width = math.max(S(40), text_w - stars_w - finished_gap),
            fgcolor   = Colors.label(),
        }
        local dsz = date_widget:getSize()
        date_widget.overlap_offset = {
            math.max(stars_w + finished_gap, text_w - dsz.w),
            math.max(0, math.floor((stars_h - dsz.h) / 2)),
        }
        table.insert(text_col, OverlapGroup:new{
            dimen = Geom:new{ w = text_w, h = stars_h },
            allow_mirroring = false,
            self.stars_frame,
            date_widget,
        })
    else
        table.insert(text_col, self.stars_frame)
    end
    table.insert(text_col, VerticalSpan:new{ width = Size.padding.small })
    table.insert(text_col, textBlock(
        self.info.title or "", title_face, Colors.value(), text_w, title_lines))

    if show_author then
        table.insert(text_col, VerticalSpan:new{ width = Size.padding.default })
        table.insert(text_col, textBlock(
            self.info.authors, author_face, Colors.label(), text_w, author_lines))
    end

    if series_line then
        table.insert(text_col, VerticalSpan:new{ width = Size.padding.small })
        table.insert(text_col, textBlock(
            series_line, series_face, Colors.label(), text_w, series_lines))
    end

    -- Description: starts one padding below the author / series and runs
    -- down to the bottom of the cover (its shadow included, when on), as many
    -- whole lines as fit - fewer by the pages / reading time line that
    -- closes the column. Tapping it opens the full text.
    local stats_widget
    if stats_text then
        stats_widget = TextWidget:new{
            text = stats_text, face = stats_face,
            max_width = text_w, fgcolor = Colors.label(),
        }
    end

    self.desc_frame = nil
    self.desc_full = nil
    if show_desc and self.info.description then
        local region_h = cover_h or math.floor(screen_h * 0.30)
        local probe = TextWidget:new{ text = "Ag", face = desc_face }
        local line_h = probe:getSize().h
        probe:free()
        -- Sum the children by hand: VerticalGroup:getSize() caches its size
        -- and offsets, which would go stale once the description is added.
        local used_h = 0
        for _idx, child in ipairs(text_col) do
            used_h = used_h + child:getSize().h
        end
        local reserved = stats_widget and ((cover and stats_gap or pad) + stats_h) or 0
        local avail = region_h - used_h - pad - reserved
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

    -- The pages / reading time line. With a cover it is pinned to the
    -- bottom of the cover (shadow included): the text column becomes a box as
    -- tall as the cover (or as the text, if that is taller) and the line sits
    -- at its foot. Without a cover it simply follows the text, one large
    -- padding below it. Either way it is laid out in the column's width.
    local text_block = text_col
    if stats_widget then
        if cover then
            local content_h = 0
            for _idx, child in ipairs(text_col) do
                content_h = content_h + child:getSize().h
            end
            local box_h = math.max(cover_h or 0, content_h + stats_gap + stats_h)
            stats_widget.overlap_offset = { 0, box_h - stats_h }
            text_block = OverlapGroup:new{
                dimen = Geom:new{ w = text_w, h = box_h },
                allow_mirroring = false,
                text_col,
                stats_widget,
            }
        else
            table.insert(text_col, VerticalSpan:new{ width = pad })
            table.insert(text_col, stats_widget)
        end
    end
    if text_col.resetLayout then text_col:resetLayout() end
    table.insert(row, text_block)

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

-- Tap or long press on the stars: the star rating popup. The rating goes into the
-- book's own sidecar (so the file manager shows it too - a book that had no
-- stars there gets them), or into the plugin's own file when the book's file
-- is not known (see Ratings.save).
function BookInfoPopup:_editRating()
    if not self.md5 and not self.save_rating then
        UIManager:show(InfoMessage:new{
            modal = true,
            text  = _("This book has no checksum, so its rating can't be saved"),
        })
        return
    end
    RatingDialog.show{
        title   = self.info.title,
        rating  = self.rating,
        on_save = function(n)
            local saved
            if self.save_rating then
                saved = self.save_rating(n)
            else
                saved = Ratings.save(self.md5, n, self.rating_file)
            end
            if not saved then
                UIManager:show(InfoMessage:new{
                    modal = true,
                    text  = _("This book has no checksum, so its rating can't be saved"),
                })
                return
            end
            self.rating = n
            self.stars_widget:setText(Ratings.stars(n))
            UIManager:setDirty(self, function()
                return "ui", self.popup_frame.dimen
            end)
            if self.on_rate then self.on_rate(n) end
        end,
    }
end

-- Is the gesture on the stars? A fingertip is bigger than five small stars:
-- a little slack all round.
function BookInfoPopup:_onStars(ges)
    local d = self.stars_frame and self.stars_frame.dimen
    local pos = ges and ges.pos
    if not d or not pos then return false end
    local slack = S(12)
    return pos.x >= d.x - slack and pos.x <= d.x + d.w + slack
       and pos.y >= d.y - slack and pos.y <= d.y + d.h + slack
end

function BookInfoPopup:onHold(arg, ges)
    if self:_onStars(ges) then
        self:_editRating()
    elseif self.cover_diag then
        -- a long press anywhere else while the cover is missing says why
        UIManager:show(InfoMessage:new{ modal = true, text = self.cover_diag })
    end
    return true
end

function BookInfoPopup:onTapClose(arg, ges)
    -- a tap on the stars opens the rating popup (as a long press does)
    if self:_onStars(ges) then
        self:_editRating()
        return true
    end
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
