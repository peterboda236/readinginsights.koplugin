--[[
Reading Insights - the full-screen insights popup.

Draws the scrollable page of reading history and handles everything on it:
year navigation, the taps that open the other popups, and the layout of the
sections. The figures themselves come from lib/insights_data.lua; nothing
here reads the statistics DB.

Sections, top to bottom:
  - Last 7 days   7-day totals and averages + daily bar chart (or, with the
                  "Current week" view setting, one pageable calendar week)
  - Streaks       current and best daily/weekly streaks
  - Year          time, days read or books read + pages, per year
  - Monthly chart per-month bars; the header cycles hours/days/books
  - Reading goal  finished books vs. a per-year target (can be switched off
                  in Settings > Reading insight popup)
  - All time    all-time totals

Gestures:
  - Tap "All time" header            reading heatmap (swipe there to page
                                       through older periods)
  - Tap yearly value or monthly bar/dot  book list for that period
  - Tap monthly chart header           cycle hours/days/books
  - Tap a streak                       that streak's dates and totals
  - Tap a Last 7 days value              8-week trend popup
  - Tap today's bar in Last 7 days       Today Timeline
  - Long press current month           CalendarView
  - Tap finished-book count            books finished that year
  - Long press finished-book count     checklist to correct that list
  - Long press reading goal value      set that year's goal
  - Long press title bar               force-reload everything from the DB
  - Swipe left/right on monthly chart change year (elsewhere: ignored)
  - Swipe down / any key               close

Refresh: "ui" on open/close by default, "full" if the Tools-menu toggle for
it is on. The trend and streak popups repaint only their own box, so they
don't flash the whole screen.

Bar chart heights: by default both charts size themselves while the page is
built so it fits one screen without a scroll bar - see _buildUI's fit loop,
and Settings > Reading insight popup > "Bar chart height" to turn it off.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local T = require("ffi/util").template

-- Shared translations/number-formatting, shared chart/text color settings,
-- and this view's own settings module (VS - lib/insights_settings.lua, every
-- user-settable option this popup reads or writes), all loaded once by
-- main.lua and passed in as this chunk's arguments (see main.lua's
-- loadModule() call for this file).
-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, PopupUtil, VS, Cache, UI, Trend, Heatmap, BookList, Data, Manual, Achievements, AchievementsView, Prefs, Streak, Records, YearShelf =
    deps.Locale, deps.Colors, deps.Fonts, deps.PopupUtil,
    deps.VS, deps.Cache, deps.UI, deps.Trend, deps.Heatmap, deps.BookList,
    deps.Data, deps.Manual, deps.Achievements, deps.AchievementsView, deps.Prefs, deps.Streak,
    deps.Records, deps.YearShelf

-- true: today's bar in the weekly chart is black. false: all bars gray.
local WEEKLY_CHART_HIGHLIGHT_TODAY = true

-- Fill used behind a handful of section headers ("Last 7 days", "Current
-- streak"/"Best streak", the year header, "Achievements" when shown next
-- to "Reading goal", and "All time") to visually group them with the
-- section above rather than reading as their own separate block. Backed by
-- the user-configurable "Section header background color" (white by
-- default, i.e. no visible fill) - see colors.lua. A function rather than
-- a value computed once at load time, so it always reflects the current
-- setting even if changed after this module was first loaded.
local function HEADER_BG() return Colors.headerBg() end

-- Value-based (not reference-based) equality for the small stat tables
-- returned by the getters below. Needed because a per-minute cache refresh
-- allocates a brand new result table every time it recomputes, even when
-- the actual numbers haven't changed (e.g. no reading happened in the last
-- minute) - a plain "==" would treat that as "changed" and force a needless
-- UI rebuild + e-ink redraw on almost every popup open.
local function valuesEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not valuesEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Localisation and number formatting now live in the shared locale.lua module
-- (required by main.lua and handed to this view as `Locale`), so both this
-- popup and the reading-stats popup translate from the same locale/<lang>.po
-- files instead of each keeping its own copy.
local _            = Locale._
local N_           = Locale.N_
local getLangBase  = Locale.getLangBase
local formatNumber = Locale.formatNumber
local formatCount  = Locale.formatCount

-- Format a YYYY-MM-DD string in the configured date format (Settings ▸
-- Settings ▸ Date & time ▸ "Date format" - see
-- Locale.formatDate).
-- no_trailing_dot: ignored (kept for compatibility); every date keeps its
-- final dot, also the first date of a range.
local function formatDateForDisplay(date_str, no_trailing_dot)
    if not date_str then return "?" end
    return Locale.formatDate(date_str, no_trailing_dot)
end

local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}
-- Hungarian month abbreviations for the monthly bar chart only: lower case
-- ("jan.", "febr.", ...), the way they are normally written in running
-- text. A lookup table rather than string.lower(), which can't lower-case
-- accented capitals like "Á". Everywhere else the shared, capitalised
-- _("Jan") ... _("Dec") strings stay as they were.
local MONTH_NAMES_SHORT_HU_LC = {
    "jan.", "febr.", "márc.", "ápr.", "máj.", "jún.",
    "júl.", "aug.", "szept.", "okt.", "nov.", "dec.",
}
local ReadingInsightsPopup

-- Format seconds as a clock-style duration for book list display, honouring
-- KOReader's global "duration_format" setting (classic "1:30:10", modern
-- "1h30'10\"", ...) - see Locale.formatDuration() in locale.lua for details.
local function formatHHMMSS(seconds)
    return Locale.formatDuration(seconds, false)
end

-- Splits a formatted duration into a bold "value" and a plain "unit" for
-- the value/label row layout used throughout this popup (bold number +
-- plain description, e.g. "7.3" + "days reading time"). Normally the
-- number is just the clock string and unit is exactly `base_label`
-- unchanged. But when "Show long durations (24h+) as days" is on and the
-- duration crosses a day, Locale.formatDurationParts() returns a trailing
-- "day"/"nap" word that must NOT be bold - so it's merged into the plain
-- `unit` ahead of the row's usual label instead of staying glued to the
-- bold number.
local function splitDurationValueUnit(seconds, base_label)
    local parts = Locale.formatDurationParts(seconds, true)
    local unit = base_label or ""
    if parts.unit ~= "" then
        unit = (unit ~= "" and (parts.unit .. " " .. unit)) or parts.unit
    end
    return parts.value, unit
end

-- Font faces for this popup's four text roles, sourced from the shared
-- Fonts settings module (see fonts.lua) so they're user-configurable via
-- the "Fonts" Tools-menu entry, the same way Colors.* works for colors.
-- Fonts.getFace() already caches per-role, so this is cheap to call again
-- on every popup (re)build - which is what keeps a just-changed font
-- setting picked up immediately, without needing our own extra cache.
--
-- `scale` (optional, default 1) shrinks all four roles by the same factor;
-- used by _buildUI's font fit (see there) to get rid of the scroll bar.
local function buildSerifFonts(scale)
    return {
        section = Fonts.getScaledFace("insights_section", scale),
        value   = Fonts.getScaledFace("insights_value",   scale),
        label   = Fonts.getScaledFace("insights_label",   scale),
        small   = Fonts.getScaledFace("insights_small",   scale),
    }
end

local _cached_layout = nil

-- Deliberately NOT cached at this module level (unlike getCachedLayout()
-- below): fonts are user-configurable via the Fonts menu, and
-- Fonts.getFace() already caches per-role internally, so rebuilding this
-- small table on every popup (re)build is cheap and guarantees a
-- just-changed font setting is picked up on the very next open, with no
-- stale fonts left over from before the change.
local function getCachedFonts(scale)
    return buildSerifFonts(scale)
end

-- Rebuilt whenever the screen width changes - not just on first use - so a
-- rotation between two openings of the popup (or, on devices that support
-- it, while it's open) is picked up instead of serving a stale portrait/
-- landscape layout.
local function getCachedLayout()
    local screen_w = Screen:getWidth()
    if not _cached_layout or _cached_layout.full_width ~= screen_w then
        _cached_layout = UI.buildLayout(screen_w, Size.padding.large, Screen:scaleBySize(20))
    end
    return _cached_layout
end

-- Landscape vs. portrait, used to switch a couple of sections (the "Last
-- week" figures, the monthly chart) between a layout tuned for a narrow
-- portrait popup and one that makes use of the extra horizontal room in
-- landscape. Shared with the calendar popups - see uikit.lua.
local isLandscapeScreen = UI.isLandscapeScreen

local function buildValueLine(font_value, font_label, col_width, value, unit)
    if value == "" then
        return TextBoxWidget:new{
            text      = unit,
            face      = font_label,
            fgcolor   = Colors.label(),
            width     = col_width,
            alignment = "left",
        }
    end

    local value_widget = TextWidget:new{ text = value, face = font_value, fgcolor = Colors.value() }
    local value_width = value_widget:getSize().w
    local text_desc_width = col_width - value_width - Size.padding.large
    return HorizontalGroup:new{
        align = "center",
        value_widget,
        HorizontalSpan:new{ width = Size.padding.large },
        TextBoxWidget:new{
            text      = unit,
            face      = font_label,
            fgcolor   = Colors.label(),
            width     = text_desc_width,
            alignment = "left",
        },
    }
end

local function tappableCell(widget, col_width, callback)
    local cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = col_width, h = widget:getSize().h },
        widget,
    }
    cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } },
    }
    function cell:onTap()
        callback()
        return true
    end
    return cell
end

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

-- Short month names for the week range, Hungarian ones lower-case with their
-- abbreviation dot ("okt."), the usual form inside a date range. Other
-- languages use the translated short month name from the translation files.
local HU_MONTHS_LOWER = { "jan.", "febr.", "márc.", "ápr.", "máj.", "jún.",
                          "júl.", "aug.", "szept.", "okt.", "nov.", "dec." }
local MONTH_KEYS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function weekMonthLabel(m)
    if Locale.getLangBase and Locale.getLangBase() == "hu" then
        return HU_MONTHS_LOWER[m]
    end
    local name = _(MONTH_KEYS[m])
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

-- Builds the reading-goal section header text, e.g. "Reading goal"
-- (en) / "Olvasási cél" (hu). Deliberately year-agnostic: the section
-- already shows and lets you navigate the selected year via swipe (like the
-- yearly/monthly sections above it), so repeating it in the header itself
-- (e.g. "2026-os olvasási cél") was redundant and needed a
-- vowel-harmony-dependent Hungarian suffix ("-os/-es/...") that had to be
-- recomputed per year.
local function buildGoalYearLabel(year)
    return _("Reading goal")
end

-- Title for the goal-edit popup (the SpinWidget opened by long-pressing the
-- goal value - see editReadingGoal below), e.g. "2026 - reading goal" (en) /
-- "2026 - olvasási cél" (hu). Unlike buildGoalYearLabel above, this one DOES
-- include the year: the section header can stay year-agnostic because the
-- section it titles is always on screen right below it, but this dialog is
-- a separate popup on top of everything else, so the year needs to be
-- spelled out here for it to be clear which year is being edited.
local function buildGoalEditTitle(year)
    return T(_("%1 - reading goal"), tostring(year))
end

local function buildYearlyRow(popup_self, yearly_stats, fonts, layout)
    -- Days of the shown year so far (the whole year once it is over): what the
    -- daily averages and the "of days read" percentage divide by.
    local selected_year = popup_self.selected_year or tonumber(os.date("%Y"))
    local current_year  = tonumber(os.date("%Y"))
    local days_in_year
    if selected_year == current_year then
        days_in_year = tonumber(os.date("%j"))
    else
        local is_leap = (selected_year % 4 == 0 and selected_year % 100 ~= 0)
                     or (selected_year % 400 == 0)
        days_in_year = is_leap and 366 or 365
    end

    local left_value = ""
    local left_unit  = ""
    local right_value, right_unit
    local mode = popup_self.mode

    if mode == VS.INSIGHTS_MODE_HOURS then
        -- Reading time | daily average time.
        local yr_secs = yearly_stats.duration or 0
        left_value, left_unit = splitDurationValueUnit(yr_secs, _("reading time"))
        local avg_secs = (days_in_year > 0) and (yr_secs / days_in_year) or 0
        right_value, right_unit = splitDurationValueUnit(avg_secs, _("daily avg time"))
    elseif mode == VS.INSIGHTS_MODE_PAGES then
        -- Pages read | daily average pages.
        local pg = yearly_stats.pages or 0
        left_value = formatCount(pg)
        left_unit  = N_("page read", "pages read", pg)
        local avg_pg = (days_in_year > 0) and (pg / days_in_year) or 0
        local avg_rounded
        if avg_pg >= 10 then
            avg_rounded = math.floor(avg_pg + 0.5)
        else
            avg_rounded = math.floor(avg_pg * 10 + 0.5) / 10
        end
        right_value = formatNumber(avg_rounded, avg_rounded ~= math.floor(avg_rounded) and 1 or 0)
        right_unit  = N_("daily avg page", "daily avg pages", avg_rounded)
    elseif mode == VS.INSIGHTS_MODE_BOOKS then
        left_value = formatCount(yearly_stats.books_started)
        left_unit  = N_("book", "books", yearly_stats.books_started)
        local avg_days = yearly_stats.avg_days_per_book or 0
        right_value = formatCount(avg_days)
        right_unit  = N_("day/book avg", "days/book avg", avg_days)
    else
        left_value = formatCount(yearly_stats.days)
        left_unit  = N_("day read", "days read", yearly_stats.days)
        local pct = (days_in_year > 0)
            and math.floor((yearly_stats.days / days_in_year) * 100 + 0.5)
            or 0
        right_value = pct .. "%"
        right_unit  = _("of days read")
    end

    local left_line = buildValueLine(
        fonts.value, fonts.label, layout.col_width, left_value, left_unit)
    local pages_val = buildValueLine(
        fonts.value, fonts.label, layout.col_width, right_value, right_unit)

    local selected_year_for_tap = popup_self.selected_year

    local left_cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = left_line:getSize().h },
        left_line,
    }
    left_cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = left_cell.dimen } },
    }
    function left_cell:onTap()
        popup_self:showBooksForYear(selected_year_for_tap)
        return true
    end

    local right_cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = pages_val:getSize().h },
        pages_val,
    }
    right_cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = right_cell.dimen } },
    }
    function right_cell:onTap()
        popup_self:showBooksForYear(selected_year_for_tap)
        return true
    end

    local yearly_row = UI.buildTwoColRow(left_cell, right_cell, layout)

    return VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            UI.padded(layout.padding_h, yearly_row),
        },
    }
end

-- Yearly chart as a smooth curve with a dot on it for each month and the
-- month's value above the dot (the default style; the "Months chart style"
-- setting switches back to bars). Always one row of all months, since the
-- curve needs to run unbroken. Each month column is tappable (opens that
-- month's books); the current month's dot has the active colour, like the
-- current bar in the bar style. Neighbouring values only move (one up a
-- row, alternating) when they would overlap, so compact values like "0:04"
-- never move.
-- Number of days in the month of a "YYYY-MM" string (28-31).
local function daysInMonthOf(month_str)
    local y, mo = tostring(month_str or ""):match("^(%d+)%-(%d+)$")
    y, mo = tonumber(y), tonumber(mo)
    if not y or not mo then return 31 end
    -- Day 0 of the next month is the last day of this one.
    return tonumber(os.date("%d", os.time{ year = y, month = mo + 1, day = 0, hour = 12 })) or 31
end

-- True for a month that hasn't happened yet in the year being shown: later
-- than the current month this year (every month of a future year). The
-- yearly chart leaves these out - no dot / value in the line style, no value
-- or tap in the bar style - instead of showing a made-up "00:00".
local function isFutureMonth(popup_self, m)
    local sel_year     = tonumber(popup_self.selected_year)
    local current_year = tonumber(os.date("%Y"))
    if not sel_year then return false end
    if sel_year > current_year then return true end
    return sel_year == current_year and tostring(m.month) > os.date("%Y-%m")
end

-- True for a month before the very first month with reading data (and with
-- nothing in the shown view either - a manually added book can be older than
-- the first reading record). The yearly chart leaves these empty, like the
-- months still to come, instead of showing "00:00".
local function isBeforeFirstData(popup_self, m)
    local yr = popup_self._year_range
    if not yr or not yr.min_year then return false end
    local first = string.format("%04d-%02d", yr.min_year, yr.min_month or 1)
    if not (tostring(m.month) < first) then return false end
    local has_value = (tonumber(m.seconds) or 0) > 0 or (tonumber(m.hours) or 0) > 0
        or (tonumber(m.book_count) or 0) > 0 or (tonumber(m.days) or 0) > 0
        or (tonumber(m.pages) or 0) > 0
    return not has_value
end

-- Horizontal gap between bars, shared by the weekly and monthly charts so
-- the two read with the same rhythm (bar widths differ with the bar count).
local function CHART_BAR_GAP()
    return tonumber(Screen:scaleBySize(8))
end

-- What the yearly chart plots for a month. In the "days read" view it is the
-- share of the month read (days / days in that month), so a month read
-- through every day stands as high as any other fully read month - 30, 31
-- or 28 days alike - instead of the longer month looking better. The label
-- still shows the real day count. Hours and books are plotted as they are.
local function monthlyPlotValue(m, value_key)
    local v = tonumber(m[value_key]) or 0
    if value_key == "days" then
        return v / daysInMonthOf(m.month)
    end
    return v
end

-- Shared line chart: a smooth curve with a dot on it for each entry, the
-- entry's value above the dot and its name (month / day) in a row below.
-- Used for the yearly chart and for "Last 7 days" when their style setting is
-- "Line with dots".
--
--   o.ratios[i]       height of entry i, 0..1 of the plot
--   o.value_strs[i]   text above the dot
--   o.axis_strs[i]    text under the chart
--   o.highlight[i]    true -> dot in the active colour
--   o.on_tap[i]       optional function, called when column i is tapped
--   o.on_widget(i, w) optional, handed the tappable column widget of entry i
--   o.slots           how many columns the full width is divided into
--                     (12 months / 7 days), so a short row stays left-aligned
--                     in the same scale
--   o.first           optional: entries before `first` are left empty too (no
--                     dot, value or curve point) - months before the first
--                     reading data. Default: 1.
--   o.visible         optional: only the first `visible` entries get a dot,
--                     a value and a place on the curve (the rest keep their
--                     axis label and baseline) - used to leave out months
--                     that haven't happened yet. Default: all.
--   o.chart_width, o.plot_height, o.fonts
--
-- Every value stands above its dot, and moves up just as far as it takes for
-- the curve not to run through it (Trend.clearLabelTops); neighbouring
-- values only move (one more row up) when they would overlap each other, so
-- compact values like "0:04" never do. The curve, the dots and the values
-- are all placed from the same coordinates, so they line up.
local function buildDotLineChart(o)
    local n_cols     = #o.ratios
    local n_vis      = math.max(0, math.min(o.visible or n_cols, n_cols))
    local first_vis  = math.max(1, o.first or 1)
    local col_width  = math.floor(o.chart_width / o.slots)
    local plot_height = o.plot_height
    local font_small = o.fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    -- The empty strip under the digits' baseline inside a value's box.
    local label_descent = math.max(0, label_height - sample_label:getBaseline())
    sample_label:free()

    local dot_size   = tonumber(Screen:scaleBySize(8))
    local baseline_h = Size.line.medium
    local label_gap  = tonumber(Screen:scaleBySize(4))
    -- Air between the digits' baseline and the curve. The box is taller than
    -- the digits: digits and colons leave the whole strip under their
    -- baseline empty, so the curve may run through all of it; a value with a
    -- hanging letter ("12 p") only gets half of it.
    local label_air  = tonumber(Screen:scaleBySize(1)) + 2
    local margins    = {}

    local label_ws = {}
    for i = first_vis, n_vis do
        local tw = TextWidget:new{ text = o.value_strs[i], face = font_small }
        label_ws[i] = tw:getSize().w
        tw:free()
    end

    -- Labels share one row above the dots; one that would run into an
    -- earlier label on the same row goes up a row instead.
    local levels, any_raised = {}, false
    for i = first_vis, n_vis do
        levels[i] = 0
        for j = i - 1, math.max(first_vis, i - 3), -1 do
            if levels[j] == levels[i]
               and (label_ws[j] + label_ws[i]) / 2 + label_gap > (i - j) * col_width then
                levels[i] = 1
                break
            end
        end
        if levels[i] == 1 then any_raised = true end
    end

    -- Where every value goes, measured from the top of the plot (the room
    -- above the highest one is added afterwards): above its dot, higher
    -- where the curve would cut through it.
    local pre_pts, widths, vis_index = {}, {}, {}
    for i = first_vis, n_vis do
        local dot_y_from_bottom = math.floor(o.ratios[i] * (plot_height - dot_size))
        local space_above = math.max(0, plot_height - dot_size - dot_y_from_bottom)
        pre_pts[#pre_pts + 1] = {
            x = (i - 1) * col_width + math.floor(col_width / 2),
            y = space_above + math.floor(dot_size / 2),
        }
        widths[#widths + 1] = label_ws[i]
        vis_index[i] = #pre_pts
        margins[#pre_pts] = label_air - (Trend.hasDescender(o.value_strs[i])
            and math.floor(label_descent / 2) or label_descent)
    end
    local pre_tops = Trend.clearLabelTops(pre_pts, widths, label_height, dot_size, margins,
        tonumber(Screen:scaleBySize(2)))
    local min_top = 0
    for i = first_vis, n_vis do
        local t = pre_tops[vis_index[i]] - levels[i] * label_height
        if t < min_top then min_top = t end
    end
    local label_area_h = -min_top + Size.padding.tiny
    local total_col_h  = plot_height + label_area_h + baseline_h

    local columns_row     = HorizontalGroup:new{ align = "bottom" }
    local axis_labels_row = HorizontalGroup:new{ align = "top" }
    local points, dots, value_labels = {}, {}, {}

    for i = 1, n_cols do
        -- The column only carries the baseline and the tap area; the dot and
        -- the value are placed explicitly on the chart area below, from the
        -- same coordinates as the curve.
        local col_group = VerticalGroup:new{ align = "center" }
        table.insert(col_group, Colors.newBar(col_width, baseline_h, Colors.inactiveBar()))

        -- Entries past `visible` (months still to come) have no dot, value
        -- or curve point; only their column and axis label remain.
        if i >= first_vis and i <= n_vis then
            local ratio = o.ratios[i]
            local dot_color = o.highlight[i] and Colors.activeBar() or Colors.inactiveBar()
            local dot_y_from_bottom = math.floor(ratio * (plot_height - dot_size))
            local space_above = plot_height - dot_size - dot_y_from_bottom
            if space_above < 0 then space_above = 0 end

            -- points/dots are kept as gap-free lists (the curve and the dots
            -- are drawn from them in order).
            local pt = {
                x = (i - 1) * col_width + math.floor(col_width / 2),
                y = label_area_h + space_above + math.floor(dot_size / 2),
            }
            points[#points + 1] = pt
            dots[#dots + 1] = { x = pt.x, y = pt.y, size = dot_size, color = dot_color }

            local value_label = TextWidget:new{ text = o.value_strs[i], face = font_small, fgcolor = Colors.small() }
            value_label.overlap_offset = {
                pt.x - math.floor(label_ws[i] / 2),
                label_area_h + pre_tops[vis_index[i]] - levels[i] * label_height,
            }
            value_labels[#value_labels + 1] = value_label
        end

        local tappable_col = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = col_width, h = total_col_h },
            BottomContainer:new{
                dimen = Geom:new{ w = col_width, h = total_col_h },
                col_group,
            },
        }
        local on_tap = o.on_tap and o.on_tap[i]
        if on_tap then
            tappable_col.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = tappable_col.dimen } },
            }
            function tappable_col:onTap()
                on_tap()
                return true
            end
        end
        if o.on_widget then o.on_widget(i, tappable_col) end
        table.insert(columns_row, tappable_col)

        local axis_widget = TextWidget:new{ text = o.axis_strs[i], face = font_small, fgcolor = Colors.small() }
        table.insert(axis_labels_row, CenterContainer:new{
            dimen = Geom:new{ w = col_width, h = axis_widget:getSize().h },
            axis_widget,
        })
    end

    local line_widget = Trend.LineChartWidget:new{
        width      = n_cols * col_width,
        height     = total_col_h,
        points     = points,
        dots       = dots,
        line_color = Colors.trendLine(),
        thickness  = 2,
        smooth     = true,
    }

    -- Columns (baseline) first, the curve and its dots over them, and the
    -- values over everything.
    local chart_area = OverlapGroup:new{
        dimen = Geom:new{ w = n_cols * col_width, h = total_col_h },
        columns_row,
        line_widget,
    }
    for _, vl in ipairs(value_labels) do
        table.insert(chart_area, vl)
    end

    return VerticalGroup:new{
        align = "center",
        chart_area,
        VerticalSpan:new{ width = Size.padding.small },
        axis_labels_row,
    }
