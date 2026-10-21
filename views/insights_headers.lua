--[[
Reading Insights - the insights popup's header rows.

Split out of insights_view.lua: the year header (previous / selected / next
year, tap = year shelf), the week pager header of the "Current week" view,
the date-range text it shows and the section-header wrapper that keeps a
coloured header background between the divider lines. Pure widget builders -
the popup hands itself in as `popup_self` only for the state it reads
(week_offset, readonly) and the methods the taps call.

Loaded once by main.lua and handed to the insights view as `deps.Headers`.
]]--

local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Screen = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, UI, Data, YearShelf =
    deps.Locale, deps.Colors, deps.UI, deps.Data, deps.YearShelf

-- Fill used behind a handful of section headers - the user-configurable
-- "Section header background color" (see colors.lua). A function rather than
-- a value computed once at load time, so it always reflects the current
-- setting even if changed after this module was first loaded.
local function HEADER_BG() return Colors.headerBg() end


-- Same as UI.buildSectionHeader, but insets the returned widget (including
-- its background) so its left/right edges land exactly where the section's
-- divider lines do. buildSectionHeader on its own spans layout.full_width
-- with the horizontal inset baked in as *internal* left/right padding, so a
-- plain white background bleeding out to the screen edges is invisible -
-- but a colored one (HEADER_BG) visibly overshoots the lines above/below
-- it, which is what this wrapper avoids.
local function buildAlignedSectionHeader(font_section, text, layout, background)
    return UI.padded(layout.padding_h,
        UI.buildSectionHeader(font_section, text, layout.content_width, 0, background))
end

local function buildYearHeader(popup_self, font_section, font_label, layout, year_range, selected_year)
    local prev_available = selected_year > year_range.min_year
    local next_available = selected_year < year_range.max_year

    local inner_pad = Size.padding.default
    local gap       = Size.padding.small

    -- The previous/next year on either side use the plain "label" face
    -- (like the "pages read" text below), so only the centre year - in the
    -- bold "section" face - stands out as the selected one.
    local sample_arrow = TextWidget:new{ text = "\xe2\x80\xb9", face = font_label }
    local arrow_w = sample_arrow:getSize().w
    sample_arrow:free()

    local sample_yr = TextWidget:new{ text = tostring(selected_year - 1), face = font_label }
    local yr_side_w = sample_yr:getSize().w
    sample_yr:free()

    local slot_w = arrow_w + gap + yr_side_w + inner_pad

    local year_label = TextWidget:new{
        text = tostring(selected_year),
        face = font_section,
        fgcolor = Colors.section(),
    }
    -- Year navigation is done via swipe on the whole popup (see
    -- onSwipe/_goToYear) and by tapping the previous/next year slot on either
    -- side of the centre year (the InputContainer wrappers below). The reading
    -- heatmap opens from the "All time" header instead of from tapping the
    -- year (see showReadingHeatmap and buildInsightsSections). Tapping the
    -- centre year itself opens the year shelf: the covers of the books read
    -- that year, month by month (see showYearShelf). Not on the sleep screen
    -- (readonly), where a tap must not navigate anywhere.
    local year_widget = year_label
    local year_tap_pad = 0
    if YearShelf and not popup_self.readonly then
        year_tap_pad = Screen:scaleBySize(16)
        local year_size = year_label:getSize()
        local year_inner = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = year_tap_pad },
            year_label,
            HorizontalSpan:new{ width = year_tap_pad },
        }
        local year_tappable = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0,
                w = year_size.w + 2 * year_tap_pad, h = year_size.h },
            year_inner,
        }
        year_tappable.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = year_tappable.dimen } },
        }
        function year_tappable:onTap()
            popup_self:showYearShelf()
            return true
        end
        year_widget = year_tappable
    end

    local function makeSlot(yr, arrow_glyph, left, visible, on_tap)
        if not visible then
            return HorizontalSpan:new{ width = slot_w }, slot_w
        end

        local arrow_tw = TextWidget:new{
            text    = arrow_glyph,
            face    = font_label,
            fgcolor = Colors.label(),
        }
        local yr_tw = TextWidget:new{
            text    = tostring(yr),
            face    = font_label,
            fgcolor = Colors.label(),
        }

        local parts
        if left then
            parts = HorizontalGroup:new{
                align = "center",
                arrow_tw,
                HorizontalSpan:new{ width = gap },
                yr_tw,
                HorizontalSpan:new{ width = inner_pad },
            }
        else
            parts = HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = inner_pad },
                yr_tw,
                HorizontalSpan:new{ width = gap },
                arrow_tw,
            }
        end

        -- Tapping the slot navigates to that year, same as the swipe.
        local tappable = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = parts:getSize().w, h = parts:getSize().h },
            parts,
        }
        tappable.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = tappable.dimen } },
        }
        function tappable:onTap()
            on_tap()
            return true
        end
        return tappable, slot_w
    end

    local left_slot,  left_w  = makeSlot(selected_year - 1, "\xe2\x80\xb9", true,  prev_available,
        function() popup_self:onGoToPrevYear() end)
    local right_slot, right_w = makeSlot(selected_year + 1, "\xe2\x80\xba", false, next_available,
        function() popup_self:onGoToNextYear() end)

    local year_w    = year_label:getSize().w + 2 * year_tap_pad
    local remaining = layout.content_width - left_w - right_w - year_w
    if remaining < 0 then remaining = 0 end
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l

    local header_content = HorizontalGroup:new{
        align = "center",
        left_slot,
        HorizontalSpan:new{ width = side_l },
        year_widget,
        HorizontalSpan:new{ width = side_r },
        right_slot,
    }

    -- padding_left/right were layout.padding_h here (baked into the
    -- background-painted area, so the background bled out to the screen
    -- edge). Moved to an external UI.padded wrap at the call site instead,
    -- so the background aligns with the section's divider lines like every
    -- other header background does.
    return FrameContainer:new{
        background     = HEADER_BG(),
        bordersize     = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = 0,
        padding_right  = 0,
        header_content,
    }
