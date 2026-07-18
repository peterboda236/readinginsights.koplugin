--[[
Reading Insights - the reading heatmaps.

Both heatmaps the insights popup shows, and the full-screen popup they open
into:

  - the calendar-style range heatmap (one cell per day, weekday rows,
    3/4/6-month periods that can be paged back through), and
  - the day-part heatmap (weekday x hour-of-day), which answers "when in the
    day do I actually read".

Plus the pieces they share: the level -> colour mapping, the legend, the
cell and weekday-label builders, and the period arithmetic behind the
paging.

Split out of insights_view.lua, which was carrying this, the 8-week trend
popup and the book lists inside one 5000-line file. The view still builds
the two heatmap *sections* on its own page - it calls the widget builders
here and passes in the data it queried - while the full-screen version lives
here entirely.

  M.buildRangeHeatmapWidget(...) / M.buildDayPartHeatmapWidget(...)
                                the two widgets, for the insights page
  M.buildHeatmapSectionHeader(...) / M.buildHeatmapBoxContent(...)
                                their section chrome
  M.getHeatmapPeriodRange(...) / M.heatmapMaxPeriodsBack(...)
                                which days a period covers, and how far back
                                paging can go
  M.Popup:new{ ... }      the full-screen version
]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Device = require("device")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

-- Shared modules, passed in as one table by main.lua. getCachedFonts and
-- parseDateYMD are handed over as plain functions rather than pulled from
-- the view: the view opens M.Popup, so a require back into the view
-- would be circular.
local deps = ...
local Colors, Fonts, Locale, VS, UI = deps.Colors, deps.Fonts, deps.Locale, deps.VS, deps.UI
local _ = Locale._

local M = {}

-- Filled in by M.bind() from insights_view.lua. The view opens M.Popup, so
-- reaching back into the view with a require would be circular; it hands
-- these two helpers over at load time instead.
local getCachedFonts, parseDateYMD

function M.bind(hooks)
    getCachedFonts = hooks.getCachedFonts
    parseDateYMD   = hooks.parseDateYMD
end

local MONTH_NAMES_SHORT = {
    _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
}

-- Adds/subtracts whole calendar months from a Y/M/D triple (relying on
-- os.time's normalisation of out-of-range month values - e.g. month=13
-- rolls over into January of the next year - same trick used elsewhere
-- in this file for date maths). Returns the shifted year/month/day plus
-- the resulting timestamp (noon, to stay clear of DST edge cases).
local function shiftMonths(year, month, day, delta)
    local t = os.time({ year = year, month = month + delta, day = day, hour = 12 })
    local dt = os.date("*t", t)
    return dt.year, dt.month, dt.day, t
end

-- Inclusive [start_t, end_t] timestamps (both at hour=12) for the
-- heatmap period `periods_back` periods before the current one, where a
-- period is VS.readHeatmapMonthsSetting() months long (3, 4 or 6 - see
-- Settings ▸ Advanced settings ▸ "Reading heatmap range"): period 0 is
-- that many months ending today, period 1 the same span before that,
-- and so on.
function M.getHeatmapPeriodRange(periods_back)
    local months_per_period = VS.readHeatmapMonthsSetting()
    local today = os.date("*t")
    local _, _, _, end_t     = shiftMonths(today.year, today.month, today.day, -months_per_period * periods_back)
    local sy, sm, sd         = shiftMonths(today.year, today.month, today.day, -months_per_period * (periods_back + 1))
    local start_t            = os.time({ year = sy, month = sm, day = sd + 1, hour = 12 })
    return start_t, end_t
end

-- How many heatmap periods back from the current one (0) still reach
-- into a month with recorded reading data, given the DB's oldest
-- year/month (getYearRange().min_year / .min_month - the calendar month
-- of the very first reading record, not just its year, so swiping back
-- stops exactly at that month instead of running to Jan 1st of that
-- year). Small loop (a handful of iterations for any realistic reading
-- history) rather than closed-form month maths, to stay in lockstep
-- with M.getHeatmapPeriodRange's own definition of a period boundary.
function M.heatmapMaxPeriodsBack(min_year, min_month)
    local min_period_start = os.time({ year = min_year, month = min_month, day = 1, hour = 12 })
    local periods_back = 0
    while periods_back < 200 do
        local _, next_end = M.getHeatmapPeriodRange(periods_back + 1)
        if next_end < min_period_start then break end
        periods_back = periods_back + 1
    end
    return periods_back
end

-- Lays [start_t, end_t] out into week columns starting on the configured
-- week start day (Settings ▸ Advanced settings ▸ "Week start day" - see
-- VS.weekStartWday), UI.padded at both ends so every column has a full 7 days
-- (leading/trailing days outside the period are kept but marked
-- in_range = false so they render as blank spacer cells rather than
-- colored squares).
function M.buildRangeHeatmapGrid(daily_map, start_t, end_t)
    local week_start_wd = VS.weekStartWday()          -- 0=Sun, 1=Mon
    local week_end_wd   = (week_start_wd + 6) % 7  -- last weekday of a row

    local start_wd    = tonumber(os.date("%w", start_t))  -- 0=Sun..6=Sat
    local start_offset = (start_wd - week_start_wd + 7) % 7  -- days back to week start
    local grid_start   = start_t - start_offset * 86400

    local end_wd      = tonumber(os.date("%w", end_t))
    local end_offset  = (week_end_wd - end_wd + 7) % 7  -- days forward to week end
    local grid_end    = end_t + end_offset * 86400

    local total_days = math.floor((grid_end - grid_start) / 86400) + 1
    local num_cols   = math.ceil(total_days / 7)

    local start_str = os.date("%Y-%m-%d", start_t)
    local end_str   = os.date("%Y-%m-%d", end_t)

    local cols = {}
    local t = grid_start
    for col = 1, num_cols do
        local col_days = {}
        for row = 1, 7 do
            local dstr = os.date("%Y-%m-%d", t)
            local d_year, d_month, d_day = parseDateYMD(dstr)
            local in_range = (dstr >= start_str and dstr <= end_str)
            col_days[row] = {
                in_range        = in_range,
                is_month_start  = (in_range and d_day == 1),
                month           = d_month,
                year            = d_year,
                seconds         = daily_map[dstr] or 0,
            }
            t = t + 86400
        end
        cols[col] = col_days
    end
    return cols, num_cols
end

-- Picks the shade for one day's seconds, relative to max_seconds (the
-- busiest single day anywhere in the period being shown).
function M.heatmapLevelColor(seconds, max_seconds)
    if not seconds or seconds <= 0 or not max_seconds or max_seconds <= 0 then
        return Colors.heatmap0()
    end
    local ratio = seconds / max_seconds
    if ratio <= 0.25 then return Colors.heatmap25() end
    if ratio <= 0.50 then return Colors.heatmap50() end
    if ratio <= 0.75 then return Colors.heatmap75() end
    return Colors.heatmap100()