end

-- Yearly chart as a line (the "Months chart style" setting switches back to
-- bars). Always one row of all months, since the curve needs to run
-- unbroken. Tapping a month opens its books; the current month's dot has the
-- active colour, like the current bar in the bar style.
local function buildMonthlyLineChart(popup_self, monthly_data, layout, fonts)
    local value_key = (popup_self.mode == VS.INSIGHTS_MODE_HOURS and "hours")
        or (popup_self.mode == VS.INSIGHTS_MODE_PAGES and "pages")
        or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS and "book_count")
        or "days"
    local max_value = 0
    for _, m in ipairs(monthly_data) do
        local v = monthlyPlotValue(m, value_key)
        if v > max_value then max_value = v end
    end
    if max_value <= 0 then max_value = 1 end

    VS.Opt.built_monthly = true

    local current_year  = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")

    local ratios, value_strs, axis_strs, highlight, on_tap = {}, {}, {}, {}, {}
    local current_idx
    for i, m in ipairs(monthly_data) do
        local value = tonumber(m[value_key]) or 0
        ratios[i] = monthlyPlotValue(m, value_key) / max_value
        if popup_self.mode == VS.INSIGHTS_MODE_HOURS then
            local mo_secs = tonumber(m.seconds) or math.floor((tonumber(m.hours) or 0) * 3600 + 0.5)
            value_strs[i] = Locale.formatDurationChart(mo_secs)
        elseif popup_self.mode == VS.INSIGHTS_MODE_PAGES then
            value_strs[i] = tostring(formatNumber(value))
        else
            value_strs[i] = formatNumber(value)
        end
        highlight[i] = (popup_self.selected_year == current_year) and (m.month == current_month)
        if highlight[i] then current_idx = i end

        local month_label_text = m.label
        if getLangBase() == "hu" then
            local mn = tonumber(tostring(m.month):match("%-(%d%d)$"))
            month_label_text = MONTH_NAMES_SHORT_HU_LC[mn] or m.label
        end
        axis_strs[i] = month_label_text

        local month_year_label = m.label_full .. " " .. popup_self.selected_year
        if getLangBase() == "hu" then
            month_year_label = tostring(popup_self.selected_year) .. ". " .. m.label_full
        end
        local month = m.month
        on_tap[i] = function() popup_self:showBooksForMonth(month, month_year_label) end
    end

    -- Months that haven't happened yet are cut off: the curve ends at the
    -- current month, they get no dot, value or tap (their names stay on the
    -- axis). Past years show all months.
    local visible = 0
    for i, m in ipairs(monthly_data) do
        if not isFutureMonth(popup_self, m) then visible = i end
    end
    -- Months before the first reading data are left empty as well.
    local first = 1
    while first <= visible and isBeforeFirstData(popup_self, monthly_data[first]) do
        first = first + 1
    end
    for i = visible + 1, #monthly_data do on_tap[i] = nil end
    for i = 1, first - 1 do on_tap[i] = nil end

    return buildDotLineChart{
        ratios = ratios, value_strs = value_strs, axis_strs = axis_strs,
        highlight = highlight, on_tap = on_tap,
        visible = visible, first = first,
        on_widget = function(i, w)
            if i == current_idx then popup_self._current_month_bar_widget = w end
        end,
        slots = 12,
        chart_width = layout.content_width,
        plot_height = tonumber(Screen:scaleBySize(VS.Opt.monthlyBarHeight())),
        fonts = fonts,
    }
end

local function buildMonthlyChart(popup_self, monthly_data, layout, fonts)
    if #monthly_data == 0 then return nil end

    if VS.readMonthlyStyleSetting() == VS.MONTHLY_STYLE_LINE then
        return buildMonthlyLineChart(popup_self, monthly_data, layout, fonts)
    end

    local value_key = (popup_self.mode == VS.INSIGHTS_MODE_HOURS and "hours")
        or (popup_self.mode == VS.INSIGHTS_MODE_PAGES and "pages")
        or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS and "book_count")
        or "days"
    -- Days view plots fractions of a month (0..1), so its scale starts from
    -- nothing; hours and books keep their old minimum scale of 1.
    local max_value = (value_key == "days") and 0 or 1
    for _, m in ipairs(monthly_data) do
        local v = monthlyPlotValue(m, value_key)
        if v > max_value then max_value = v end
    end
    if max_value <= 0 then max_value = 1 end

    local chart_width  = layout.content_width
    VS.Opt.built_monthly = true
    local bar_height   = tonumber(Screen:scaleBySize(VS.Opt.monthlyBarHeight()))
    -- Default (and landscape): all 12 months on one row, so the year reads
    -- as a single strip. The "Months chart layout" setting can switch
    -- portrait back to two rows of 6 months.
    local months_per_row = (isLandscapeScreen()
        or VS.readMonthlyLayoutSetting() ~= VS.MONTHLY_LAYOUT_TWO_ROWS) and 12 or 6
    -- Same fixed gap as the weekly chart (CHART_BAR_GAP); the bar width
    -- follows from it.
    local bar_width    = math.floor((chart_width - CHART_BAR_GAP() * (months_per_row - 1)) / months_per_row)
    local bar_gap      = CHART_BAR_GAP()
    -- Pixels left over after the integer bar width: split evenly on the two
    -- sides so the gap stays exactly CHART_BAR_GAP and the chart stays centred.
    local lead_pad     = math.floor((chart_width - bar_width * months_per_row
                                     - bar_gap * (months_per_row - 1)) / 2)
    local font_small   = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local current_year  = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")

    local function createBarRow(data_slice)
        local bars_row        = HorizontalGroup:new{ align = "bottom" }
        local month_labels_row = HorizontalGroup:new{ align = "top" }
        local baseline_h      = Size.line.medium
        local total_bar_height = bar_height + label_height

        for i, m in ipairs(data_slice) do
            local value = tonumber(m[value_key]) or 0
            local ratio = max_value > 0 and (monthlyPlotValue(m, value_key) / max_value) or 0
            local bar_h = math.floor(ratio * bar_height + 0.5)
            if bar_h == 0 and value > 0 then bar_h = 1 end

            local is_current = (popup_self.selected_year == current_year) and (m.month == current_month)
            local bar_color  = is_current and Colors.activeBar() or Colors.inactiveBar()

            -- A month still to come, or from before the first reading data,
            -- has no value to show: no "00:00" above it and no tap (its bar
            -- is empty and its name stays below).
            local future = isFutureMonth(popup_self, m) or isBeforeFirstData(popup_self, m)

            local bar_label_str
            if popup_self.mode == VS.INSIGHTS_MODE_HOURS then
                local mo_secs = tonumber(m.seconds) or math.floor((tonumber(m.hours) or 0) * 3600 + 0.5)
                -- The compact label (letters format: "1.9h" / "45m") is for the
                -- tight 12-in-a-row strip; with two rows of 6 months there is
                -- room for the full duration.
                bar_label_str = (months_per_row == 6)
                    and Locale.formatDuration(mo_secs, true)
                    or Locale.formatDurationChart(mo_secs)
            elseif popup_self.mode == VS.INSIGHTS_MODE_PAGES then
                bar_label_str = tostring(formatNumber(value))
            else
                bar_label_str = formatNumber(value)
            end
            local value_label   = TextWidget:new{ text = bar_label_str, face = font_small, fgcolor = Colors.small() }
            local centered_label = CenterContainer:new{
                dimen  = Geom:new{ w = bar_width, h = label_height },
                value_label,
            }

            local bar_column = VerticalGroup:new{ align = "center" }
            if not future then
                table.insert(bar_column, centered_label)
            else
                value_label:free()
            end
            if bar_h > 0 then
                table.insert(bar_column, Colors.newBar(bar_width, bar_h, bar_color))
            end
            table.insert(bar_column, Colors.newBar(bar_width, baseline_h, bar_color))

            local bar_container = BottomContainer:new{
                dimen = Geom:new{ w = bar_width, h = total_bar_height },
                bar_column,
            }

            local tappable_bar = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = bar_width, h = total_bar_height },
                bar_container,
            }
            local month_data       = m
            local month_year_label = m.label_full .. " " .. popup_self.selected_year
            if getLangBase() == "hu" then
                -- Hungarian: "2026. január" (year first, lower-case month),
                -- matching the calendar headers.
                month_year_label = tostring(popup_self.selected_year) .. ". " .. m.label_full
            end
            if not future then
                tappable_bar.ges_events = {
                    Tap  = { GestureRange:new{ ges = "tap",  range = tappable_bar.dimen } },
                }
                function tappable_bar:onTap()
                    popup_self:showBooksForMonth(month_data.month, month_year_label)
                    return true
                end
            end
            if is_current then
                popup_self._current_month_bar_widget = tappable_bar
            end

            table.insert(bars_row, tappable_bar)

            local month_label_text = m.label
            if getLangBase() == "hu" then
                local mn = tonumber(tostring(m.month):match("%-(%d%d)$"))
                month_label_text = MONTH_NAMES_SHORT_HU_LC[mn] or m.label
            end
            local month_label_widget = TextWidget:new{ text = month_label_text, face = font_small, fgcolor = Colors.small() }
            table.insert(month_labels_row, CenterContainer:new{
                dimen = Geom:new{ w = bar_width, h = month_label_widget:getSize().h },
                month_label_widget,
            })

            if i < #data_slice then
                table.insert(bars_row,         HorizontalSpan:new{ width = bar_gap })
                table.insert(month_labels_row, HorizontalSpan:new{ width = bar_gap })
            end
        end

        if lead_pad > 0 then
            table.insert(bars_row,         1, HorizontalSpan:new{ width = lead_pad })
            table.insert(month_labels_row, 1, HorizontalSpan:new{ width = lead_pad })
        end

        return VerticalGroup:new{
            align = "center",
            bars_row,
            VerticalSpan:new{ width = Size.padding.small },
            month_labels_row,
        }
    end

    local chart     = VerticalGroup:new{ align = "center" }
    local row_index = 0
    for i = 1, #monthly_data, months_per_row do
        local row_data = {}
        for j = i, math.min(i + months_per_row - 1, #monthly_data) do
            table.insert(row_data, monthly_data[j])
        end
        if #row_data > 0 then
            if row_index > 0 then
                table.insert(chart, VerticalSpan:new{ width = Size.padding.small })
            end
            table.insert(chart, createBarRow(row_data))
            row_index = row_index + 1
        end
    end

    return chart
end

-- Any tap / swipe / key dismisses; onShow/onCloseWidget mark the popup box
-- region dirty. All five come from the shared helper (see popuputil.lua).
PopupUtil.makeDismissable(Trend.Popup, function(self) return self.box_content.dimen end)
-- ...except its tap: a tap on the chart switches totals / averages, any other
-- tap closes the popup (see Trend.popupOnTap).
Trend.Popup.onTap = Trend.popupOnTap

-- Weekly bar chart: 7 bars, index 1 = the newest day, index 7 = the oldest.
-- Last-7-days view: index 1 = today, index 7 = 6 days ago, labels "Today",
-- "Yesterday", then weekday abbreviations. Current-week view: index 1 = the
-- week's last day, index 7 = its first, labels are weekday abbreviations
-- only, today carries is_today and the days after it (current week only)
-- carry future (drawn empty). Which end of the row the newest day is drawn
-- at follows the "Bar order" setting (rightmost by default, so time runs
-- left to right); the data index stays the same either way.
local function buildWeeklyChart(popup_self, daily_data, layout, fonts, mode)
    if not daily_data or #daily_data == 0 then return nil end
    mode = VS.normalizeWeeklyChartMode(mode)
    local show_pages = (mode == VS.WEEKLY_CHART_MODE_PAGES)

    -- Entries without an is_today flag (the last-7-days series) have today
    -- at index 1.
    local function isTodayEntry(d, i)
        if d.is_today ~= nil then return d.is_today end
        return i == 1
    end

    -- Pad to exactly 7 entries.
    while #daily_data < 7 do
        table.insert(daily_data, { hours = 0, seconds = 0, pages = 0, label = "" })
    end

    if VS.readWeeklyStyleSetting() == VS.WEEKLY_STYLE_LINE then
        -- Same smooth line with dots as the yearly chart. Order follows the
        -- "today on the left/right" setting; today is highlighted and, as
        -- in the bar style, opens the timeline when tapped.
        VS.Opt.built_weekly = true
        local num = 7
        local max_v = 0
        for _, d in ipairs(daily_data) do
            local v = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
            if v > max_v then max_v = v end
        end
        if max_v < 0.1 then max_v = 1 end
        local today_last_l = (VS.readWeeklyBarOrderSetting() == VS.WEEKLY_BAR_ORDER_TODAY_LAST)
        local ratios, value_strs, axis_strs, highlight, on_tap = {}, {}, {}, {}, {}
        local n_future = 0
        for pos = 1, num do
            local i = today_last_l and (num + 1 - pos) or pos
            local d = daily_data[i]
            local v = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
            ratios[pos] = v / max_v
            if d.future then
                n_future = n_future + 1
                value_strs[pos] = ""
            elseif show_pages then
                value_strs[pos] = string.format("%d", math.floor((tonumber(d.pages) or 0) + 0.5))
            else
                value_strs[pos] = Locale.formatDuration(tonumber(d.seconds) or 0, true)
            end
            axis_strs[pos] = d.label or ""
            highlight[pos] = (WEEKLY_CHART_HIGHLIGHT_TODAY and isTodayEntry(d, i))
            if isTodayEntry(d, i) then
                on_tap[pos] = function() popup_self:openTodayTimeline() end
            end
        end
        -- Days still to come in the current week get no dot: they sit at
        -- the end of the row (newest on the right) or at its start (newest
        -- on the left), so the visible dots are one contiguous run.
        local visible, first
        if n_future > 0 then
            if today_last_l then visible = num - n_future else first = n_future + 1 end
        end
        return buildDotLineChart{
            ratios = ratios, value_strs = value_strs, axis_strs = axis_strs,
            highlight = highlight, on_tap = on_tap,
            slots = num,
            visible = visible, first = first,
            chart_width = layout.content_width,
            plot_height = tonumber(Screen:scaleBySize(VS.Opt.weeklyBarHeight())),
            fonts = fonts,
        }
    end

    local chart_width  = layout.content_width

    VS.Opt.built_weekly = true
    local bar_height   = tonumber(Screen:scaleBySize(VS.Opt.weeklyBarHeight()))
    local num_bars     = 7
    -- Same fixed gap as the monthly chart (CHART_BAR_GAP); the bar width
    -- follows from it.
    local bar_width    = math.floor((chart_width - CHART_BAR_GAP() * (num_bars - 1)) / num_bars)
    local bar_gap      = CHART_BAR_GAP()
    -- Leftover pixels split on both sides (see the monthly chart).
    local lead_pad     = math.floor((chart_width - bar_width * num_bars
                                     - bar_gap * (num_bars - 1)) / 2)
    local font_small   = fonts.small

    local sample_label = TextWidget:new{ text = "0", face = font_small }
    local label_height = sample_label:getSize().h
    sample_label:free()

    local max_value = 0
    for _, d in ipairs(daily_data) do
        local v = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
        if v > max_value then max_value = v end
    end
    if max_value < 0.1 then max_value = 1 end  -- avoid division by zero

    local bars_row        = HorizontalGroup:new{ align = "bottom" }
    local day_labels_row  = HorizontalGroup:new{ align = "top" }
    local baseline_h      = Size.line.medium
    local total_bar_height = bar_height + label_height

    -- pos = where the bar is drawn (1 = leftmost), i = which day it holds
    -- (1 = today). They are the same unless today is drawn on the right.
    local today_last = (VS.readWeeklyBarOrderSetting() == VS.WEEKLY_BAR_ORDER_TODAY_LAST)

    for pos = 1, num_bars do
        local i = today_last and (num_bars + 1 - pos) or pos
        local d = daily_data[i]
        local value = show_pages and (tonumber(d.pages) or 0) or (tonumber(d.seconds) or 0)
        local ratio = value / max_value
        local bar_h = math.floor(ratio * bar_height + 0.5)
        if bar_h == 0 and value > 0 then bar_h = 1 end

        local is_today_bar = isTodayEntry(d, i)
        local bar_color = (WEEKLY_CHART_HIGHLIGHT_TODAY and is_today_bar) and Colors.activeBar() or Colors.inactiveBar()

        local val_str
        if d.future then
            val_str = ""
        elseif show_pages then
            local pages = math.floor((tonumber(d.pages) or 0) + 0.5)
            val_str = string.format("%d", pages)
        else
            local secs = tonumber(d.seconds) or 0
            val_str = Locale.formatDuration(secs, true)
        end
        local value_label   = TextWidget:new{ text = val_str, face = font_small, fgcolor = Colors.small() }
        local centered_label = CenterContainer:new{
            dimen  = Geom:new{ w = bar_width, h = label_height },
            value_label,
        }

        local bar_column = VerticalGroup:new{ align = "center" }
        table.insert(bar_column, centered_label)
        if bar_h > 0 then
            table.insert(bar_column, Colors.newBar(bar_width, bar_h, bar_color))
        end
        table.insert(bar_column, Colors.newBar(bar_width, baseline_h, bar_color))

        local bar_container = BottomContainer:new{
            dimen = Geom:new{ w = bar_width, h = total_bar_height },
            bar_column,
        }

        if is_today_bar then
            local tappable_bar = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = bar_width, h = total_bar_height },
                bar_container,
            }
            tappable_bar.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = tappable_bar.dimen } },
            }
            function tappable_bar:onTap()
                popup_self:openTodayTimeline()
                return true
            end
            table.insert(bars_row, tappable_bar)
        else
            table.insert(bars_row, bar_container)
        end

        local day_label_widget = TextWidget:new{ text = d.label, face = font_small, fgcolor = Colors.small() }
        table.insert(day_labels_row, CenterContainer:new{
            dimen = Geom:new{ w = bar_width, h = day_label_widget:getSize().h },
            day_label_widget,
        })

        if pos < num_bars then
            table.insert(bars_row,       HorizontalSpan:new{ width = bar_gap })
            table.insert(day_labels_row, HorizontalSpan:new{ width = bar_gap })
        end
    end

    if lead_pad > 0 then
        table.insert(bars_row,       1, HorizontalSpan:new{ width = lead_pad })
        table.insert(day_labels_row, 1, HorizontalSpan:new{ width = lead_pad })
    end

    return VerticalGroup:new{
        align = "center",
        bars_row,
        VerticalSpan:new{ width = Size.padding.small },
        day_labels_row,
    }
