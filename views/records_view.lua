--[[
Reading Insights - the Records popup.

A floating card showing personal reading records:

  - Most reading time in a day   across all books, with the date
  - Most pages in a day
  - Best daily streak            longest run of consecutive reading days
  - Last milestone               highest total-hours milestone passed
  - Next milestone               the next one ahead

The values and their caching live in lib/records_data.lua; this file draws
them. Opened from Tools > Reading insights > Show Records, or the
"reading_records_popup" gesture/dispatcher action - both available in reader
and file manager view alike, since none of this is tied to an open book. Tap
anywhere, swipe down or press any key to close.

Shown as a content-sized bordered card centred on screen rather than a
full-screen overlay, the same convention as the streak and trend popups: an
invisible tap-anywhere-to-close layer hosts the card.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer  = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

-- Injected by main.lua (same pattern as insights_view.lua /
-- book_stats_view.lua), plus the shared statistics-DB accessor (StatsDb)
-- and dismissable-popup helper (PopupUtil).
-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, PopupUtil, RecordsData =
    deps.Locale, deps.Colors, deps.Fonts, deps.PopupUtil, deps.RecordsData

local _ = Locale._
local N_ = Locale.N_
local formatCount = Locale.formatCount

-- ---------------------------------------------------------------------------
-- Row icons
-- ---------------------------------------------------------------------------
local ICONS = {
    session = "\xEF\x80\x97", -- U+F017 fa-clock
    pages   = "\xEF\x80\xAD", -- U+F02D fa-book
    streak  = "\xEF\x81\xAD", -- U+F06D fa-fire
    last_ms = "\xEF\x82\x91", -- U+F091 fa-trophy
    next_ms = "\xEF\x84\x9D", -- U+F11D fa-flag-o
}

-- ---------------------------------------------------------------------------
-- Date helpers
-- ---------------------------------------------------------------------------
-- Format a YYYY-MM-DD string in the configured date format. The same
-- shared formatter insights_view.lua's formatDateForDisplay uses, so
-- records, insights and stats popups all show dates the same way.
local formatDate = Locale.formatDate

-- ---------------------------------------------------------------------------
-- UI building helpers
-- ---------------------------------------------------------------------------
local ROW_PADDING = Size.padding.default

local function getCachedFonts()
    return {
        value = Fonts.getFace("records_value"),
        label = Fonts.getFace("records_label"),
        small = Fonts.getFace("records_small"),
    }
end

-- Builds one row using pre-measured, fixed column widths (see measureColumns
-- below) so that the icon / label / value columns line up like a table
-- across all rows, and the label column can never grow into the value
-- column - the widest label and the widest value each get their own fixed
-- width, with a dedicated gap between them.
local function buildRecordRow(fonts, icon_glyph, label_text, value_text, sub_text, cols)
    local pad = cols.pad
    local gap = cols.gap

    local value_w = TextWidget:new{
        text    = value_text,
        face    = fonts.value,
        fgcolor = Colors.value(),
    }
    local value_size = value_w:getSize()

    local sub_w
    if sub_text and sub_text ~= "" then
        sub_w = TextWidget:new{
            text    = sub_text,
            face    = fonts.small,
            fgcolor = Colors.small(),
        }
    end

    local right_col = VerticalGroup:new{ align = "right" }
    table.insert(right_col, value_w)
    if sub_w then
        table.insert(right_col, VerticalSpan:new{ height = 1 })
        table.insert(right_col, sub_w)
    end
    local right_size = right_col:getSize()

    local icon_w = TextWidget:new{
        text    = icon_glyph,
        face    = fonts.label,
        fgcolor = Colors.label(),
    }
    local icon_size = icon_w:getSize()

    local left_col = TextBoxWidget:new{
        text      = label_text,
        face      = fonts.label,
        fgcolor   = Colors.label(),
        width     = cols.label_w,
        alignment = "left",
    }
    local row_h = math.max(icon_size.h, left_col:getSize().h, right_size.h) + ROW_PADDING * 2

    local left_group = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = cols.icon_w, h = icon_size.h },
            icon_w,
        },
        HorizontalSpan:new{ width = cols.icon_gap },
        left_col,
    }

    return FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = 0,
        padding_top    = ROW_PADDING,
        padding_bottom = ROW_PADDING,
        padding_left   = pad,
        padding_right  = pad,
        HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = cols.icon_w + cols.icon_gap + cols.label_w, h = row_h - ROW_PADDING * 2 },
                left_group,
            },
            HorizontalSpan:new{ width = gap },
            RightContainer:new{
                dimen = Geom:new{ w = cols.right_w, h = row_h - ROW_PADDING * 2 },
                right_col,
            },
        },
    }