end

-- A single heatmap square: a thin separator-colored frame with the level
-- color filled inside, built from two overlapping ColorBars (same trick
-- as everywhere else in this file that needs a solid-color rectangle -
-- see Colors.newBar) rather than a bordered FrameContainer, so it keeps
-- working with the RGB32 custom-color patch documented in colors.lua.
local function buildHeatmapCell(cell_size, border, fill_color)
    local inner_size = cell_size - 2 * border
    if inner_size < 1 then inner_size = cell_size end
    return OverlapGroup:new{
        dimen = Geom:new{ w = cell_size, h = cell_size },
        Colors.newBar(cell_size, cell_size, Colors.separator()),
        CenterContainer:new{
            dimen = Geom:new{ w = cell_size, h = cell_size },
            Colors.newBar(inner_size, inner_size, fill_color),
        },
    }
end

-- Mon/Wed/Fri labels run down the left side of both heatmap grids, three
-- rows apart, same as GitHub's contribution graph (the in-between rows
-- get no label). Which row each label lands on depends on the configured
-- week start day (Settings ▸ Advanced settings ▸ "Week start day"): row 1
-- is Monday when weeks start on Monday (labels on rows 1/3/5), or Sunday
-- when weeks start on Sunday (labels shift down a row, to rows 2/4/6).
-- Shared by the calendar heatmap (M.buildRangeHeatmapWidget) and the
-- time-of-day heatmap (M.buildDayPartHeatmapWidget) below, so both grids
-- use identical labels/rows.
local function getWeekdayRowLabels()
    if VS.readWeekStartSetting() == "sunday" then
        return { [2] = _("Mon"), [4] = _("Wed"), [6] = _("Fri") }
    end
    return { [1] = _("Mon"), [3] = _("Wed"), [5] = _("Fri") }
end

-- Width of the fixed-width weekday-label column - sized to the widest of
-- the three weekday-row-label strings in the given font - reserved
-- before sizing either grid, so the cells still fit within max_width.
local function getWeekdayLabelWidth(fonts)
    local wd_label_w = 0
    for _, text in pairs(getWeekdayRowLabels()) do
        local tw = TextWidget:new{ text = text, face = fonts.small }
        wd_label_w = math.max(wd_label_w, tw:getSize().w)
        tw:free()
    end
    return wd_label_w
end

