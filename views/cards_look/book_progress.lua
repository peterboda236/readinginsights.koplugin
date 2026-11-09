--[[
Reading Insights - the "Cards" look of the Book progress popup (Settings >
Appearance > Look).

Builds the same sections as book_stats_view.lua's buildSections (the Classic
look), each one as a card with an icon in its header: Chapter, Chapters,
This book, Pace. The tap targets are stored on the popup under the same
names the Classic builder uses, so ReadingStatsPopup:onTapClose handles both
looks.

Loaded once by main.lua and handed to the Book progress view as
`deps.BookCards`. The view passes its own small helpers (`H`) on each build.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Colors, Fonts, VS, UI, ChapterBar, SkimBar, Donut, Pages =
    deps.Locale, deps.Colors, deps.Fonts, deps.VS, deps.UI,
    deps.ChapterBar, deps.SkimBar, deps.Donut, deps.Pages

local _           = Locale._
local N_          = Locale.N_
local formatCount = Locale.formatCount

local M = {}

local function joinLabel(unit, label)
    if label and label ~= "" then
        if unit and unit ~= "" then return unit .. " " .. label end
        return label
    end
    return unit or ""
end

-- `callback` runs on a tap, before the popup's own tap handler sees it.
local function tappableCell(widget, callback)
    local size = widget:getSize()
    local cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h },
        widget,
    }
    cell.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } },
    }
    function cell:onTap()
        return callback()
    end
    return cell
end

