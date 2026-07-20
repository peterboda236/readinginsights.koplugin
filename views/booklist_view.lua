--[[
Reading Insights - the book list popups.

The list views the insights popup opens on a tap or a long press:

  - the books read in a given month/year/period (with the time spent on
    each),
  - the books that count towards the reading goal for a year,
  - the checklist for correcting that last list by hand, where a trailing
    "*" marks every book whose state the reader changed, and
  - the hand-kept list of books the statistics DB knows nothing about
    (read on paper, in another app, on another device), which counts
    towards the reading goal all the same - see lib/manual_books.lua.

The first two are read-only, and keep the KeyValuePage look they have
always had - with the same sort menu behind the title bar's left icon as
the editable ones (M.showSortMenu in widgets/booklistwidget.lua is shared
by both). The last two are the ones the reader edits, and are drawn by
widgets/booklistwidget.lua (a thin subclass of KOReader's SortWidget): a
sort menu behind the title bar's left icon (by last reading entry or by
title, each way round - last entry, newest first by default), a close "X"
on the right, paged rows with checkboxes where there's something to tick,
and a bottom bar with the page navigation plus a cancel "X" and an accept
check mark.

The read-only period lists replace the insights popup rather than stacking
on top of it: they close it, and reopen it with the same data when they
close. That needs the popup class, which would be a circular require - so
the view registers what's needed here instead, by calling M.bind() once at
load time. Calling any of these before bind() is a programming error, not a
runtime condition, so nothing here guards against it.

  BookList.bind(hooks)          wire in the view's popup class and helpers
  BookList.showBooksForPeriod(popup, books, empty_text, title)
                                close the insights popup, show a list,
                                reopen it on close
  BookList.showFinishedChecklist(popup, year)
  BookList.showManualBooks(popup, year)
]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local deps = ...
local Locale, VS, Data, Cache, ListWidget, Manual =
    deps.Locale, deps.VS, deps.Data, deps.Cache, deps.ListWidget, deps.Manual
local _  = Locale._

local M = {}

-- Filled in by M.bind() from insights_view.lua: the popup class these lists
-- reopen, and the few view-level helpers they share with it (the year's
-- finished-book query, duration formatting).
local ReadingInsightsPopup, getFinishedBooksForYear, formatHHMMSS

function M.bind(hooks)
    ReadingInsightsPopup    = hooks.popup_class
    getFinishedBooksForYear = hooks.getFinishedBooksForYear
    formatHHMMSS            = hooks.formatHHMMSS
end

-- Settings keys the three lists remember their sort order under. Kept
-- apart so ordering the goal checklist by title doesn't reorder the
-- period lists as well.
local SORT_KEY_BOOKS     = "reading_insights_booklist_sort"
local SORT_KEY_CHECKLIST = "reading_insights_checklist_sort"
local SORT_KEY_MANUAL    = "reading_insights_manuallist_sort"

-- The right-hand column of a finished-books list: the day the book was
-- finished, rather than the time spent on it. A hand-added book has no
-- measured time at all, so a "00:00:00" there would read as a broken
-- measurement instead of "nothing to measure" - and since this list is
-- ordered by that very date, showing it explains the order too. Entries
-- the reader added themselves keep the "*" the checklist uses for the same
-- meaning: set by hand, not by the statistics.
-- A timestamp as a plain date, in whatever format KOReader is set to show
-- dates in. Empty string for "no date known", so it simply leaves the
-- column blank rather than printing an epoch.
local function dateText(ts)
    if not ts or ts <= 0 then return "" end
    local datetime = require("datetime")
    return datetime.secondsToDate(ts)
end

local function finishedDateText(book)
    local text = dateText(book.last_read)
    if book.manual then
        return text ~= "" and ("* " .. text) or "*"
    end
    return text
end

-- The read-only period lists keep KOReader's KeyValuePage look they always
-- had: title and author on the left, reading time on the right, tap a row
-- for that book's statistics. Only the two lists the reader edits (the
-- finished-books checklist and the hand-kept list below) use the sortable
-- widget, where the sort menu and the cancel/accept buttons earn their
-- place.
--
-- opts.show_dates puts the finished-on date in the value column instead of
-- the reading time; used by the reading goal's finished-books list only.
function M.showBookList(title, books, on_close, stats_plugin, opts)
    local KeyValuePage = require("ui/widget/keyvaluepage")

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books read") })
        return
    end

    local function buildPairs(sorted_books)
        local kv_pairs = {}
        for _idx, book in ipairs(sorted_books) do
            local display_text = book.title
            -- Books the reader added by hand are shown as a bare title: they
            -- have no reading time to report (nothing was ever timed), and the
            -- author line would be the only thing filling the row out.
            if not book.manual and book.authors and book.authors ~= "" then
                display_text = display_text .. "\n" .. book.authors
            end

            local time_str
            if opts and opts.show_dates then
                time_str = finishedDateText(book)
            elseif book.manual then
                time_str = ""
            elseif book.duration and book.duration > 0 then
                time_str = formatHHMMSS(book.duration)
            else
                time_str = "00:00:00"
            end
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
                time_str,
                callback = cb,
            })
        end
        return kv_pairs
    end

    -- Same four orders as the editable lists, from the same menu - but
    -- these lists are KeyValuePages, which take their rows in init() and
    -- have no way to swap them afterwards. Re-sorting therefore closes the
    -- page and opens a fresh one; `resorting` keeps that from being
    -- mistaken for the reader closing the list, which would reopen the
    -- insights popup underneath it.
    local sort_mode = ListWidget.readSortMode(SORT_KEY_BOOKS)
    local kv, resorting

    local function sortedBooks()
        local sorted = {}
        for _idx, book in ipairs(books) do table.insert(sorted, book) end
        table.sort(sorted, ListWidget.comparator(sort_mode,
            function(b) return b.title or "" end,
            function(b) return b.last_read or 0 end))
        return sorted
    end

    local function openPage()
        kv = KeyValuePage:new{
            title               = title,
            kv_pairs            = buildPairs(sortedBooks()),
            value_align         = "right",
            title_bar_left_icon = "appbar.menu",
            title_bar_left_icon_tap_callback = function()
                ListWidget.showSortMenu{
                    current       = sort_mode,
                    anchor_widget = kv.title_bar and kv.title_bar.left_button,
                    callback      = function(mode)
                        if mode == sort_mode then return end
                        sort_mode = mode
                        ListWidget.saveSortMode(SORT_KEY_BOOKS, mode)
                        resorting = true
                        UIManager:close(kv)
                        resorting = false
                        openPage()
                    end,
                }
            end,
            close_callback = function()
                if resorting then return end
                UIManager:close(kv)
                UIManager:scheduleIn(0, function()
                    if on_close then on_close() end
                end)
            end,
        }
        UIManager:show(kv)
    end

    openPage()
