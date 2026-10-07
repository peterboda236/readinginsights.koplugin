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

The first two are read-only (tap a book for its Book info popup, long-press
it for its statistics), and keep the KeyValuePage look they have
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
  BookList.bindBookInfo(class)  wire in the Book info popup (tap on a row)
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
local Locale, VS, Data, Cache, ListWidget, Manual, Ratings, RatingDialog =
    deps.Locale, deps.VS, deps.Data, deps.Cache, deps.ListWidget, deps.Manual, deps.Ratings,
    deps.RatingDialog
local BookStatsData = deps.BookStatsData
local _  = Locale._

local M = {}

-- Filled in by M.bind() from insights_view.lua: the popup class these lists
-- reopen, and the few view-level helpers they share with it (the year's
-- finished-book query, duration formatting).
local ReadingInsightsPopup, getFinishedBooksForYear, formatHHMMSS

-- The Book info popup class, handed over by main.lua once it is loaded.
local BookInfoPopup
function M.bindBookInfo(class)
    BookInfoPopup = class
end

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

-- Same for what the right-hand column shows (reading time, pages read, star
-- rating, or the date): one remembered choice per list.
local DISPLAY_KEY_BOOKS     = "reading_insights_booklist_display"
local DISPLAY_KEY_FINISHED  = "reading_insights_finishedlist_display"
local DISPLAY_KEY_CHECKLIST = "reading_insights_checklist_display"
local DISPLAY_KEY_MANUAL    = "reading_insights_manuallist_display"

-- Which columns each kind of list can show; the first is the default. The
-- period lists have always shown the reading time, so that stays the
-- default there; the lists that are ordered by a date keep showing it.
local MODES_PERIOD   = { "time", "pages", "rating" }
local MODES_DATED    = { "date", "time", "pages", "rating" }
local MODES_MANUAL   = { "date", "rating" }

-- The right-hand column of a finished-books list: the day the book was
-- finished, rather than the time spent on it. A hand-added book has no
-- measured time at all, so a "00:00:00" there would read as a broken
-- measurement instead of "nothing to measure" - and since this list is
-- ordered by that very date, showing it explains the order too. Entries
-- the reader added themselves keep the "*" the checklist uses for the same
-- meaning: set by hand, not by the statistics.
-- A timestamp as a plain date, in the format picked under Settings ▸
-- Advanced settings ▸ Date & time ▸ "Date format" - the same one the
-- insights, records and stats popups print their dates in. Empty string
-- for "no date known", so it simply leaves the column blank rather than
-- printing an epoch.
local dateText = Locale.formatDateFromTS

local function finishedDateText(book)
    return dateText(book.last_read)
end

-- Looks each book's star rating up (from its sidecar, via the statistics
-- DB's md5) and stores it on the record. Books added by hand carry their own
-- rating already.
local function annotateRatings(books)
    for _idx, book in ipairs(books) do
        if not book.manual then
            book.rating = Ratings.get(book.md5) or 0
        end
    end
end

-- The text for one book in one display mode (see ListWidget.displayLabel).
-- A hand-added book has no reading time and no pages to report, so those
-- stay blank for it rather than printing a zero.
local function valueText(book, mode)
    if mode == "date" then
        return finishedDateText(book)
    elseif mode == "rating" then
        return Ratings.stars(book.rating)
    elseif mode == "pages" then
        if book.manual then return "" end
        return tostring(book.pages or 0) .. " " .. _("pages")
    end
    if book.manual then return "" end
    if book.duration and book.duration > 0 then
        return formatHHMMSS(book.duration)
    end
    return "00:00:00"
end

-- "Series / #2" for a hand-added book (just the name when it has no number
-- yet), in the language's own shape; "" when the book has no series.
local function seriesText(series, index)
    if not series or series == "" then return "" end
    if not index or index == "" then return series end
    return (_("{series} / #{index}"):gsub("{(%w+)}", function(k)
        if k == "series" then return series end
        if k == "index" then return tostring(index) end
        return "{" .. k .. "}"
    end))
end

-- All four texts of a book at once, the shape the list widget's rows take.
local function valueTable(book)
    return {
        date   = finishedDateText(book),
        time   = valueText(book, "time"),
        pages  = valueText(book, "pages"),
        rating = valueText(book, "rating"),
    }
end