-- Builds the month-start label row + the 7-row/num_cols-column grid for
-- [start_t, end_t]. Returns the combined widget plus the cell_size
-- actually used (so the legend below can draw matching squares).
function M.buildRangeHeatmapWidget(daily_map, start_t, end_t, fonts, max_width)
    local cols, num_cols = M.buildRangeHeatmapGrid(daily_map, start_t, end_t)

    local gap     = Screen:scaleBySize(2)
    -- Vertical gap between grid rows - clearly wider than the horizontal
    -- gap between columns (gap) so the rows read as visually distinct
    -- bands rather than a near-continuous block, matching how the column
    -- gaps already separate the day squares side by side. A flat
    -- scaleBySize value (not a multiple of the tiny 2px column gap) so
    -- it stays clearly visible even on high-density screens.
    local row_gap = Screen:scaleBySize(2)
    local border  = Size.line.thin

    local wd_label_w = getWeekdayLabelWidth(fonts)

    local grid_width = max_width - wd_label_w - gap
    local cell_size = math.floor((grid_width - (num_cols - 1) * gap) / num_cols)
    local min_cell   = Screen:scaleBySize(8)
    -- No upper cap: for shorter heatmap ranges (fewer columns - see
    -- Settings ▸ Advanced settings ▸ "Reading heatmap range"), the cells
    -- grow proportionally to use the full available width instead of
    -- leaving empty space to the right of a small fixed-size grid.
    if cell_size < min_cell then cell_size = min_cell end

    local max_seconds = 0
    for _, col_days in ipairs(cols) do
        for _, d in ipairs(col_days) do
            if d.in_range and d.seconds > max_seconds then max_seconds = d.seconds end
        end
    end

    -- Month-start labels, one slot per column (same width/gap as the
    -- grid below it so the label lines up with the column it belongs to).
    -- Starts with a spacer matching the weekday label column + gap so it
    -- lines up with the grid, which is shifted right by that same amount.
    local sample_label = TextWidget:new{ text = "Xxx", face = fonts.small }
    local label_h = sample_label:getSize().h
    sample_label:free()

    -- First pass: which column (if any) gets a month-start label, same
    -- one-per-month logic as before, but split out from widget-building
    -- so the second pass can also see Dec->Jan boundaries ahead of time.
    local month_label_col = {}   -- col -> { month = n, year = n }
    local last_month_labeled = nil
    for col = 1, num_cols do
        for _, d in ipairs(cols[col]) do
            if d.is_month_start and d.month ~= last_month_labeled then
                month_label_col[col] = { month = d.month, year = d.year }
                last_month_labeled = d.month
                break
            end
        end
    end

    -- Slot a "YYYY" year label into the gap between a December label
    -- and the January label that follows it, so the year is visible
    -- right where the row rolls over into a new one (e.g. "... Dec.
    -- 2026 Jan. Febr. ..."). Spans and centers within *all* the free
    -- columns between the two labels (not just one), since "Dec." and
    -- "Jan." are each wider than a single column and would otherwise
    -- get overlapped by a lopsided year label. If there's no free
    -- column at all between them, the year is prefixed onto the
    -- January label instead ("2026 Jan.") so it's never lost.
    local year_label_span = nil   -- { start_col, end_col, text }
    local prev_col, prev_month = nil, nil
    for col = 1, num_cols do
        local d = month_label_col[col]
        if d then
            if d.month == 1 and prev_month == 12 then
                local free_cols = col - prev_col - 1
                if free_cols >= 1 then
                    year_label_span = { start_col = prev_col + 1, end_col = col - 1, text = tostring(d.year) }
                else
                    d.combined = tostring(d.year) .. " " .. MONTH_NAMES_SHORT[d.month]
                end
            end
            prev_col, prev_month = col, d.month
        end
    end

    local labels_row = HorizontalGroup:new{ align = "bottom" }
    table.insert(labels_row, HorizontalSpan:new{ width = wd_label_w + gap })
    local col = 1
    while col <= num_cols do
        if year_label_span and col == year_label_span.start_col then
            local span_cols = year_label_span.end_col - year_label_span.start_col + 1
            local span_w    = span_cols * cell_size + (span_cols - 1) * gap

            -- Plain centering puts the label closer to "Dec." than to
            -- "Jan.": "Dec." is drawn from its own column and overflows
            -- rightward past that column's width, eating into the left
            -- side of this gap, while "Jan." doesn't reach backward into
            -- it at all. Nudge the centering right by that overflow so
            -- the label reads as visually centered between the two.
            local dec_label = TextWidget:new{ text = MONTH_NAMES_SHORT[12], face = fonts.small }
            local dec_overflow = math.max(0, dec_label:getSize().w - cell_size)
            dec_label:free()

            local year_widget = TextWidget:new{ text = year_label_span.text, face = fonts.small, fgcolor = Colors.label() }
            local text_w = year_widget:getSize().w
            if dec_overflow > span_w - text_w then dec_overflow = math.max(0, span_w - text_w) end
            local left_pad  = dec_overflow + math.floor((span_w - text_w - dec_overflow) / 2)
            if left_pad < 0 then left_pad = 0 end
            local right_pad = span_w - text_w - left_pad
            if right_pad < 0 then right_pad = 0 end

            table.insert(labels_row, HorizontalGroup:new{
                HorizontalSpan:new{ width = left_pad },
                year_widget,
                HorizontalSpan:new{ width = right_pad },
            })
            col = year_label_span.end_col + 1
        else
            local widget = nil
            local d = month_label_col[col]
            if d then
                widget = TextWidget:new{ text = d.combined or MONTH_NAMES_SHORT[d.month],
                    face = fonts.small, fgcolor = Colors.small() }
            end
            if widget then
                table.insert(labels_row, LeftContainer:new{
                    dimen = Geom:new{ w = cell_size, h = label_h },
                    widget,
                })
            else
                table.insert(labels_row, HorizontalSpan:new{ width = cell_size })
            end
            col = col + 1
        end
        if col <= num_cols then
            table.insert(labels_row, HorizontalSpan:new{ width = gap })
        end
    end

    -- 7-row grid, week start day (row 1) at the top through the last day
    -- of the week (row 7) - see VS.weekStartWday/M.buildRangeHeatmapGrid - each
    -- row prefixed with its weekday label slot (blank unless it's one of
    -- the getWeekdayRowLabels rows).
    --
    -- Row widgets + row_gap spans are appended directly as top-level
    -- children of `widget` below (not wrapped in their own nested
    -- VerticalGroup) - on-device testing showed VerticalSpans nested
    -- two VerticalGroups deep were rendering with zero height (rows
    -- stacked flush with no visible gap) even though the exact same
    -- VerticalSpan pattern between labels_row and the row widgets one
    -- level up rendered correctly. Flattening avoids the nested case
    -- entirely.
    local row_labels = getWeekdayRowLabels()
    local widget = VerticalGroup:new{
        align = "left",
        labels_row,
        VerticalSpan:new{ height = Size.padding.small },
    }
    for row = 1, 7 do
        local row_group = HorizontalGroup:new{ align = "center" }
        local wd_text = row_labels[row]
        if wd_text then
            table.insert(row_group, LeftContainer:new{
                dimen = Geom:new{ w = wd_label_w, h = cell_size },
                TextWidget:new{ text = wd_text, face = fonts.small, fgcolor = Colors.small() },
            })
        else
            table.insert(row_group, HorizontalSpan:new{ width = wd_label_w })
        end
        table.insert(row_group, HorizontalSpan:new{ width = gap })

        for col = 1, num_cols do
            local d = cols[col][row]
            if d.in_range then
                table.insert(row_group,
                    buildHeatmapCell(cell_size, border, M.heatmapLevelColor(d.seconds, max_seconds)))
            else
                table.insert(row_group, HorizontalSpan:new{ width = cell_size })
            end
            if col < num_cols then
                table.insert(row_group, HorizontalSpan:new{ width = gap })
            end
        end
        table.insert(widget, row_group)
        if row < 7 then
            table.insert(widget, VerticalSpan:new{ width = row_gap })
        end
    end

    -- cell_size and the wd_label_w + gap offset (where the first day
    -- column starts) are both handed back so the legend built below can
    -- match the grid exactly, however it's currently sized (see
    -- M.buildHeatmapLegendWidget).
    return widget, cell_size, wd_label_w + gap