end

function M.showBooksForPeriod(popup_self, books, empty_text, title, opts)
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
    end, stats_plugin, opts)
end

-- Refreshes the insights popup's reading-goal section in place, so the
-- updated count is visible as soon as one of the editing lists closes -
-- without the full close/reopen the read-only lists do.
local function refreshGoalSection(insights_popup, year)
    if not insights_popup or insights_popup._closed then return end
    -- The count is cached for a minute at a time; something was just
    -- changed by hand, so throw that away and let it be worked out again.
    Cache.clearGoalMinuteCacheForYear(year)
    insights_popup._goal_finished = Data.getFinishedBookCountForYear(year)
    insights_popup:_buildUI()
    UIManager:setDirty(insights_popup, function()
        return "ui", insights_popup.popup_frame.dimen
    end)
end

-- ---------------------------------------------------------------------
-- "Mark book finished" - the checklist behind the reading goal's count.
-- ---------------------------------------------------------------------
--
-- One row per book with any activity that year (the same candidate pool
-- showBooksForYear uses), each with a checkbox for whether it currently
-- counts as "finished": what the automatic "last entry reached 99%" rule
-- found, corrected by any override the reader has set. Tapping a row
-- toggles and immediately persists that book's override
-- (VS.saveFinishedOverrides), so the goal count and the finished-books
-- list both reflect it as soon as this list is accepted.
--
-- The bottom bar's check mark keeps those changes; its "X" (and the title
-- bar's, and a swipe down) puts the overrides back exactly as they were
-- when the list was opened.
function M.showFinishedChecklist(insights_popup, year)
    -- The statistics plugin keeps the running session's page timings in
    -- memory and only writes them out now and then, so a book finished a
    -- moment ago may have no row in the DB yet - and would come up
    -- unticked. Ask for those rows first, then query.
    Data.flushStatsToDB(insights_popup and insights_popup.ui)

    local books, base_finished

    local function loadFromDB()
        books = insights_popup:getBooksForYear(year)
        base_finished = {}
        for _idx, b in ipairs(getFinishedBooksForYear(year)) do
            base_finished[tostring(b.id_book)] = true
        end
    end
    loadFromDB()

    local overrides = VS.readFinishedOverrides(year)

    -- Snapshot for the cancel button. Every tap saves immediately (so
    -- nothing is lost if the reader walks away or the device sleeps), and
    -- cancelling simply writes this copy back.
    local original = {}
    for k, v in pairs(overrides) do original[k] = v end

    local function isFinished(id_str)
        local ov = overrides[id_str]
        if ov ~= nil then return ov end
        return base_finished[id_str] == true
    end

    -- A trailing "*" marks the rows where this checklist disagrees with
    -- what the automatic rule found - i.e. the ones the reader set by
    -- hand. Without it there's no way to tell a manual correction from the
    -- query's own verdict, which matters when reviewing why the goal count
    -- says what it says.
    local function rowText(book, id_str)
        local overridden = overrides[id_str] ~= nil
            and overrides[id_str] ~= (base_finished[id_str] == true)
        local text = book.title or _("Unknown")
        return overridden and (text .. " *") or text
    end

    local function buildItems()
      local item_table = {}
      for _idx, book in ipairs(books) do
        local id_str = tostring(book.id_book)
        local item
        item = {
            text         = rowText(book, id_str),
            -- Right-hand column: the day of this book's last reading
            -- entry - the very thing the "finished" rule is judged on, and
            -- what the list is sorted by out of the box.
            mandatory    = dateText(book.last_read),
            sort_title   = book.title or "",
            sort_time    = book.last_read or 0,
            checked_func = function() return isFinished(id_str) end,
            callback     = function()
                local new_state = not isFinished(id_str)
                if new_state == (base_finished[id_str] == true) then
                    overrides[id_str] = nil
                else
                    overrides[id_str] = new_state
                end
                VS.saveFinishedOverrides(year, overrides)
                item.text = rowText(book, id_str)
            end,
        }
        table.insert(item_table, item)
      end
      return item_table
    end

    local item_table = buildItems()
    if #item_table == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books read in this year") })
        return
    end

    local widget
    widget = ListWidget.new{
        title            = T(_("Mark book finished - %1"), tostring(year)),
        item_table       = item_table,
        sort_setting_key = SORT_KEY_CHECKLIST,
        show_ok_cancel   = true,
        -- Offered next to the sort orders in the title bar's menu: re-runs
        -- both queries, so a book finished while this list was open (or
        -- one whose reading session hadn't been written out yet when it was
        -- opened) picks up its tick without closing and reopening.
        extra_menu_buttons = {{
            text = _("Reload data"),
            callback = function()
                Data.flushStatsToDB(insights_popup and insights_popup.ui)
                Cache.clearGoalCacheForYear(year)
                loadFromDB()
                widget:updateItems(buildItems())
            end,
        }},
        cancel_callback  = function()
            VS.saveFinishedOverrides(year, original)
        end,
        close_callback   = function()
            refreshGoalSection(insights_popup, year)
        end,
    }
    UIManager:show(widget)