end

local function buildSeparator(width)
    return LineWidget:new{
        dimen      = Geom:new{ w = width, h = Size.line.thin },
        background = Colors.separator(),
    }
end

-- Measures the icon / label / value(+sub) column widths needed across ALL
-- rows (i.e. the widest icon, the widest label, the widest value/sub-value),
-- so every row can be laid out on the same table-like grid: the label
-- column is exactly as wide as the longest label - never more, never less -
-- and the value column is exactly as wide as the longest value, with a
-- fixed gap in between.
local function measureColumns(fonts, row_defs)
    local icon_w, label_w, right_w = 0, 0, 0
    for _, def in ipairs(row_defs) do
        local iw = TextWidget:new{ text = def.icon, face = fonts.label }
        icon_w = math.max(icon_w, iw:getSize().w)
        iw:free()

        local lw = TextWidget:new{ text = def.label, face = fonts.label }
        label_w = math.max(label_w, lw:getSize().w)
        lw:free()

        local vw = TextWidget:new{ text = def.value, face = fonts.value }
        right_w = math.max(right_w, vw:getSize().w)
        vw:free()

        if def.sub and def.sub ~= "" then
            local sw = TextWidget:new{ text = def.sub, face = fonts.small }
            right_w = math.max(right_w, sw:getSize().w)
            sw:free()
        end
    end
    return {
        icon_w   = icon_w,
        icon_gap = icon_w, -- space after the icon, same convention as before
        label_w  = label_w,
        right_w  = right_w,
    }
end

-- ---------------------------------------------------------------------------
-- Records popup widget
-- ---------------------------------------------------------------------------
local RecordsPopup = InputContainer:extend{
    modal     = true,
    _box_dimen = nil,
}

function RecordsPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end

    self:_buildUI()
end