end

-- A year strictly before the current calendar year: its reading is history
-- and won't change, so its year-specific data can be frozen in the
-- completed-year cache and served without ever re-querying (see
-- Cache._completed_year and _fetchYearSpecific/_primeYearSpecific below).
local function isCompletedYear(year)
    return year ~= nil and year < tonumber(os.date("%Y"))
end

local function buildInsightsSections(popup_self, streaks, yearly_stats, year_range, monthly_data, all_time_stats, last_week_stats, last_week_daily, fonts, layout, goal_finished_count)
    -- Long-press targets of the chart captions (view pickers).
    popup_self._chart_hold_targets = {}
    local sections = VerticalGroup:new{ align = "left" }

    -- "Daily goal | Weekly goal": time read today / this calendar week against
    -- a goal in minutes. Long press on the section edits the goals. Today's
    -- and this week's seconds come from the last-7-days data already loaded
    -- for the "Last 7 days" section (a calendar week never reaches back more
    -- than 7 days, so no extra query is needed).
    popup_self._timegoal_hold_targets = {}
    if VS.readShowTimeGoals() then

        local daily_goal_secs  = VS.readDailyGoalMinutes()  * 60
        local weekly_goal_secs = VS.readWeeklyGoalMinutes() * 60

        local today_secs, week_secs = 0, 0
        if last_week_daily then
            local week_start_wd = Data.weekStartWday()
            local wday = tonumber(os.date("%w"))
            local days_into_week = (week_start_wd == 0) and wday or ((wday + 6) % 7)
            for i = 1, math.min(days_into_week + 1, #last_week_daily) do
                local secs = (last_week_daily[i] and last_week_daily[i].seconds) or 0
                week_secs = week_secs + secs
                if i == 1 then today_secs = secs end
            end
        end

        local function addTimeGoalHold(widget, fn)
            table.insert(popup_self._timegoal_hold_targets, { w = widget, fn = fn })
        end
        local function editDaily()  popup_self:editTimeGoal("daily")  end
        local function editWeekly() popup_self:editTimeGoal("weekly") end

        -- Same duration format as the rest of the plugin (follows KOReader's
        -- "Duration format" setting): "0:23 / 0:30" classic, "23m / 30m" etc.
        local function goalText(done, goal)
            local txt = Locale.formatDuration(done, true) .. " / " .. Locale.formatDuration(goal, true)
            if goal > 0 and done >= goal then txt = txt .. "  \u{2713}" end  -- goal met
            return txt
        end

        local daily_header_w  = UI.buildSectionHeader(fonts.section, _("Daily goal"),  layout.col_width, 0, HEADER_BG())
        local weekly_header_w = UI.buildSectionHeader(fonts.section, _("Weekly goal"), layout.col_width, 0, HEADER_BG())
        local header_h = daily_header_w:getSize().h

        -- Hold edits the goal, tap shows how long the goal has been met in a row.
        local function holdCell(widget, w, fn, on_tap)
            local cell = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = w, h = widget:getSize().h },
                widget,
            }
            if on_tap then
                cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
                cell.onTap = function() on_tap(); return true end
            end
            addTimeGoalHold(cell, fn)
            return cell
        end

        local function showDailyStreak()  popup_self:showTimeGoalStreak("daily")  end
        local function showWeeklyStreak() popup_self:showTimeGoalStreak("weekly") end

        local daily_header_cell  = holdCell(daily_header_w,  layout.col_width, editDaily,  showDailyStreak)
        local weekly_header_cell = holdCell(weekly_header_w, layout.col_width, editWeekly, showWeeklyStreak)

        local goal_header = UI.padded(layout.padding_h, FrameContainer:new{
            background = HEADER_BG(),
            bordersize = 0,
            padding    = 0,
            HorizontalGroup:new{
                align = "center",
                UI.fixedCol(daily_header_cell, layout.col_width),
                UI.buildColumnSeparator(layout.column_gap, header_h),
                UI.fixedCol(weekly_header_cell, layout.col_width),
            },
        })

        -- Thin (5 px) progress bar under a goal value, drawn with the chart's
        -- active (done) / inactive (remaining) bar colors. Can be switched
        -- off in Settings > Reading insight popup > "Daily / weekly goal bar".
        local show_goal_bar = VS.readShowTimeGoalBar()
        local GOAL_BAR_HEIGHT = 5
        local function buildGoalBar(done, goal, width)
            local ratio = 0
            if goal > 0 then ratio = math.min(1, math.max(0, done / goal)) end
            local done_w = math.floor(width * ratio + 0.5)
            if ratio > 0 and done_w == 0 then done_w = 1 end
            if ratio < 1 and done_w >= width then done_w = width - 1 end
            if done_w < 0 then done_w = 0 end
            local rest_w = width - done_w
            local bar = HorizontalGroup:new{ align = "top" }
            if done_w > 0 then
                table.insert(bar, Colors.newBar(done_w, GOAL_BAR_HEIGHT, Colors.activeBar()))
            end
            if rest_w > 0 then
                table.insert(bar, Colors.newBar(rest_w, GOAL_BAR_HEIGHT, Colors.inactiveBar()))
            end
            bar.dimen = Geom:new{ w = width, h = GOAL_BAR_HEIGHT }
            return bar
        end

        local function valueCell(text, fn, on_tap, done, goal)
            local tw = TextWidget:new{
                text    = text,
                face    = fonts.value,
                fgcolor = Colors.value(),
                max_width = layout.col_width,
            }
            local content = tw
            if show_goal_bar then
                -- Gap around the bar = the empty space under the day labels of
                -- the weekly bar chart (small-font label height minus its
                -- baseline; the section's own padding.large + bottom line
                -- follow after it, same as under the chart). Below the bar
                -- that is the whole gap; above it, the value text already
                -- has its own descent, so only the remainder is added.
                -- NB: here VerticalSpan only honors `width` (it is the
                -- vertical size); `height` is ignored.
                local function descentOf(widget)
                    local ok_d, d = pcall(function()
                        return widget:getSize().h - widget:getBaseline()
                    end)
                    return (ok_d and d and d > 0) and d or 0
                end
                local ref = TextWidget:new{ text = "0", face = fonts.small }
                local gap = descentOf(ref)
                ref:free()
                if gap <= 0 then gap = Size.padding.default end
                local gap_above = math.max(0, gap - descentOf(tw))
                content = VerticalGroup:new{
                    align = "left",
                    tw,
                    VerticalSpan:new{ width = gap_above },
                    buildGoalBar(done, goal, layout.col_width),
                    VerticalSpan:new{ width = gap },
                }
            end
            return holdCell(content, layout.col_width, fn, on_tap)
        end

        local goal_row = UI.buildTwoColRow(
            valueCell(goalText(today_secs, daily_goal_secs),  editDaily,  showDailyStreak, today_secs, daily_goal_secs),
            valueCell(goalText(week_secs,  weekly_goal_secs), editWeekly, showWeeklyStreak, week_secs, weekly_goal_secs),
            layout)

        UI.addSectionWithRow(sections, goal_header, goal_row, layout, { gap_above_row = true })
    end

    do
        -- Two views of the same section (Settings > Reading insight popup >
        -- Week > View): the rolling last 7 days, or one calendar week that
        -- can be paged. Everything below - totals, averages, chart and the
        -- comparison - is worked out from whichever week is shown.
        local cal_mode = VS.readWeeklyViewIsCalendar()
        popup_self._week_swipe_targets = {}
        -- Long-press targets that flip between the two week views.
        popup_self._week_hold_targets = {}
        local cal = cal_mode and popup_self._cal_week or nil
        local lw, week_daily
        if cal_mode then
            lw = (cal and cal.stats) or { avg_seconds = 0, avg_pages = 0, total_seconds = 0,
                                          total_pages = 0, days = 7, prev_seconds = 0, prev_pages = 0 }
            week_daily = cal and cal.daily or nil
        else
            lw = last_week_stats or { avg_seconds = 0, avg_pages = 0 }
            week_daily = last_week_daily
        end
        -- The calendar view is always shown, even for a week without any
        -- reading: its header is what pages to the other weeks.
        local has_week = cal_mode or lw.avg_seconds > 0 or lw.avg_pages > 0
        if has_week then
            local days_n = lw.days or 7

            local avg_secs = lw.avg_seconds or 0
            local week_time_val, week_time_unit_full = splitDurationValueUnit(avg_secs, _("daily avg time"))

            local avg_pages_rounded
            if lw.avg_pages >= 10 then
                avg_pages_rounded = math.floor(lw.avg_pages + 0.5)
            else
                avg_pages_rounded = math.floor(lw.avg_pages * 10 + 0.5) / 10
            end
            local week_pages_val  = formatNumber(avg_pages_rounded, avg_pages_rounded ~= math.floor(avg_pages_rounded) and 1 or 0)
            local week_pages_unit = N_("daily avg page", "daily avg pages", avg_pages_rounded)

            local total_secs = lw.total_seconds or (lw.avg_seconds or 0) * 7
            local total_time_val, total_time_unit = splitDurationValueUnit(total_secs, _("reading time"))

            local total_pages_raw = math.floor((lw.total_pages or (lw.avg_pages or 0) * 7) + 0.5)
            local total_pages_val = formatCount(total_pages_raw)
            local total_pages_unit = N_("page read", "pages read", total_pages_raw)

            local weekly_chart_mode = VS.normalizeWeeklyChartMode(popup_self.weekly_chart_mode)
            local pages_mode = (weekly_chart_mode == VS.WEEKLY_CHART_MODE_PAGES)

            local time_cells  = { total_time_val, total_time_unit, "time_total",
                                  week_time_val, week_time_unit_full, "time_avg" }
            local pages_cells = { total_pages_val, total_pages_unit, "pages_total",
                                  week_pages_val, week_pages_unit, "pages_avg" }

            -- One 2-column row: total on the left, daily average on the right.
            local function weekRow(c)
                return UI.buildTwoColRow(
                    tappableCell(
                        buildValueLine(fonts.value, fonts.label, layout.col_width, c[1], c[2]),
                        layout.col_width, function() popup_self:showWeeklyTrendPopup(c[3]) end),
                    tappableCell(
                        buildValueLine(fonts.value, fonts.label, layout.col_width, c[4], c[5]),
                        layout.col_width, function() popup_self:showWeeklyTrendPopup(c[6]) end),
                    layout)
            end

            -- Compact row (always shown), driven by the chart mode (tap the
            -- "Last 7 days" header to switch): time view = total time +
            -- daily avg time, pages view = total pages + daily avg pages.
            local last_week_rows = { weekRow(pages_mode and pages_cells or time_cells) }
            -- Optional second row with the other metric.
            if VS.readWeeklyExtraRow() then
                table.insert(last_week_rows, weekRow(pages_mode and time_cells or pages_cells))
            end

            local weekly_chart = buildWeeklyChart(popup_self, week_daily, layout, fonts, weekly_chart_mode)
            local last_week_content = VerticalGroup:new{ align = "left" }
            for idx, row in ipairs(last_week_rows) do
                if idx > 1 then
                    table.insert(last_week_content, VerticalSpan:new{ width = Size.padding.small })
                end
                table.insert(last_week_content, UI.padded(layout.padding_h, row))
            end
            -- Optional "compared to previous 7 days" row, above the chart
            -- (like the yearly figures above the monthly chart), after a thin divider: change of the total and of the daily
            -- average against the 7 days before the last 7 days.
            if VS.readWeeklyVsPrev() then
                local cur_total, prev_total, fmt_delta
                if pages_mode then
                    cur_total  = total_pages_raw
                    prev_total = math.floor((lw.prev_pages or 0) + 0.5)
                    fmt_delta = function(d, decimals)
                        local a = math.abs(d)
                        local txt = decimals and formatNumber(math.floor(a * 10 + 0.5) / 10, 1)
                                              or formatCount(math.floor(a + 0.5))
                        return (d < 0 and "-" or "+") .. txt
                    end
                else
                    cur_total  = math.floor(total_secs + 0.5)
                    prev_total = math.floor((lw.prev_seconds or 0) + 0.5)
                    -- Honours KOReader's "duration_format" (classic / modern /
                    -- letters) and the "long durations as days" option via
                    -- splitDurationValueUnit(), same as the rest of the popup.
                    -- Returns the signed value plus the label with an optional
                    -- "day" word merged in front of it.
                    fmt_delta = function(d, base_label)
                        local a = math.floor(math.abs(d) / 60 + 0.5) * 60
                        local val, unit = splitDurationValueUnit(a, base_label)
                        return ((d < 0 and a > 0) and "-" or "+") .. val, unit
                    end
                end
                local diff_total = cur_total - prev_total
                local diff_avg   = diff_total / days_n
                local d_total_val, d_total_unit, d_avg_val, d_avg_unit
                if pages_mode then
                    d_total_val  = fmt_delta(diff_total)
                    d_avg_val    = fmt_delta(diff_avg, true)
                    d_total_unit = cal_mode
                        and N_("page vs prev. week", "pages vs prev. week", math.abs(diff_total))
                        or  N_("page vs prev. 7d", "pages vs prev. 7d", math.abs(diff_total))
                    d_avg_unit   = _("daily avg pages")
                    -- Same idea as in the time view: when a long value leaves
                    -- too little room for either full label (it would wrap),
                    -- switch both to their shorter forms so the two cells stay
                    -- consistent.
                    local function cellFits(val, unit)
                        local value_probe = TextWidget:new{ text = val,  face = fonts.value }
                        local label_probe = TextWidget:new{ text = unit, face = fonts.label }
                        local ok = value_probe:getSize().w + Size.padding.large
                                   + label_probe:getSize().w <= layout.col_width
                        value_probe:free()
                        label_probe:free()
                        return ok
                    end
                    if not (cellFits(d_total_val, d_total_unit) and cellFits(d_avg_val, d_avg_unit)) then
                        d_total_unit = cal_mode and _("pg vs prev. wk") or _("pg vs prev. 7d")
                        d_avg_unit   = _("daily avg pg")
                    end
                else
                    d_total_val, d_total_unit = fmt_delta(diff_total,
                        cal_mode and _("time vs prev. week") or _("time vs prev. 7d"))
                    -- A long value ("-6h 18m") can leave too little room for
                    -- the full label, which would then wrap onto two lines.
                    -- In that case fall back to the shorter "vs prev. 7d".
                    local value_probe = TextWidget:new{ text = d_total_val,  face = fonts.value }
                    local label_probe = TextWidget:new{ text = d_total_unit, face = fonts.label }
                    local fits = value_probe:getSize().w + Size.padding.large
                                 + label_probe:getSize().w <= layout.col_width
                    value_probe:free()
                    label_probe:free()
                    if not fits then
                        d_total_val, d_total_unit = fmt_delta(diff_total,
                            cal_mode and _("vs prev. week") or _("vs prev. 7d"))
                    end
                    d_avg_val,   d_avg_unit   = fmt_delta(diff_avg,   _("daily avg time"))
                end
                local vs_row = UI.buildTwoColRow(
                    buildValueLine(fonts.value, fonts.label, layout.col_width, d_total_val, d_total_unit),
                    buildValueLine(fonts.value, fonts.label, layout.col_width, d_avg_val,   d_avg_unit),
                    layout)
                table.insert(last_week_content, VerticalSpan:new{ width = Size.padding.small })
                table.insert(last_week_content, UI.padded(layout.padding_h,
                    Colors.newBar(layout.content_width, Size.line.thin, Colors.separator())))
                table.insert(last_week_content, VerticalSpan:new{ width = Size.padding.small })
                table.insert(last_week_content, UI.padded(layout.padding_h, vs_row))
            end

            -- All the figures sit above the chart, as in the yearly section:
            -- thin divider, then a caption for the chart that - like the
            -- monthly chart's caption - switches the figures above and the
            -- chart together (here between reading time and pages per day),
            -- then the chart.
            table.insert(last_week_content, VerticalSpan:new{ width = Size.padding.small })
            table.insert(last_week_content, UI.padded(layout.padding_h,
                Colors.newBar(layout.content_width, Size.line.thin, Colors.separator())))
            if weekly_chart then
                local caption_text = pages_mode and _("Pages per day") or _("Reading time per day")
                local caption_widget = TextWidget:new{
                    text = caption_text, face = fonts.label, fgcolor = Colors.label(),
                }
                local caption_frame = FrameContainer:new{
                    background     = Blitbuffer.COLOR_WHITE,
                    bordersize     = 0,
                    padding_top    = Size.padding.small,
                    padding_bottom = Size.padding.small,
                    padding_left   = Size.padding.large,
                    padding_right  = 0,
                    caption_widget,
                }
                local tappable_caption = InputContainer:new{
                    dimen = Geom:new{ x = 0, y = 0, w = caption_frame:getSize().w, h = caption_frame:getSize().h },
                    caption_frame,
                }
                tappable_caption.ges_events = {
                    Tap = { GestureRange:new{ ges = "tap", range = tappable_caption.dimen } },
                }
                function tappable_caption:onTap()
                    popup_self:toggleWeeklyChartMode()
                    return true
                end
                -- Long press: pick the view from a list.
                if not popup_self.readonly then
                    table.insert(popup_self._chart_hold_targets, {
                        w  = tappable_caption,
                        fn = function() popup_self:showWeeklyChartModePicker() end,
                    })
                end
                table.insert(last_week_content, tappable_caption)
                table.insert(last_week_content, VerticalSpan:new{ width = Size.padding.small })
                table.insert(last_week_content, UI.padded(layout.padding_h, weekly_chart))
            end

            -- Tapping the header toggles the chart above between reading
            -- time and pages read per day (see toggleWeeklyChartMode()).
            local tappable_last_week_header
            if cal_mode then
                -- Paging header (its middle toggles time/pages itself).
                tappable_last_week_header = UI.padded(layout.padding_h,
                    buildWeekNavHeader(popup_self, fonts.section, fonts.label, layout))
            else
                local last_week_header = buildAlignedSectionHeader(fonts.section, _("Last 7 days"), layout, HEADER_BG())
                tappable_last_week_header = InputContainer:new{
                    dimen = Geom:new{ x = 0, y = 0, w = last_week_header:getSize().w, h = last_week_header:getSize().h },
                    last_week_header,
                }
                -- A plain tap does nothing here; a long press lists the two
                -- week views (last 7 days / current week) to choose from.
                if not popup_self.readonly then
                    table.insert(popup_self._week_hold_targets, {
                        w  = tappable_last_week_header,
                        fn = function() popup_self:showWeeklyViewPicker() end,
                    })
                end
            end

            -- Calendar view: a horizontal swipe over this section pages the
            -- week (see onSwipe); the year is paged only from the monthly
            -- chart. The two wrappers only keep track of where the header
            -- and the content are on screen (their dimen follows the paint).
            if cal_mode and not popup_self.readonly then
                local function track(w)
                    local sz = w:getSize()
                    local box = InputContainer:new{
                        dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h },
                        w,
                    }
                    table.insert(popup_self._week_swipe_targets, box)
                    return box
                end
                tappable_last_week_header = track(tappable_last_week_header)
                last_week_content = track(last_week_content)
            end

            UI.addSectionWithRow(sections,
                tappable_last_week_header,
                last_week_content, layout, { pad_row = false, gap_above_row = true })
        end
    end

    local function streakDisplay(n, unit_label, empty_label)
        if n < 2 then return "", empty_label end
        return formatCount(n), unit_label(n)
    end

    -- Compact unit labels ("days"/"weeks" instead of "days in a row") so that
    -- the days/weeks values fit side by side within a single Current/Best column.
    local cd_val, cd_unit = streakDisplay(streaks.current_days,
        function(n) return N_("day",  "days",  n) end, _("No streak"))
    local cw_val, cw_unit = streakDisplay(streaks.current_weeks,
        function(n) return N_("week", "weeks", n) end, _("No streak"))
    local bd_val, bd_unit = streakDisplay(streaks.best_days,
        function(n) return N_("day",  "days",  n) end, _("No streak"))
    local bw_val, bw_unit = streakDisplay(streaks.best_weeks,
        function(n) return N_("week", "weeks", n) end, _("No streak"))

    -- Single data row: each Current/Best column is split into a days sub-cell
    -- and a weeks sub-cell (tappable, each shows its own date range), giving
    -- a 2x2 grid overall: [Current | Best] header, [days|weeks  days|weeks] data.
    local inner_gap        = math.floor(layout.column_gap / 2)
    local half_col_width   = math.floor((layout.col_width - inner_gap) / 2)

    local cd_line = buildValueLine(fonts.value, fonts.label, half_col_width, cd_val, cd_unit)
    local cw_line = buildValueLine(fonts.value, fonts.label, half_col_width, cw_val, cw_unit)
    local bd_line = buildValueLine(fonts.value, fonts.label, half_col_width, bd_val, bd_unit)
    local bw_line = buildValueLine(fonts.value, fonts.label, half_col_width, bw_val, bw_unit)

    local tap_cd = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=cd_line:getSize().h }, cd_line,
    }
    tap_cd.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_cd.dimen } } }
    function tap_cd:onTap() Streak.show(streaks) return true end

    local tap_cw = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=cw_line:getSize().h }, cw_line,
    }
    tap_cw.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_cw.dimen } } }
    function tap_cw:onTap() Streak.show(streaks) return true end

    local tap_bd = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=bd_line:getSize().h }, bd_line,
    }
    tap_bd.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_bd.dimen } } }
    function tap_bd:onTap() Streak.show(streaks) return true end

    local tap_bw = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=half_col_width, h=bw_line:getSize().h }, bw_line,
    }
    tap_bw.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_bw.dimen } } }
    function tap_bw:onTap() Streak.show(streaks) return true end

    local current_cell = HorizontalGroup:new{
        align = "center",
        UI.fixedCol(tap_cd, half_col_width),
        UI.buildColumnSeparator(inner_gap, tap_cd:getSize().h),
        UI.fixedCol(tap_cw, half_col_width),
    }
    local best_cell = HorizontalGroup:new{
        align = "center",
        UI.fixedCol(tap_bd, half_col_width),
        UI.buildColumnSeparator(inner_gap, tap_bd:getSize().h),
        UI.fixedCol(tap_bw, half_col_width),
    }

    local streak_data_row = UI.buildTwoColRow(current_cell, best_cell, layout)

    -- Two-column streak header (tappable: shows date range for that streak).
    local streak_header_left  = UI.buildSectionHeader(fonts.section, _("Current streak"), layout.col_width, 0, HEADER_BG())
    local streak_header_right = UI.buildSectionHeader(fonts.section, _("Best streak"),    layout.col_width, 0, HEADER_BG())
    local sep_h = streak_header_left:getSize().h

    local tap_current_header = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=streak_header_left:getSize().h },
        streak_header_left,
    }
    tap_current_header.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_current_header.dimen } } }
    function tap_current_header:onTap()
        Streak.show(streaks)
        return true
    end

    local tap_best_header = InputContainer:new{
        dimen = Geom:new{ x=0, y=0, w=layout.col_width, h=streak_header_right:getSize().h },
        streak_header_right,
    }
    tap_best_header.ges_events = { Tap = { GestureRange:new{ ges="tap", range=tap_best_header.dimen } } }
    function tap_best_header:onTap()
        Streak.show(streaks)
        return true
    end

    -- The HorizontalSpan that used to sit inside this FrameContainer (as
    -- the left inset) is now the outer UI.padded wrap below instead, so the
    -- gray background itself is inset to match the section's divider
    -- lines, rather than bleeding out to the screen edge the way a plain
    -- white background could get away with unnoticed.
    local streak_combined_header = UI.padded(layout.padding_h, FrameContainer:new{
        background = HEADER_BG(),
        bordersize = 0,
        padding    = 0,
        HorizontalGroup:new{
            align = "center",
            UI.fixedCol(tap_current_header, layout.col_width),
            UI.buildColumnSeparator(layout.column_gap, sep_h),
            UI.fixedCol(tap_best_header,    layout.col_width),
        },
    })

    local streak_rows = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            UI.padded(layout.padding_h, streak_data_row),
        },
    }

    UI.addSectionWithRow(sections,
        streak_combined_header,
        streak_rows, layout, { pad_row = false, gap_above_row = true })

    local year_header = UI.padded(layout.padding_h,
        buildYearHeader(popup_self, fonts.section, fonts.label, layout, year_range, popup_self.selected_year))
    local yearly_row  = buildYearlyRow(popup_self, yearly_stats, fonts, layout)

    popup_self._year_swipe_targets = {}
    -- A horizontal swipe over any widget wrapped with this pages the year
    -- (see onSwipe): the year header, its stats row (reading time, average
    -- time...), the monthly chart and the reading goal row. The wrapper only keeps track of where the widget is on screen
    -- (its dimen follows the paint).
    local function trackYearSwipe(w)
        local sz = w:getSize()
        local box = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h },
            w,
        }
        table.insert(popup_self._year_swipe_targets, box)
        return box
    end
    local chart = buildMonthlyChart(popup_self, monthly_data, layout, fonts)
    -- The few pixels the auto-fit could not hand out as whole bar points
    -- (see _buildUI's fit) go here, under the monthly chart, so the page
    -- ends exactly at the bottom of the screen. The bars themselves stay
    -- the same height as the weekly chart's.
    if chart and VS.Opt.readBarHeightAuto() then
        local extra_px = VS.Opt.monthly_extra_px or 0
        if extra_px > 0 then
            chart = VerticalGroup:new{
                align = "left",
                chart,
                VerticalSpan:new{ width = extra_px },
            }
        end
    end

    year_header = trackYearSwipe(year_header)
    yearly_row  = trackYearSwipe(yearly_row)
    UI.addSectionWithRow(sections, year_header, yearly_row, layout, { pad_row = false, no_bottom_line = not chart, bottom_line_thin = true, gap_above_row = true })

    if chart then
        local chart_header_text = (popup_self.mode == VS.INSIGHTS_MODE_HOURS
            and _("Reading time per month"))
            or (popup_self.mode == VS.INSIGHTS_MODE_PAGES
            and _("Pages per month"))
            or (popup_self.mode == VS.INSIGHTS_MODE_BOOKS
            and _("Books per month"))
            or _("Days read per month")
        chart_header_text = chart_header_text
        --.. " \xe2\x80\xba"
        -- Styled like the label captions under a value (e.g. "pages read",
        -- "reading time" - fonts.label/Colors.label()) rather than a bold
        -- section title, and with no divider under it (no_top_line below),
        -- so it reads as a lightweight caption for the chart rather than a
        -- heavyweight section header.
        local chart_header_text_widget = TextWidget:new{
            text = chart_header_text, face = fonts.label, fgcolor = Colors.label(),
        }
        local chart_header = FrameContainer:new{
            background     = Blitbuffer.COLOR_WHITE,
            bordersize     = 0,
            padding_top    = Size.padding.small,
            padding_bottom = Size.padding.small,
            padding_left   = Size.padding.large,
            padding_right  = 0,
            chart_header_text_widget,
        }
        local tappable_chart_header = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = chart_header:getSize().w, h = chart_header:getSize().h },
            chart_header,
        }
        tappable_chart_header.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = tappable_chart_header.dimen } },
        }
        function tappable_chart_header:onTap()
            popup_self:cycleInsightsMode()
            return true
        end
        -- Long press: pick any of the four views from a list.
        if not popup_self.readonly then
            table.insert(popup_self._chart_hold_targets, {
                w  = tappable_chart_header,
                fn = function() popup_self:showInsightsModePicker() end,
            })
        end
        -- The divider below the chart depends on what follows it:
        --   - reading goal on: its row follows with no header of its own,
        --     so a thin line keeps it visually tied to the chart section.
        --   - otherwise (achievements header, or "All time" when both
        --     sections are off): the regular thick line.
        -- no_top_line: no divider directly under the chart header - it now
        -- reads as a plain caption for the chart rather than a section
        -- title with its own separator line.
        tappable_chart_header = trackYearSwipe(tappable_chart_header)
        chart = trackYearSwipe(chart)
        UI.addSectionWithRow(sections, tappable_chart_header, chart, layout,
            { add_divider = true, no_top_line = true, no_bottom_line = false,
              bottom_line_thin = VS.Opt.readShowReadingGoal() })
    end

    -- Long-press targets for the reading-goal section (its headers and
    -- cells). Reset every build so onHold never tests a hold against the
    -- coordinates a previous build's widgets occupied. Each entry is
    -- { w = widget, fn = function }.
    popup_self._goal_hold_targets = {}

    -- The reading-goal and achievements sections are switched on/off
    -- independently (Settings > Reading insight popup). With the goal on it
    -- comes first (a headerless row); the achievements section follows below
    -- it, with a header of its own. With both off nothing is drawn.
    local show_goal = VS.Opt.readShowReadingGoal()
    local show_ach  = VS.Opt.readShowAchievements() and Achievements ~= nil

    if show_goal or show_ach then
        local goal_year      = popup_self.selected_year
        local finished_count = goal_finished_count or 0
        local goal_value     = VS.readReadingGoal(goal_year)

        local function addHold(widget, fn)
            table.insert(popup_self._goal_hold_targets, { w = widget, fn = fn })
        end

        -- Actions shared by the cells and their header labels, so a tap/hold
        -- on the "Reading goal"/"Achievements" title behaves like the cell
        -- under it.
        local function openFinished()     popup_self:showFinishedBooksForYear(goal_year) end
        local function openFinishedMenu() popup_self:showFinishedBooksMenu(goal_year) end
        local function editGoal()         popup_self:editReadingGoal(goal_year) end
        -- Shared with the hamburger menu - see
        -- ReadingInsightsPopup:openAchievementsList() above.
        local function openAchievements() popup_self:openAchievementsList() end

        -- A value/label data cell (col_width wide) with a tap action.
        local function dataCell(line, on_tap)
            local cell = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = line:getSize().h },
                line,
            }
            cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
            cell.onTap = function() on_tap(); return true end
            return cell
        end

        -- An interactive section-title cell, so the header label is tappable
        -- like the cell below it. `width` defaults to one column.
        local function headerCell(text, on_tap, width)
            local tw = TextWidget:new{ text = text, face = fonts.section, fgcolor = Colors.section() }
            local cell = InputContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = width or layout.col_width, h = tw:getSize().h },
                tw,
            }
            if on_tap then
                cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
                cell.onTap = function() on_tap(); return true end
            end
            return cell
        end

        -- Same small top/bottom padding buildSectionHeader wraps its title
        -- in, but baked into each column individually (instead of once for
        -- the whole row), so one column can get its own background (used to
        -- gray out only "Achievements", not "Reading goal" next to it -
        -- see HEADER_BG above) while staying the same height as the other.
        -- `extra_left_gap`, when given, adds that much blank space *inside*
        -- the (possibly colored) frame before the widget - used to let a
        -- colored column's background absorb the gap before it, so it
        -- reaches right up to the column divider instead of stopping short
        -- with a visible white sliver in between.
        local function headerCol(widget, background, extra_left_gap)
            local content = widget
            if extra_left_gap then
                content = HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = extra_left_gap },
                    widget,
                }
            end
            return FrameContainer:new{
                background     = background or Blitbuffer.COLOR_WHITE,
                bordersize     = 0,
                padding_top    = Size.padding.small,
                padding_bottom = Size.padding.small,
                padding_left   = 0,
                padding_right  = 0,
                content,
            }
        end

        -- Two-column title row (goal_title | ach_title). Built by hand
        -- rather than via UI.buildTwoColRow so the right column's
        -- background - when given - can start right after the divider
        -- line (covering what would otherwise be a plain gap), reaching
        -- all the way to the line instead of floating short of it.
        local function paddedTwoColHeader(left_widget, right_widget, right_bg)
            local left_col  = UI.fixedCol(headerCol(left_widget), layout.col_width)
            local row_h     = left_col:getSize().h
            local separator = HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = layout.column_gap },
                Colors.newBar(Size.line.medium, row_h, Colors.separator()),
            }
            local right_col = UI.fixedCol(
                headerCol(right_widget, right_bg, layout.column_gap),
                layout.col_width + layout.column_gap, row_h)

            return FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                padding    = 0,
                UI.padded(layout.padding_h,
                    HorizontalGroup:new{ align = "center", left_col, separator, right_col }),
            }
        end

        local function wrapRow(row)
            return VerticalGroup:new{
                align = "left",
                FrameContainer:new{ bordersize = 0, padding = 0, UI.padded(layout.padding_h, row) },
            }
        end

        if show_goal then
            -- No header of its own: "24 / 30 books finished" | "80% of
            -- yearly goal". Tapping either cell opens the finished books,
            -- long press opens the finished-books menu.
            local percent = 0
            if goal_value > 0 then
                percent = math.floor(finished_count / goal_value * 100 + 0.5)
            end
            local left_value = formatCount(finished_count) .. " / " .. formatCount(goal_value)
            local left_line  = buildValueLine(fonts.value, fonts.label, layout.col_width,
                left_value, N_("book finished", "books finished", finished_count))
            local right_line = buildValueLine(fonts.value, fonts.label, layout.col_width,
                formatCount(percent) .. "%", _("of yearly goal"))

            -- With a goal set, the percentage is replaced by:
            --   closed year  -> "Goal reached" / "Goal not reached"
            --   current year -> the pace: "3 books ahead of pace" /
            --                   "1 book behind pace" / "On track" / "Goal reached"
            -- Pace uses the day of the year and whole books only (floor), so
            -- "On track" covers less than a book either way. Text without a
            -- number is plain label-font text; only numbers are bold.
            local this_year = tonumber(os.date("%Y"))
            local function plainText(txt)
                return buildValueLine(fonts.value, fonts.label, layout.col_width, "", txt)
            end
            if goal_value > 0 and goal_year < this_year then
                right_line = plainText(finished_count >= goal_value
                    and _("Goal reached") or _("Goal not reached"))
            elseif goal_value > 0 and goal_year == this_year then
                local y = goal_year
                local leap = (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
                local expected = goal_value * tonumber(os.date("%j")) / (leap and 366 or 365)
                local diff = finished_count - expected
                local n = math.floor(math.abs(diff))
                if finished_count >= goal_value then
                    right_line = plainText(_("Goal reached"))
                elseif n == 0 then
                    right_line = plainText(_("On track"))
                elseif diff > 0 then
                    right_line = buildValueLine(fonts.value, fonts.label, layout.col_width,
                        formatCount(n), N_("book ahead of pace", "books ahead of pace", n))
                else
                    right_line = buildValueLine(fonts.value, fonts.label, layout.col_width,
                        formatCount(n), N_("book behind pace", "books behind pace", n))
                end
            end

            local left_cell  = dataCell(left_line, openFinished)
            addHold(left_cell, openFinishedMenu)
            local right_cell = dataCell(right_line, openFinished)
            addHold(right_cell, openFinishedMenu)

            table.insert(sections, VerticalSpan:new{ width = Size.padding.small })
            table.insert(sections, trackYearSwipe(wrapRow(UI.buildTwoColRow(left_cell, right_cell, layout))))
            table.insert(sections, VerticalSpan:new{ width = Size.padding.small })
            table.insert(sections, UI.padded(layout.padding_h,
                Colors.newBar(layout.content_width, Size.line.thick, Colors.separator())))
        end

        if show_ach then
            -- Header "Achievements | Latest", then: "earned/total earned" |
            -- name of the most recently earned achievement.
            local earned_count = Achievements.earnedCount()
            local ach_total    = Achievements.totalCount()
            -- Trailing star = achievements earned since the list was last
            -- opened (see Achievements.newCount); tapping opens & clears it.
            local has_new      = Achievements.newCount() > 0
            local left_value   = formatCount(earned_count) .. "/" .. formatCount(ach_total)
                                 .. (has_new and " ★" or "")
            local left_line    = buildValueLine(fonts.value, fonts.label, layout.col_width,
                left_value, _("earned"))

            -- The latest achievement's icon + name, in the regular (non-bold)
            -- explanatory-text face used for the unit labels.
            local latest = Achievements.latest()
            local right_line = TextBoxWidget:new{
                text      = latest and (latest.icon .. "  " .. latest.title) or "–",
                face      = fonts.label,
                fgcolor   = Colors.label(),
                width     = layout.col_width,
                alignment = "left",
            }

            local left_cell  = dataCell(left_line, openAchievements)
            local right_cell = dataCell(right_line, openAchievements)

            local ach_title    = headerCell(_("Achievements"), openAchievements)
            local latest_title = headerCell(_("Latest"), openAchievements)

            UI.addSectionWithRow(sections,
                paddedTwoColHeader(ach_title, latest_title, HEADER_BG()),
                wrapRow(UI.buildTwoColRow(left_cell, right_cell, layout)),
                layout, { pad_row = false, gap_above_row = true })
        end
    end -- if show_goal or show_ach

    do
        local all_hours = all_time_stats and all_time_stats.hours or 0
        local all_pages = all_time_stats and all_time_stats.pages or 0

        local all_secs_approx = (all_time_stats and all_time_stats.duration) or (all_hours * 3600)
        local all_time_val, all_time_unit = splitDurationValueUnit(all_secs_approx, _("reading time"))
        local all_pages_val  = formatCount(all_pages)
        local all_pages_unit = N_("page read", "pages read", all_pages)

        local left_line  = buildValueLine(fonts.value, fonts.label, layout.col_width, all_time_val,  all_time_unit)
        local right_line = buildValueLine(fonts.value, fonts.label, layout.col_width, all_pages_val, all_pages_unit)

        local left_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = left_line:getSize().h },
            left_line,
        }
        left_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = left_cell.dimen } },
        }
        function left_cell:onTap()
            popup_self:showAllBooks()
            return true
        end

        local right_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = layout.col_width, h = right_line:getSize().h },
            right_line,
        }
        right_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = right_cell.dimen } },
        }
        function right_cell:onTap()
            popup_self:showAllBooks()
            return true
        end

        local all_time_row = UI.buildTwoColRow(left_cell, right_cell, layout)

        local all_book_count = all_time_stats and all_time_stats.book_count or 0
        local header_text = _("All time")

        -- Tapping the header opens the reading heatmap popup (moved here
        -- from tapping the year, see showReadingHeatmap / buildYearHeader).
        local total_read_header = buildAlignedSectionHeader(fonts.section, header_text, layout, HEADER_BG())
        local tappable_total_read_header = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = total_read_header:getSize().w, h = total_read_header:getSize().h },
            total_read_header,
        }
        tappable_total_read_header.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = tappable_total_read_header.dimen } },
        }
        function tappable_total_read_header:onTap()
            popup_self:showReadingHeatmap()
            return true
        end

        UI.addSectionWithRow(sections,
            tappable_total_read_header,
            all_time_row, layout, { no_bottom_line = true, gap_above_row = true })
    end

    return sections
