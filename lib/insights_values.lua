--[[
Reading Insights - the values the Reading insights popup shows.

Worked out once for both looks (Classic in views/insights_view.lua, Cards in
views/cards_look/sections.lua), so the two always show the same numbers: each
function takes the loaded data and returns the texts to show, the look only
draws them. No widgets here, so it runs without KOReader's UI.

  Values.streakValues(streaks)
      -> cd_val, cd_unit, cw_val, cw_unit, bd_val, bd_unit, bw_val, bw_unit
  Values.yearlyValues(selected_year, mode, yearly_stats)
      -> left_value, left_unit, right_value, right_unit
  Values.weekData(cal_mode, cal, last_week_stats, last_week_daily)
      -> lw, week_daily, has_week
  Values.weekValues(lw)  -> total_secs, total_pages_raw, time_cells, pages_cells
  Values.weekDiff(lw, pages_mode, total_secs, total_pages_raw, days_n)
      -> diff_total, diff_avg
  Values.timeGoalValues(last_week_daily, week_start_wd)
      -> today_secs, week_secs, daily_goal_secs, weekly_goal_secs
  Values.timeGoalText(done, goal)            "0:23 / 0:30"
  Values.goalPercent(finished_count, goal_value)
  Values.goalPace(finished_count, goal_value, goal_year)  -> state, n
  Values.allTimeValues(all_time_stats)
      -> time_val, time_unit, pages_val, pages_unit
  Values.roundAvgPages(avg), Values.formatAvgPages(avg_rounded)
]]--

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, VS = deps.Locale, deps.VS

local _            = Locale._
local N_           = Locale.N_
local formatCount  = Locale.formatCount
local formatNumber = Locale.formatNumber
local splitDurationValueUnit = Locale.splitDurationValueUnit

local M = {}

-- Current / best streak in days and in weeks, as value + unit each:
-- cd_val, cd_unit, cw_val, cw_unit, bd_val, bd_unit, bw_val, bw_unit.
-- A streak shorter than 2 shows no number and "No streak". Compact units
-- ("days" / "weeks") so the days and weeks fit side by side in one column.
function M.streakValues(streaks)
    local function display(n, unit_label)
        if n < 2 then return "", _("No streak") end
        return formatCount(n), unit_label(n)
    end
    local function days(n)  return N_("day",  "days",  n) end
    local function weeks(n) return N_("week", "weeks", n) end
    local cd_val, cd_unit = display(streaks.current_days,  days)
    local cw_val, cw_unit = display(streaks.current_weeks, weeks)
    local bd_val, bd_unit = display(streaks.best_days,     days)
    local bw_val, bw_unit = display(streaks.best_weeks,    weeks)
    return cd_val, cd_unit, cw_val, cw_unit, bd_val, bd_unit, bw_val, bw_unit
end

-- A daily average of pages: whole pages from 10 up, one decimal below.
function M.roundAvgPages(avg)
    if avg >= 10 then
        return math.floor(avg + 0.5)
    end
    return math.floor(avg * 10 + 0.5) / 10
end

-- A rounded daily average of pages as text: the decimal only when there is one.
function M.formatAvgPages(avg_rounded)
    return formatNumber(avg_rounded, avg_rounded ~= math.floor(avg_rounded) and 1 or 0)
end

-- The year row for the popup's mode (time / pages / books / days):
-- left_value, left_unit, right_value, right_unit. `selected_year` nil = this
-- year. The daily averages and "of days read" divide by the days of the year
-- so far (the whole year once it is over).
function M.yearlyValues(selected_year, mode, yearly_stats)
    local current_year = tonumber(os.date("%Y"))
    selected_year = selected_year or current_year
    local days_in_year
    if selected_year == current_year then
        days_in_year = tonumber(os.date("%j"))
    else
        local is_leap = (selected_year % 4 == 0 and selected_year % 100 ~= 0)
                     or (selected_year % 400 == 0)
        days_in_year = is_leap and 366 or 365
    end

    local left_value, left_unit, right_value, right_unit
    if mode == VS.INSIGHTS_MODE_HOURS then
        local yr_secs = yearly_stats.duration or 0
        left_value, left_unit = splitDurationValueUnit(yr_secs, _("reading time"))
        local avg_secs = (days_in_year > 0) and (yr_secs / days_in_year) or 0
        right_value, right_unit = splitDurationValueUnit(avg_secs, _("daily avg time"))
    elseif mode == VS.INSIGHTS_MODE_PAGES then
        local pg = yearly_stats.pages or 0
        left_value = formatCount(pg)
        left_unit  = N_("page read", "pages read", pg)
        local avg_rounded = M.roundAvgPages((days_in_year > 0) and (pg / days_in_year) or 0)
        right_value = M.formatAvgPages(avg_rounded)
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
    return left_value, left_unit, right_value, right_unit
end

-- The week the "Last 7 days" section shows: the rolling last 7 days, or (the
-- calendar view) the calendar week `cal` being paged. Returns its stats, its
-- per-day rows and whether the section is shown - the calendar view always
-- is, even for a week without reading: its header pages to the other weeks.
function M.weekData(cal_mode, cal, last_week_stats, last_week_daily)
    local lw, week_daily
    if cal_mode then
        lw = (cal and cal.stats) or { avg_seconds = 0, avg_pages = 0, total_seconds = 0,
                                      total_pages = 0, days = 7, prev_seconds = 0, prev_pages = 0 }
        week_daily = cal and cal.daily or nil
    else
        lw = last_week_stats or { avg_seconds = 0, avg_pages = 0 }
        week_daily = last_week_daily
    end
    local has_week = cal_mode or lw.avg_seconds > 0 or lw.avg_pages > 0
    return lw, week_daily, has_week