function RecordsPopup:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local fonts    = getCachedFonts()

    -- Load data (uses cache when possible)
    local d = RecordsData.load()

    local tot_hours        = math.floor((d.total_secs or 0) / 3600)
    local last_ms, next_ms = RecordsData.getMilestones(tot_hours)
    local last_ms_date     = d.last_ms_date

    local outer_padding = Size.padding.large
    local max_w = math.floor(screen_w * 0.92)
    local min_w = math.min(Screen:scaleBySize(280), max_w)

    -- Collect row data first (without building widgets yet) so we can
    -- measure how wide the content actually needs to be.
    local row_defs = {}
    local function defRow(icon, label, value, sub)
        table.insert(row_defs, { icon = icon, label = label, value = value, sub = sub })
    end

    -- 1. Most reading time in a day
    local sess_val = (d.longest.duration_sec or 0) > 0
        and Locale.formatDuration(d.longest.duration_sec, true)
        or  "\xE2\x80\x93"
    local sess_sub = d.longest.date and formatDate(d.longest.date) or ""
    defRow(ICONS.session, _("Most reading time in a day"), sess_val, sess_sub)

    -- 2. Most pages in a day
    local pages_val = "\xE2\x80\x93"
    if (d.best_day.pages or 0) > 0 then
        pages_val = formatCount(d.best_day.pages) .. " " .. N_("page", "pages", d.best_day.pages)
    end
    local pages_sub = d.best_day.date and formatDate(d.best_day.date) or ""
    defRow(ICONS.pages, _("Most pages in a day"), pages_val, pages_sub)

    -- 3. Best daily streak
    local streak_val = "\xE2\x80\x93"
    if (d.streak.days or 0) > 0 then
        streak_val = formatCount(d.streak.days) .. " " .. N_("day", "days", d.streak.days)
    end
    local streak_sub = ""
    if d.streak.start_date and d.streak.end_date then
        streak_sub = formatDate(d.streak.start_date) .. " \xE2\x80\x93 " .. formatDate(d.streak.end_date)
    end
    defRow(ICONS.streak, _("Best daily streak"), streak_val, streak_sub)

    -- 4. Last milestone
    local last_val = last_ms
        and (formatCount(last_ms) .. " " .. N_("hour", "hours", last_ms))
        or  "\xE2\x80\x93"
    local last_sub = last_ms_date and formatDate(last_ms_date) or ""
    defRow(ICONS.last_ms, _("Last milestone"), last_val, last_sub)

    -- 5. Next milestone
    if next_ms then
        local hours_left = next_ms - tot_hours
        local next_sub = ""
        if hours_left > 0 then
            next_sub = string.format(N_("%d hour left", "%d hours left", hours_left), hours_left)
        end
        defRow(ICONS.next_ms, _("Next milestone"),
            formatCount(next_ms) .. " " .. N_("hour", "hours", next_ms),
            next_sub)
    else
        defRow(ICONS.next_ms, _("Next milestone"), "\xE2\x80\x93", "")
    end

    -- Measure fixed table columns (icon / label / value) across all rows,
    -- then size the card to fit the widest combination (title, or icon +
    -- label column + gap + value column), clamped between a sane minimum
    -- and 92% of the screen width.
    local title_w = TextWidget:new{
        text    = _("Records"),
        face    = fonts.value,
        fgcolor = Colors.value(),
    }
    local pad  = Size.padding.large
    local gap  = Size.padding.large
    local cols = measureColumns(fonts, row_defs)
    local row_content_w = 2 * pad + cols.icon_w + cols.icon_gap + cols.label_w + gap + cols.right_w

    local needed_w  = math.max(title_w:getSize().w + 2 * outer_padding, row_content_w + 2 * outer_padding)
    local card_w    = math.max(min_w, math.min(max_w, needed_w))
    local content_w = card_w - 2 * outer_padding

    -- Fit the columns into content_w: if the card got clamped narrower than
    -- the natural row width, shrink (and let wrap) the label column only -
    -- the value column keeps its full width so numbers never truncate. If
    -- there's slack instead (e.g. the title is the widest thing), grow the
    -- gap rather than the label, so the label stays snug against its icon.
    local avail_for_label = content_w - 2 * pad - cols.icon_w - cols.icon_gap - gap - cols.right_w
    if avail_for_label < cols.label_w then
        cols.label_w = math.max(avail_for_label, Screen:scaleBySize(10))
    else
        gap = gap + (avail_for_label - cols.label_w)
    end
    cols.pad = pad
    cols.gap = gap

    local rows = VerticalGroup:new{ align = "left" }
    local function addRow(icon, label, value, sub)
        table.insert(rows, buildRecordRow(fonts, icon, label, value, sub, cols))
        table.insert(rows, HorizontalGroup:new{
            HorizontalSpan:new{ width = pad },
            buildSeparator(content_w - 2 * pad),
        })
    end
    for _, def in ipairs(row_defs) do
        addRow(def.icon, def.label, def.value, def.sub)
    end
    table.remove(rows) -- remove trailing separator

    -- Title and divider use the same horizontal inset as the row content
    -- (rows have padding_left/right = Size.padding.large on their own
    -- FrameContainer, so the inner content starts at that offset).
    local row_pad   = Size.padding.large
    local inner_w   = content_w - 2 * row_pad

    local content = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            HorizontalSpan:new{ width = row_pad },
            LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = title_w:getSize().h },
                title_w,
            },
        },
        VerticalSpan:new{ height = Size.padding.default },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = row_pad },
            Colors.newBar(inner_w, Size.line.thick, Colors.separator()),
        },
        VerticalSpan:new{ height = Size.padding.large },
        rows,
    }

    local box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = outer_padding,
        padding_bottom = outer_padding,
        padding_left   = outer_padding,
        padding_right  = outer_padding,
        content,
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        box,
    }
    self._box_dimen = box.dimen
end

-- Any tap / swipe / key dismisses; onShow/onCloseWidget mark the records
-- box region (self._box_dimen, set in the build above) dirty. All five come
-- from the shared helper (see popuputil.lua).
PopupUtil.makeDismissable(RecordsPopup, function(self) return self._box_dimen end)

return { Popup = RecordsPopup }