end

local ReadingInsightsPopup = InputContainer:extend{
    modal         = true,
    ui            = nil,
    width         = nil,
    height        = nil,
    selected_year = nil,
    mode          = nil,
    -- When true, the popup is being used as sleep-screen content: swipe-down,
    -- "any key", and the title bar's close tap are ignored so a stray touch
    -- or the wake key itself doesn't dismiss it early. Year navigation
    -- (left/right swipe or key) still works. Actually closing this instance
    -- is then the caller's responsibility (see main.lua's onResume).
    --
    -- A readonly popup also loads and draws EVERYTHING inside init(), with
    -- nothing deferred (see init and _sleep_sync): it is built while the
    -- device is going to sleep, so no query or redraw may be left for a
    -- timer that would fire after it has gone.
    readonly      = false,
}

-- Returns a { ["YYYY-MM-DD"] = seconds_read } map for the inclusive date
-- range [start_t, end_t] (timestamps at hour=12), by fetching every
-- calendar year the range touches via getDailyReadingData (1 or 2 years
-- for a half-year heatmap period) and filtering each down to just the
-- days inside the range.
function ReadingInsightsPopup:getDailyReadingDataForRange(start_t, end_t, shared_conn)
    local year_start = tonumber(os.date("%Y", start_t))
    local year_end   = tonumber(os.date("%Y", end_t))
    local start_str  = os.date("%Y-%m-%d", start_t)
    local end_str    = os.date("%Y-%m-%d", end_t)

    local merged = {}
    for year = year_start, year_end do
        local year_map = Data.getDailyReadingData(year, shared_conn)
        for dstr, seconds in pairs(year_map) do
            if dstr >= start_str and dstr <= end_str then
                merged[dstr] = seconds
            end
        end
    end
    return merged