-- Long press on a book's rating: the star rating popup (five stars side by
-- side, tap or slide to set; see widgets/ratingdialog.lua).
-- Calls on_pick(n) with the chosen 0..5; the caller stores it.
local function pickRating(title, current, on_pick)
    RatingDialog.show{
        title   = title,
        rating  = current,
        on_save = on_pick,
    }
end

-- A book from the statistics DB: store the rating by its checksum (hand-added
-- books carry their own and are handled where they are listed).
local function rateStatsBook(book, on_done)
    if not book.md5 or book.md5 == "" then
        UIManager:show(InfoMessage:new{ text = _("This book has no checksum, so its rating can't be saved") })
        return
    end
    pickRating(book.title or _("Unknown"), book.rating, function(n)
        Ratings.set(book.md5, n)
        book.rating = n
        on_done(n)
    end)
end

-- The read-only period lists keep KOReader's KeyValuePage look they always
-- had: title and author on the left, reading time on the right. Tap a row
-- for that book's Book info popup (cover, title, stars, pages and time, ...;
-- long-press its stars to rate the book), long-press a row for that book's
-- statistics. Only the two lists the reader edits (the
-- finished-books checklist and the hand-kept list below) use the sortable
-- widget, where the sort menu and the cancel/accept buttons earn their
-- place.
--
-- opts.show_dates puts the finished-on date in the value column instead of
-- the reading time; used by the reading goal's finished-books list only.
-- opts.modal marks the list (and the book stats page a row opens) as modal,
-- so it stacks above modal popups such as the streak calendar and the
-- insights popup instead of opening behind them.
-- The author of a list book, for finding its file: the rows of the lists
-- carry none, so it is read from the statistics DB when needed.
local function authorsOf(book)
    if book.authors and book.authors ~= "" then return book.authors end
    if book.id_book and BookStatsData then
        local ok, row = pcall(BookStatsData.getBookRow, book.id_book)
        if ok and row and row.authors then return row.authors end
    end
    return nil
end

