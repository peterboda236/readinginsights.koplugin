--[[
Reading Insights - chapter bar widget for the book progress view.

The horizontal strip of per-chapter blocks under the "This book" section:
one block per chapter, width proportional to the chapter's page count, the
current chapter filled to show how far into it the reader is, with arrows on
either side when the chapters don't all fit in one row.

Split out of book_stats_view.lua, which had grown to hold this ~150-line
builder in the middle of its own layout code even though nothing else in it
touches the widget's internals. It takes a chapter_info table (see
lib/chapterinfo.lua for where that comes from) and returns a widget, so the
two halves - working out which chapter you're in, and drawing it - are now
separate files.

Loaded by main.lua with the shared colors and fonts modules, plus the
callback that reads the user's chapter-bar height setting (which lives with
the rest of the book-progress settings in the view).

  ChapterBar.PAGE_SIZE       chapter columns per page of the bar
  ChapterBar.readHeightSetting() / ChapterBar.saveHeightSetting(v) / ChapterBar.DEFAULT_HEIGHT
      the bar's height in "points" (Settings > Advanced settings > Bar
      chart height > "Book progress: Chapters"), read on every build
  ChapterBar.build(chapter_info, full_width, padding_h, offset_override,
                   on_prev, on_next)
      chapter_info    { current, total, page_counts, chapter_progress_ratio }
      offset_override  first chapter to show, for paging with the arrows
      on_prev/on_next  called with the new offset when an arrow is tapped;
                       nil when that direction has nothing more to show
]]--

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = require("device").screen

-- Shared color and font settings, passed in as this chunk's arguments by
-- main.lua.
-- Shared modules, passed in as one named table by main.lua. Named rather
-- than positional on purpose: the list had grown long enough that
-- inserting one module in the middle would silently shift every module
-- after it, and the resulting nil would only surface far from the cause.
local deps = ...
local Colors, Fonts, UI =
    deps.Colors, deps.Fonts, deps.UI

local M = {}

-- How many chapter columns one page of the bar shows. Exported because the
-- view pages the bar by exactly this much on a swipe, and works out which
-- page the current chapter falls on the same way.
M.PAGE_SIZE = 25

-- Chapter-bar height setting (Settings ▸ Advanced settings ▸
-- "Bar chart height" ▸ "Book progress: Chapters"). Same "points" value
-- previously hardcoded into Screen:scaleBySize(46) below; restoring the
-- default reproduces the exact original look.
local SETTINGS_KEY_HEIGHT = "reading_insights_chapter_bar_height"
M.DEFAULT_HEIGHT = 46

function M.readHeightSetting()
    if G_reader_settings and G_reader_settings.readSetting then
        local v = G_reader_settings:readSetting(SETTINGS_KEY_HEIGHT)
        if v == nil then return M.DEFAULT_HEIGHT end
        return v
    end
    return M.DEFAULT_HEIGHT
end

function M.saveHeightSetting(value)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(SETTINGS_KEY_HEIGHT, value)
    end
end

