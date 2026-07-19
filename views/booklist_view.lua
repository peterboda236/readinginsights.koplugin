--[[
Reading Insights - the book list popups.

The three list views the insights popup opens on a tap:

  - the books read in a given month/year/period (with time and pages each),
  - the books that count towards the reading goal for a year, and
  - the checklist for correcting that last list by hand, where a trailing
    "*" marks every book whose state the reader changed.

Split out of insights_view.lua along with the heatmap and the 8-week trend
popup, so the view file holds the insights page itself rather than every
popup reachable from it.

These popups replace the insights popup rather than stacking on top of it:
they close it, and reopen it with the same data when they close. That needs
the popup class, which would be a circular require - so the view registers
what's needed here instead, by calling M.bind() once at load time. Calling
any of these before bind() is a programming error, not a runtime condition,
so nothing here guards against it.

  BookList.bind(hooks)          wire in the view's popup class and helpers
  BookList.showBooksForPeriod(popup, books, empty_text, title)
                                close the insights popup, show a list,
                                reopen it on close
  BookList.Checklist:new{ year = ..., insights_popup = ... }
]]--

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = require("device").screen
local T = require("ffi/util").template

local deps = ...
local Colors, Locale, VS, UI, Data =
    deps.Colors, deps.Locale, deps.VS, deps.UI, deps.Data
local _  = Locale._
local N_ = Locale.N_

local M = {}

-- Filled in by M.bind() from insights_view.lua: the popup class these lists
-- reopen, and the few view-level helpers they share with it (cached fonts
-- and layout, the year's finished-book query, duration formatting).
local ReadingInsightsPopup, getCachedFonts, getCachedLayout, getFinishedBooksForYear, formatHHMMSS

function M.bind(hooks)
    ReadingInsightsPopup    = hooks.popup_class
    getCachedFonts          = hooks.getCachedFonts
    getCachedLayout         = hooks.getCachedLayout
    getFinishedBooksForYear = hooks.getFinishedBooksForYear
    formatHHMMSS            = hooks.formatHHMMSS
end

function M.showBookList(title, books, on_close, stats_plugin)
    local KeyValuePage = require("ui/widget/keyvaluepage")

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books read") })
        return
    end

    local kv_pairs = {}
    for _, book in ipairs(books) do
        local display_text = book.title
        if book.authors and book.authors ~= "" then
            display_text = display_text .. "\n" .. book.authors
        end

        local time_str
        if book.duration and book.duration > 0 then
            time_str = formatHHMMSS(book.duration)
        else
            time_str = "00:00:00"
        end
        local time_text = time_str
        local book_id = book.id_book
        local book_title = book.title
        local cb = nil
        if book_id and stats_plugin then
            cb = function()
                local kv2
                kv2 = KeyValuePage:new{
                    title           = book_title,
                    kv_pairs        = stats_plugin:getBookStat(book_id),
                    value_align     = "right",
                    single_page     = true,
                    callback_return = function()
                        UIManager:close(kv2)
                    end,
                    close_callback  = function() kv2 = nil end,
                }
                UIManager:show(kv2)
            end
        end
        table.insert(kv_pairs, {
            display_text,
            time_text,
            callback = cb,
        })
    end

    local kv
    kv = KeyValuePage:new{
        title          = title,
        kv_pairs       = kv_pairs,
        value_align    = "right",
        close_callback = function()
            UIManager:close(kv)
            UIManager:scheduleIn(0, function()
                if on_close then on_close() end
            end)
        end,
    }
    UIManager:show(kv)
end

function M.showBooksForPeriod(popup_self, books, empty_text, title)
    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = empty_text })
        return
    end

    local saved_year     = popup_self.selected_year
    local saved_mode     = popup_self.mode
    local saved_ui       = popup_self.ui

    local saved_streaks        = popup_self._streaks
    local saved_yr             = popup_self._year_range
    local saved_yearly         = popup_self._yearly
    local saved_monthly        = popup_self._monthly
    local saved_all_time       = popup_self._all_time
    local saved_goal_finished  = popup_self._goal_finished
    local saved_last_week      = popup_self._last_week
    local saved_last_week_daily = popup_self._last_week_daily

    popup_self._closed = true
    UIManager:close(popup_self)

    local stats_plugin = saved_ui and saved_ui.statistics or nil
    M.showBookList(title, books, function()
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
        }
        UIManager:show(p)
    end, stats_plugin)
end

-- Long-press target for the same cell: a checklist of every book with
-- activity that year (same candidate pool as showBooksForYear), each row
-- showing a checkbox for whether it currently counts as "finished"
-- (query result, corrected by any existing override - see
-- M.Checklist:_isFinished). Tapping a row toggles and
-- immediately persists that book's override (VS.saveFinishedOverrides), so
-- the reading-goal count and showFinishedBooksForYear's list both reflect
-- it as soon as this popup closes.
M.Checklist = InputContainer:extend{
    modal          = true,
    year           = nil,
    insights_popup = nil,
}

function M.Checklist:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    self.books = self.insights_popup:getBooksForYear(self.year)

    self.base_finished = {}
    for _, b in ipairs(getFinishedBooksForYear(self.year)) do
        self.base_finished[tostring(b.id_book)] = true
    end

    self.overrides = VS.readFinishedOverrides(self.year)

    self:_buildUI()
end

function M.Checklist:_isFinished(id_str)
    local ov = self.overrides[id_str]
    if ov ~= nil then return ov end
    return self.base_finished[id_str] == true