-- stats: ReadingStatsPopup:gatherStats(); H: helpers from book_stats_view.lua
-- (tappableWrap, buildValueLine, splitHalfWidth, buildSplitCellValue,
-- buildPagesSplitValue, resetTapTargets, chapterBarPaging,
-- chapterCountValues, paceTodayValues, finishDaysValue). avail_h: the height the content may
-- take; taller cards go on pages (views/cards_look/pages.lua).
function M.buildSections(stats, fonts, layout, popup, H, avail_h)
    local Opt = VS.Opt
    local readonly = popup and popup.readonly
    local small = Fonts.getFace("insights_small")
    local card_fonts = { value = fonts.value, label = fonts.label, small = small }

    local ilayout = UI.cardLayout(layout)
    local inner_w = ilayout.content_width
    local divider = Colors.cardsColor("divider")

    local function statCell(data, label, width, opts)
        width = width or ilayout.col_width
        if not data or data.value == "" then
            return TextBoxWidget:new{
                text = data and data.unit or "", face = fonts.label,
                fgcolor = Colors.label(), width = width, alignment = "left",
            }
        end
        return UI.buildStatCell(card_fonts, width, data.value, joinLabel(data.unit, label), opts)
    end
    local function twoCol(left, right, opts)
        return UI.buildTwoColRow(left, right, ilayout, false, opts, Size.line.thin, divider)
    end
    local function hDivider()
        return Colors.vLine(inner_w, Size.line.thin, divider)
    end
    local function cardBody(header, rows)
        local body = VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = Size.padding.small },
        }
        for _idx, w in ipairs(rows) do table.insert(body, w) end
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        return body
    end
    local function chevron()
        return UI.chevron(fonts.section)
    end

    H.resetTapTargets(popup)

    local sections = VerticalGroup:new{ align = "left" }
    sections._breaks = {}
    -- Also kept for the section order (Settings > Book progress popup >
    -- Section order): the cards are built in a fixed order below and
    -- rearranged at the end (VS.Order.reorderGroup). `lead`: the gap
    -- UI.addCard puts above the very first card, which moves with the card
    -- that is first.
    local marks = {}
    local function addCard(card, id)
        table.insert(sections._breaks, #sections + 1)
        table.insert(marks, { id = id, first = #sections + 1, lead = (#sections == 0) or nil })
        UI.addCard(sections, card, layout)
    end

    -- ===== Chapter: This chapter / Next chapter =========================
    -- Tapping the card switches time / pages (onTapClose, _chapter_headers).
    local chapter_view_mode = (popup and popup._chapter_view_mode) or "time"
    local pages_mode = (chapter_view_mode == "pages")
    local show_two_next = Opt.readNextChapterCount() == 2 and stats.has_chapter_after_next
    local show_cur  = Opt.readShowChapterCurrent()
    local show_next = Opt.readShowChapterNext() and stats.has_next_chapter
    if show_cur or show_next then
        local function splitCell(side1, side2)
            local sub_layout = { col_width = H.splitHalfWidth(ilayout), column_gap = ilayout.column_gap }
            return UI.buildTwoColRow(side1, side2, sub_layout, false, nil, Size.line.thin, divider)
        end
        local cur_val, next_val
        if pages_mode then
            local left_count = stats.chapter_pages_left_count
            cur_val = statCell(left_count and { value = formatCount(left_count), unit = "" } or { value = "—", unit = "" },
                N_("page left", "pages left", left_count or 0))
            if show_two_next then
                local half_width = H.splitHalfWidth(ilayout)
                local function pagesWidget(count)
                    if not count then return H.buildSplitCellValue(fonts.value, fonts.label, "—", nil) end
                    return H.buildPagesSplitValue(fonts.value, fonts.label, formatCount(count), count, half_width)
                end
                next_val = splitCell(pagesWidget(stats.next_chapter_pages_count),
                    pagesWidget(stats.chapter_after_next_pages_count))
            else
                local next_count = stats.next_chapter_pages_count
                next_val = statCell(next_count and { value = formatCount(next_count), unit = "" } or UI.emptyValue(),
                    next_count and N_("page", "pages", next_count) or "")
            end
        else
            cur_val = statCell(stats.chapter_time_left_hhmm, _("reading time left"))
            if show_two_next then
                next_val = splitCell(
                    H.buildSplitCellValue(fonts.value, fonts.label, stats.next_chapter_time_hhmm.value, nil),
                    H.buildSplitCellValue(fonts.value, fonts.label, stats.chapter_after_next_time_hhmm.value, nil))
            else
                next_val = statCell(stats.next_chapter_time_hhmm, _("reading time"))
            end
        end
        local next_title = show_two_next and _("Next 2 chapters") or _("Next chapter")
        local function column(title, value, width)
            return VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = title, face = fonts.label, bold = true, fgcolor = Colors.section(), max_width = width },
                value,
            }
        end
        local row
        if show_cur and show_next then
            local cur_col = column(_("This chapter"), cur_val, ilayout.col_width)
            local next_col = column(next_title, next_val, ilayout.col_width)
            local col_h = math.max(cur_col:getSize().h, next_col:getSize().h)
            row = twoCol(UI.padBottom(cur_col, col_h - cur_col:getSize().h),
                UI.padBottom(next_col, col_h - next_col:getSize().h))
        elseif show_cur then
            row = column(_("This chapter"), cur_val, inner_w)
        else
            row = column(next_title, next_val, inner_w)
        end
        local switch = (not readonly)
            and UI.buildSegmented({ _("Time"), _("Pages") }, pages_mode and 2 or 1, small) or nil
        local card = UI.buildCard(cardBody(
            UI.cardHeader("bookmark", _("Chapter"), fonts.section, inner_w, false, switch),
            { row }), layout.content_width)
        local wrap = H.tappableWrap(card, card:getSize().w)
        if popup then popup._chapter_headers = wrap end
        addCard(wrap, "chapter")
    end

    -- ===== Chapter bar (or the skim bar) ================================
    local chapter_on_prev, chapter_on_next = H.chapterBarPaging(popup, stats, inner_w, 0)
    local chapter_bar, left_arrow, right_arrow, can_left, can_right = ChapterBar.build(
        stats.chapter_info, inner_w, 0, popup and popup.chapter_bar_offset or nil,
        chapter_on_prev, chapter_on_next, true)

    local skim_bar = nil
    if SkimBar and stats.skim and Opt.readChapterBarStyle() == Opt.CHAPTER_BAR_STYLE_SKIM then
        local skim_widget = SkimBar.build(stats.skim, inner_w)
        if skim_widget then
            skim_bar = FrameContainer:new{
                bordersize     = 0,
                padding        = 0,
                padding_top    = Size.padding.default,
                padding_bottom = Size.padding.default,
                margin         = 0,
                background     = Blitbuffer.COLOR_WHITE,
                skim_widget,
            }
            chapter_bar, left_arrow, right_arrow = skim_bar, nil, nil
            can_left, can_right = false, false
        end
    end
    local show_chapter_bar = chapter_bar and Opt.readShowChapterBar()
    local skim_in_book = (show_chapter_bar and skim_bar ~= nil) and true or false
    local function storeChapterBarOnPopup()
        if not popup then return end
        popup._chapter_bar            = chapter_bar
        popup._chapter_bar_prev_arrow = left_arrow
        popup._chapter_bar_next_arrow = right_arrow
        popup._chapter_bar_can_prev   = can_left
        popup._chapter_bar_can_next   = can_right
        popup._chapter_bar_on_prev    = chapter_on_prev
        popup._chapter_bar_on_next    = chapter_on_next
    end

    -- ===== Chapters =====================================================
    if show_chapter_bar and not skim_in_book then
        storeChapterBarOnPopup()
        local rows = { chapter_bar }
        local ci = stats.chapter_info
        if ci and Opt.readShowChapterCountRow() then
            local left, left_label, right, right_label = H.chapterCountValues(ci, stats, popup)
            local swap = (popup and not readonly) and { swap = true } or nil
            local read_cell = H.tappableWrap(
                statCell(left, left_label, nil, (not stats.at_book_end) and swap or nil), ilayout.col_width)
            if popup and not stats.at_book_end then popup._chapter_read_cell = read_cell end
            local avg_cell = H.tappableWrap(statCell(right, right_label, nil, swap), ilayout.col_width)
            if popup then popup._chapter_avg_cell = avg_cell end
            table.insert(rows, hDivider())
            table.insert(rows, VerticalSpan:new{ width = Size.padding.small })
            table.insert(rows, twoCol(read_cell, avg_cell))
        end
        addCard(UI.buildCard(cardBody(
            UI.cardHeader("chapters", _("Chapters"), fonts.section, inner_w, false), rows),
            layout.content_width), "chapters")
    end

    -- ===== This book ====================================================
    -- Header tap: Book info (onTapClose, _this_book_header).
    local donut_style = Donut ~= nil and Opt.readBookSectionStyle() == Opt.BOOK_SECTION_STYLE_DONUT
    -- Every value cell has its own switch (Settings > Book progress popup);
    -- a row is drawn while at least one of its two cells is on.
    local show_pct    = Opt.readBookCell("read_pct")
    local show_pages  = Opt.readBookCell("read_pages")
    local show_tleft  = Opt.readBookCell("time_left")
    local show_tspent = Opt.readBookCell("time_spent")
    local show_read_row = donut_style or show_pct or show_pages
    local show_time_row = donut_style or show_tleft or show_tspent
    -- Two cells side by side; with only one of them on it keeps the left
    -- position (the other half stays blank, without a separator).
    local function cellsRow(left, right)
        if left and right then return twoCol(left, right) end
        return UI.buildTwoColRow(left or right, VerticalSpan:new{ width = 0 }, ilayout, true)
    end
    local has_book_rows = show_read_row or show_time_row
    if has_book_rows or skim_in_book then
        local header = H.tappableWrap(
            UI.cardHeader("book", _("This book"), fonts.section, inner_w, false,
                (not readonly) and chevron() or nil),
            inner_w)
        if popup then popup._this_book_header = header end

        local rows = {}
        if skim_in_book then
            storeChapterBarOnPopup()
            table.insert(rows, skim_bar)
        end
        if has_book_rows and donut_style then
            local stack = VerticalGroup:new{ align = "left" }
            local stack_w = inner_w - math.floor(ilayout.col_width * 0.52) - Size.padding.large
            local function line(data, label)
                table.insert(stack, H.buildValueLine(fonts.value, fonts.label, stack_w, data, label))
            end
            if show_read_row then line(stats.book_pages_read, "") end
            if show_time_row then
                line(stats.book_time_left_hhmm, _("reading time left"))
                line(stats.book_time_spent_hhmm, _("read so far"))
            end
            local diameter = math.max(Screen:scaleBySize(48),
                math.min(stack:getSize().h, math.floor(ilayout.col_width * 0.52)))
            local ring = Donut.build{
                ratio        = stats.book_progress_ratio,
                diameter     = diameter,
                thickness    = math.floor(diameter * 0.11 + 0.5),
                text         = stats.book_progress.value,
                face         = Fonts.getBoldFace("stats_value"),
                text_color   = Colors.value(),
                read_color   = Colors.cardsColor("active_bar"),
                unread_color = Colors.cardsColor("inactive_bar"),
            }
            table.insert(rows, HorizontalGroup:new{
                align = "center",
                ring or VerticalSpan:new{ width = 0 },
                HorizontalSpan:new{ width = Size.padding.large },
                stack,
            })
        elseif has_book_rows then
            if show_read_row then
                table.insert(rows, cellsRow(
                    show_pct and statCell(stats.book_progress, stats.book_progress.value ~= "" and _("read") or "") or nil,
                    show_pages and statCell(stats.book_pages_read, "") or nil))
                if Opt.readShowCellBars() and show_pct then
                    table.insert(rows, VerticalSpan:new{ width = Size.padding.default })
                    table.insert(rows, UI.buildRoundBar(stats.book_progress_ratio, inner_w, Screen:scaleBySize(6)))
                    table.insert(rows, VerticalSpan:new{ width = Size.padding.default })
                elseif show_time_row then
                    table.insert(rows, VerticalSpan:new{ width = Size.padding.small })
                end
            end
            if show_time_row then
                table.insert(rows, cellsRow(
                    show_tleft and statCell(stats.book_time_left_hhmm, _("reading time left")) or nil,
                    show_tspent and statCell(stats.book_time_spent_hhmm, _("read so far")) or nil))
            end
        end
        addCard(UI.buildCard(cardBody(header, rows), layout.content_width), "book")
    end

    -- ===== Pace =========================================================
    -- Header tap: Book progress calendar; tap on the first row or the
    -- switch: time / pages (onTapClose, _pace_header / _pace_row).
    local show_today   = Opt.readBookCell("today")
    local show_avg     = Opt.readBookCell("avg_day")
    local show_pace_today = show_today or show_avg
    local show_started = (stats.started_days_ago and Opt.readBookCell("started")) and true or false
    local show_finish  = (stats.finish_days_left and Opt.readBookCell("finish")) and true or false
    local show_dates_row  = show_started or show_finish
    if show_pace_today or show_dates_row then
        local pace_pages = ((popup and popup._pace_view_mode) or "time") == "pages"
        local switch
        if show_pace_today and not readonly then
            switch = tappableCell(UI.buildSegmented({ _("Time"), _("Pages") }, pace_pages and 2 or 1, small),
                function()
                    popup._pace_view_mode = pace_pages and "time" or "pages"
                    VS.Opt.savePopupMode("pace_view", popup._pace_view_mode)
                    popup:_rebuildUI()
                    return true
                end)
        end
        local header = H.tappableWrap(
            UI.cardHeader("gauge", _("Pace"), fonts.section, inner_w, false, switch,
                (not readonly and stats.book_id) and chevron() or nil),
            inner_w)
        if popup then popup._pace_header = header end

        local rows = {}
        if show_pace_today then
            local today_val, today_label, avg_val, avg_label = H.paceTodayValues(stats, pace_pages)
            local today_cell = statCell(today_val, today_label)
            local avg_cell = statCell(avg_val, avg_label)
            local pace_row = H.tappableWrap(
                cellsRow(show_today and today_cell or nil, show_avg and avg_cell or nil), inner_w)
            if popup then popup._pace_row = pace_row end
            table.insert(rows, pace_row)
        end
        if show_dates_row then
            if show_pace_today then
                table.insert(rows, VerticalSpan:new{ width = Size.padding.small })
                table.insert(rows, hDivider())
                table.insert(rows, VerticalSpan:new{ width = Size.padding.small })
            end
            if show_started and show_finish then
                local started_tap = H.tappableWrap(statCell(stats.started_days_ago, ""), ilayout.col_width)
                local finish_tap  = H.tappableWrap(statCell(H.finishDaysValue(stats), ""), ilayout.col_width)
                if popup then
                    popup._started_widget = started_tap
                    popup._finish_widget  = finish_tap
                end
                table.insert(rows, twoCol(started_tap, finish_tap))
            elseif show_started then
                local started_tap = H.tappableWrap(statCell(stats.started_days_ago, "", inner_w), inner_w)
                if popup then popup._started_widget = started_tap end
                table.insert(rows, started_tap)
            else
                local finish_tap = H.tappableWrap(statCell(H.finishDaysValue(stats), "", inner_w), inner_w)
                if popup then popup._finish_widget = finish_tap end
                table.insert(rows, finish_tap)
            end
        end
        addCard(UI.buildCard(cardBody(header, rows), layout.content_width), "pace")
    end

    VS.Order.reorderGroup(sections, marks, "book", {
        makeLead = function() return VerticalSpan:new{ width = Size.padding.small } end,
    })

    -- The full-width sheet hanging from the top edge closes with a thick
    -- line, as in the Classic look; the centered box has its own border.
    local closing_line = not (popup and popup._centered) and LineWidget:new{
        dimen      = Geom:new{ w = layout.full_width, h = Size.line.thick },
        background = Blitbuffer.COLOR_BLACK,
    } or nil
    local room = (avail_h or math.huge) - (closing_line and Size.line.thick or 0)

    local content = sections
    if popup then popup._page_count = 1 end
    -- The sleep screen can't turn pages: it keeps one screen.
    if popup and not readonly and Pages and sections:getSize().h > room then
        content = Pages.paginate(popup, sections, room, fonts, layout.full_width, {
            "_chapter_headers", "_chapter_values", "_chapter_read_cell", "_chapter_avg_cell",
            "_this_book_header", "_pace_header", "_pace_row", "_started_widget", "_finish_widget",
            "_chapter_bar", "_chapter_bar_prev_arrow", "_chapter_bar_next_arrow",
        })
    end
    local out = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = layout.full_width },
        content,
    }
    if closing_line then table.insert(out, closing_line) end
    return out
end

return M
