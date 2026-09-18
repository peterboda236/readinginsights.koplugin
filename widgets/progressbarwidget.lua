--[[
Reading Insights - progress bar widget for the book progress view.

A single horizontal bar shown in the "This book" section, between the
section header and the percentage/pages row: filled from the left with the
already-read portion, the rest filled with the unread portion. On/off and
its two colors are user-configurable (Settings > Advanced settings > Book
progress popup > Progress bar); this module only owns the bar's height
setting, the same way chapterbarwidget.lua owns its own height setting -
the on/off toggle lives in lib/insights_settings.lua (Opt.readShowProgressBar)
and the colors live in lib/colors.lua (progress_bar_read/progress_bar_unread),
right alongside every other on/off toggle and color in the plugin.

  ProgressBar.readHeightSetting() / ProgressBar.saveHeightSetting(v) / ProgressBar.DEFAULT_HEIGHT
      the bar's height in "points" (Settings > Advanced settings > Bar
      chart height > "Book progress: Progress bar"), read on every build
  ProgressBar.build(ratio, full_width, read_color, unread_color)
      ratio              0.0..1.0 fraction of the book already read
      full_width         total width of the bar, in pixels
      read_color/unread_color  Blitbuffer color objects (e.g. from
                         Colors.progressBarRead()/Colors.progressBarUnread())
      Returns a widget with getSize() == { w = full_width, h = <height> },
      or nil if full_width is not usable.
]]--

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Screen = require("device").screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Colors = deps.Colors

local M = {}

local SETTINGS_KEY_HEIGHT = "reading_insights_progress_bar_height"
M.DEFAULT_HEIGHT = 1

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

-- Builds the bar. `read_color`/`unread_color` default to the shared
-- Colors module's own progress-bar colors when not given, so callers that
-- don't care about overriding them can just pass ratio + width.
function M.build(ratio, full_width, read_color, unread_color)
    if not full_width or full_width <= 0 then return nil end

    ratio = tonumber(ratio) or 0
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end

    read_color   = read_color   or Colors.progressBarRead()
    unread_color = unread_color or Colors.progressBarUnread()

    local height = Screen:scaleBySize(M.readHeightSetting())

    -- Rounded rather than floored, and nudged so a genuinely-started book
    -- always shows at least a sliver of the read color, and a genuinely-
    -- unfinished book always shows at least a sliver of the unread color -
    -- the same "always visible, never both-or-nothing at the edges" idea
    -- as the chapter bar's current-chapter fill.
    local read_w = math.floor(full_width * ratio + 0.5)
    if ratio > 0 and read_w == 0 then read_w = 1 end
    if ratio < 1 and read_w >= full_width then read_w = full_width - 1 end
    if read_w < 0 then read_w = 0 end
    local unread_w = full_width - read_w

    local bar_row = HorizontalGroup:new{ align = "top" }
    if read_w > 0 then
        table.insert(bar_row, Colors.newBar(read_w, height, read_color))
    end
    if unread_w > 0 then
        table.insert(bar_row, Colors.newBar(unread_w, height, unread_color))
    end

    -- HorizontalGroup sizes itself from its children, but callers (the
    -- section-row builder in book_stats_view.lua) want a dependable
    -- getSize() up front - wrap the size rather than trust the group's own
    -- bookkeeping to always match `full_width` exactly (rounding above can
    -- leave read_w+unread_w a pixel off full_width in edge cases).
    bar_row.dimen = Geom:new{ w = full_width, h = height }
    return bar_row
end

return M