end

-- Short month name for the week range, always with its abbreviation dot
-- ("okt.", "Oct."), the usual form inside a date range. The name itself is
-- the translated one (Locale.shortMonthName), lower-cased in the languages
-- that opted in (Hungarian).
local function weekMonthLabel(m)
    local name = Locale.shortMonthName(m)
    if name:sub(-1) ~= "." then name = name .. "." end
    return name
end

local function parseWeekDate(date_str)
    local y, m, d = tostring(date_str):match("^(%d+)-(%d+)-(%d+)$")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

-- First day only, for a very narrow screen, in the configured date format:
--   Hungarian  okt. 12.     UK 12/10     US 10/12     ISO 10-12
local function formatWeekDay(date_str)
    local y, m, d = parseWeekDate(date_str)
    if not y then return tostring(date_str) end
    local fmt = Locale.readDateFormatSetting and Locale.readDateFormatSetting()
    if fmt == "ymd_dot" then
        return string.format("%s %d.", weekMonthLabel(m), d)
    elseif fmt == "ymd_dash" then
        return string.format("%02d-%02d", m, d)
    elseif fmt == "mdy_slash" then
        return string.format("%02d/%02d", m, d)
    end
    return string.format("%02d/%02d", d, m)
end

-- First and last day of a week for the pager, by the plugin's "Date format".
-- Three shapes, each written the way the format is written correctly:
--   one month        Hungarian  okt. 12–18.            (also "okt. 12–18. között")
--                    UK         12–18/10
--                    US         10/12–18
--                    ISO        10-12 – 10-18
--   across months    Hungarian  okt. 26. – nov. 1.     (spaced en dash)
--                    UK         26/10 – 01/11
--                    US         10/26 – 11/01
--                    ISO        10-26 – 11-01
--   with the year    Hungarian  2026. dec. 28. – 2027. jan. 3.   (week across the
--                               new year: the year on both ends)
--                    UK         28/12/2026 – 03/01/2027
--                    US         12/28/2026 – 01/03/2027
--                    ISO        2026-12-28 – 2027-01-03
--                    (US writes both ends in full whenever a year is shown)
-- The year is also shown, once, for a week that lies outside the current year
-- ("2025. okt. 12–18."), so a week paged far back is not ambiguous.
-- tier 1 = as above, tier 2 = the same without the year, tier 3 = only the
-- first day (narrow screens).
local function formatWeekRange(start_date, end_date, tier)
    local sy, sm, sd = parseWeekDate(start_date)
    local ey, em, ed = parseWeekDate(end_date)
    if not sy or not ey then return tostring(start_date) end
    if tier == 3 then return formatWeekDay(start_date) end

    local dash      = "\xe2\x80\x93"
    local sp_dash   = " " .. dash .. " "
    local cross_yr  = (sy ~= ey)
    local with_year = (tier == 1) and (cross_yr or sy ~= tonumber(os.date("%Y")))
    local fmt = Locale.readDateFormatSetting and Locale.readDateFormatSetting()

    if fmt == "ymd_dot" then
        if with_year and cross_yr then
            return string.format("%d. %s %d.%s%d. %s %d.",
                sy, weekMonthLabel(sm), sd, sp_dash, ey, weekMonthLabel(em), ed)
        end
        local prefix = with_year and (sy .. ". ") or ""
        if sm == em then
            return string.format("%s%s %d%s%d.", prefix, weekMonthLabel(sm), sd, dash, ed)
        end
        return string.format("%s%s %d.%s%s %d.",
            prefix, weekMonthLabel(sm), sd, sp_dash, weekMonthLabel(em), ed)

    elseif fmt == "ymd_dash" then
        if with_year then
            return string.format("%d-%02d-%02d%s%d-%02d-%02d",
                sy, sm, sd, sp_dash, ey, em, ed)
        end
        return string.format("%02d-%02d%s%02d-%02d", sm, sd, sp_dash, em, ed)

    elseif fmt == "mdy_slash" then
        -- A year after "10/13-19" would read as "19/2025", so with a year
        -- both ends are written out in full.
        if with_year then
            return string.format("%02d/%02d/%d%s%02d/%02d/%d",
                sm, sd, sy, sp_dash, em, ed, ey)
        end
        if sm == em then
            return string.format("%02d/%02d%s%02d", sm, sd, dash, ed)
        end
        return string.format("%02d/%02d%s%02d/%02d", sm, sd, sp_dash, em, ed)
    end

    -- UK: day first.
    if with_year and cross_yr then
        return string.format("%02d/%02d/%d%s%02d/%02d/%d",
            sd, sm, sy, sp_dash, ed, em, ey)
    end
    local ys = with_year and ("/" .. sy) or ""
    if sm == em then
        return string.format("%02d%s%02d/%02d%s", sd, dash, ed, sm, ys)
    end
    return string.format("%02d/%02d%s%02d/%02d%s", sd, sm, sp_dash, ed, em, ys)