end

function M.Checklist:_toggle(id_book)
    local id_str = tostring(id_book)
    local new_state = not self:_isFinished(id_str)
    if new_state == (self.base_finished[id_str] == true) then
        self.overrides[id_str] = nil
    else
        self.overrides[id_str] = new_state
    end
    VS.saveFinishedOverrides(self.year, self.overrides)

    self:_buildUI()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
end

function M.Checklist:_buildUI()
    local fonts      = getCachedFonts()
    local layout      = getCachedLayout()
    local padding_h   = layout.padding_h
    local row_width   = self.screen_w - 2 * padding_h
    local checklist_self = self

    local title_bar = TitleBar:new{
        fullscreen     = true,
        width          = self.screen_w,
        align          = "left",
        title          = T(_("Mark book finished - %1"), tostring(self.year)),
        subtitle       = _("* = changed by you"),
        close_callback = function() self:_close() end,
        show_parent    = self,
        top_v_padding    = Size.padding.default,
        bottom_v_padding = Size.padding.default,
    }
    self._title_bar_height = title_bar:getSize().h

    local rows = VerticalGroup:new{ align = "left" }
    table.insert(rows, VerticalSpan:new{ height = Size.padding.default })

    if #self.books == 0 then
        table.insert(rows, UI.padded(padding_h, TextBoxWidget:new{
            text      = _("No books read in this year"),
            face      = fonts.label,
            fgcolor   = Colors.label(),
            width     = row_width,
            alignment = "left",
        }))
    end

    for _, book in ipairs(self.books) do
        local id_str  = tostring(book.id_book)
        local checked = checklist_self:_isFinished(id_str)
        -- U+2611 BALLOT BOX WITH CHECK / U+2610 BALLOT BOX
        local mark = checked and "\xe2\x98\x91" or "\xe2\x98\x90"

        -- A trailing "*" marks the rows where this checklist disagrees with
        -- what the automatic "last entry reached 99%" rule found - i.e. the
        -- ones the reader set by hand. Without it there's no way to tell a
        -- manual correction from the query's own verdict, which matters
        -- when reviewing why the goal count says what it says.
        local overridden = self.overrides[id_str] ~= nil
            and self.overrides[id_str] ~= (self.base_finished[id_str] == true)
        local row_title = overridden and (book.title .. " *") or book.title

        local mark_widget = TextWidget:new{ text = mark, face = fonts.value, fgcolor = Colors.value() }
        local gap   = Size.padding.default
        local mark_w = mark_widget:getSize().w
        local title_widget = TextBoxWidget:new{
            text      = row_title,
            face      = fonts.label,
            fgcolor   = Colors.label(),
            width     = row_width - mark_w - gap,
            alignment = "left",
        }
        local row_content = HorizontalGroup:new{
            align = "center",
            mark_widget,
            HorizontalSpan:new{ width = gap },
            title_widget,
        }

        local id_book = book.id_book
        local row_cell = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = row_width, h = row_content:getSize().h },
            row_content,
        }
        row_cell.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = row_cell.dimen } },
        }
        function row_cell:onTap()
            checklist_self:_toggle(id_book)
            return true
        end

        table.insert(rows, UI.padded(padding_h, row_cell))
        table.insert(rows, VerticalSpan:new{ height = Size.padding.default })
        table.insert(rows, UI.padded(padding_h,
            Colors.newBar(row_width, Size.line.thin, Colors.separator())))
        table.insert(rows, VerticalSpan:new{ height = Size.padding.default })
    end

    local content = VerticalGroup:new{
        align = "left",
        title_bar,
        UI.padded(padding_h, Colors.newBar(layout.content_width, Size.line.thick, Colors.separator())),
        rows,
        VerticalSpan:new{ height = title_bar:getSize().h },
    }

    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    self.scroll_container = ScrollableContainer:new{
        dimen               = Geom:new{ w = self.screen_w, h = self.screen_h },
        show_parent         = self,
        scroll_bar_position = "right",
        content,
    }

    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        radius     = 0,
        padding    = 0,
        width      = self.screen_w,
        VerticalGroup:new{
            align = "left",
            self.scroll_container,
        },
    }
    self.popup_frame.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    self[1] = VerticalGroup:new{ self.popup_frame }
end

-- Closes and, once the checklist is off-screen, refreshes the parent
-- popup's reading-goal section so the updated count and finished-books
-- list are visible immediately without a full close/reopen.
function M.Checklist:_close()
    UIManager:close(self)
    local ip   = self.insights_popup
    local year = self.year
    UIManager:scheduleIn(0, function()
        if not ip or ip._closed then return end
        ip._goal_finished = Data.getFinishedBookCountForYear(year)
        ip:_buildUI()
        UIManager:setDirty(ip, function()
            return "ui", ip.popup_frame.dimen
        end)
    end)
end

function M.Checklist:onSwipe(arg, ges_ev)
    if not ges_ev then return false end
    local dir = ges_ev.direction
    if dir == "south" or dir == "down" then
        self:_close()
        return true
    end
    return false
end

function M.Checklist:onAnyKeyPressed()
    self:_close()
    return true
end

function M.Checklist:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.popup_frame.dimen
    end)
    return true
end

function M.Checklist:onCloseWidget()
    if self.scroll_container then
        self.scroll_container:free()
    end
    UIManager:setDirty(nil, "ui")
end

return M