function M.showBookList(title, books, on_close, stats_plugin, opts)
    local KeyValuePage = require("ui/widget/keyvaluepage")

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books") })
        return
    end

    annotateRatings(books)
    local display_modes = (opts and opts.show_dates) and MODES_DATED or MODES_PERIOD
    local display_key   = (opts and opts.show_dates) and DISPLAY_KEY_FINISHED or DISPLAY_KEY_BOOKS
    local display_mode  = ListWidget.readDisplayMode(display_key, display_modes)

    local openPage          -- defined below; rows reopen the page after a rating edit
    local kv, resorting
    local ui = (opts and opts.ui) or (stats_plugin and stats_plugin.ui) or nil

    local function buildPairs(sorted_books)
        local kv_pairs = {}
        for _idx, book in ipairs(sorted_books) do
            local display_text = book.title
            -- Books the reader added by hand are shown as a bare title: they
            -- have no reading time to report (nothing was ever timed), and the
            -- author line would be the only thing filling the row out.
            if not book.manual and book.authors and book.authors ~= "" then
                display_text = display_text .. "\n" .. book.authors
            elseif book.manual then
                -- ... except for the series it was given, when it has one.
                local line = seriesText(book.series, book.series_index)
                if line ~= "" then display_text = display_text .. "\n" .. line end
            end

            local time_str = valueText(book, display_mode)
            local book_id = book.id_book
            local book_title = book.title

            -- Long press: the book's statistics page.
            local hold_cb = nil
            if book_id and stats_plugin then
                hold_cb = function()
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
                    -- opts.modal: opened from a modal popup (the streak
                    -- calendar), so this page has to be modal too or the
                    -- UIManager would slot it in *behind* that popup.
                    if opts and opts.modal then kv2.modal = true end
                    UIManager:show(kv2)
                end
            end

            -- Tap: the Book info popup. A rating set there changes this
            -- list's rating column / order, so the page is rebuilt (on the
            -- same page) once the popup is closed.
            local cb = nil
            if BookInfoPopup then
                cb = function()
                    local rated = false
                    -- When the book was finished, if it counts as finished:
                    -- a hand-added book only if the reader gave a date
                    -- (otherwise last_read is just when it was added); the
                    -- finished-books list already knows the date of each
                    -- of its books; any other list (month, year, day...)
                    -- works it out the same way that list does, manual
                    -- ticks and unticks included.
                    local finished_ts = nil
                    if book.manual then
                        if book.date_known and (book.last_read or 0) > 0 then
                            finished_ts = book.last_read
                        end
                    elseif opts and opts.show_dates then
                        if (book.last_read or 0) > 0 then finished_ts = book.last_read end
                    elseif book.id_book then
                        local ok, ts = pcall(Data.getFinishedTimestamp, book.id_book)
                        if ok then finished_ts = ts end
                    end
                    UIManager:show(BookInfoPopup:new{
                        ui      = ui,
                        book    = book,
                        finished_ts = finished_ts,
                        file    = (not book.manual) and Ratings.fileFor(book.md5, book.title, authorsOf(book)) or nil,
                        -- A hand-added book keeps its rating in the manual list.
                        save_rating = book.manual and function(n)
                            if not (book.manual_year and book.manual_id) then return false end
                            Manual.update(book.manual_year, book.manual_id, { rating = n })
                            return true
                        end or nil,
                        on_rate = function(n)
                            book.rating = n
                            rated = true
                        end,
                        on_close = function()
                            if not rated or not kv then return end
                            local page = kv.show_page or 1
                            resorting = true
                            UIManager:close(kv)
                            resorting = false
                            openPage(page)
                        end,
                    })
                end
            end
            table.insert(kv_pairs, {
                display_text,
                time_str,
                callback = cb,
                hold_callback = hold_cb,
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

    local function sortedBooks()
        local sorted = {}
        for _idx, book in ipairs(books) do table.insert(sorted, book) end
        table.sort(sorted, ListWidget.comparator(sort_mode,
            function(b) return b.title or "" end,
            function(b) return b.last_read or 0 end,
            function(b) return b.rating or 0 end))
        return sorted
    end

    openPage = function(page)
        kv = KeyValuePage:new{
            show_page           = page or 1,
            title               = title,
            kv_pairs            = buildPairs(sortedBooks()),
            value_align         = "right",
            title_bar_left_icon = "appbar.menu",
            title_bar_left_icon_tap_callback = function()
                -- Re-sorting and switching the right-hand column both rebuild
                -- the page (see the note above on why).
                local function reopen()
                    resorting = true
                    UIManager:close(kv)
                    resorting = false
                    openPage()
                end
                ListWidget.showSortMenu{
                    current       = sort_mode,
                    modes         = ListWidget.BOOK_SORT_MODES,
                    anchor_widget = kv.title_bar and kv.title_bar.left_button,
                    display       = {
                        modes    = display_modes,
                        current  = display_mode,
                        callback = function(mode)
                            if mode == display_mode then return end
                            display_mode = mode
                            ListWidget.saveDisplayMode(display_key, mode)
                            reopen()
                        end,
                    },
                    callback      = function(mode)
                        if mode == sort_mode then return end
                        sort_mode = mode
                        ListWidget.saveSortMode(SORT_KEY_BOOKS, mode)
                        reopen()
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
        ListWidget.fitTitle(kv)
        if opts and opts.modal then kv.modal = true end
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
    -- The list's rows open the Book info popup, which wants the UI (to know
    -- the open book): hand it over next to the caller's own options.
    local list_opts = {}
    for k, v in pairs(opts or {}) do list_opts[k] = v end
    list_opts.ui = saved_ui
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
    end, stats_plugin, list_opts)
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

    local widget            -- the list below; the rows' long press asks it for its display mode
    local function buildItems()
      local item_table = {}
      annotateRatings(books)
      for _idx, book in ipairs(books) do
        local id_str = tostring(book.id_book)
        local item
        item = {
            text         = rowText(book, id_str),
            -- Right-hand column: the day of this book's last reading
            -- entry - the very thing the "finished" rule is judged on, and
            -- what the list is sorted by out of the box.
            mandatory    = dateText(book.last_read),
            values       = valueTable(book),
            sort_title   = book.title or "",
            sort_time    = book.last_read or 0,
            sort_rating  = book.rating or 0,
            checked_func = function() return isFinished(id_str) end,
            -- Long press while the rating column is shown: edit the rating.
            hold_callback = function(_item, refresh)
                if not widget or widget.display_mode ~= "rating" then return end
                rateStatsBook(book, function(n)
                    item.values      = valueTable(book)
                    item.sort_rating = n
                    if refresh then refresh() end
                end)
            end,
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
        UIManager:show(InfoMessage:new{ text = _("No books this year") })
        return
    end

    widget = ListWidget.new{
        title            = T(_("Mark book finished - %1"), tostring(year)),
        item_table       = item_table,
        sort_setting_key = SORT_KEY_CHECKLIST,
        sort_modes       = ListWidget.BOOK_SORT_MODES,
        display_modes    = MODES_DATED,
        display_setting_key = DISPLAY_KEY_CHECKLIST,
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
--
-- Returned as "YYYY-MM-DD" (what the store keeps); the dialog below shows
-- it, like every other date the entry is edited through, in the configured
-- date format.
local function defaultManualDate(year)
    local today = os.date("*t")
    if tostring(today.year) == tostring(year) then
        return os.date("%Y-%m-%d")
    end
    return string.format("%s-12-31", tostring(year))
end

-- The series field of the book editor: "Name #2" - the number is optional.
local function seriesFieldText(entry)
    if not entry or not entry.series or entry.series == "" then return "" end
    local idx = entry.series_index
    if idx and idx ~= "" then return entry.series .. " #" .. tostring(idx) end
    return entry.series
end

-- Splits what was typed into the series field into name and number.
-- "Dune #2" -> "Dune", "2"; "Dune" -> "Dune", ""; returns nil for a "#" that
-- isn't followed by a number. A number alone ("#2") has no series to belong
-- to, so it is dropped.
local function parseSeriesField(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not text:find("#", 1, true) then return text, "" end
    local name, num = text:match("^(.-)%s*#%s*(.-)%s*$")
    if not name then return nil end
    local idx = Manual.normaliseSeriesIndex(num)
    if not idx or idx == "" then return nil end
    if name == "" then return "", "" end
    return name, idx
end

local function editManualBook(year, entry, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local date_hint = Locale.dateFormatHint()
    local dialog
    -- The rating is picked in the star popup (five stars side by side, tap
    -- or slide), opened from the button row below; the button shows the
    -- stars chosen so far.
    local rating = Manual.normaliseRating(entry and entry.rating) or 0
    local function ratingButtonText()
        return _("Rating") .. "  " .. Ratings.stars(rating)
    end
    local function openRating()
        RatingDialog.show{
            title   = entry and entry.title or _("Add book"),
            rating  = rating,
            on_save = function(n)
                rating = n
                local b = dialog and dialog.button_table
                    and dialog.button_table:getButtonById("rating")
                if b then
                    b:setText(ratingButtonText(), b.width)
                    UIManager:setDirty(dialog, "ui")
                end
            end,
        }
    end
    dialog = MultiInputDialog:new{
        -- The list this is opened from is modal, and UIManager inserts
        -- non-modal windows below the topmost modal one - without this the
        -- dialog would open behind the list.
        modal  = true,
        title  = entry and _("Edit book") or _("Add book"),
        -- Order matters: with the on-screen keyboard up only the top of this
        -- dialog is visible, so the fields most often edited (title, author,
        -- date read) come first and the optional series ones last.
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
            -- Shown and typed in the configured date format (Settings ▸
            -- Advanced settings ▸ Date & time ▸ "Date format"), while the
            -- store keeps ISO either way - so an entry added under one
            -- format still reads back correctly after the setting is
            -- changed.
            {
                description = T(_("Date read (%1)"), date_hint),
                text        = Locale.formatDate(
                    (entry and entry.date ~= "" and entry.date)
                    or defaultManualDate(year)),
                hint        = date_hint,
            },
            -- Optional: the series and the book's number in it, typed in one
            -- field as "Dune #2" (or "Dune #2.5"). Either part may be left out.
            {
                description = _("Series"),
                text        = seriesFieldText(entry),
                hint        = _("e.g. Dune #2"),
            },
        },
        buttons = {
          {
            {
                text     = ratingButtonText(),
                id       = "rating",
                callback = openRating,
            },
          },
          {
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
                    local series, idx = parseSeriesField(fields[4])
                    if title == "" then
                        UIManager:show(InfoMessage:new{ text = _("Please enter a title") })
                        return
                    end
                    if not series then
                        UIManager:show(InfoMessage:new{
                            text = _("Please enter the number in the series as a number (e.g. 2 or 2.5)") })
                        return
                    end
                    -- An empty date is fine (the entry then sorts by when it
                    -- was added); a date that isn't one is not, or it would
                    -- be silently dropped on save. What was typed is read
                    -- back through the configured format and stored as ISO.
                    if date ~= "" then
                        local iso = Locale.parseDateInput(date)
                        if not iso or not Manual.parseDate(iso) then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Please enter the date as %1"), date_hint) })
                            return
                        end
                        date = iso
                    end
                    UIManager:close(dialog)
                    local values = { title = title, authors = authors, series = series,
                                    series_index = idx, date = date, rating = rating }
                    if entry then
                        Manual.update(year, entry.id, values)
                    else
                        Manual.add(year, values)
                    end
                    if on_done then on_done() end
                end,
            },
          },
        },
    }
    -- No dialog:onShowKeyboard() here: the keyboard only comes up once a
    -- field is tapped (MultiInputDialog:onSwitchFocus shows it then).
    UIManager:show(dialog)
end

-- Just the title; the date it was read is the row's right-hand value (see
-- the item's `mandatory` field below), the same layout the finished-books
-- list and the checklist use. The author is still stored and editable, it
-- simply isn't what these rows are scanned for.
local function manualRowText(entry)
    local text = entry.title or _("Unknown")
    -- The row is a single line, so the series follows the title in
    -- brackets: "Title (Series / #2)".
    local line = seriesText(entry.series, entry.series_index)
    if line ~= "" then text = text .. " (" .. line .. ")" end
    return text
end

-- The list of hand-added books for one year: a pinned "add a book" row on
-- top, then one row per entry. Long-pressing an entry offers edit and delete;
-- both write straight through to the store and rebuild the list in place.
-- Tapping an entry opens its Book info popup; long-pressing it offers edit and delete.
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
            local row
            row = {
                text       = manualRowText(this_entry),
                -- Only a date the reader actually gave: entries saved
                -- without one fall back to their creation time for
                -- sorting, which isn't a reading date and shouldn't be
                -- shown as one.
                mandatory  = (this_entry.date ~= "" and dateText(this_entry.read_ts)) or "",
                values     = {
                    rating = Ratings.stars(this_entry.rating),
                },
                sort_title = this_entry.title or "",
                sort_time  = this_entry.read_ts or this_entry.ts or 0,
                sort_rating = this_entry.rating or 0,
                -- Long press: edit or delete the entry.
                hold_callback = function()
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local dialog
                    dialog = ButtonDialog:new{
                        -- Modal, or it opens behind the list.
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
                -- Tap: the Book info popup, like any other book list. A
                -- rating set there is saved with the entry.
                callback   = function()
                    if not BookInfoPopup then return end
                    local has_date = this_entry.date ~= ""
                    local book = {
                        title        = this_entry.title,
                        authors      = this_entry.authors or "",
                        series       = this_entry.series or "",
                        series_index = this_entry.series_index or "",
                        date_known   = has_date,
                        duration     = 0,
                        pages        = 0,
                        rating       = this_entry.rating or 0,
                        manual_id    = this_entry.id,
                        manual_year  = year,
                        last_read    = this_entry.read_ts or this_entry.ts or 0,
                        manual       = true,
                    }
                    UIManager:show(BookInfoPopup:new{
                        modal       = true,
                        book        = book,
                        finished_ts = (has_date and (book.last_read or 0) > 0) and book.last_read or nil,
                        save_rating = function(n)
                            Manual.update(year, this_entry.id, { rating = n })
                            return true
                        end,
                        on_rate = function(n)
                            this_entry.rating = n
                            row.values        = { rating = Ratings.stars(n) }
                            row.sort_rating   = n
                        end,
                        on_close = function()
                            widget:updateItems(buildItems())
                        end,
                    })
                end,
            }
            table.insert(items, row)
        end
        return items
    end

    widget = ListWidget.new{
        title            = T(_("Add books manually - %1"), tostring(year)),
        item_table       = buildItems(),
        sort_setting_key = SORT_KEY_MANUAL,
        sort_modes       = ListWidget.BOOK_SORT_MODES,
        display_modes    = MODES_MANUAL,
        display_setting_key = DISPLAY_KEY_MANUAL,
        show_ok_cancel   = false,
        -- No per-row checkboxes here, so drop the blank checkbox column that
        -- otherwise leaves an empty gap on the left (same as the achievements
        -- list).
        no_checkbox      = true,
        close_callback   = function()
            refreshGoalSection(insights_popup, year)
        end,
    }
    UIManager:show(widget)
end

return M