function M.build(chapter_info, full_width, padding_h, offset_override, on_prev, on_next)
    if not chapter_info or not chapter_info.total or chapter_info.total == 0 then
        return nil
    end

    local total                  = chapter_info.total
    local current                = chapter_info.current or 0
    local page_counts            = chapter_info.page_counts
    local chapter_progress_ratio = chapter_info.chapter_progress_ratio or 0.0

    local col_h_max = Screen:scaleBySize(M.readHeightSetting())

    local max_pages = 0
    if page_counts then
        for i = 1, total do
            local pc = page_counts[i] or 0
            if pc > max_pages then max_pages = pc end
        end
    end

    local function barHeight(ch_idx)
        if page_counts and max_pages > 0 then
            local pc = page_counts[ch_idx] or 0
            return math.max(1, math.floor(1 + (pc / max_pages) * (col_h_max - 1)))
        end
        return col_h_max
    end

    local v_pad      = Size.padding.large
    local arrow_face = Fonts.getFace("stats_arrow")
    local inner_pad  = Size.padding.default

    -- Measure arrow glyph width once; both arrows use the same face so width is identical.
    local arrow_glyph_w = TextWidget:new{ text = "\xe2\x80\xb9", face = arrow_face }:getSize().w
    local slot_w        = arrow_glyph_w + 2 * inner_pad

    -- Available width for exactly PAGE_SIZE columns, after symmetric padding and both arrow slots.
    local avail_w   = full_width - 2 * padding_h - 2 * slot_w
    local col_w     = math.floor(avail_w / M.PAGE_SIZE)
    local remainder = avail_w - col_w * M.PAGE_SIZE  -- extra pixels, absorbed into right padding
    local gap       = math.max(1, math.floor(col_w * 0.15))
    local bar_w     = col_w - gap

    -- offset snaps to PAGE_SIZE pages: 1, 26, 51, …
    local offset = math.max(1, math.min(offset_override or 1, total))

    local can_go_left  = (offset > 1)
    local can_go_right = (offset + M.PAGE_SIZE - 1 < total)
    local left_arrow_color  = can_go_left  and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_E
    local right_arrow_color = can_go_right and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_E

    -- Build exactly PAGE_SIZE slots; slots beyond total are white (empty).
    local bar_row = HorizontalGroup:new{ align = "bottom" }
    for i = 1, M.PAGE_SIZE do
        local ch_idx = offset + i - 1
        if ch_idx <= total then
            local bh = barHeight(ch_idx)
            if ch_idx == current then
                local read_h   = math.max(1, math.floor(bh * chapter_progress_ratio))
                local unread_h = bh - read_h
                table.insert(bar_row, VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ height = col_h_max - bh },
                    unread_h > 0 and Colors.newBar(bar_w, unread_h, Colors.inactiveBar())
                        or VerticalSpan:new{ height = 0 },
                    read_h > 0 and Colors.newBar(bar_w, read_h, Colors.activeBar())
                        or VerticalSpan:new{ height = 0 },
                })
            else
                table.insert(bar_row, VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ height = col_h_max - bh },
                    Colors.newBar(bar_w, bh, ch_idx < current and Colors.activeBar() or Colors.inactiveBar()),
                })
            end
        else
            -- empty slot: same width as a real bar so the total row width stays fixed
            table.insert(bar_row, LineWidget:new{
                dimen      = Geom:new{ w = bar_w, h = col_h_max },
                background = Blitbuffer.COLOR_WHITE,
            })
        end
        if i < M.PAGE_SIZE then
            table.insert(bar_row, LineWidget:new{
                dimen      = Geom:new{ w = gap, h = col_h_max },
                background = Blitbuffer.COLOR_WHITE,
            })
        end
    end

    local function makeArrowSpan(symbol, fgcolor)
        local tw      = TextWidget:new{ text = symbol, face = arrow_face, fgcolor = fgcolor }
        local gh      = tw:getSize().h
        local top_pad = math.floor((col_h_max - gh) / 2)
        return FrameContainer:new{
            background     = nil,
            bordersize     = 0,
            padding_top    = 0,
            padding_bottom = 0,
            padding_left   = 0,
            padding_right  = 0,
            margin         = 0,
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ height = top_pad },
                HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = inner_pad },
                    tw,
                    HorizontalSpan:new{ width = inner_pad },
                },
                VerticalSpan:new{ height = col_h_max - gh - top_pad },
            },
        }
    end

    -- Layout: (padding_h + remainder/2) | left_arrow | [PAGE_SIZE slots] | right_arrow | (padding_h + remainder/2)
    -- The leftover rounding pixels from col_w's floor() are split evenly between
    -- both sides (any odd extra pixel goes to the right) so the empty space
    -- around the two arrows stays visually symmetric.
    local remainder_left  = math.floor(remainder / 2)
    local remainder_right = remainder - remainder_left
    
    local left_arrow_widget  = makeArrowSpan("\xe2\x80\xb9", left_arrow_color)
    local right_arrow_widget = makeArrowSpan("\xe2\x80\xba", right_arrow_color)
    
    local flat_row = HorizontalGroup:new{ align = "center" }
    table.insert(flat_row, HorizontalSpan:new{ width = padding_h + remainder_left })
    table.insert(flat_row, left_arrow_widget)
    table.insert(flat_row, bar_row)
    table.insert(flat_row, right_arrow_widget)
    table.insert(flat_row, HorizontalSpan:new{ width = padding_h + remainder_right })

    local bar_h = col_h_max + 2 * Size.padding.default

    local fixed_bar_row = FrameContainer:new{
        bordersize     = 0,
        padding_top    = Size.padding.default,
        padding_bottom = Size.padding.default,
        padding_left   = 0,
        padding_right  = 0,
        background     = Blitbuffer.COLOR_WHITE,
        dimen          = Geom:new{ w = full_width, h = bar_h },
        flat_row,
    }

    local result = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ height = v_pad },
        fixed_bar_row,
        VerticalSpan:new{ height = v_pad },
    }
    result._on_swipe_left  = can_go_right and on_next or nil
    result._on_swipe_right = can_go_left  and on_prev or nil
    return result, left_arrow_widget, right_arrow_widget, can_go_left, can_go_right
end

return M