end

-- The week's figures: total_secs, total_pages_raw (whole pages), and the two
-- rows of cells, each { total value, unit, metric, daily avg value, unit,
-- metric } - the metric is what a tap on that cell opens (8-week trend).
function M.weekValues(lw)
    local week_time_val, week_time_unit = splitDurationValueUnit(lw.avg_seconds or 0, _("daily avg time"))

    local avg_pages_rounded = M.roundAvgPages(lw.avg_pages)
    local week_pages_val  = M.formatAvgPages(avg_pages_rounded)
    local week_pages_unit = N_("daily avg page", "daily avg pages", avg_pages_rounded)

    local total_secs = lw.total_seconds or (lw.avg_seconds or 0) * 7
    local total_time_val, total_time_unit = splitDurationValueUnit(total_secs, _("reading time"))

    local total_pages_raw = math.floor((lw.total_pages or (lw.avg_pages or 0) * 7) + 0.5)
    local total_pages_val  = formatCount(total_pages_raw)
    local total_pages_unit = N_("page read", "pages read", total_pages_raw)

    local time_cells  = { total_time_val, total_time_unit, "time_total",
                          week_time_val, week_time_unit, "time_avg" }
    local pages_cells = { total_pages_val, total_pages_unit, "pages_total",
                          week_pages_val, week_pages_unit, "pages_avg" }
    return total_secs, total_pages_raw, time_cells, pages_cells
end

-- Change against the week before: diff_total (whole pages, or whole seconds
-- of reading time) and diff_avg (per day of the shown week). `total_secs` /
-- `total_pages_raw` are weekValues' totals, `days_n` the days of the week.
function M.weekDiff(lw, pages_mode, total_secs, total_pages_raw, days_n)
    local diff_total
    if pages_mode then
        diff_total = total_pages_raw - math.floor((lw.prev_pages or 0) + 0.5)
    else
        diff_total = math.floor(total_secs + 0.5) - math.floor((lw.prev_seconds or 0) + 0.5)
    end
    return diff_total, diff_total / days_n
end

-- Daily / weekly time goal: today_secs, week_secs (this calendar week so
-- far), daily_goal_secs, weekly_goal_secs. `last_week_daily` is the last 7
-- days, today first (a calendar week never reaches back more than 7 days);
-- `week_start_wd` the first day of the week (0 = Sunday).
function M.timeGoalValues(last_week_daily, week_start_wd)
    local daily_goal_secs  = VS.readDailyGoalMinutes()  * 60
    local weekly_goal_secs = VS.readWeeklyGoalMinutes() * 60

    local today_secs, week_secs = 0, 0
    if last_week_daily then
        local wday = tonumber(os.date("%w"))
        local days_into_week = (week_start_wd == 0) and wday or ((wday + 6) % 7)
        for i = 1, math.min(days_into_week + 1, #last_week_daily) do
            local secs = (last_week_daily[i] and last_week_daily[i].seconds) or 0
            week_secs = week_secs + secs
            if i == 1 then today_secs = secs end
        end
    end
    return today_secs, week_secs, daily_goal_secs, weekly_goal_secs
end

-- "0:23 / 0:30" (KOReader's "Duration format"), with a check mark once met.
function M.timeGoalText(done, goal)
    local txt = Locale.formatDuration(done, true) .. " / " .. Locale.formatDuration(goal, true)
    if goal > 0 and done >= goal then txt = txt .. "  \226\156\147" end  -- U+2713
    return txt
end

-- Finished books as a rounded percentage of the yearly goal (0 without a goal).
function M.goalPercent(finished_count, goal_value)
    if goal_value <= 0 then return 0 end
    return math.floor(finished_count / goal_value * 100 + 0.5)
end

-- Where the reading goal stands: "reached" / "not_reached" for a past year;
-- for this year "reached", "on_track", or "ahead" / "behind" plus the whole
-- books (floor) against the pace by day of the year - so "on_track" covers
-- less than a book either way. nil without a goal or for a future year.
function M.goalPace(finished_count, goal_value, goal_year)
    if goal_value <= 0 then return nil end
    local this_year = tonumber(os.date("%Y"))
    if goal_year < this_year then
        return finished_count >= goal_value and "reached" or "not_reached"
    end
    if goal_year ~= this_year then return nil end
    local leap = (goal_year % 4 == 0 and goal_year % 100 ~= 0) or (goal_year % 400 == 0)
    local expected = goal_value * tonumber(os.date("%j")) / (leap and 366 or 365)
    local diff = finished_count - expected
    local n = math.floor(math.abs(diff))
    if finished_count >= goal_value then return "reached" end
    if n == 0 then return "on_track" end
    return diff > 0 and "ahead" or "behind", n
end

-- All time: reading time (the hours when the exact duration is missing) and
-- pages read, as time_val, time_unit, pages_val, pages_unit.
function M.allTimeValues(all_time_stats)
    local all_hours = all_time_stats and all_time_stats.hours or 0
    local all_pages = all_time_stats and all_time_stats.pages or 0
    local all_secs = (all_time_stats and all_time_stats.duration) or (all_hours * 3600)
    local time_val, time_unit = splitDurationValueUnit(all_secs, _("reading time"))
    return time_val, time_unit, formatCount(all_pages), N_("page read", "pages read", all_pages)
end

return M