end

-- Opens the "Reading heatmap" popup - tap the "All time" header (see
-- buildInsightsSections) to open it, starting on the most recent
-- half-year; swipe left/right inside the popup to page through older/
-- newer half-years as far back as there's data.
function ReadingInsightsPopup:showReadingHeatmap()
    -- Whether this open is actually going to touch the DB: mirrors the
    -- exact stale-cache check getHeatmapData (heatmap_view.lua) makes for
    -- the current (periods_back == 0) period. There's no way to measure a
    -- blocking Lua call's duration before making it, so this is the best
    -- available proxy for "this open is about to be slow" - a cache hit
    -- returns with no DB access at all and stays instant, while a miss
    -- runs the full calendar + day-part queries synchronously on the UI
    -- thread. Same "let the message actually reach the screen first"
    -- pattern as openRecordsPopup above.
    local start_t, end_t = Heatmap.getHeatmapPeriodRange(0)
    local key = os.date("%Y-%m-%d", start_t) .. ".." .. os.date("%Y-%m-%d", end_t)
    local cache_hit = Cache.ENABLE_CACHE
        and Cache._stale_daily_map[key] and Cache._stale_weekday_hour_map[key]

    if cache_hit then
        UIManager:show(Heatmap.Popup:new{ popup_self = self, periods_back = 0 })
        return
    end

    local popup_self = self
    local msg = InfoMessage:new{ text = _("Loading data…") }
    UIManager:show(msg)
    UIManager:scheduleIn(0.1, function()
        UIManager:show(Heatmap.Popup:new{ popup_self = popup_self, periods_back = 0 })
        UIManager:close(msg)
    end)
end

-- Opens the achievements list. Shared by the reading-goal section's
-- "Achievements" title/cell (see buildInsightsSections) and the hamburger
-- menu (see onShowHamburgerMenu). Refreshes this popup's own build when the
-- list closes, so the "new" star badge next to the earned count clears at
-- once (opening the list marks everything seen).
function ReadingInsightsPopup:openAchievementsList()
    if not AchievementsView then return end
    local popup_self = self
    AchievementsView.show(function()
        if popup_self._closed then return end
        popup_self:_buildUI()
        UIManager:setDirty(popup_self, function()
            return "ui", popup_self.popup_frame.dimen
        end)
    end)
end

-- Opens the Records popup (all-time reading records) - same popup the
-- Tools-menu "Show Records" entry opens (see main.lua's
-- onShowReadingRecordsPopup), reachable here from the hamburger menu.
function ReadingInsightsPopup:openRecordsPopup()
    if not Records then return end
    local popup_self = self
    -- A first-ever open (no records cache yet) recomputes every record from
    -- the full statistics history in one blocking scan - the plugin's own
    -- slowest thing, and it runs on the UI thread (see records_view.lua's
    -- onHold, which shows this same message before its own forced recount
    -- for exactly that reason). Shown here too, so a big history doesn't
    -- read as "nothing happened" while it's still counting - the message is
    -- given a moment to actually reach the screen before the blocking call.
    local msg = InfoMessage:new{ text = _("Loading data…") }
    UIManager:show(msg)
    UIManager:scheduleIn(0.1, function()
        -- Wrapped in pcall: this is the one popup among the four
        -- hamburger-menu entries that also touches the statistics database
        -- on the way up (RecordsData.load()), so an InfoMessage here beats
        -- a tap that silently does nothing if that ever throws instead of
        -- returning its documented zero-value fallback.
        local ok, err = pcall(function()
            UIManager:show(Records.Popup:new{ ui = popup_self.ui })
        end)
        UIManager:close(msg)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Couldn't open Records: ") .. tostring(err),
            })
        end
    end)
end

-- Opens the combined current/best streak popup - same popup the streak
-- header cells open (see buildInsightsSections) and the Tools-menu
-- "Show Reading streak" entry (Insights.showStreaks below), reachable here
-- from the hamburger menu. Uses whatever streak data this popup already
-- has loaded rather than re-querying the DB.
function ReadingInsightsPopup:openStreakPopup()
    Streak.show(self._streaks or Data.calculateStreaks())
end