end

-- Formats hour `h` (0-23) as a column label, honouring Settings ▸ Advanced
-- settings ▸ "Heatmap hour format": "24" -> "00".."23", "12" -> "12a",
-- "3a", ..., "9p" (compact AM/PM, since these labels only get a single
-- cell-width slot every 3 columns). Independent of the interface language.
local function formatHeatmapHourLabel(h)
    if VS.readHeatmapHourFormatSetting() == "12" then
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        local suffix = h < 12 and "AM" or "PM"
        return tostring(h12) .. suffix
    end
    return string.format("%02d", h)
end

-- Maps time-of-day-heatmap grid row (1-7) to the weekday index used by
-- weekday_hour_map (1 = Monday .. 7 = Sunday, see
-- ReadingInsightsPopup:getWeekdayHourReadingData), honouring the
-- configured week start day: Monday-first keeps rows 1-7 = Mon-Sun as-is;
-- Sunday-first shifts to rows 1-7 = Sun, Mon, ..., Sat.
local function weekdayRowOrder()
    if VS.readWeekStartSetting() == "sunday" then
        return { 7, 1, 2, 3, 4, 5, 6 }
    end
    return { 1, 2, 3, 4, 5, 6, 7 }
end

-- Builds the hour-of-day label row + the 7-row/24-column "time of day"
-- grid: one column per hour (0-23), one row per weekday (order and start
-- day set by Settings ▸ Advanced settings ▸ "Week start day" - see
-- weekdayRowOrder/getWeekdayRowLabels; hour labels honour "Heatmap hour
-- format" - see formatHeatmapHourLabel), each cell shaded by total
-- reading time in that weekday+hour slot relative to the busiest slot
-- anywhere in the grid. weekday_hour_map is { [1..7] = { [0..23] =
-- seconds } }, 1 = Monday (see ReadingInsightsPopup:getWeekdayHourReadingData).
-- Returns the combined widget plus the wd_label_w + gap offset (where the
-- first hour column starts), same shape as M.buildRangeHeatmapWidget's own
-- return, so the legend below can be pinned to whichever of the two
-- grids it should align with.
function M.buildDayPartHeatmapWidget(weekday_hour_map, fonts, max_width)
    local num_cols = 24
    local gap      = Screen:scaleBySize(2)
    -- Vertical gap between grid rows - same fixed, clearly-visible value
    -- as M.buildRangeHeatmapWidget's own row_gap above, so the two
    -- heatmaps look consistent.
    local row_gap  = Screen:scaleBySize(2)
    local border   = Size.line.thin

    local wd_label_w = getWeekdayLabelWidth(fonts)

    local grid_width = max_width - wd_label_w - gap
    local cell_size   = math.floor((grid_width - (num_cols - 1) * gap) / num_cols)
    local min_cell    = Screen:scaleBySize(8)
    if cell_size < min_cell then cell_size = min_cell end

    local max_seconds = 0
    for wd = 1, 7 do
        for h = 0, 23 do
            local secs = weekday_hour_map[wd][h] or 0
            if secs > max_seconds then max_seconds = secs end
        end
    end

    -- Hour labels every 3 columns ("00", "03", ... "21" in 24-hour format,
    -- or "12a", "3a", ... "9p" in 12-hour format - see
    -- formatHeatmapHourLabel/Settings ▸ Advanced settings ▸ "Heatmap hour
    -- format"), same slot width as the grid below so each label lines up
    -- with its column, prefixed with a spacer matching the weekday-label
    -- column + gap.
    local sample_label = TextWidget:new{ text = "00", face = fonts.small }
    local label_h = sample_label:getSize().h
    sample_label:free()

    local labels_row = HorizontalGroup:new{ align = "bottom" }
    table.insert(labels_row, HorizontalSpan:new{ width = wd_label_w + gap })
    for h = 0, num_cols - 1 do
        if h % 3 == 0 then
            table.insert(labels_row, LeftContainer:new{
                dimen = Geom:new{ w = cell_size, h = label_h },
                TextWidget:new{ text = formatHeatmapHourLabel(h), face = fonts.small, fgcolor = Colors.small() },
            })
        else
            table.insert(labels_row, HorizontalSpan:new{ width = cell_size })
        end
        if h < num_cols - 1 then
            table.insert(labels_row, HorizontalSpan:new{ width = gap })
        end
    end

    local row_order = weekdayRowOrder()
    local row_labels = getWeekdayRowLabels()

    -- Row widgets + row_gap spans appended directly as top-level children
    -- of this VerticalGroup (not a separately nested one) - see the long
    -- comment in M.buildRangeHeatmapWidget above for why: VerticalSpans
    -- nested two VerticalGroups deep rendered with zero height on-device.
    local widget = VerticalGroup:new{
        align = "left",
        labels_row,
        VerticalSpan:new{ height = Size.padding.small },
    }
    for row = 1, 7 do
        local wd = row_order[row]
        local row_group = HorizontalGroup:new{ align = "center" }
        local wd_text = row_labels[row]
        if wd_text then
            table.insert(row_group, LeftContainer:new{
                dimen = Geom:new{ w = wd_label_w, h = cell_size },
                TextWidget:new{ text = wd_text, face = fonts.small, fgcolor = Colors.small() },
            })
        else
            table.insert(row_group, HorizontalSpan:new{ width = wd_label_w })
        end
        table.insert(row_group, HorizontalSpan:new{ width = gap })

        for h = 0, num_cols - 1 do
            local secs = weekday_hour_map[wd][h] or 0
            table.insert(row_group, buildHeatmapCell(cell_size, border, M.heatmapLevelColor(secs, max_seconds)))
            if h < num_cols - 1 then
                table.insert(row_group, HorizontalSpan:new{ width = gap })
            end
        end
        table.insert(widget, row_group)
        if row < 7 then
            table.insert(widget, VerticalSpan:new{ width = row_gap })
        end
    end

    return widget, wd_label_w + gap
end

-- Color legend for the reading heatmap: a "Less" label, the same five
-- shades used by the grid squares above (see M.heatmapLevelColor /
-- Colors.heatmap0..100), and a "More" label - so it's clear at a glance
-- which end of the scale a given square's color falls on. The swatches
-- are sized as a fraction of the heatmap's own month/weekday label text
-- height (fonts.small - see the "Xxx" sample-label measurement in
-- M.buildRangeHeatmapWidget above, done the same way here) rather than a
-- fixed pixel value, so if the user changes that font's size in the
-- Fonts settings, the legend swatches scale along with it - but at
-- SWATCH_SIZE_RATIO of that height, so they stay visibly smaller than
-- the label text (and the grid's own cells) instead of matching it
-- 1-for-1. They're spaced apart from each other by Size.padding.small.
-- The whole row starts at left_offset, the same x position as the
-- grid's first day column, so it always lines up with the heatmap above
-- it regardless of how many months are currently shown.
local SWATCH_SIZE_RATIO = 0.55

function M.buildHeatmapLegendWidget(fonts, left_offset)
    local label_gap    = Screen:scaleBySize(2)
    local swatch_gap    = Size.padding.small
    local border        = Size.line.thin

    local less_label = TextWidget:new{ text = _("Less"), face = fonts.small, fgcolor = Colors.small() }

    local sample_label = TextWidget:new{ text = "Xxx", face = fonts.small }
    local label_h = sample_label:getSize().h
    sample_label:free()
    local swatch_size = math.max(Screen:scaleBySize(6), math.floor(label_h * SWATCH_SIZE_RATIO))

    local swatch_colors = {
        Colors.heatmap0(), Colors.heatmap25(), Colors.heatmap50(),
        Colors.heatmap75(), Colors.heatmap100(),
    }

    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, HorizontalSpan:new{ width = left_offset })
    table.insert(row, less_label)
    table.insert(row, HorizontalSpan:new{ width = label_gap })
    for i, color in ipairs(swatch_colors) do
        table.insert(row, buildHeatmapCell(swatch_size, border, color))
        if i < #swatch_colors then
            table.insert(row, HorizontalSpan:new{ width = swatch_gap })
        end
    end
    table.insert(row, HorizontalSpan:new{ width = label_gap })
    table.insert(row, TextWidget:new{ text = _("More"), face = fonts.small, fgcolor = Colors.small() })
    return row
end

-- Builds the box_content (title + grid + legend) for the
-- "Reading heatmap" popup showing the half-year period `periods_back`
-- half-years before the current one (0 = most recent, ending today - see
-- M.getHeatmapPeriodRange). The title shows just the year, or a "start–end"
-- year range if the period spans a Dec/Jan boundary. Also returns
-- whether an older/newer period exists, so M.Popup can gate
-- swipe navigation.
-- Section header for the calendar heatmap grid, with optional ‹ / ›
-- paging arrows at the left/right edges when there's an older/newer
-- half-year to page to - same layout/style as book_stats_view.lua's own
-- buildBookCalendarHeader (BookCalendarPopup's month header), so the
-- paging controls look consistent across both popups. Both arrow slots
-- are always reserved at their full width, whether or not that arrow is
-- actually visible - see buildBookCalendarHeader's own comment: without
-- this, the title jumps sideways whenever an arrow appears/disappears
-- while paging (e.g. hitting the oldest available half-year).
function M.buildHeatmapSectionHeader(title_str, content_width, section_font, prev_available, next_available)
    local arrow_pad = Size.padding.default

    local left_glyph_w  = TextWidget:new{ text = "\xe2\x80\xb9", face = section_font }:getSize().w
    local right_glyph_w = TextWidget:new{ text = "\xe2\x80\xba", face = section_font }:getSize().w
    local slot_w = math.max(left_glyph_w, right_glyph_w) + 2 * arrow_pad

    local function makeArrow(glyph, visible)
        if not visible then
            return HorizontalSpan:new{ width = slot_w }, nil
        end
        local tw = TextWidget:new{ text = glyph, face = section_font, fgcolor = Colors.section() }
        local extra = slot_w - 2 * arrow_pad - tw:getSize().w
        local frame = FrameContainer:new{
            background     = nil,
            bordersize     = 0,
            padding_top    = 0,
            padding_bottom = 0,
            padding_left   = arrow_pad + math.floor(extra / 2),
            padding_right  = arrow_pad + math.ceil(extra / 2),
            margin         = 0,
            tw,
        }
        return frame, frame
    end

    local left_widget,  left_frame  = makeArrow("\xe2\x80\xb9", prev_available)
    local right_widget, right_frame = makeArrow("\xe2\x80\xba", next_available)

    local title_w = TextWidget:new{ text = title_str, face = section_font, fgcolor = Colors.section() }

    local remaining = content_width - left_widget:getSize().w - right_widget:getSize().w - title_w:getSize().w
    if remaining < 0 then remaining = 0 end
    local side_l = math.floor(remaining / 2)
    local side_r = remaining - side_l

    local header_row = HorizontalGroup:new{
        align = "center",
        left_widget,
        HorizontalSpan:new{ width = side_l },
        title_w,
        HorizontalSpan:new{ width = side_r },
        right_widget,
    }

    return header_row, left_frame, right_frame, left_widget:getSize().w, right_widget:getSize().w, header_row:getSize().h
end

function M.buildHeatmapBoxContent(popup_self, periods_back)
    local start_t, end_t = M.getHeatmapPeriodRange(periods_back)
    local daily_map        = popup_self:getDailyReadingDataForRange(start_t, end_t)
    local weekday_hour_map = popup_self:getWeekdayHourReadingData(start_t, end_t)

    local fonts = getCachedFonts()
    local inner_padding = Size.padding.large
    local box_width      = math.floor(Screen:getWidth() * 0.94)
    local content_width  = box_width - 2 * inner_padding

    -- Older/newer availability, needed up front now (not just at the end)
    -- since the calendar heatmap's own header needs it to decide whether
    -- to show its ‹ / › paging arrows.
    local year_range      = popup_self:getYearRange()
    local older_available = periods_back < M.heatmapMaxPeriodsBack(year_range.min_year, year_range.min_month)
    local newer_available = periods_back > 0

    -- Small helper: a centered section header (same font/color as every
    -- other section header in this file) above one of the two grids.
    local function sectionTitle(text)
        local w = TextWidget:new{ text = text, face = fonts.section, fgcolor = Colors.section() }
        return CenterContainer:new{
            dimen = Geom:new{ w = content_width, h = w:getSize().h }, w,
        }
    end

    -- Blank row between the two grids, the height of a (blank) section
    -- header - no visible line, just the same cushion of space that used
    -- to sit around the separator line, so removing the line doesn't
    -- also shrink the gap between the two heatmaps.
    local function sectionSeparator()
        local sample = TextWidget:new{ text = "", face = fonts.section }
        local row_h = sample:getSize().h
        sample:free()
        return VerticalSpan:new{ height = row_h }
    end

    -- Each grid ends up centered (as a block) within content_width rather
    -- than flush against the box's left edge. Wrapping it in a same-width
    -- (the grid's own width) left-aligned box before handing it to the
    -- outer, center-aligned VerticalGroup below keeps its internal
    -- column/row labels lined up with themselves - it doesn't need to
    -- match the *other* grid's width, since the two are visually
    -- independent sections (the legend below is pinned to the
    -- time-of-day grid specifically - see day_part_left_offset below).
    local function matchOwnWidth(widget)
        if not widget then return nil end
        return LeftContainer:new{
            dimen = Geom:new{ w = widget:getSize().w, h = widget:getSize().h },
            widget,
        }
    end

    -- Year is shown inline in the calendar grid's own label row (see
    -- M.buildRangeHeatmapWidget) when the period crosses a Dec/Jan
    -- boundary; no separate subtitle needed here, even for periods that
    -- stay within one year.
    local calendar_widget = M.buildRangeHeatmapWidget(daily_map, start_t, end_t, fonts, content_width)

    local day_part_widget, day_part_left_offset =
        M.buildDayPartHeatmapWidget(weekday_hour_map, fonts, content_width)

    -- The shared legend/caption is pinned to the time-of-day grid
    -- specifically (not centered on its own): wrapping it in a box the
    -- same width as day_part_widget, with its own left_offset spacer
    -- (weekday-label column + gap, same as M.buildDayPartHeatmapWidget's
    -- own internal grid), means it gets centered as a block by the same
    -- amount as that grid below - so the legend's first swatch starts
    -- exactly under the grid's first hour column.
    local legend_row = M.buildHeatmapLegendWidget(fonts, day_part_left_offset)
    local legend_widget = LeftContainer:new{
        dimen = Geom:new{ w = day_part_widget:getSize().w, h = legend_row:getSize().h },
        legend_row,
    }

    -- Calendar heatmap header: same title as before, now with ‹ / ›
    -- paging arrows at the edges (shown only when there's an older/newer
    -- half-year to page to - see older_available/newer_available above),
    -- styled like BookCalendarPopup's own month header (see
    -- M.buildHeatmapSectionHeader). cal_left_frame/cal_right_frame are nil
    -- when the corresponding arrow is hidden; M.Popup uses their
    -- presence (not .dimen) to decide whether to register a tap zone.
    local calendar_header, cal_left_frame, cal_right_frame, cal_left_w, cal_right_w, cal_header_h =
        M.buildHeatmapSectionHeader(_("Calendar heatmap"), content_width, fonts.section, older_available, newer_available)

    local content = VerticalGroup:new{
        align = "center",
        calendar_header,
        VerticalSpan:new{ height = Size.padding.large + Size.padding.default },
        matchOwnWidth(calendar_widget),
        VerticalSpan:new{ height = 2 * Size.padding.large },
        sectionSeparator(),
        VerticalSpan:new{ width = Size.padding.large * 2 },
        sectionTitle(_("Time of day heatmap")),
        VerticalSpan:new{ height = Size.padding.large + Size.padding.default },
        matchOwnWidth(day_part_widget),
        VerticalSpan:new{ height = 2 * Size.padding.large },
        legend_widget,
    }

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

    return box, older_available, newer_available,
        cal_left_frame, cal_right_frame, cal_left_w, cal_right_w, cal_header_h
end

-- Full-screen "Reading heatmap" popup, paginated in half-year steps.
-- Unlike the other full-screen popups in this file (Trend.Popup),
-- a single tap does close it, but swipe left/right pages between
-- half-year periods instead of closing (mirrors the main popup's own
-- swipe-to-change-year convention - see ReadingInsightsPopup:onSwipe),
-- and swipe down / any other key closes.
M.Popup = InputContainer:extend{
    modal        = true,
    popup_self   = nil,   -- the ReadingInsightsPopup, for data access
    periods_back = 0,     -- 0 = most recent half-year, ending today
}

function M.Popup:init()
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

    self:_rebuild()
end

function M.Popup:_rebuild()
    local box, older_available, newer_available, left_frame, right_frame, left_w, right_w, header_h =
        M.buildHeatmapBoxContent(self.popup_self, self.periods_back)
    self.box_content      = box
    self._older_available = older_available
    self._newer_available = newer_available
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.box_content,
    }

    -- Absolute tap zones for the calendar heatmap's ‹ / › paging arrows,
    -- computed from geometry (box position + inner padding) rather than
    -- from left_frame/right_frame.dimen - same reasoning as
    -- BookCalendarPopup's own _nav_zones in book_calendar_view.lua: a
    -- FrameContainer without an explicit width/height only gets .dimen
    -- populated once it's actually painted, so relying on it here could
    -- crash if the user pages again before the first paint tick.
    local inner_padding = Size.padding.large
    local border_w      = Size.border.window
    local box_rect       = self:_centeredRect(self.box_content)
    local content_width  = box_rect.w - 2 * border_w - 2 * inner_padding
    local header_x = box_rect.x + border_w + inner_padding
    local header_y = box_rect.y + border_w + inner_padding
    local tap_pad  = Screen:scaleBySize(14)

    self._nav_zones = {}
    if left_frame then
        table.insert(self._nav_zones, {
            dimen = Geom:new{
                x = header_x - tap_pad,
                y = header_y - tap_pad,
                w = left_w + 2 * tap_pad,
                h = header_h + 2 * tap_pad,
            },
            delta = 1, -- older
        })
    end
    if right_frame then
        table.insert(self._nav_zones, {
            dimen = Geom:new{
                x = header_x + content_width - right_w - tap_pad,
                y = header_y - tap_pad,
                w = right_w + 2 * tap_pad,
                h = header_h + 2 * tap_pad,
            },
            delta = -1, -- newer
        })
    end
end

-- Returns the screen rectangle a CenterContainer of size self.dimen
-- would actually paint the given child widget at - mirrors
-- CenterContainer's own centering math. Takes the widget itself (not
-- widget.dimen): a FrameContainer without an explicit width/height
-- (like box_content - see M.buildHeatmapBoxContent) only gets its .dimen
-- field populated as a side effect of actually being painted, so
-- relying on .dimen here crashes with a nil index if this runs before
-- the box has ever been drawn (e.g. the user swipes right after the
-- popup opens, before the first paint tick). getSize() computes the
-- size directly and safely, with no painting required.
function M.Popup:_centeredRect(widget)
    local size = widget:getSize()
    local w, h = size.w, size.h
    local x = self.dimen.x + math.floor((self.dimen.w - w) / 2)
    local y = self.dimen.y + math.floor((self.dimen.h - h) / 2)
    return Geom:new{ x = x, y = y, w = w, h = h }