end

-- ---------------------------------------------------------------------
-- "Add books manually" - the reader's own list for a year.
-- ---------------------------------------------------------------------

-- The date a hand-added book is filed under. New entries start from today
-- when the list belongs to the current year, and from the last day of the
-- year otherwise - both are inside the year being edited, which is what
-- the reading goal counts on.
local function defaultManualDate(year)
    local today = os.date("*t")
    if tostring(today.year) == tostring(year) then
        return os.date("%Y-%m-%d")
    end
    return string.format("%s-12-31", tostring(year))
end

local function editManualBook(year, entry, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        -- The list this is opened from is modal, and UIManager inserts
        -- non-modal windows below the topmost modal one - without this the
        -- dialog would open behind the list.
        modal  = true,
        title  = entry and _("Edit book") or _("Add book"),
        fields = {
            {
                description = _("Title"),
                text        = entry and entry.title or "",
                hint        = _("Title"),
            },
            {
                description = _("Author"),
                text        = entry and entry.authors or "",
                hint        = _("Author"),
            },
            {
                description = _("Date read (YYYY-MM-DD)"),
                text        = (entry and entry.date ~= "" and entry.date)
                    or defaultManualDate(year),
                hint        = "YYYY-MM-DD",
            },
        },
        buttons = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text     = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local title   = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local authors = (fields[2] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local date    = (fields[3] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if title == "" then
                        UIManager:show(InfoMessage:new{ text = _("Please enter a title") })
                        return
                    end
                    -- An empty date is fine (the entry then sorts by when it
                    -- was added); a date that isn't one is not, or it would
                    -- be silently dropped on save.
                    if date ~= "" and not Manual.parseDate(date) then
                        UIManager:show(InfoMessage:new{
                            text = _("Please enter the date as YYYY-MM-DD") })
                        return
                    end
                    UIManager:close(dialog)
                    local values = { title = title, authors = authors, date = date }
                    if entry then
                        Manual.update(year, entry.id, values)
                    else
                        Manual.add(year, values)
                    end
                    if on_done then on_done() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Just the title; the date it was read is the row's right-hand value (see
-- the item's `mandatory` field below), the same layout the finished-books
-- list and the checklist use. The author is still stored and editable, it
-- simply isn't what these rows are scanned for.
local function manualRowText(entry)
    return entry.title or _("Unknown")
end

-- The list of hand-added books for one year: a pinned "add a book" row on
-- top, then one row per entry. Tapping an entry offers edit and delete;
-- both write straight through to the store and rebuild the list in place.
-- No cancel/accept buttons at the bottom - there's nothing pending to
-- accept, every change is already saved.
function M.showManualBooks(insights_popup, year)
    local widget

    local function buildItems()
        local items = {}
        table.insert(items, {
            -- U+2795 HEAVY PLUS SIGN
            text     = "\xe2\x9e\x95  " .. _("Add book"),
            pinned   = true,
            callback = function()
                editManualBook(year, nil, function()
                    widget:updateItems(buildItems())
                end)
            end,
        })
        for _idx, entry in ipairs(Manual.list(year)) do
            local this_entry = entry
            table.insert(items, {
                text       = manualRowText(this_entry),
                -- Only a date the reader actually gave: entries saved
                -- without one fall back to their creation time for
                -- sorting, which isn't a reading date and shouldn't be
                -- shown as one.
                mandatory  = (this_entry.date ~= "" and dateText(this_entry.read_ts)) or "",
                sort_title = this_entry.title or "",
                sort_time  = this_entry.read_ts or this_entry.ts or 0,
                callback   = function()
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local dialog
                    dialog = ButtonDialog:new{
                        -- Same as above: modal, or it opens behind the list.
                        modal       = true,
                        title       = this_entry.title,
                        title_align = "center",
                        buttons = {
                            {{
                                text = _("Edit"),
                                callback = function()
                                    UIManager:close(dialog)
                                    editManualBook(year, this_entry, function()
                                        widget:updateItems(buildItems())
                                    end)
                                end,
                            }},
                            {{
                                text = _("Delete"),
                                callback = function()
                                    UIManager:close(dialog)
                                    local ConfirmBox = require("ui/widget/confirmbox")
                                    UIManager:show(ConfirmBox:new{
                                        text = T(_("Delete \"%1\"?"), this_entry.title),
                                        ok_text = _("Delete"),
                                        ok_callback = function()
                                            Manual.remove(year, this_entry.id)
                                            widget:updateItems(buildItems())
                                        end,
                                    })
                                end,
                            }},
                        },
                    }
                    UIManager:show(dialog)
                end,
            })
        end
        return items
    end

    widget = ListWidget.new{
        title            = T(_("Add books manually - %1"), tostring(year)),
        item_table       = buildItems(),
        sort_setting_key = SORT_KEY_MANUAL,
        show_ok_cancel   = false,
        close_callback   = function()
            refreshGoalSection(insights_popup, year)
        end,
    }
    UIManager:show(widget)
end

return M