end

-- Header of the weekly section in the "Current week" view. Laid out like the
-- year header: the previous week's first-last day on the left (tap = go
-- there), the shown week's own first-last day in the middle (bold) and the
-- next week's range on the right. A tap on the
-- middle jumps back to the current week (the chart is still toggled
-- between time and pages by tapping its caption or the values). Weeks are paged with these two slots or by swiping over the
-- weekly section; the year is paged only by swiping over the monthly chart.
local function buildWeekNavHeader(popup_self, font_section, font_label, layout)
    local offset   = popup_self.week_offset or 0
    local can_prev = popup_self:_weekInRange(offset - 1)
    local can_next = offset < 0
    local readonly = popup_self.readonly

    local cur_s,  cur_e  = Data.calendarWeekBounds(offset)
    local prev_s, prev_e = Data.calendarWeekBounds(offset - 1)
    local next_s, next_e = Data.calendarWeekBounds(offset + 1)

    local inner_pad = Size.padding.default
    local gap       = Size.padding.small

    local function measure(text, face)
        local tw = TextWidget:new{ text = text, face = face }
        local w = tw:getSize().w
        tw:free()
        return w
    end

    local arrow_w = measure("\xe2\x80\xb9", font_label)

    -- The centre (shown week) and the two neighbours get their own detail
    -- level, so a long centre label - worst case a week across New Year,
    -- "2025. dec. 29. - 2026. jan. 4." - keeps its full range with the year
    -- while the neighbours shrink (no year, then first day only) if all
    -- three would not fit side by side.
    --   centre tier: 1 = with year when needed, 2 = no year, 3 = first day
    --   side tier:   2 = range without year,     3 = first day
    local function layoutFor(center_tier, side_tier)
        local center_text = formatWeekRange(cur_s, cur_e, center_tier)
        local prev_text = formatWeekRange(prev_s, prev_e, side_tier)
        local next_text = formatWeekRange(next_s, next_e, side_tier)
        local side_w = math.max(measure(prev_text, font_label), measure(next_text, font_label))
        local slot_w = arrow_w + gap + side_w + inner_pad
        local center_w = measure(center_text, font_section)
        return center_text, prev_text, next_text, slot_w, center_w
    end

    -- Preference order: most informative first.
    local combos = { {1, 2}, {2, 2}, {1, 3}, {2, 3}, {3, 3} }
    local center_text, prev_text, next_text, slot_w, center_w
    for _, c in ipairs(combos) do
        center_text, prev_text, next_text, slot_w, center_w = layoutFor(c[1], c[2])
        if 2 * slot_w + center_w <= layout.content_width then break end
    end

    local function makeSlot(text, arrow_glyph, left, visible, on_tap)
        if not visible or readonly then
            return HorizontalSpan:new{ width = slot_w }
        end
        local arrow_tw = TextWidget:new{ text = arrow_glyph, face = font_label, fgcolor = Colors.label() }
        local text_tw  = TextWidget:new{ text = text,        face = font_label, fgcolor = Colors.label() }
        local parts
        if left then
            parts = HorizontalGroup:new{ align = "center",
                arrow_tw, HorizontalSpan:new{ width = gap }, text_tw }
        else
            parts = HorizontalGroup:new{ align = "center",
                text_tw, HorizontalSpan:new{ width = gap }, arrow_tw }
        end
        -- Pad to the common slot width so the middle stays centred; the
        -- outer edge of the slot keeps its inner padding.
        local pad = math.max(0, slot_w - parts:getSize().w)
        local boxed
        if left then
            boxed = HorizontalGroup:new{ align = "center", parts, HorizontalSpan:new{ width = pad } }
        else
            boxed = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad }, parts }
        end
        local tappable = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = boxed:getSize().w, h = boxed:getSize().h },
            boxed,
        }
        tappable.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = tappable.dimen } },
        }
        function tappable:onTap()
            on_tap()
            return true
        end
        return tappable
    end

    local left_slot  = makeSlot(prev_text, "\xe2\x80\xb9", true,  can_prev,
        function() popup_self:onGoToPrevWeek() end)
    local right_slot = makeSlot(next_text, "\xe2\x80\xba", false, can_next,
        function() popup_self:onGoToNextWeek() end)

    local center_label = TextWidget:new{
        text    = center_text,
        face    = font_section,
        bold    = true,
        fgcolor = Colors.section(),
    }
    local center_widget = center_label
    if not readonly then
        local tap_pad = Screen:scaleBySize(16)
        local sz = center_label:getSize()
        local inner = HorizontalGroup:new{ align = "center",
            HorizontalSpan:new{ width = tap_pad }, center_label, HorizontalSpan:new{ width = tap_pad } }
        local tappable = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = sz.w + 2 * tap_pad, h = sz.h },
            inner,
        }
        tappable.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = tappable.dimen } },
        }
        function tappable:onTap()
            popup_self:onGoToCurrentWeek()
            return true
        end
        center_widget = tappable
        center_w = sz.w + 2 * tap_pad
        -- Long press on the shown week's date: the week-view list.
        table.insert(popup_self._week_hold_targets, {
            w  = tappable,
            fn = function() popup_self:showWeeklyViewPicker() end,
        })
    end

    local remaining = layout.content_width - 2 * slot_w - center_w
    if remaining < 0 then remaining = 0 end
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l

    return FrameContainer:new{
        background     = HEADER_BG(),
        bordersize     = 0,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left   = 0,
        padding_right  = 0,
        HorizontalGroup:new{
            align = "center",
            left_slot,
            HorizontalSpan:new{ width = side_l },
            center_widget,
            HorizontalSpan:new{ width = side_r },
            right_slot,
        },
    }
end

return {
    buildAlignedSectionHeader = buildAlignedSectionHeader,
    buildYearHeader           = buildYearHeader,
    buildWeekNavHeader        = buildWeekNavHeader,
}