-- Hamburger menu (title bar, top left): quick access to the other reading-
-- insights popups without paging/tapping through this one. Mirrors the
-- sort-menu pattern used by the book-list popups (see
-- widgets/booklistwidget.lua's onShowWidgetMenu / M.showSortMenu) - a
-- ButtonDialog anchored under the title bar's left icon button.
function ReadingInsightsPopup:onShowHamburgerMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local popup_self = self
    local dialog
    local title_bar = self.title_bar
    dialog = ButtonDialog:new{
        -- This popup is itself modal, and UIManager stacks a non-modal
        -- window shown over it underneath it - see showFinishedBooksMenu
        -- above for the same reasoning.
        modal                  = true,
        shrink_unneeded_width  = true,
        buttons = {
            {{
                text  = _("Show Reading calendar"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:openStreakPopup()
                end,
            }},
            {{
                text  = _("Show Reading habits"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:showReadingHeatmap()
                end,
            }},
            {{
                text  = _("Show Reading shelf"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:showYearShelf()
                end,
            }},
            {{
                text  = _("Show Records"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:openRecordsPopup()
                end,
            }},
            {{
                text  = _("Show Achievements"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    popup_self:openAchievementsList()
                end,
            }},
        },
        -- Anchored under the title bar's hamburger icon, like the book
        -- lists' sort menu - falls back to centred if that button isn't
        -- there for some reason.
        anchor = title_bar and title_bar.left_button and function()
            return title_bar.left_button.image.dimen
        end or nil,
    }
    UIManager:show(dialog)
end

-- Combines getFinishedBooksForYear's query-based list with the user's
-- manual overrides (see VS.readFinishedOverrides above) for that year: drops
-- any book explicitly overridden to "not finished", and adds any book
-- explicitly overridden to "finished" that the query didn't already
-- include (looked up from popup_self:getBooksForYear, the same candidate
-- pool the checklist itself is built from - see
-- ReadingInsightsPopup:showFinishedBooksChecklist below). This is what
-- both the goal section's tap-to-list (showFinishedBooksForYear) and the
-- checklist's own checkbox state are based on, so all three stay in sync.
-- The list is shown in the order the query returns it (last reading entry
-- first), and the two kinds of book added to it afterwards - the ones the
-- reader ticked by hand, and the hand-added ones - have to be merged into
-- that order rather than dropped at the end, or a book finished today
-- shows up below one finished in January.
local function sortByLastRead(books)
    table.sort(books, function(a, b)
        local ta, tb = a.last_read or 0, b.last_read or 0
        if ta == tb then return (a.title or "") < (b.title or "") end
        return ta > tb
    end)
    return books
end

-- The hand-added books of a year (lib/manual_books.lua) as book-shaped
-- records, no reading time and no pages. Only the finished-books list
-- shows them.
local function manualBooksForYear(year)
    local out = {}
    for _idx, e in ipairs(Manual.list(year)) do
        local date = e.date or ""
        do
            table.insert(out, {
                title     = e.title,
                -- No author and no reading time in these lists: the row is
                -- shown as a bare title (see BookList.showBookList's
                -- `manual` branch).
                authors   = e.authors or "",
                series       = e.series or "",
                series_index = e.series_index or "",
                date_known   = date ~= "",
                duration  = 0,
                pages     = 0,
                rating    = e.rating or 0,
                manual_id   = e.id,
                manual_year = year,
                last_read = e.read_ts or e.ts or 0,
                manual    = true,
            })
        end
    end
    return out
end

local function getFinishedBooksForYearCombined(popup_self, year)
    local base_books = Data.getFinishedBooksForYear(year)
    local overrides = VS.readFinishedOverrides(year)

    -- The books the reader added by hand (lib/manual_books.lua) have no
    -- rows in the statistics DB at all, so no query can find them - they
    -- are appended here, as book-shaped entries with no reading time, so
    -- this list matches the goal count (which adds them the same way, see
    -- Data.applyFinishedOverrides).
    local manual_books = manualBooksForYear(year)

    if not next(overrides) then
        if #manual_books == 0 then return base_books end
        local out = {}
        for _idx, b in ipairs(base_books) do table.insert(out, b) end
        for _idx, b in ipairs(manual_books) do table.insert(out, b) end
        return sortByLastRead(out)
    end

    local by_id = {}
    for _, b in ipairs(base_books) do
        by_id[tostring(b.id_book)] = b
    end

    local result = {}
    for _, b in ipairs(base_books) do
        if overrides[tostring(b.id_book)] ~= false then
            table.insert(result, b)
        end
    end

    -- Books ticked by hand that the query missed: look up just those, not
    -- the whole year (see Data.getBooksForYearByIds).
    local missing_ids = {}
    for id_str, val in pairs(overrides) do
        if val == true and not by_id[id_str] then
            missing_ids[#missing_ids + 1] = id_str
        end
    end
    if #missing_ids > 0 then
        local candidates = Data.getBooksForYearByIds(year, missing_ids)
        for _, b in ipairs(candidates) do
            local id_str = tostring(b.id_book)
            if overrides[id_str] == true and not by_id[id_str] then
                table.insert(result, b)
            end
        end
    end

    for _idx, b in ipairs(manual_books) do
        table.insert(result, b)
    end

    return sortByLastRead(result)
end

-- Build and show the 8-week trend popup. Any of "time_total" | "time_avg"
-- opens the time chart (total + daily average), any of "pages_total" |
-- "pages_avg" the pages chart - so it follows what the tapped value showed.
function ReadingInsightsPopup:showWeeklyTrendPopup(metric)
    local weeks = Data.getLast8WeeksData()
    if not weeks or #weeks == 0 then
        UIManager:show(InfoMessage:new{ text = _("No streak dates") })
        return
    end

    local has_data = false
    for _, w in ipairs(weeks) do
        if (w.seconds or 0) > 0 or (w.pages or 0) > 0 then
            has_data = true
            break
        end
    end
    if not has_data then
        UIManager:show(InfoMessage:new{ text = _("No reading data in the last 8 weeks") })
        return
    end

    local fonts  = getCachedFonts()
    local inner_padding = Size.padding.large
    local box_width   = math.floor(Screen:getWidth() * 0.94)
    local chart_width = box_width - 2 * inner_padding

    local content, chart_handle = Trend.buildContent(weeks, metric, chart_width, fonts)

    local box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }

    UIManager:show(Trend.Popup:new{ box_content = box, chart_handle = chart_handle })
end

function ReadingInsightsPopup:getBooksForMonth(year_month)
    return Data.getBooksForPeriod("%Y-%m", year_month)
end

function ReadingInsightsPopup:showBooksForMonth(year_month, month_label_full)
    local books = self:getBooksForMonth(year_month)
    local total_secs = Data.sumDuration(books)
    local title = T(N_("%1 - %2 book", "%1 - %2 books", #books), month_label_full, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")"
    BookList.showBooksForPeriod(
        self, books,
        T(_("No books in %1"), month_label_full),
        title)
end

-- Open CalendarView for the given "YYYY-MM" string.
-- Closes this popup first; reopens it when CalendarView is dismissed.
function ReadingInsightsPopup:openCalendarForMonth(year_month)
    local year  = tonumber(year_month:sub(1, 4))
    local month = tonumber(year_month:sub(6, 7))
    if not year or not month then return end

    local ok, CalendarView = pcall(require, "ui/widget/calendarview")
    if not ok or not CalendarView then
        ok, CalendarView = pcall(require, "calendarview")
    end
    if not ok or not CalendarView then
        UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
        return
    end

    -- Save state so the popup can be recreated after CalendarView closes.
    local saved_year             = self.selected_year
    local saved_mode             = self.mode
    local saved_ui               = self.ui
    local saved_streaks          = self._streaks
    local saved_yr               = self._year_range
    local saved_yearly           = self._yearly
    local saved_monthly          = self._monthly
    local saved_all_time         = self._all_time
    local saved_goal_finished    = self._goal_finished
    local saved_last_week        = self._last_week
    local saved_last_week_daily  = self._last_week_daily
    local saved_cal_week         = self._cal_week
    local saved_week_offset      = self.week_offset

    self._closed = true
    UIManager:close(self)

    -- Wait one frame so the popup is fully closed before opening CalendarView.
    UIManager:scheduleIn(0, function()
        local stats_plugin = saved_ui and saved_ui.statistics or nil

        local function reopen_popup()
            local p = ReadingInsightsPopup:new{
                ui               = saved_ui,
                selected_year    = saved_year,
                mode             = saved_mode,
                _streaks         = saved_streaks,
                _year_range      = saved_yr,
                _yearly          = saved_yearly,
                _monthly         = saved_monthly,
                _all_time        = saved_all_time,
                _goal_finished   = saved_goal_finished,
                _last_week       = saved_last_week,
                _last_week_daily = saved_last_week_daily,
                _cal_week        = saved_cal_week,
                week_offset      = saved_week_offset,
            }
            UIManager:show(p)
        end

        local reopened = false
        local function reopen_once()
            if reopened then return end
            reopened = true
            UIManager:scheduleIn(0, reopen_popup)
        end

        local cv
        cv = CalendarView:new{
            reader_statistics = stats_plugin,
            shown_year        = year,
            shown_month       = month,
            close_callback    = function()

                reopen_once()
            end,
        }
        -- onCloseWidget fires on all dismiss paths; the flag prevents double-open.
        local orig_onCloseWidget = cv.onCloseWidget
        cv.onCloseWidget = function(self_cv, ...)
            if orig_onCloseWidget then orig_onCloseWidget(self_cv, ...) end
            reopen_once()
        end
        UIManager:show(cv)
    end)
end

-- Open today's reading timeline (CalendarDayView) for the current day.
-- Closes this popup first; reopens it when the timeline is dismissed.
function ReadingInsightsPopup:openTodayTimeline()
    local ok, CalendarView = pcall(require, "ui/widget/calendarview")
    if not ok or not CalendarView then
        ok, CalendarView = pcall(require, "calendarview")
    end
    if not ok or not CalendarView then
        UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
        return
    end

    -- Save state so the popup can be recreated after the timeline closes.
    local saved_year             = self.selected_year
    local saved_mode             = self.mode
    local saved_ui               = self.ui
    local saved_streaks          = self._streaks
    local saved_yr               = self._year_range
    local saved_yearly           = self._yearly
    local saved_monthly          = self._monthly
    local saved_all_time         = self._all_time
    local saved_goal_finished    = self._goal_finished
    local saved_last_week        = self._last_week
    local saved_last_week_daily  = self._last_week_daily
    local saved_cal_week         = self._cal_week
    local saved_week_offset      = self.week_offset

    self._closed = true
    UIManager:close(self)

    -- Wait one frame so the popup is fully closed before opening the timeline.
    UIManager:scheduleIn(0, function()
        local stats_plugin = saved_ui and saved_ui.statistics or nil
        if not stats_plugin then
            UIManager:show(InfoMessage:new{ text = _("CalendarView not available") })
            return
        end

        local function reopen_popup()
            local p = ReadingInsightsPopup:new{
                ui               = saved_ui,
                selected_year    = saved_year,
                mode             = saved_mode,
                _streaks         = saved_streaks,
                _year_range      = saved_yr,
                _yearly          = saved_yearly,
                _monthly         = saved_monthly,
                _all_time        = saved_all_time,
                _goal_finished   = saved_goal_finished,
                _last_week       = saved_last_week,
                _last_week_daily = saved_last_week_daily,
                _cal_week        = saved_cal_week,
                week_offset      = saved_week_offset,
            }
            UIManager:show(p)
        end

        local reopened = false
        local function reopen_once()
            if reopened then return end
            reopened = true
            UIManager:scheduleIn(0, reopen_popup)
        end

        -- CalendarView:showCalendarDayView() builds and shows the day's
        -- CalendarDayView for us (its day_ts logic respects the user's
        -- configured calendar_day_start_hour/minute), but it doesn't expose
        -- a close_callback hook. We build a CalendarView purely to call
        -- that helper (it's never itself shown), and intercept the single
        -- UIManager:show() call it makes so we can attach our own
        -- close_callback / onCloseWidget before the widget is painted.
        local cv = CalendarView:new{ reader_statistics = stats_plugin }

        local orig_show = UIManager.show
        UIManager.show = function(mgr, widget, ...)
            UIManager.show = orig_show -- one-shot: restore immediately
            widget.close_callback = reopen_once
            local orig_onCloseWidget = widget.onCloseWidget
            widget.onCloseWidget = function(self_w, ...)
                if orig_onCloseWidget then orig_onCloseWidget(self_w, ...) end
                reopen_once()
            end
            return orig_show(mgr, widget, ...)
        end

        cv:showCalendarDayView(stats_plugin)
    end)
end

-- Open CalendarView for today's month.
function ReadingInsightsPopup:openCalendarForCurrentMonth()
    local year_month = os.date("%Y-%m")
    self:openCalendarForMonth(year_month)
end

function ReadingInsightsPopup:getBooksForYear(year)
    return Data.getBooksForPeriod("%Y", tostring(year))
end

function ReadingInsightsPopup:showAllBooks()
    local books = Data.getAllBooks()
    local total_secs = Data.sumDuration(books)
    BookList.showBooksForPeriod(
        self, books,
        _("No books"),
        T(_("All books %1"), formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
end

function ReadingInsightsPopup:showBooksForYear(year)
    local books = self:getBooksForYear(year)
    local total_secs = Data.sumDuration(books)
    BookList.showBooksForPeriod(
        self, books,
        T(_("No books in %1"), tostring(year)),
        T(N_("%1 - %2 book", "%1 - %2 books", #books), year, formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")")
end

-- Tap target for the reading-goal section's left cell ("N book(s)
-- finished"). Uses the same "last entry >= 99% progress" definition as
-- getFinishedBookCountForYear.
function ReadingInsightsPopup:showFinishedBooksForYear(year)
    local books = getFinishedBooksForYearCombined(self, year)
    local total_secs = Data.sumDuration(books)
    BookList.showBooksForPeriod(
        self, books,
        T(_("No books finished in %1"), tostring(year)),
        T(N_("%1 - book finished %2", "%1 - books finished %2", #books), tostring(year), formatCount(#books)) .. " (" .. formatHHMMSS(total_secs) .. ")",
        -- This list is about *when* each book was finished (it's ordered by
        -- that), so its value column shows the date rather than the time
        -- spent - see BookList.showBookList's opts.show_dates.
        { show_dates = true })
end

-- Opens the year shelf (views/year_shelf_view.lua) on the year shown here: the
-- covers of the books read in it, month by month. It stacks on top of this
-- popup, like the heatmap and the streak calendar, so closing it brings this
-- one back as it was. The books come from the same lists the tap on the yearly
-- figures and on the reading goal open - "all books read" or, with the shelf's
-- "only finished" switch, the finished ones (manual ticks and hand-added books
-- included).
function ReadingInsightsPopup:showYearShelf()
    if not YearShelf then return end
    local popup_self = self
    YearShelf.show{
        ui         = self.ui,
        year       = self.selected_year or tonumber(os.date("%Y")),
        year_range = self._year_range or self.year_range,
        getBooks   = function(year, finished_only)
            if finished_only then
                return getFinishedBooksForYearCombined(popup_self, year)
            end
            return popup_self:getBooksForYear(year)
        end,
    }
end

function ReadingInsightsPopup:showFinishedBooksChecklist(year)
    BookList.showFinishedChecklist(self, year)
end

-- The other half of the long-press menu on the same cell: the reader's own
-- list of books the statistics DB knows nothing about (see
-- lib/manual_books.lua), kept per year - the year currently shown by the
-- popup is the one entries are added to.
function ReadingInsightsPopup:showManualBooksList(year)
    BookList.showManualBooks(self, year)
end

-- Long press on the reading goal's "N book(s) finished" cell. Two ways to
-- correct that count, so the press opens a chooser rather than one of them
-- directly: the checklist for books the statistics DB does know about, and
-- the hand-kept list for the ones it doesn't.
function ReadingInsightsPopup:showFinishedBooksMenu(year)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        -- The insights popup itself is modal, and UIManager puts non-modal
        -- windows below the topmost modal one - without this the chooser
        -- would open behind the popup that spawned it.
        modal       = true,
        -- Only as wide as its texts need, not the dialog's default width.
        shrink_unneeded_width = true,
        buttons = {
            {{
                text = _("Mark books finished"),
                callback = function()
                    UIManager:close(dialog)
                    self:showFinishedBooksChecklist(year)
                end,
            }},
            {{
                text = _("Add books manually"),
                callback = function()
                    UIManager:close(dialog)
                    self:showManualBooksList(year)
                end,
            }},
            -- The yearly goal used to be edited by long-pressing the goal
            -- value cell; that cell was merged into the "N/M books finished"
            -- figure, so goal editing moved here.
            {{
                text = _("Set reading goal"),
                callback = function()
                    UIManager:close(dialog)
                    self:editReadingGoal(year)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- The popup's header text.
function ReadingInsightsPopup:_titleBarText()
    -- Popup header has its own translation key, so the Tools menu entry can
    -- stay "Reading insights" while the popup shows the localised title.
    -- Falls back to "Reading insights" if a language lacks the key.
    return Locale.insightsTitle()
end

-- A string that changes whenever any of this plugin's settings (or the UI
-- language) changes, whichever module saved it - read straight from the
-- settings store, so enabling/disabling a section, switching a layout, a
-- font or a bar height all show up. _buildUI compares it with the one the
-- remembered landscape font scale was computed under: a different one means
-- the page's content changed, so the old scale is no longer a valid guess
-- and the fit starts over from the configured font sizes.
local function settingsSignature()
    local data = G_reader_settings and G_reader_settings.data
    if type(data) ~= "table" then return "" end
    local keys = {}
    for k in pairs(data) do
        if type(k) == "string"
           and (k:find("^reading_insights_") or k:find("^readinginsights_") or k == "language") then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. "=" .. tostring(data[k]) end
    return table.concat(parts, "|")
end

function ReadingInsightsPopup:_buildUI()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local fonts    = getCachedFonts()
    local layout   = getCachedLayout()
    -- Text scale (1 = the configured sizes). Lowered by the
    -- fit step below when the page is taller than the screen even after the
    -- bar charts have been sized; everything in the popup that is text goes
    -- through `fonts`, so changing it and rebuilding scales all of it.
    local font_scale = 1

    -- Cold start (e.g. right after a KOReader restart): no cache, no stale
    -- data, nothing to show yet. Rather than flashing zeroed-out sections
    -- for a moment, show a plain loading message; _loadAndRebuild() will
    -- call _buildUI() again as soon as real data is available.
    if self._initial_loading then
        local title_bar_inner = TitleBar:new{
            fullscreen     = true,
            width          = screen_w,
            align          = "left",
            title          = self:_titleBarText(),
            -- Hamburger menu, top left: quick access to the streak/heatmap/
            -- records/achievements popups - see onShowHamburgerMenu below.
            -- Hidden in readonly (sleep-screen) mode, same as close_callback,
            -- so a stray touch there can't navigate away from the wake screen.
            left_icon              = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and "appbar.menu" or nil,
            left_icon_tap_callback = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and function() self:onShowHamburgerMenu() end or nil,
            close_callback = (not self.readonly) and function() UIManager:close(self) end or nil,
            show_parent    = self,
            top_v_padding    = Size.padding.default,
            bottom_v_padding = Size.padding.default,
        }
        self._title_bar_height = title_bar_inner:getSize().h
        self.title_bar = title_bar_inner

        self.popup_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            radius     = 0,
            padding    = 0,
            width      = screen_w,
            height     = screen_h,
            VerticalGroup:new{
                align = "left",
                title_bar_inner,
                CenterContainer:new{
                    dimen = Geom:new{ w = screen_w, h = screen_h - title_bar_inner:getSize().h },
                    TextWidget:new{
                        text = _("Loading data…"),
                        face = fonts.label,
                        fgcolor = Colors.label(),
                    },
                },
            },
        }
        self.popup_frame.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self[1] = VerticalGroup:new{ self.popup_frame }
        return
    end

    -- One full pass: build the sections with whatever bar heights are
    -- currently in force (VS.Opt.auto_height in auto mode, see
    -- VS.Opt.weeklyBarHeight/monthlyBarHeight) and wrap them in the
    -- scrollable content group.
    -- Returns the group plus its total height, which is what the auto-fit
    -- loop below compares against the screen height.
    local auto_fit    = VS.Opt.readBarHeightAuto()
    -- Auto mode: what is left under the last row is the same as under the
    -- Reading calendar's streak section (Size.padding.default in total; the
    -- section already ends with a Size.padding.small gap of its own).
    local bottom_span = auto_fit and math.max(0, Size.padding.default - Size.padding.small) or nil
    -- Extra pixels in force during the latest buildContent() (see the fit).
    local built_extra = 0

    local function buildContent()
        VS.Opt.built_weekly  = false
        VS.Opt.built_monthly = false
        if not auto_fit then VS.Opt.monthly_extra_px = 0 end
        built_extra = VS.Opt.monthly_extra_px or 0

        local sections = buildInsightsSections(
            self,
            self._streaks    or { current_days=0, best_days=0, current_weeks=0, best_weeks=0 },
            self._yearly     or { days=0, pages=0, duration=0 },
            self._year_range or { min_year=self.selected_year, max_year=self.selected_year },
            self._monthly    or {},
            self._all_time   or { hours=0, pages=0 },
            self._last_week  or { avg_seconds=0, avg_pages=0 },
            self._last_week_daily or nil,
            fonts, layout,
            self._goal_finished)

        local title_bar_inner = TitleBar:new{
            fullscreen     = true,
            width          = screen_w,
            align          = "left",
            title          = self:_titleBarText(),
            -- Same scale as the rest of the text (nil = TitleBar's own
            -- default face while nothing is scaled).
            title_face     = font_scale < 0.999 and Font:getFace("smalltfont",
                math.max(8, math.floor(((Font.sizemap and Font.sizemap.smalltfont) or 24) * font_scale + 0.5))) or nil,
            -- Hamburger menu, top left: quick access to the streak/heatmap/
            -- records/achievements popups - see onShowHamburgerMenu below.
            -- Hidden in readonly (sleep-screen) mode, same as close_callback,
            -- so a stray touch there can't navigate away from the wake screen.
            left_icon              = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and "appbar.menu" or nil,
            left_icon_tap_callback = (not self.readonly and VS.Opt.readShowHamburgerMenu()) and function() self:onShowHamburgerMenu() end or nil,
            close_callback = (not self.readonly) and function() UIManager:close(self) end or nil,
            show_parent    = self,
            top_v_padding    = Size.padding.default,
            bottom_v_padding = Size.padding.default,
        }

        local title_bar_h = title_bar_inner:getSize().h
        self._title_bar_height = title_bar_h
        self.title_bar = title_bar_inner

        -- Manual mode keeps the generous title-bar-tall bottom spacer it
        -- always had (the page is expected to scroll there anyway); auto
        -- mode uses a small one, so the space it would have eaten goes to
        -- the charts instead.
        local group = VerticalGroup:new{
            align = "left",
            title_bar_inner,
            UI.padded(layout.padding_h, Colors.newBar(layout.content_width, Size.line.thick, Colors.separator())),
            sections,
            -- VerticalSpan reads `width` (a `height` field is ignored, which
            -- left this spacer at 0 px). Without a monthly chart to take
            -- the extra pixels they end up here.
            VerticalSpan:new{ width = (bottom_span or title_bar_h)
                + (VS.Opt.built_monthly and 0 or built_extra) },
        }
        return group, group:getSize().h
    end

    -- Auto-fit: grow/shrink the two adjustable charts until the page is as
    -- close to exactly one screen tall as it can get without going over
    -- (which is what makes the scroll bar appear).
    --
    -- Each build is measured rather than predicted, because a lot of what
    -- surrounds the charts has data- and font-dependent height (year
    -- header, streak rows, wrapped labels...). The per-point pixel cost of
    -- a bar is known though (Screen:scaleBySize is linear), so one
    -- measurement is enough to compute the next candidate directly instead
    -- of stepping towards it - in practice this settles in one or two extra
    -- builds on the very first open, and in zero afterwards, since the
    -- heights that fit last time are kept as the next starting guess.
    local content, content_h = buildContent()

    local adjusted = false
    if auto_fit then
        local px_per_point = Screen:scaleBySize(1000) / 1000
        if px_per_point <= 0 then px_per_point = 1 end

        local function rebuild()
            local discarded = content
            content, content_h = buildContent()
            -- Free the measured-then-thrown-away build; failure here is
            -- harmless (worst case it's collected later), so it must never
            -- take the popup down with it.
            pcall(function() if discarded.free then discarded:free() end end)
        end

        for _ = 1, 4 do
            local n_charts = (VS.Opt.built_weekly and 1 or 0) + (VS.Opt.built_monthly and 1 or 0)
            if n_charts == 0 then break end -- nothing adjustable on this page

            -- Room the page has with the extra pixels taken back out: the
            -- bar points are fitted first, the extra pixels only take up
            -- what a whole point (per chart) cannot.
            local slack_px = screen_h - content_h + built_extra
            if slack_px >= 0 and slack_px < px_per_point * n_charts then break end

            local delta_points = math.floor(slack_px / (px_per_point * n_charts))
            if delta_points == 0 then
                -- Overflowing by less than one point per chart: still has
                -- to come off, or the scroll bar stays.
                delta_points = (slack_px < 0) and -1 or 0
            end
            if delta_points == 0 then break end

            local current = VS.Opt.auto_height or VS.DEFAULT_MONTHLY_BAR_HEIGHT
            local new_height = math.max(VS.Opt.AUTO_MIN,
                math.min(VS.Opt.AUTO_MAX, current + delta_points))

            -- Clamped, so another build would produce the exact same page:
            -- give up and let it scroll (tiny screen, huge fonts) or stay
            -- slightly short (huge screen, few sections).
            if new_height == current then break end

            VS.Opt.auto_height = new_height
            VS.Opt.monthly_extra_px = 0
            adjusted = true
            rebuild()
        end

        -- Whole pixels that did not make a bar point: hand them to the
        -- monthly chart (under it) so the page is exactly one screen tall
        -- and its last row lands where the Reading calendar's does. Only a
        -- small remainder is handed out - if the heights are clamped and
        -- much room is left, the page stays short as before.
        local n_charts = (VS.Opt.built_weekly and 1 or 0) + (VS.Opt.built_monthly and 1 or 0)
        local slack_px = screen_h - content_h + built_extra
        local want_extra = 0
        if n_charts > 0 and slack_px >= 0 and slack_px <= px_per_point * n_charts * 2 then
            want_extra = slack_px
        end
        if want_extra ~= built_extra then
            VS.Opt.monthly_extra_px = want_extra
            rebuild()
            -- The extra is plain pixels, so this should fit exactly; if it
            -- somehow overflows, take it back rather than show a scroll bar.
            if content_h > screen_h and want_extra > 0 then
                VS.Opt.monthly_extra_px = 0
                rebuild()
            end
        end
    end

    -- Landscape and portrait: if the page is still taller than the screen here (the
    -- bar charts are at their smallest, or auto height is off and the fixed
    -- heights are too big) the scroll bar would show up. Shrink every font
    -- by the same percentage until the content fits and the scroll bar is
    -- gone. If everything fits, the configured font sizes stay untouched.
    --
    -- Like the bar fit above, each step is measured, not predicted: text
    -- height shrinks roughly in proportion to the scale while the bars and
    -- spacing don't, so the next scale is the current one times
    -- screen/content (a little under, to land on the fitting side), which
    -- usually settles in one or two extra builds. The result is remembered
    -- in VS.Opt.font_scale as the first guess for the next open.
    -- FONT_SCALE_MIN stops it from shrinking text into unreadability; below
    -- that the page just scrolls.
    -- A settings change since the remembered scale was computed (a section
    -- switched on/off, a layout, font or height changed...) discards it, so
    -- the fit is recalculated from scratch instead of reusing a scale that
    -- belonged to a different page.
    local sig = settingsSignature()
    if VS.Opt.settings_sig ~= sig then
        VS.Opt.font_scale   = nil
        VS.Opt.settings_sig = sig
    end

    if content_h > screen_h then
        local FONT_SCALE_MIN = 0.5
        local remembered     = VS.Opt.font_scale
        local scale          = 1
        local best           = nil   -- smallest-change scale that fitted
        for attempt = 1, 6 do
            local candidate
            if attempt == 1 and remembered and remembered < 1 and remembered >= FONT_SCALE_MIN then
                candidate = remembered
            else
                candidate = scale * (screen_h / content_h) * 0.98
                -- Always make progress, even if the measurement says the
                -- estimate is the same as before.
                if candidate > scale - 0.02 then candidate = scale - 0.02 end
            end
            candidate = math.max(FONT_SCALE_MIN, math.floor(candidate * 100) / 100)
            if candidate >= scale then break end

            scale      = candidate
            font_scale = scale
            fonts      = getCachedFonts(scale)

            local discarded = content
            content, content_h = buildContent()
            pcall(function() if discarded.free then discarded:free() end end)

            if content_h <= screen_h then best = scale; break end
            if scale <= FONT_SCALE_MIN then break end
        end
        VS.Opt.font_scale = best  -- nil when it never fitted: don't pin a bad guess
    else
        VS.Opt.font_scale = nil
    end

    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")

    self.scroll_container = ScrollableContainer:new{
        dimen               = Geom:new{ w = screen_w, h = screen_h },
        show_parent         = self,
        scroll_bar_position = "right",
        content,
    }

    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        radius     = 0,
        padding    = 0,
        width      = screen_w,
        VerticalGroup:new{
            align = "left",
            self.scroll_container,
        },
    }

    self.popup_frame.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    self[1] = VerticalGroup:new{ self.popup_frame }
end

-- Runs the DB getter for one insights mode's monthly chart. Shared by
-- _fetchYearSpecific (current mode, on the popup's own load path) and
-- _prefetchOtherModes (the other two modes, in the background) so both stay
-- in sync with which getter belongs to which mode.
local function queryMonthlyForMode(year, mode, conn)
    if mode == VS.INSIGHTS_MODE_HOURS then
        return Data.getMonthlyReadingHours(year, conn)
    elseif mode == VS.INSIGHTS_MODE_PAGES then
        return Data.getMonthlyReadingPages(year, conn)
    elseif mode == VS.INSIGHTS_MODE_BOOKS then
        return Data.getMonthlyBookCounts(year, conn)
    end
    return Data.getMonthlyReadingDays(year, conn)
end

-- Fetches (and, for a completed year, freezes) one mode's monthly chart for
-- `year`. This is the completed-year-aware wrapper around
-- queryMonthlyForMode: a past year is read from the frozen completed-year
-- cache and only ever queried the first time it's needed for that mode, the
-- current year always queries live (which itself is cheap after the first
-- call today - see the base-cache comments on the getters in
-- lib/insights_data.lua). Used for the popup's own mode as well as for
-- warming the modes it isn't currently showing.
local function fetchMonthlyForYearMode(year, mode, conn)
    if not isCompletedYear(year) then
        return queryMonthlyForMode(year, mode, conn)
    end
    local monthly = Cache.getCompletedMonthly(year, mode)
    if monthly == nil then
        monthly = queryMonthlyForMode(year, mode, conn)
        Cache.setCompletedYearData(year, nil, mode, monthly)
    end
    return monthly
end

-- The two year-specific slices (yearly totals + the monthly chart for the
-- current mode), fetched the way the selected year wants them. A completed
-- (past) year is read from the frozen completed-year cache and only queried
-- the first time it's ever needed - then written back so it's never queried
-- again; the current year always queries live. `conn` is the shared batch
-- connection (may be nil, in which case each getter opens its own).
function ReadingInsightsPopup:_fetchYearSpecific(conn)
    local year = self.selected_year
    local mode = self.mode or VS.INSIGHTS_MODE_HOURS

    if not isCompletedYear(year) then
        return Data.getYearlyStats(year, conn), queryMonthlyForMode(year, mode, conn)
    end

    local yearly  = Cache.getCompletedYearly(year)
    local monthly = Cache.getCompletedMonthly(year, mode)
    if yearly == nil then yearly = Data.getYearlyStats(year, conn) end
    if monthly == nil then monthly = queryMonthlyForMode(year, mode, conn) end
    -- Freeze whatever we had to compute (a no-op re-store for cache hits).
    Cache.setCompletedYearData(year, yearly, mode, monthly)
    return yearly, monthly
end

-- Warms the monthly chart cache for the insights modes the popup ISN'T
-- currently showing, so switching to "days" or "books" later this session
-- lands on the same warm cache as the mode the popup opened with, instead of
-- doing the once-a-day full-year scan right when the user taps to switch.
--
-- Scheduled from _loadAndRebuild, after that call's own data has already
-- loaded and painted (see _scheduleAchievementsRefresh right above it for
-- the same reasoning), so this never delays what's on screen for the
-- current mode. For a mode whose base cache was already computed today -
-- an earlier popup open, or an earlier switch this session - the getter
-- call below is effectively free (same per-day base cache the visible mode
-- itself relies on), so this is a real DB scan at most once per mode per
-- day, same cost the visible mode already pays for itself.
function ReadingInsightsPopup:_schedulePrefetchOtherModes()
    if self._sleep_sync then return end
    if self._prefetch_scheduled then return end
    self._prefetch_scheduled = true
    UIManager:scheduleIn(0.3, function()
        self._prefetch_scheduled = false
        if self._closed then return end
        local year         = self.selected_year
        local current_mode = self.mode or VS.INSIGHTS_MODE_HOURS
        local other_modes = {}
        for _, m in ipairs({ VS.INSIGHTS_MODE_HOURS, VS.INSIGHTS_MODE_PAGES, VS.INSIGHTS_MODE_DAYS, VS.INSIGHTS_MODE_BOOKS }) do
            if m ~= current_mode then table.insert(other_modes, m) end
        end
        Data.withBatchConnection(function(conn)
            for _, m in ipairs(other_modes) do
                if self._closed then break end
                pcall(fetchMonthlyForYearMode, year, m, conn)
            end
        end)
        if self._closed then return end
        Cache.saveDiskCache()
    end)
end

-- Set self._yearly/_monthly for the current selected_year+mode ahead of a
-- _buildUI, so that first build already has the right data - and therefore
-- the bar-chart auto-fit sizes correctly on the first pass, with no
-- stale-then-real reflow. reset_yearly is false on a mode switch (same year,
-- only the monthly chart changes) so the mode-independent yearly numbers on
-- screen don't flicker.
--
-- Fast path first: a past year from its frozen cache, the current year from
-- its last stale values - both instant. Whatever the fast path can't supply
-- (a year/mode not seen yet today) is then fetched synchronously, so the
-- monthly chart is on the page for that very first build instead of appearing
-- a beat later and reflowing the charts. That synchronous fill is the fix for
-- "it still jumps once, only when not cached yet": the first switch into
-- days- or books-per-month, or paging to a year not opened yet today.
function ReadingInsightsPopup:_primeYearSpecific(reset_yearly)
    local year = self.selected_year
    local mode = self.mode or VS.INSIGHTS_MODE_HOURS

    local fast_yearly, fast_monthly
    if isCompletedYear(year) then
        fast_yearly  = Cache.getCompletedYearly(year)
        fast_monthly = Cache.getCompletedMonthly(year, mode)
    else
        fast_yearly  = Cache.findStaleByPrefix(Cache._stale_yearly, year .. ":v3:")
        fast_monthly = Cache.findStaleByPrefix(Cache._stale_monthly,
            VS.monthKeyPrefixForMode(mode) .. year .. ":")
    end

    if reset_yearly then
        -- Year changed (paging or a direct open): take the fast values, but
        -- don't null out anything already served (e.g. init's stale) just
        -- because the fast source has a gap - the sync fill below covers it.
        self._yearly  = fast_yearly  or self._yearly
        self._monthly = fast_monthly or self._monthly
    else
        -- Only the mode changed: replace the monthly chart outright (the
        -- prior value is a *different* mode's chart, so it must not be kept);
        -- yearly is mode-independent and stays as it is.
        self._monthly = fast_monthly
    end

    -- Fetch any genuine gap synchronously. _fetchYearSpecific also freezes a
    -- past year's result; for the current year it's a one-off bootstrap that
    -- _loadAndRebuild refreshes right after. Only assign what actually came
    -- back, so a failed one-off (e.g. a locked DB) keeps whatever was served
    -- rather than nulling a section into a reflow.
    local need_yearly  = (reset_yearly and self._yearly == nil)
    local need_monthly = (self._monthly == nil)
    if need_yearly or need_monthly then
        local got = Data.withBatchConnection(function(conn)
            local y, m = self:_fetchYearSpecific(conn)
            return { yearly = y, monthly = m }
        end) or {}
        if need_yearly  and got.yearly  ~= nil then self._yearly  = got.yearly  end
        if need_monthly and got.monthly ~= nil then self._monthly = got.monthly end
    end
end

function ReadingInsightsPopup:_loadAndRebuild()
    -- Re-fetch everything over one shared DB connection (seven open/close
    -- cycles become one). Each getter still manages its own cache and works
    -- without a connection, so this only saves the redundant opens; the
    -- connection is opened and closed by the data module (see
    -- Data.withBatchConnection), leaving this file with no DB knowledge.
    local batch = Data.withBatchConnection(function(conn)
        -- Year-specific parts; a cache hit (no DB) for an already-frozen
        -- past year, so paging back to it never re-queries.
        local yearly, monthly = self:_fetchYearSpecific(conn)
        local last_week, last_week_daily = Data.getLastWeekAll(conn)
        local cal_week
        if VS.readWeeklyViewIsCalendar() then
            cal_week = Data.getCalendarWeek(self.week_offset or 0, conn)
        end
        return {
            streaks    = Data.calculateStreaks(conn),
            year_range = Data.getYearRange(conn),
            yearly     = yearly,
            all_time   = Data.getAllTimeStats(conn),
            -- Only worth querying when the section that displays it is on.
            goal_finished = VS.Opt.readShowReadingGoal()
                and Data.getFinishedBookCountForYear(self.selected_year, conn)
                or nil,
            last_week       = last_week,
            last_week_daily = last_week_daily,
            cal_week        = cal_week,
            monthly         = monthly,
        }
    end) or {}

    -- Achievements are re-evaluated *after* this rebuild has painted, not
    -- here, so the day's fresh reading numbers appear first and aren't held
    -- back by the (occasionally expensive) achievement recompute - see
    -- _scheduleAchievementsRefresh(), scheduled at the end of this function.
    -- For now we reuse whatever count is already known, so the goal/
    -- achievements cell keeps its current value until that deferred pass
    -- (a beat later) updates it if anything was unlocked.
    local new_ach_count = Achievements and Achievements.earnedCount() or 0

    local new_streaks         = batch.streaks
    local new_year_range      = batch.year_range
    local new_yearly          = batch.yearly
    local new_all_time        = batch.all_time
    local new_goal_finished   = batch.goal_finished
    local new_last_week       = batch.last_week
    local new_last_week_daily = batch.last_week_daily
    local new_cal_week        = batch.cal_week
    local new_monthly         = batch.monthly

    -- Skip rebuild if nothing actually displayed would change - compared by
    -- value, not by table reference (see valuesEqual() for why reference
    -- equality isn't enough now that all_time/yearly refresh every minute).
    -- Exception: coming out of the cold-start "Loading data..." placeholder
    -- always needs a rebuild, even if the freshly-loaded values happen to
    -- be all-zero (e.g. a brand new, still-empty statistics.sqlite3).
    local was_initial_loading = self._initial_loading
    if not was_initial_loading and
       new_ach_count == self._ach_count                        and
       valuesEqual(new_streaks,         self._streaks)         and
       valuesEqual(new_year_range,      self._year_range)      and
       valuesEqual(new_yearly,          self._yearly)          and
       valuesEqual(new_all_time,        self._all_time)        and
       valuesEqual(new_goal_finished,   self._goal_finished)   and
       valuesEqual(new_last_week,       self._last_week)       and
       valuesEqual(new_last_week_daily, self._last_week_daily) and
       valuesEqual(new_cal_week,        self._cal_week)        and
       valuesEqual(new_monthly,         self._monthly)         then
        -- Still adopt the new table references so future comparisons are
        -- against the freshest cache entries, but skip the rebuild/redraw.
        self._streaks         = new_streaks
        self._year_range      = new_year_range
        self._yearly          = new_yearly
        self._all_time        = new_all_time
        self._goal_finished   = new_goal_finished
        self._last_week       = new_last_week
        self._last_week_daily = new_last_week_daily
        self._cal_week        = new_cal_week
        self._monthly         = new_monthly
        self._ach_count       = new_ach_count
        Cache.saveDiskCache()
        self:_scheduleAchievementsRefresh()
        self:_schedulePrefetchOtherModes()
        return
    end

    self._streaks          = new_streaks
    self._year_range       = new_year_range
    self._yearly           = new_yearly
    self._all_time         = new_all_time
    self._goal_finished    = new_goal_finished
    self._last_week        = new_last_week
    self._last_week_daily = new_last_week_daily
    self._cal_week        = new_cal_week
    self._monthly         = new_monthly
    self._ach_count       = new_ach_count
    self._initial_loading = false

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    Cache.saveDiskCache()
    self:_scheduleAchievementsRefresh()
    self:_schedulePrefetchOtherModes()
end

-- Deferred, one-shot achievement re-evaluation. Scheduled at the end of
-- _loadAndRebuild(), i.e. only once the reading data has been loaded and
-- painted, so opening the popup shows the day's fresh numbers straight away
-- and the (sometimes costly) achievement recompute runs a beat later. If it
-- unlocks anything, the goal/achievements cell is repainted then; otherwise
-- nothing visible changes. refreshIfChanged() is cheap when nothing changed -
-- one fingerprint query, or nothing at all more than once a day - so it is
-- fine to schedule this on every rebuild; the flag only stops overlapping
-- passes from stacking up, and the pass never reschedules itself, so it can't
-- loop.
function ReadingInsightsPopup:_scheduleAchievementsRefresh()
    if self._sleep_sync then return end
    if not Achievements then return end
    -- Only worth doing when the popup actually shows the achievements
    -- section. When it's switched off the count isn't drawn, so skip even
    -- the cheap fingerprint query here - the list
    -- (reachable via "Show Achievements") recomputes on its own force-reload,
    -- and a full popup title-bar reload still re-scans regardless (see the
    -- Achievements.recompute call in the reload path).
    if not VS.Opt.readShowAchievements() then return end
    if self._ach_refresh_scheduled then return end
    self._ach_refresh_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._ach_refresh_scheduled = false
        if self._closed then return end
        local before = self._ach_count or 0
        pcall(Achievements.refreshIfChanged, VS.Opt.readAchievementRefresh())
        local after = Achievements and Achievements.earnedCount() or 0
        if after == before then return end
        self._ach_count = after
        if self._closed then return end
        self:_buildUI()
        UIManager:setDirty(self, function()
            return "ui", self.popup_frame.dimen
        end)
    end)
end

-- init() shows cached/stale data immediately, then _loadAndRebuild() refreshes in the background.
function ReadingInsightsPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Write the current (in-memory, not yet saved) reading session into
    -- statistics.sqlite3, then invalidate the "Last 7 days" cache so it is
    -- always re-queried from the DB on every open of this popup - not just
    -- once per minute. Older cached/stale values are still shown instantly
    -- below (stale-while-revalidate); _loadAndRebuild() then replaces them
    -- with the freshly-flushed numbers a moment later.
    Data.flushStatsToDB(self.ui)
    Cache._cache.last_week              = nil
    Cache._cache.last_week_minute       = nil
    Cache._cache.last_week_daily        = nil
    Cache._cache.last_week_daily_minute = nil
    Data.clearCalendarWeekCache()

    -- Use fresh cache if available.
    if Cache.ENABLE_CACHE then
        self._streaks    = self._streaks    or Cache._cache.streaks
        local minute = Cache.currentMinute()
        self._year_range = self._year_range or Cache._cache.year_range
        self._all_time   = self._all_time   or Cache._cache.all_time
        local year_key = (self.selected_year or tonumber(os.date("%Y"))) .. ":v3:" .. Cache.todayDateStr()
        self._yearly  = self._yearly  or Cache._yearly_cache[year_key]
        local mode = VS.normalizeInsightsMode(self.mode or VS.readInsightsMode())
        local month_key = VS.monthKeyPrefixForMode(mode) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":" .. Cache.todayDateStr()
        self._monthly = self._monthly or Cache._monthly_cache[month_key]
        if not self._last_week or not self._last_week_daily then
            local lw_cached    = Cache.getMinuteCache(Cache._cache, "last_week", "last_week_minute", minute)
            local daily_cached = Cache.getMinuteCache(Cache._cache, "last_week_daily", "last_week_daily_minute", minute)
            self._last_week       = self._last_week       or lw_cached
            self._last_week_daily = self._last_week_daily or daily_cached
        end
    end

    -- Fall back to stale cache for anything still missing (e.g. after a restart or day rollover).
    if Cache.ENABLE_CACHE then
        local year_key_any   = (self.selected_year or tonumber(os.date("%Y"))) .. ":v3:"
        local mode_fb = VS.normalizeInsightsMode(self.mode or VS.readInsightsMode())
        local month_key_fb = VS.monthKeyPrefixForMode(mode_fb) .. (self.selected_year or tonumber(os.date("%Y"))) .. ":"

        if not self._streaks then
            self._streaks = Cache._stale_cache.streaks
        end

        if not self._year_range then
            self._year_range = Cache._stale_cache.year_range
            -- Ensure selected_year stays within the stale range if we got one.
            if self._year_range and self.selected_year then
                if self.selected_year < self._year_range.min_year then
                    self.selected_year = self._year_range.min_year
                elseif self.selected_year > self._year_range.max_year then
                    self.selected_year = self._year_range.max_year
                end
            end
        end

        if not self._all_time then
            self._all_time = Cache._stale_cache.all_time
        end

        if not self._last_week then
            self._last_week = Cache._stale_cache.last_week
        end

        if not self._last_week_daily then
            self._last_week_daily = Cache._stale_cache.last_week_daily
        end
        -- Find any stale yearly entry for the current year.
        if not self._yearly then
            self._yearly = Cache.findStaleByPrefix(Cache._stale_yearly, year_key_any)
        end
        -- Find any stale monthly entry for the current year + mode.
        if not self._monthly then
            self._monthly = Cache.findStaleByPrefix(Cache._stale_monthly, month_key_fb)
        end
        -- The finished-book count for the reading-goal section: seeded
        -- straight from the persisted, disk-backed finished-books list
        -- (see getFinishedBookCountForYear) rather than left nil, so the
        -- popup doesn't open showing "0 books finished" for a moment
        -- before _loadAndRebuild() replaces it with the real count a beat
        -- later.
        if not self._goal_finished then
            local goal_year_key = tostring(self.selected_year or tonumber(os.date("%Y")))
            local known = Cache._goal_finished_books[goal_year_key]
            if type(known) == "table" then
                local c = 0
                for _ in pairs(known) do c = c + 1 end
                self._goal_finished = Data.applyFinishedOverrides(goal_year_key, c)
            end
        end
    end

    self.mode = VS.normalizeInsightsMode(self.mode or VS.readInsightsMode())
    self.weekly_chart_mode = VS.normalizeWeeklyChartMode(self.weekly_chart_mode or VS.readWeeklyChartMode())

    -- selected_year needs a value before we can prime year-specific data or
    -- run _loadAndRebuild.
    if not self.selected_year then
        self.selected_year = tonumber(os.date("%Y"))
    end

    -- "Current week" view of the weekly section: it opens on the current
    -- week (week_offset 0) unless a reopen hands one over, and is loaded
    -- before the first build, so the section is on the page at once rather
    -- than appearing a beat later. The sleep screen skips this:
    -- _sleep_load() fetches it together with the rest.
    self.week_offset = self.week_offset or 0
    if not self.readonly then
        -- Paint from the previous numbers when there are some from today and
        -- let _loadAndRebuild() refresh them together with the rest over one
        -- shared query; only a cold start queries here, before the first paint.
        local stale = VS.readWeeklyViewIsCalendar() and Data.getCalendarWeekStale(self.week_offset) or nil
        if stale then
            self._cal_week = stale
        else
            self:_primeCalendarWeek()
        end
    end

    -- Direct-open on a past year (a caller passing selected_year, rather than
    -- the usual open-on-the-current-year then page): serve that year's
    -- immutable year-specific data straight from the completed-year cache
    -- before the first build - fetched synchronously once if it isn't frozen
    -- yet - exactly as _goToYear does, so the bar-chart auto-fit lands right
    -- the first time instead of reflowing when the async refresh arrives. The
    -- current year keeps the stale-then-refresh path handled above.
    if isCompletedYear(self.selected_year) then
        self:_primeYearSpecific(true)
    end

    -- True only on a genuine cold start (e.g. right after a KOReader restart):
    -- no fresh cache and no stale fallback for any of the core stats. In that
    -- case _buildUI() shows a "Loading data..." placeholder instead of a
    -- flash of zeroed-out sections; cleared as soon as _loadAndRebuild()
    -- brings in real data.
    self._initial_loading = not (self._streaks or self._yearly or self._monthly
        or self._all_time or self._last_week or self._goal_finished)

    self.dimen = Geom:new{ w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        -- Hold handled at popup level to avoid ScrollableContainer eating inner Hold events.
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
        self.ges_events.Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end

    -- Build UI immediately with available data; refresh in background.
    -- Small delay (not 0) so the initial paint actually lands on screen
    -- before _loadAndRebuild() (which now recomputes all_time/yearly on
    -- almost every open, not just once a day) can trigger a second redraw.
    if self.readonly then
        -- Sleep screen: no stale-then-refresh. Every query runs and the page
        -- is built once, right here, before the Suspend handler returns -
        -- otherwise the numbers would be refreshed by a timer after the
        -- device has already started to sleep (or never, if it is quicker).
        self:_sleep_load()
    else
        self:_buildUI()
        UIManager:scheduleIn(0.1, function()
            if self._closed then return end
            self:_loadAndRebuild()
        end)
    end
end

-- Readonly (sleep screen) loading: the whole of _loadAndRebuild() plus the
-- achievements count, run now and in order, with the deferred passes
-- (_scheduleAchievementsRefresh / _schedulePrefetchOtherModes) switched off.
function ReadingInsightsPopup:_sleep_load()
    self._sleep_sync = true
    -- Forces _loadAndRebuild() to build the page even when the fresh numbers
    -- equal the cached ones - this is the first (and only) build.
    self._initial_loading = true
    local ok, err = pcall(self._loadAndRebuild, self)
    if not ok then
        logger.warn("ReadingInsights sleep screen: load failed:", tostring(err))
        self._initial_loading = false
        if not self[1] then self:_buildUI() end
        return
    end

    -- The achievements count: normally refreshed a beat after the open;
    -- here it is done now, and the page rebuilt only if it changed.
    if Achievements and VS.Opt.readShowAchievements() then
        local before = self._ach_count or 0
        pcall(Achievements.refreshIfChanged, VS.Opt.readAchievementRefresh())
        local after = Achievements.earnedCount() or 0
        if after ~= before then
            self._ach_count = after
            self:_buildUI()
        end
    end
end

function ReadingInsightsPopup:onSwipe(arg, ges_ev)
    if not ges_ev then return false end
    local dir = ges_ev.direction
    local west  = (dir == "west" or dir == "left")
    local east  = (dir == "east" or dir == "right")
    local function inside(list)
        local pos = ges_ev.pos
        if not pos then return false end
        for _idx, w in ipairs(list or {}) do
            local d = w.dimen
            if d and pos.x >= d.x and pos.x <= d.x + d.w
                  and pos.y >= d.y and pos.y <= d.y + d.h then
                return true
            end
        end
        return false
    end
    -- The year zone is one continuous full-width band: from the top of the
    -- first year widget (year header) to the bottom of the last one (monthly
    -- chart / reading goal row), including the gaps and divider lines between
    -- them and the short caption rows that don't span the whole width.
    local function inYearZone()
        local pos = ges_ev.pos
        if not pos then return false end
        local top, bottom
        for _idx, w in ipairs(self._year_swipe_targets or {}) do
            local d = w.dimen
            if d and d.h and d.h > 0 then
                if not top or d.y < top then top = d.y end
                if not bottom or d.y + d.h > bottom then bottom = d.y + d.h end
            end
        end
        return top ~= nil and pos.y >= top and pos.y <= bottom
    end
    -- Sideways swipes only act where they start:
    --   - on the weekly section (calendar-week view) -> page the week
    --   - on the year header, its stats row, the monthly chart or the
    --     reading goal row
    --                                                -> page the year
    -- A sideways swipe anywhere else is ignored.
    if west or east then
        if VS.readWeeklyViewIsCalendar() and inside(self._week_swipe_targets) then
            if west then return self:onGoToNextWeek() end
            return self:onGoToPrevWeek()
        end
        if inYearZone() then
            if west then return self:onGoToNextYear() end
            return self:onGoToPrevYear()
        end
        return true
    end
    if dir == "south" or dir == "down" then
        if self.readonly then return true end
        UIManager:close(self)
        return true
    end
    return false
end

-- Hold dispatch by touch position:
--   title bar      → cache reload
--   chart header   → CalendarView for current month
--   goal value     → edit the reading goal for the currently shown year
function ReadingInsightsPopup:onHold(arg, ges_ev)
    if not ges_ev or not ges_ev.pos then return true end
    local pos = ges_ev.pos

    local title_h = self._title_bar_height
    if title_h and pos.y <= title_h then
        -- The "Reloading data..." message stays up for the whole reload (the
        -- UI is busy while the database is re-scanned and the achievements
        -- are re-dated), and a short result message follows it.
        local msg = InfoMessage:new{ text = _("Reloading data...") }
        UIManager:show(msg)
        UIManager:scheduleIn(0.5, function()
            local before = Achievements and Achievements.earnedCount() or 0
            Cache.clearAllCache()
            Data.clearCalendarWeekCache(true)
            Data.clearTimeGoalCache()
            -- ratings changed outside the plugin (file manager, status page)
            if BookList and BookList.refreshRatings then pcall(BookList.refreshRatings, true) end
            -- A full reload is the one place achievements are re-evaluated
            -- against the (now uncached) database - see lib/achievements.lua.
            -- Newly earned ones get persisted; the rebuilt goal section then
            -- reads the updated count from the file.
            if Achievements then pcall(Achievements.recompute) end
            local gained = (Achievements and Achievements.earnedCount() or 0) - before
            self._streaks         = nil
            self._yearly          = nil
            self._monthly         = nil
            self._all_time        = nil
            self._last_week       = nil
            self._last_week_daily = nil
            UIManager:close(msg)
            self:_loadAndRebuild()
            local text = _("Data reloaded")
            if gained > 0 then
                text = T(_("Data reloaded. New achievements: %1"), tostring(gained))
            end
            UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
        end)
        return true
    end

    if self._current_month_bar_widget then
        local d = self._current_month_bar_widget.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            self:openCalendarForCurrentMonth()
            return true
        end
    end

    -- Chart captions: hold opens a list of their views.
    for _idx, t in ipairs(self._chart_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    -- Weekly section header: hold flips between "Last 7 days" and the
    -- current-week view.
    for _idx, t in ipairs(self._week_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    -- Daily/Weekly time goal section: a hold edits that goal.
    for _idx, t in ipairs(self._timegoal_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    -- Reading-goal section: a hold on any of its headers/cells runs that
    -- widget's registered action (see buildInsightsSections' addHold).
    for _idx, t in ipairs(self._goal_hold_targets or {}) do
        local d = t.w and t.w.dimen
        if d and pos.x >= d.x and pos.x <= d.x + d.w
              and pos.y >= d.y and pos.y <= d.y + d.h then
            t.fn()
            return true
        end
    end

    return true
end

-- Opens a numeric picker (long press on the goal value in the reading-goal
-- section) to set/change that year's target. Saved immediately on "Save";
-- the popup is rebuilt in place so the new value shows without a full
-- close/reopen.
function ReadingInsightsPopup:editReadingGoal(year)
    local InputDialog = require("ui/widget/inputdialog")
    local popup_self = self
    local dialog
    dialog = InputDialog:new{
        -- ReadingInsightsPopup is modal, and UIManager stacks a *non*-modal
        -- window shown over it *underneath* it. A SpinWidget's own inline
        -- number entry is non-modal, so it landed behind this popup - you
        -- couldn't see what you typed (only the committed value on Enter),
        -- and the keyboard covered it. A modal InputDialog instead sits on
        -- top of the popup and lifts itself above the keyboard like every
        -- other text field (same pattern as the manual-books add dialog).
        modal      = true,
        title      = buildGoalEditTitle(year),
        input      = tostring(VS.readReadingGoal(year)),
        input_type = "number",
        input_hint = "1 - 999",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id   = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local n = tonumber(dialog:getInputText())
                        if n then
                            n = math.floor(n)
                            if n < 1 then n = 1 elseif n > 999 then n = 999 end
                            VS.saveReadingGoal(year, n)
                        end
                        UIManager:close(dialog)
                        popup_self:_buildUI()
                        UIManager:setDirty(popup_self, function()
                            return "ui", popup_self.popup_frame.dimen
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Tap on the Daily/Weekly goal section: how many days / weeks in a row the
-- goal has been met. Runs one grouped query only now, so opening the popup
-- itself costs nothing extra.
function ReadingInsightsPopup:showTimeGoalStreak(kind)
    local is_daily = (kind == "daily")
    Data.flushStatsToDB(self.ui)
    local goal_secs = (is_daily and VS.readDailyGoalMinutes() or VS.readWeeklyGoalMinutes()) * 60
    local n = Data.getTimeGoalStreak(kind, goal_secs) or 0
    local text
    if n <= 0 then
        text = is_daily and _("You haven't met your daily goal yet.")
                         or _("You haven't met your weekly goal yet.")
    elseif is_daily then
        text = T(N_("You've met your daily goal %1 day in a row.",
                    "You've met your daily goal %1 days in a row.", n), formatCount(n))
    else
        text = T(N_("You've met your weekly goal %1 week in a row.",
                    "You've met your weekly goal %1 weeks in a row.", n), formatCount(n))
    end
    UIManager:show(InfoMessage:new{ text = text, modal = true, timeout = 5 })
end

-- Long press on the Daily/Weekly goal section: hours/minutes spinner for the
-- goal (stored as total minutes). Marked modal so it opens above this popup,
-- same reason as editReadingGoal's modal InputDialog.
function ReadingInsightsPopup:editTimeGoal(kind)
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")

    -- Label for the "default" button, e.g. "Default: 30m" / "Default: 5h"
    -- (depends on KOReader's duration format setting), instead of KOReader's
    -- raw "Default values: 0 : 30". Seconds are dropped.
    local function formatDefaultGoal(total_min)
        return T(_("Default: %1"), Locale.formatDuration(total_min * 60, true))
    end
    local popup_self = self
    local is_daily = (kind == "daily")
    local current  = is_daily and VS.readDailyGoalMinutes() or VS.readWeeklyGoalMinutes()
    local default  = is_daily and VS.DEFAULT_DAILY_GOAL_MIN or VS.DEFAULT_WEEKLY_GOAL_MIN
    local max_hours = is_daily and 23 or 99
    local widget
    widget = DoubleSpinWidget:new{
        modal        = true,
        title_text   = is_daily and _("Daily goal") or _("Weekly goal"),
        left_text    = _("Hours"),
        left_value   = math.floor(current / 60),
        left_min     = 0,
        left_max     = max_hours,
        left_step    = 1,
        left_hold_step = 5,
        right_text   = _("Minutes"),
        right_value  = current % 60,
        right_min    = 0,
        right_max    = 59,
        right_step   = 1,
        right_hold_step = 5,
        default_values = true,
        left_default   = math.floor(default / 60),
        right_default  = default % 60,
        default_text   = formatDefaultGoal(default),
        ok_always_enabled = true,
        callback = function(hours, minutes)
            local total = (tonumber(hours) or 0) * 60 + (tonumber(minutes) or 0)
            if total < 1 then total = 1 end
            if is_daily then VS.saveDailyGoalMinutes(total) else VS.saveWeeklyGoalMinutes(total) end
            popup_self:_buildUI()
            UIManager:setDirty(popup_self, function()
                return "ui", popup_self.popup_frame.dimen
            end)
        end,
    }
    widget.modal = true
    UIManager:show(widget)
end

-- Cycles the insights mode (hours -> days -> books -> hours) and reloads
-- the monthly chart for it. Bound to both the "Press" key handler
-- (toggleInsightsMode) and tapping the monthly chart header
-- (cycleInsightsMode) - kept as two names since that's what the gesture/key
-- wiring elsewhere calls, but there's only one implementation.
function ReadingInsightsPopup:cycleInsightsMode()
    local new_mode
    -- time -> pages -> days -> books -> time
    if self.mode == VS.INSIGHTS_MODE_HOURS then
        new_mode = VS.INSIGHTS_MODE_PAGES
    elseif self.mode == VS.INSIGHTS_MODE_PAGES then
        new_mode = VS.INSIGHTS_MODE_DAYS
    elseif self.mode == VS.INSIGHTS_MODE_DAYS then
        new_mode = VS.INSIGHTS_MODE_BOOKS
    else
        new_mode = VS.INSIGHTS_MODE_HOURS
    end

    return self:setInsightsMode(new_mode)
end

-- Applies an insights mode (hours / pages / days / books): persists it and
-- reloads the monthly chart for it.
function ReadingInsightsPopup:setInsightsMode(new_mode)
    if self.mode == new_mode then return true end
    VS.saveInsightsMode(new_mode)
    self.mode = new_mode

    -- Only the monthly chart changes with the mode; a past year serves it
    -- from the frozen cache, the current year from stale + background
    -- refresh. reset_yearly = false so the (mode-independent) yearly numbers
    -- on screen don't flicker.
    self:_primeYearSpecific(false)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    UIManager:scheduleIn(0, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
    return true
end

-- Shows a list dialog with one row per choice, the active one marked with a
-- check mark (same look as the other pickers of the plugin).
--   choices = { { value = ..., text = ... }, ... }
function ReadingInsightsPopup:_showChoiceDialog(choices, current, on_pick)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _idx, c in ipairs(choices) do
        local value = c.value
        table.insert(buttons, {{
            -- U+2713 CHECK MARK in front of the view currently in use.
            text  = (current == value and "\xe2\x9c\x93 " or "    ") .. c.text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                on_pick(value)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        modal                 = true,
        shrink_unneeded_width = true,
        buttons               = buttons,
    }
    -- ButtonDialog repaints its area with a flashing "flashui" refresh when
    -- it closes; use a plain "ui" refresh instead so choosing an item does
    -- not flash the screen. The popup is redrawn right after by the callback.
    dialog.onCloseWidget = function(this)
        UIManager:setDirty(nil, function()
            return "ui", this.movable and this.movable.dimen
        end)
    end
    UIManager:show(dialog)
end

-- Long press on the monthly chart caption: choose the monthly view.
function ReadingInsightsPopup:showInsightsModePicker()
    local popup_self = self
    self:_showChoiceDialog({
        { value = VS.INSIGHTS_MODE_HOURS, text = _("Reading time per month") },
        { value = VS.INSIGHTS_MODE_PAGES, text = _("Pages per month") },
        { value = VS.INSIGHTS_MODE_DAYS,  text = _("Days read per month") },
        { value = VS.INSIGHTS_MODE_BOOKS, text = _("Books per month") },
    }, self.mode, function(mode) popup_self:setInsightsMode(mode) end)
    return true
end

-- Long press on the weekly chart caption: choose time or pages per day.
function ReadingInsightsPopup:showWeeklyChartModePicker()
    local popup_self = self
    self:_showChoiceDialog({
        { value = VS.WEEKLY_CHART_MODE_TIME,  text = _("Reading time per day") },
        { value = VS.WEEKLY_CHART_MODE_PAGES, text = _("Pages per day") },
    }, VS.normalizeWeeklyChartMode(self.weekly_chart_mode), function(mode)
        if VS.normalizeWeeklyChartMode(popup_self.weekly_chart_mode) ~= mode then
            popup_self:toggleWeeklyChartMode()
        end
    end)
    return true
end

function ReadingInsightsPopup:toggleInsightsMode()
    return self:cycleInsightsMode()
end

-- Toggles the "Last 7 days" bar chart between reading time and pages read per
-- day. No DB re-query is needed: both values are already fetched together
-- by getLastWeekAll(), so this just flips the persisted display mode and
-- rebuilds the UI.
function ReadingInsightsPopup:toggleWeeklyChartMode()
    local new_mode = (self.weekly_chart_mode == VS.WEEKLY_CHART_MODE_PAGES)
        and VS.WEEKLY_CHART_MODE_TIME or VS.WEEKLY_CHART_MODE_PAGES

    self.weekly_chart_mode = new_mode
    VS.saveWeeklyChartMode(new_mode)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Shared implementation for year navigation: moves selected_year by `delta`
-- (-1 or +1), staying within the known year range, serves stale yearly/
-- monthly data for the new year immediately, then reloads for real.
function ReadingInsightsPopup:_goToYear(delta)
    local yr = self._year_range or self.year_range
    if not yr then return true end
    local new_year = self.selected_year + delta
    if new_year < yr.min_year or new_year > yr.max_year then return true end

    self.selected_year = new_year
    self._monthly = nil
    self._yearly  = nil
    -- Serve the target year's year-specific data before building: a past
    -- year exactly, from its frozen cache (so the auto-fit is right on the
    -- first pass, no reflow); the current year from stale, refreshed by the
    -- background _loadAndRebuild below.
    self:_primeYearSpecific(true)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    UIManager:scheduleIn(0, function()
        if self._closed then return end
        self:_loadAndRebuild()
    end)
    return true
end

function ReadingInsightsPopup:onGoToPrevYear()
    return self:_goToYear(-1)
end

-- Whether the calendar week `offset` weeks from the current one (0 = this
-- week, -1 = last week, ...) may be shown: never a future week, and not a
-- week that ends before the first year with reading data.
function ReadingInsightsPopup:_weekInRange(offset)
    if offset > 0 then return false end
    local yr = self._year_range or self.year_range
    local min_year = (yr and yr.min_year) or tonumber(os.date("%Y"))
    local _start, week_end = Data.calendarWeekBounds(offset)
    return (tonumber(week_end:sub(1, 4)) or 0) >= min_year
end

-- Loads the shown calendar week (self.week_offset) into self._cal_week.
-- Used where the week must be on the page at once - the first build, and
-- paging - since it is one small query (cached per minute). Anything that
-- comes back empty (a locked DB) keeps whatever was shown before.
function ReadingInsightsPopup:_primeCalendarWeek()
    if not VS.readWeeklyViewIsCalendar() then
        self._cal_week = nil
        return
    end
    local ok, res = pcall(Data.getCalendarWeek, self.week_offset or 0)
    if ok and res then self._cal_week = res end
end

-- Pages the calendar week by `delta` (-1 = the week before, +1 = the next),
-- the same way _goToYear pages the year. The data of one week is fetched
-- right away, so there is no stale flash and no second redraw.
function ReadingInsightsPopup:_goToWeek(delta)
    if not VS.readWeeklyViewIsCalendar() then return true end
    local new_offset = (self.week_offset or 0) + delta
    if not self:_weekInRange(new_offset) then return true end

    self.week_offset = new_offset
    self._cal_week = nil
    self:_primeCalendarWeek()

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Tap on the shown week's label: jump straight back to the current week.
function ReadingInsightsPopup:onGoToCurrentWeek()
    if not VS.readWeeklyViewIsCalendar() then return true end
    if (self.week_offset or 0) == 0 then return true end
    self.week_offset = 0
    self._cal_week = nil
    self:_primeCalendarWeek()

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Switches the weekly section between the rolling last 7 days and the
-- current calendar week (the same setting as Settings > Week > View).
function ReadingInsightsPopup:setWeeklyView(value)
    if self.readonly then return true end
    if VS.readWeeklyViewSetting() == value then return true end
    VS.saveWeeklyViewSetting(value)
    self.week_offset = 0
    self._cal_week = nil
    self:_primeCalendarWeek()

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

-- Long press on the "Last 7 days" header: choose the week view from a list.
function ReadingInsightsPopup:showWeeklyViewPicker()
    local popup_self = self
    self:_showChoiceDialog({
        { value = VS.WEEKLY_VIEW_LAST7,    text = _("Last 7 days") },
        { value = VS.WEEKLY_VIEW_CALENDAR, text = _("Current week") },
    }, VS.readWeeklyViewSetting(), function(view) popup_self:setWeeklyView(view) end)
    return true
end

function ReadingInsightsPopup:onGoToPrevWeek()
    return self:_goToWeek(-1)
end

function ReadingInsightsPopup:onGoToNextWeek()
    return self:_goToWeek(1)
end

function ReadingInsightsPopup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:onGoToPrevYear() end
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:onGoToNextYear() end
    if key and key:match({ { "Press" } }) then return self:toggleInsightsMode() end
    if self.readonly then return true end
    UIManager:close(self)
    return true
end

function ReadingInsightsPopup:onGoToNextYear()
    return self:_goToYear(1)
end

function ReadingInsightsPopup:onShow()
    if VS.readFullRefreshSetting() then
        UIManager:setDirty(self, function()
            return "full", self.popup_frame.dimen
        end)
    else
        UIManager:setDirty(self, function()
            return "ui", self.popup_frame.dimen
        end)
    end
    return true
end

function ReadingInsightsPopup:onTapClose()
    if self.readonly then return true end
    UIManager:close(self)
    return true
end

function ReadingInsightsPopup:onCloseWidget()
    self._closed = true
    if self.scroll_container then
        self.scroll_container:free()
    end
    if VS.readFullRefreshSetting() then
        UIManager:setDirty(nil, "full")
    else
        UIManager:setDirty(nil, "ui")
    end
end

-- The book-list popups replace this popup and reopen it when they close, so
-- they need the class and a few of the helpers defined above. Registering
-- them here (rather than having booklist_view.lua require this file back)
-- keeps the dependency one-way.
Heatmap.bind{
    getCachedFonts = getCachedFonts,
    parseDateYMD   = Data.parseDateYMD,
}

BookList.bind{
    popup_class             = ReadingInsightsPopup,
    getFinishedBooksForYear = Data.getFinishedBooksForYear,
    formatHHMMSS            = formatHHMMSS,
}

-- Module export.
--
-- Just the Popup class main.lua instantiates on demand. The setting
-- accessors that used to be re-exported from here now live in
-- lib/insights_settings.lua, which main.lua loads itself and hands to this
-- file - so the Tools-menu entries read and write exactly the same
-- functions this view does, without the view having to pass them through.
-- The year shelf without an insights window under it - the sleep screen shows
-- it on its own (lib/sleepscreen.lua). opts: ui, year (default: this year),
-- readonly. Returns the shelf window, nil when there is no shelf module.
local function openYearShelf(opts)
    if not YearShelf then return nil end
    opts = opts or {}
    local year_range
    pcall(function() year_range = Data.getYearRange() end)
    local year = tonumber(opts.year) or tonumber(os.date("%Y"))
    if year_range and year_range.min_year and year_range.max_year then
        year = math.max(year_range.min_year, math.min(year_range.max_year, year))
    end
    return YearShelf.show{
        ui         = opts.ui,
        year       = year,
        year_range = year_range,
        readonly   = opts.readonly,
        getBooks   = function(y, finished_only)
            if finished_only then
                return getFinishedBooksForYearCombined(nil, y)
            end
            return Data.getBooksForPeriod("%Y", tostring(y))
        end,
    }
end

return {
    showYearShelf = openYearShelf,
    Popup = ReadingInsightsPopup,
    -- Open the combined current/best streak popup straight from the menu.
    showStreaks = function()
        Streak.show(Data.calculateStreaks())
    end,
}
