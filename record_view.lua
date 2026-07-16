--[[
Records popup (record_view.lua)

Shows personal reading records and milestone progress:
  - Most reading time in a day  most total reading time on a single calendar
                                 day, across all books
  - Most pages in a day      most pages read on a single calendar day
  - Best daily streak        longest run of consecutive reading days
  - Fastest book finished    fewest calendar days from first to last page
  - Last milestone           highest total-hours milestone already passed
  - Next milestone           next total-hours milestone ahead

Milestone ladder (total reading hours):
  1 -> 5 -> 10 -> 25 -> 50 -> 100 -> 250 -> 500 -> 1000 -> 2500 -> 5000 -> 10000

Opened from:
  - Tools > Reading insights > Show Records
  - Gesture / Dispatcher action "reading_records_popup" (general - works in
    both Reader view and File manager, same as the main Insights popup,
    since none of this data is tied to a specific open book)
  - Tap anywhere / swipe down / any key to close

Shown as a floating, bordered card centered on screen (not a full-screen
overlay) - same convention as the streak-detail card in insights_view.lua's
WeeklyTrendPopup: an invisible full-screen tap-anywhere-to-close layer
hosts a content-sized FrameContainer card in the middle.

All user-facing strings are plain English source text, translated via the
shared L10N module (see l10n.lua + l10n/<lang>.po) - same pattern as
insights_view.lua and stats_view.lua.

Cache behaviour
---------------
On first open (or after a reset) the six queries run in full and the
results are written to a small Lua-table file next to statistics.sqlite3:
  readinginsights_records_cache.lua

On every subsequent open we compare the DB's current MAX(start_time) and
total row count against the values stored in the cache.

  • If both match  → use the cached values directly (zero SQL heavy lifting).
  • If only new rows exist (max start_time advanced or row count grew but the
    previously seen max start_time is still present in the DB) → run the
    lightweight incremental queries that only touch rows newer than the
    cached high-water mark, merge them with the stored totals, and rewrite
    the cache.
  • If the DB looks different in a way we can't reconcile (row count shrank,
    the old max timestamp disappeared – e.g. after a sync or manual delete)
    → fall back to a full recompute and rewrite the cache.

Only queryBestStreak and queryMilestoneDate cannot be made truly incremental
(streak continuity and cumulative-hours crossing require the full ordered
sequence).  For those two we cache the computed result and only re-run the
full query when new rows exist AND the new data could actually change the
cached value (streak: only if today's date is adjacent to the cached
end_date; milestone: only if total hours crossed a new threshold).
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer  = require("ui/widget/container/centercontainer")
local DataStorage     = require("datastorage")
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
local SQ3             = require("lua-ljsqlite3/init")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

-- Injected by main.lua (same pattern as insights_view.lua / stats_view.lua)
local L10N, Colors, Fonts = ...

local _ = L10N._
local N_ = L10N.N_
local formatCount = L10N.formatCount

-- ---------------------------------------------------------------------------
-- Milestone ladder (total reading hours)
-- ---------------------------------------------------------------------------
local MILESTONES = { 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }

-- ---------------------------------------------------------------------------
-- Row icons
-- ---------------------------------------------------------------------------
local ICONS = {
    session = "\xEF\x80\x97", -- U+F017 fa-clock
    pages   = "\xEF\x80\xAD", -- U+F02D fa-book
    streak  = "\xEF\x81\xAD", -- U+F06D fa-fire
    fastest = "\xEF\x83\xA7", -- U+F0E7 fa-bolt
    last_ms = "\xEF\x82\x91", -- U+F091 fa-trophy
    next_ms = "\xEF\x84\x9D", -- U+F11D fa-flag-o
}

-- ---------------------------------------------------------------------------
-- DB helpers
-- ---------------------------------------------------------------------------
local function dbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

local function cachePath()
    return DataStorage:getSettingsDir() .. "/readinginsights_records_cache.lua"
end

local function withStatsDb(fallback, fn)
    local lfs = require("libs/libkoreader-lfs")
    local path = dbPath()
    if lfs.attributes(path, "mode") ~= "file" then return fallback end
    local conn = SQ3.open(path)
    if not conn then return fallback end
    pcall(function()
        conn:exec("PRAGMA journal_mode=WAL; PRAGMA cache_size=2000; PRAGMA temp_store=MEMORY;")
    end)
    local ok, result = pcall(fn, conn)
    conn:close()
    if ok then return result end
    return fallback
end

local function withStatement(conn, sql, fn)
    local stmt = conn:prepare(sql)
    if not stmt then return end
    pcall(fn, stmt)
    stmt:close()
end

-- ---------------------------------------------------------------------------
-- Cache I/O
-- ---------------------------------------------------------------------------
-- Cache table fields:
--   hw_max_time  (integer) highest start_time seen when cache was written
--   hw_row_count (integer) total page_stat row count when cache was written
--   longest      { duration_sec, date }  -- most reading time in a day (all books)
--   best_day     { pages, date }
--   streak       { days, start_date, end_date }
--   fastest      { title, days, date, duration_sec }
--   total_secs   (integer)
--   last_ms_date (string|nil)

local function loadCache()
    local path = cachePath()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, result = pcall(function()
        local chunk = loadfile(path)
        if not chunk then return nil end
        return chunk()
    end)
    if ok and type(result) == "table" then return result end
    return nil
end

local function saveCache(c)
    local path = cachePath()
    local ok = pcall(function()
        local f = io.open(path, "w")
        if not f then return end
        f:write("return {\n")
        f:write(string.format("  hw_max_time  = %d,\n",  c.hw_max_time  or 0))
        f:write(string.format("  hw_row_count = %d,\n",  c.hw_row_count or 0))
        f:write(string.format("  total_secs   = %d,\n",  c.total_secs   or 0))
        -- most reading time in a day
        f:write(string.format("  longest_sec  = %d,\n",  c.longest.duration_sec or 0))
        local ld = c.longest.date
        if ld then f:write(string.format("  longest_date = %q,\n",  ld))
        else        f:write("  longest_date = false,\n") end
        -- best day
        f:write(string.format("  best_day_pages = %d,\n", c.best_day.pages or 0))
        local bd = c.best_day.date
        if bd then f:write(string.format("  best_day_date  = %q,\n", bd))
        else        f:write("  best_day_date  = false,\n") end
        -- streak
        f:write(string.format("  streak_days  = %d,\n",  c.streak.days or 0))
        local ss = c.streak.start_date
        local se = c.streak.end_date
        if ss then f:write(string.format("  streak_start = %q,\n", ss))
        else        f:write("  streak_start = false,\n") end
        if se then f:write(string.format("  streak_end   = %q,\n", se))
        else        f:write("  streak_end   = false,\n") end
        -- fastest
        local ft = c.fastest.title
        if ft then f:write(string.format("  fastest_title = %q,\n", ft))
        else        f:write("  fastest_title = false,\n") end
        local fd = c.fastest.days
        if fd then f:write(string.format("  fastest_days  = %d,\n", fd))
        else        f:write("  fastest_days  = false,\n") end
        local fdate = c.fastest.date
        if fdate then f:write(string.format("  fastest_date  = %q,\n", fdate))
        else          f:write("  fastest_date  = false,\n") end
        local fdur = c.fastest.duration_sec
        if fdur then f:write(string.format("  fastest_dur   = %d,\n", fdur))
        else          f:write("  fastest_dur   = false,\n") end
        -- milestone date
        local lmd = c.last_ms_date
        if lmd then f:write(string.format("  last_ms_date = %q,\n", lmd))
        else         f:write("  last_ms_date = false,\n") end
        f:write("}\n")
        f:close()
    end)
    return ok
end

local function cacheToData(c)
    -- Reconstruct the data tables from the flat cache fields
    return {
        longest  = { duration_sec = c.longest_sec or 0, date = c.longest_date or nil },
        best_day = { pages = c.best_day_pages or 0, date = c.best_day_date or nil },
        streak   = { days = c.streak_days or 0,
                     start_date = c.streak_start or nil,
                     end_date   = c.streak_end   or nil },
        fastest  = { title = c.fastest_title or nil,
                     days  = c.fastest_days  or nil,
                     date  = c.fastest_date  or nil,
                     duration_sec = c.fastest_dur or nil },
        total_secs  = c.total_secs or 0,
        last_ms_date = c.last_ms_date or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Date helpers
-- ---------------------------------------------------------------------------
local MONTH_KEYS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function formatDate(date_str)
    if not date_str then return "" end
    local y, m, d = date_str:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return date_str end
    local mi = tonumber(m) or 1
    local month_name = _(MONTH_KEYS[mi] or "Jan")
    return month_name .. " " .. tonumber(d) .. "."
end

local function dateDiffDays(a, b)
    local function toTime(s)
        local y, mo, d = s:match("^(%d+)-(%d+)-(%d+)$")
        return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
    end
    return math.floor((toTime(b) - toTime(a)) / 86400 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Full queries (run when cache is absent or invalid)
-- ---------------------------------------------------------------------------
local function fullQueryMostReadingTimeDay(conn)
    local result = { duration_sec = 0, date = nil }
    withStatement(conn, [[
        SELECT date(start_time, 'unixepoch', 'localtime') AS day,
               SUM(duration) AS day_dur
        FROM page_stat
        GROUP BY day
        ORDER BY day_dur DESC
        LIMIT 1
    ]], function(stmt)
        for row in stmt:rows() do
            result.duration_sec = tonumber(row[2]) or 0
            result.date         = row[1]
        end
    end)
    return result
end

local function fullQueryMostPagesDay(conn)
    local result = { pages = 0, date = nil }
    withStatement(conn, [[
        SELECT date(start_time, 'unixepoch', 'localtime') AS day,
               COUNT(DISTINCT id_book || '-' || page) AS page_count
        FROM page_stat
        GROUP BY day
        ORDER BY page_count DESC
        LIMIT 1
    ]], function(stmt)
        for row in stmt:rows() do
            result.pages = tonumber(row[2]) or 0
            result.date  = row[1]
        end
    end)
    return result
end

local function fullQueryBestStreak(conn)
    local dates = {}
    withStatement(conn, [[
        SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d
        FROM page_stat ORDER BY d ASC
    ]], function(stmt)
        for row in stmt:rows() do
            table.insert(dates, row[1])
        end
    end)
    if #dates == 0 then return { days = 0, start_date = nil, end_date = nil } end

    local best_len, best_start, best_end = 1, dates[1], dates[1]
    local cur_len, cur_start = 1, dates[1]

    for i = 2, #dates do
        if dateDiffDays(dates[i-1], dates[i]) == 1 then
            cur_len = cur_len + 1
            if cur_len > best_len then
                best_len   = cur_len
                best_start = cur_start
                best_end   = dates[i]
            end
        else
            cur_len   = 1
            cur_start = dates[i]
        end
    end
    return { days = best_len, start_date = best_start, end_date = best_end }
end

local function fullQueryFastestBook(conn)
    local result = { title = nil, days = nil, date = nil, duration_sec = nil }
    withStatement(conn, [[
        SELECT b.title,
               julianday(date(MAX(ps.start_time), 'unixepoch', 'localtime')) -
               julianday(date(MIN(ps.start_time), 'unixepoch', 'localtime')) + 1 AS days_span,
               date(MAX(ps.start_time), 'unixepoch', 'localtime') AS finish_date,
               SUM(ps.duration) AS total_dur
        FROM page_stat ps
        JOIN book b ON ps.id_book = b.id
        WHERE b.pages > 0
        GROUP BY ps.id_book
        HAVING MAX(ps.page) >= b.pages
        ORDER BY days_span ASC, total_dur ASC
        LIMIT 1
    ]], function(stmt)
        for row in stmt:rows() do
            result.title        = row[1]
            result.days         = math.floor(tonumber(row[2]) or 1)
            result.date         = row[3]
            result.duration_sec = tonumber(row[4]) or 0
        end
    end)
    return result
end

local function fullQueryTotalSecs(conn)
    local total = 0
    withStatement(conn, "SELECT SUM(duration) FROM page_stat", function(stmt)
        for row in stmt:rows() do total = tonumber(row[1]) or 0 end
    end)
    return total
end

local function fullQueryMilestoneDate(conn, threshold_hours)
    if not threshold_hours then return nil end
    local cumulative = 0
    local result = nil
    withStatement(conn, [[
        SELECT date(start_time, 'unixepoch', 'localtime') AS day,
               SUM(duration) AS day_dur
        FROM page_stat
        GROUP BY day
        ORDER BY day ASC
    ]], function(stmt)
        for row in stmt:rows() do
            if not result then
                cumulative = cumulative + (tonumber(row[2]) or 0)
                if cumulative / 3600 >= threshold_hours then
                    result = row[1]
                end
            end
        end
    end)
    return result
end

-- ---------------------------------------------------------------------------
-- DB fingerprint helpers
-- ---------------------------------------------------------------------------
local function getDbFingerprint(conn)
    local max_time  = 0
    local row_count = 0
    withStatement(conn, "SELECT MAX(start_time), COUNT(*) FROM page_stat", function(stmt)
        for row in stmt:rows() do
            max_time  = tonumber(row[1]) or 0
            row_count = tonumber(row[2]) or 0
        end
    end)
    return max_time, row_count
end

-- ---------------------------------------------------------------------------
-- Incremental helpers (only touch rows newer than hw_max_time)
-- ---------------------------------------------------------------------------

-- Returns updated most-reading-time day: checks whether any calendar day
-- touched by new rows (summed across all books) beats the cached champion.
local function incrMostReadingTimeDay(conn, hw_time, cached)
    local result = { duration_sec = cached.duration_sec, date = cached.date }
    -- For each day that has new rows, recompute that day's total across all
    -- books (new rows alone can't give the full picture for a day already
    -- partially in cache, so we re-aggregate the whole day).
    local touched_days = {}
    withStatement(conn, string.format([[
        SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS day
        FROM page_stat
        WHERE start_time > %d
    ]], hw_time), function(stmt)
        for row in stmt:rows() do
            table.insert(touched_days, row[1])
        end
    end)
    for _, day in ipairs(touched_days) do
        withStatement(conn, string.format([[
            SELECT SUM(duration)
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = %q
        ]], day), function(stmt)
            for row in stmt:rows() do
                local dur = tonumber(row[1]) or 0
                if dur > result.duration_sec then
                    result.duration_sec = dur
                    result.date         = day
                end
            end
        end)
    end
    return result
end

-- Returns updated most-pages day similarly.
local function incrMostPagesDay(conn, hw_time, cached)
    local result = { pages = cached.pages, date = cached.date }
    local touched_days = {}
    withStatement(conn, string.format([[
        SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS day
        FROM page_stat
        WHERE start_time > %d
    ]], hw_time), function(stmt)
        for row in stmt:rows() do
            table.insert(touched_days, row[1])
        end
    end)
    for _, day in ipairs(touched_days) do
        withStatement(conn, string.format([[
            SELECT COUNT(DISTINCT id_book || '-' || page)
            FROM page_stat
            WHERE date(start_time, 'unixepoch', 'localtime') = %q
        ]], day), function(stmt)
            for row in stmt:rows() do
                local cnt = tonumber(row[1]) or 0
                if cnt > result.pages then
                    result.pages = cnt
                    result.date  = day
                end
            end
        end)
    end
    return result
end

-- Returns extra seconds accumulated in rows newer than hw_time.
local function incrExtraSecs(conn, hw_time)
    local extra = 0
    withStatement(conn, string.format(
        "SELECT SUM(duration) FROM page_stat WHERE start_time > %d", hw_time
    ), function(stmt)
        for row in stmt:rows() do extra = tonumber(row[1]) or 0 end
    end)
    return extra
end

-- Fastest book: re-run the full query (it's a JOIN with an ORDER BY that
-- can't be cheaply incremented), but only when new rows exist — which is
-- already the condition for calling this path.
local function incrFastestBook(conn)
    return fullQueryFastestBook(conn)
end

-- ---------------------------------------------------------------------------
-- Milestone helpers
-- ---------------------------------------------------------------------------
local function getMilestones(total_hours)
    local last_ms, next_ms = nil, nil
    for _, ms in ipairs(MILESTONES) do
        if ms <= total_hours then
            last_ms = ms
        elseif next_ms == nil then
            next_ms = ms
        end
    end
    return last_ms, next_ms
end

-- ---------------------------------------------------------------------------
-- Main data loader with cache logic
-- ---------------------------------------------------------------------------
local function loadData()
    return withStatsDb({
        longest      = { duration_sec = 0, date = nil },
        best_day     = { pages = 0, date = nil },
        streak       = { days = 0, start_date = nil, end_date = nil },
        fastest      = { title = nil, days = nil, date = nil, duration_sec = nil },
        total_secs   = 0,
        last_ms_date = nil,
    }, function(conn)

        -- 1. Get current DB fingerprint
        local cur_max_time, cur_row_count = getDbFingerprint(conn)

        -- 2. Try to load existing cache
        local cache = loadCache()

        -- Helper: run full queries, write cache, return data
        local function fullRecompute()
            local longest   = fullQueryMostReadingTimeDay(conn)
            local best_day  = fullQueryMostPagesDay(conn)
            local streak    = fullQueryBestStreak(conn)
            local fastest   = fullQueryFastestBook(conn)
            local tot_secs  = fullQueryTotalSecs(conn)
            local tot_hours = math.floor(tot_secs / 3600)
            local last_ms   = getMilestones(tot_hours)
            local lmd       = fullQueryMilestoneDate(conn, last_ms)

            local new_cache = {
                hw_max_time  = cur_max_time,
                hw_row_count = cur_row_count,
                longest      = longest,
                best_day     = best_day,
                streak       = streak,
                fastest      = fastest,
                total_secs   = tot_secs,
                last_ms_date = lmd,
            }
            saveCache(new_cache)
            return {
                longest      = longest,
                best_day     = best_day,
                streak       = streak,
                fastest      = fastest,
                total_secs   = tot_secs,
                last_ms_date = lmd,
            }
        end

        -- 3. No cache → full recompute
        if not cache then
            return fullRecompute()
        end

        -- 4. Cache matches DB exactly → return cached data directly
        if cache.hw_max_time == cur_max_time and cache.hw_row_count == cur_row_count then
            return cacheToData(cache)
        end

        -- 5. Row count shrank or max timestamp receded → data was deleted/modified
        --    Cannot increment safely → full recompute.
        if cur_row_count < (cache.hw_row_count or 0)
            or cur_max_time < (cache.hw_max_time or 0)
        then
            return fullRecompute()
        end

        -- 6. Only new rows added (count grew and max_time advanced or stayed).
        --    Verify the old high-water timestamp still exists (guards against
        --    a sync that replaced rows with same or higher timestamps).
        if (cache.hw_max_time or 0) > 0 then
            local old_still_exists = false
            withStatement(conn, string.format(
                "SELECT 1 FROM page_stat WHERE start_time = %d LIMIT 1",
                cache.hw_max_time
            ), function(stmt)
                for _ in stmt:rows() do old_still_exists = true end
            end)
            if not old_still_exists then
                return fullRecompute()
            end
        end

        -- 7. Incremental update
        local d = cacheToData(cache)
        local hw = cache.hw_max_time or 0

        d.longest  = incrMostReadingTimeDay(conn, hw, d.longest)
        d.best_day = incrMostPagesDay(conn, hw, d.best_day)
        d.fastest  = incrFastestBook(conn)

        local extra_secs = incrExtraSecs(conn, hw)
        d.total_secs = (d.total_secs or 0) + extra_secs

        local old_hours = math.floor((cache.total_secs or 0) / 3600)
        local new_hours = math.floor(d.total_secs / 3600)
        local old_last  = getMilestones(old_hours)
        local new_last  = getMilestones(new_hours)

        -- Streak: only re-run the full streak query when new days were added;
        -- the streak can only grow if reading happened on a day adjacent to the
        -- cached streak end, or on a new day not yet in the streak sequence.
        -- Re-running only when new distinct dates appeared keeps it correct.
        local new_distinct_dates = false
        if cache.streak_end then
            withStatement(conn, string.format([[
                SELECT 1 FROM page_stat
                WHERE start_time > %d
                  AND date(start_time, 'unixepoch', 'localtime') != %q
                LIMIT 1
            ]], hw, cache.streak_end), function(stmt)
                for _ in stmt:rows() do new_distinct_dates = true end
            end)
        else
            new_distinct_dates = true
        end
        if new_distinct_dates then
            d.streak = fullQueryBestStreak(conn)
        end

        -- Milestone date: only re-query if the last milestone changed
        if new_last ~= old_last then
            d.last_ms_date = fullQueryMilestoneDate(conn, new_last)
        end

        -- Rewrite cache with updated values
        local new_cache = {
            hw_max_time  = cur_max_time,
            hw_row_count = cur_row_count,
            longest      = d.longest,
            best_day     = d.best_day,
            streak       = d.streak,
            fastest      = d.fastest,
            total_secs   = d.total_secs,
            last_ms_date = d.last_ms_date,
        }
        saveCache(new_cache)
        return d
    end)
end

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

local function buildRecordRow(fonts, icon_glyph, label_text, value_text, sub_text, width)
    local pad = Size.padding.large
    local gap = Size.padding.small

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
    local icon_gap  = icon_size.w

    local left_avail = width - 2 * pad - right_size.w - gap
    local label_max  = math.max(left_avail - icon_size.w - icon_gap, 10)

    local left_col = TextBoxWidget:new{
        text      = label_text,
        face      = fonts.label,
        fgcolor   = Colors.label(),
        width     = label_max,
        alignment = "left",
    }
    local row_h = math.max(icon_size.h, left_col:getSize().h, right_size.h) + ROW_PADDING * 2

    local left_group = HorizontalGroup:new{
        align = "center",
        icon_w,
        HorizontalSpan:new{ width = icon_gap },
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
                dimen = Geom:new{ w = left_avail, h = row_h - ROW_PADDING * 2 },
                left_group,
            },
            HorizontalSpan:new{ width = gap },
            RightContainer:new{
                dimen = Geom:new{ w = right_size.w, h = row_h - ROW_PADDING * 2 },
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
    local d = loadData()

    local tot_hours        = math.floor((d.total_secs or 0) / 3600)
    local last_ms, next_ms = getMilestones(tot_hours)
    local last_ms_date     = d.last_ms_date

    local outer_padding = Size.padding.large
    local card_w    = math.min(math.floor(screen_w * 0.92), Screen:scaleBySize(560))
    local content_w = card_w - 2 * outer_padding

    local rows = VerticalGroup:new{ align = "left" }
    local function addRow(icon, label, value, sub)
        table.insert(rows, buildRecordRow(fonts, icon, label, value, sub, content_w))
        table.insert(rows, buildSeparator(content_w))
    end

    -- 1. Most reading time in a day
    local sess_val = (d.longest.duration_sec or 0) > 0
        and L10N.formatDuration(d.longest.duration_sec, true)
        or  "\xE2\x80\x93"
    local sess_sub = d.longest.date and formatDate(d.longest.date) or ""
    addRow(ICONS.session, _("Most reading time in a day"), sess_val, sess_sub)

    -- 2. Most pages in a day
    local pages_val = "\xE2\x80\x93"
    if (d.best_day.pages or 0) > 0 then
        pages_val = formatCount(d.best_day.pages) .. " " .. N_("page", "pages", d.best_day.pages)
    end
    local pages_sub = d.best_day.date and formatDate(d.best_day.date) or ""
    addRow(ICONS.pages, _("Most pages in a day"), pages_val, pages_sub)

    -- 3. Best daily streak
    local streak_val = "\xE2\x80\x93"
    if (d.streak.days or 0) > 0 then
        streak_val = formatCount(d.streak.days) .. " " .. N_("day", "days", d.streak.days)
    end
    local streak_sub = ""
    if d.streak.start_date and d.streak.end_date then
        streak_sub = formatDate(d.streak.start_date) .. " \xE2\x80\x93 " .. formatDate(d.streak.end_date)
    end
    addRow(ICONS.streak, _("Best daily streak"), streak_val, streak_sub)

    -- 4. Fastest book finished
    local fast_val = "\xE2\x80\x93"
    local fast_sub = ""
    if d.fastest.title and d.fastest.days then
        if d.fastest.days <= 1 and (d.fastest.duration_sec or 0) > 0 then
            -- Finished within a single calendar day: showing "1 day" would
            -- hide how fast it actually was, so show the reading time instead.
            fast_val = L10N.formatDuration(d.fastest.duration_sec, true)
        else
            fast_val = formatCount(d.fastest.days) .. " " .. N_("day", "days", d.fastest.days)
        end
        local short_title = d.fastest.title
        if #short_title > 30 then
            short_title = short_title:sub(1, 28) .. "\xE2\x80\xA6"
        end
        fast_sub = short_title
    end
    addRow(ICONS.fastest, _("Fastest book finished"), fast_val, fast_sub)

    -- 5. Last milestone
    local last_val = last_ms
        and (formatCount(last_ms) .. " " .. N_("hour", "hours", last_ms))
        or  "\xE2\x80\x93"
    local last_sub = last_ms_date and formatDate(last_ms_date) or ""
    addRow(ICONS.last_ms, _("Last milestone"), last_val, last_sub)

    -- 6. Next milestone
    if next_ms then
        local hours_left = next_ms - tot_hours
        local next_sub = ""
        if hours_left > 0 then
            next_sub = string.format(N_("%d hour left", "%d hours left", hours_left), hours_left)
        end
        addRow(ICONS.next_ms, _("Next milestone"),
            formatCount(next_ms) .. " " .. N_("hour", "hours", next_ms),
            next_sub)
    else
        addRow(ICONS.next_ms, _("Next milestone"), "\xE2\x80\x93", "")
    end
    table.remove(rows) -- remove trailing separator

    local title_w = TextWidget:new{
        text    = _("Records"),
        face    = fonts.value,
        fgcolor = Colors.value(),
    }

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

function RecordsPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self._box_dimen
    end)
    return true
end

function RecordsPopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self._box_dimen
    end)
end

function RecordsPopup:onTap()           UIManager:close(self) return true end
function RecordsPopup:onSwipe()         UIManager:close(self) return true end
function RecordsPopup:onAnyKeyPressed() UIManager:close(self) return true end

return { Popup = RecordsPopup }