end

function M.Popup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self:_centeredRect(self.box_content)
    end)
    return true
end

function M.Popup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self:_centeredRect(self.box_content)
    end)
end

-- delta: -1 = newer (toward today), +1 = older. No-op (but still
-- consumes the gesture) once there's nothing further in that direction.
function M.Popup:_goToPeriod(delta)
    if delta < 0 and not self._newer_available then return true end
    if delta > 0 and not self._older_available then return true end

    -- Remember where the box we're about to replace was actually drawn,
    -- so we can make sure that area gets a fresh repaint even if the
    -- new box (a different half-year can have a different number of
    -- calendar week-rows) ends up smaller and no longer covers it.
    local old_rect = self:_centeredRect(self.box_content)

    self.periods_back = self.periods_back + delta
    self:_rebuild()

    local new_rect = self:_centeredRect(self.box_content)
    local x1 = math.min(old_rect.x, new_rect.x)
    local y1 = math.min(old_rect.y, new_rect.y)
    local x2 = math.max(old_rect.x + old_rect.w, new_rect.x + new_rect.w)
    local y2 = math.max(old_rect.y + old_rect.h, new_rect.y + new_rect.h)
    local refresh_region = Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }

    -- "all" (rather than self) tells UIManager to repaint the *whole*
    -- window stack - including whatever sits behind this popup - for
    -- that region, not just this widget. That's what actually erases
    -- the old box's leftover edge where it stuck out past the new,
    -- smaller one, restoring whatever should show through there
    -- (instead of painting an opaque backdrop over the whole screen,
    -- which would lose the floating-popup look).
    UIManager:setDirty("all", function()
        return "ui", refresh_region
    end)
    return true
end

function M.Popup:onTap(arg, ges_ev)
    if ges_ev then
        local x, y = ges_ev.pos.x, ges_ev.pos.y
        for _, zone in ipairs(self._nav_zones or {}) do
            if zone.dimen and x >= zone.dimen.x and x <= zone.dimen.x + zone.dimen.w
               and y >= zone.dimen.y and y <= zone.dimen.y + zone.dimen.h then
                return self:_goToPeriod(zone.delta)
            end
        end
    end
    UIManager:close(self)
    return true
end

function M.Popup:onSwipe(arg, ges_ev)
    if not ges_ev then UIManager:close(self) return true end
    local dir = ges_ev.direction
    if dir == "west" or dir == "left"  then return self:_goToPeriod(-1) end
    if dir == "east" or dir == "right" then return self:_goToPeriod(1)  end
    UIManager:close(self)
    return true
end

function M.Popup:onAnyKeyPressed(_, key)
    if key and key:match({ { "RPgBack", "LPgBack", "Left"  } }) then return self:_goToPeriod(1)  end
    if key and key:match({ { "RPgFwd",  "LPgFwd",  "Right" } }) then return self:_goToPeriod(-1) end
    UIManager:close(self)
    return true
end

return M
