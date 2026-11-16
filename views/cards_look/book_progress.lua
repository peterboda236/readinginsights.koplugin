--[[
Reading Insights - the "Cards" look of the Book progress popup (Settings >
Appearance > Look).

Builds the same sections as book_stats_view.lua's buildSections (the Classic
look), each one as a card with an icon in its header: Chapter, Chapters,
This book, Pace. Chapter and Chapters share one card while they stand next
to each other in the section order. The tap targets are stored on the popup under the same
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
-- take; taller cards go on pages (views/cards_look/pages.lua). plain: no
-- rings or bars, only the values (the sleep screen's fallback, see the end).
function M.buildSections(stats, fonts, layout, popup, H, avail_h, plain)
    local Opt = VS.Opt
    local readonly = popup and popup.readonly
    local small = Fonts.getFace("insights_small")
    local card_fonts = { value = fonts.value, label = fonts.label, small = small }

    local ilayout = UI.cardLayout(layout)
    local inner_w = ilayout.content_width
    local divider = Colors.cardsColor("divider")
    -- Settings > Book progress popup > Progress bar.
    local show_bars = not plain and Opt.readShowCellBars()
    local probe = TextWidget:new{ text = "0", face = fonts.value }
    local value_h = probe:getSize().h
    probe:free()
    -- Bars and the timeline follow the value text, so they keep their weight
    -- on every screen and font size.
    local bar_h = math.max(Screen:scaleBySize(4), math.floor(value_h * 0.24 + 0.5))
    local timeline_h = math.floor(value_h * 0.64 + 0.5)

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
    -- The gap above the header keeps the Time / Pages switch and the chapter
    -- chip, which fill their row, off the card's top edge.
    local function cardBody(header, rows)
        local body = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = Size.padding.default },
            header,
            VerticalSpan:new{ width = Size.padding.small },
        }
        for _idx, w in ipairs(rows) do table.insert(body, w) end
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        return body
    end
    local function chevron(after_word)
        return UI.chevron(fonts.section, after_word)
    end
    -- The This chapter and This book rings share one size: about three
    -- value lines, at most a good part of a column.
    local ring_d = math.max(Screen:scaleBySize(48), math.min(3 * value_h, math.floor(ilayout.col_width * 0.42)))
    -- Above a ring: the room a value line has above its digits, so the ring
    -- starts where the values beside and above it start.
    local ring_top = UI.capTopRoom(fonts.value)
    local function ring(ratio, text)
        return Donut.build{
            ratio        = ratio,
            diameter     = ring_d,
            thickness    = math.floor(ring_d * 0.11 + 0.5),
            text         = text,
            face         = Fonts.getBoldFace("stats_value"),
            text_color   = Colors.value(),
            read_color   = Colors.cardsColor("active_bar"),
            unread_color = Colors.cardsColor("inactive_bar"),
        }
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

    -- Whether This book and Pace are drawn: decides below whether Chapter and
    -- Chapters stand next to each other.
    local donut_style = not plain and Donut ~= nil and Opt.readBookSectionStyle() == Opt.BOOK_SECTION_STYLE_DONUT
    -- Every value cell has its own switch (Settings > Book progress popup);
    -- a row is drawn while at least one of its two cells is on.
    local show_pct    = Opt.readBookCell("read_pct")
    local show_pages  = Opt.readBookCell("read_pages")
    local show_tleft  = Opt.readBookCell("time_left")
    local show_tspent = Opt.readBookCell("time_spent")
    local show_read_row = donut_style or show_pct or show_pages
    local show_time_row = donut_style or show_tleft or show_tspent
    local has_book_rows = show_read_row or show_time_row
    local show_today  = Opt.readBookCell("today")
    local show_avg     = Opt.readBookCell("avg_day")
    local show_pace_today = show_today or show_avg
    local show_started = (stats.started_days_ago and Opt.readBookCell("started")) and true or false
    local show_finish  = (stats.finish_days_left and Opt.readBookCell("finish")) and true or false
    local show_dates_row  = show_started or show_finish

    local chapter_view_mode = (popup and popup._chapter_view_mode) or "time"
    local pages_mode = (chapter_view_mode == "pages")
    local show_two_next = Opt.readNextChapterCount() == 2 and stats.has_chapter_after_next
    local show_cur  = Opt.readShowChapterCurrent()
    local show_next = Opt.readShowChapterNext() and stats.has_next_chapter
    local show_chapter_card  = show_cur or show_next
    local show_chapters_card = show_chapter_bar and not skim_in_book
    -- Chapter and Chapters next to each other in the section order (hidden
    -- sections skipped) make one card, the chapter bar at its bottom.
    local merge_chapters = false
    if show_chapter_card and show_chapters_card then
        local order = VS.Order.effective("book", {
            chapter = true, chapters = true,
            book = has_book_rows or skim_in_book,
            pace = show_pace_today or show_dates_row,
        })
        for i = 2, #order do
            local a, b = order[i - 1], order[i]
            if (a == "chapter" and b == "chapters") or (a == "chapters" and b == "chapter") then
                merge_chapters = true
            end
        end
    end

    -- The chapter count: "8 / 20" (tap: chapters left) as a chip in the
    -- Chapters header, and the typical length (tap: time / pages) under the
    -- chapter bar, keyed with the dashed mark the next chapters' bars show it
    -- with. Both nil when the count row is off.
    local count_chip, typical_row, typical_pages
    if show_chapters_card and stats.chapter_info and Opt.readShowChapterCountRow() then
        local ci = stats.chapter_info
        local left, left_label, right, right_label = H.chapterCountValues(ci, stats, popup)
        local can_swap = popup and not readonly
        local can_swap_left = can_swap and not stats.at_book_end
        local left_mode = popup and popup._chapter_read_mode == "left" and not stats.at_book_end
        local chip = UI.buildPill(left_mode and joinLabel(left.value, left_label) or left.value, small, true, nil,
            can_swap_left and UI.swapIcon(small) or nil)
        count_chip = H.tappableWrap(chip, chip:getSize().w)
        if popup and not stats.at_book_end then popup._chapter_read_cell = count_chip end
        typical_pages = show_bars and stats.avg_chapter_pages or nil
        local typical = UI.buildInlineCell(card_fonts, inner_w, right.value, right_label, {
            swap = can_swap,
            lead = typical_pages and UI.buildDashMark(math.floor(value_h * 0.7)) or nil,
        })
        typical_row = H.tappableWrap(typical, inner_w)
        if popup then popup._chapter_avg_cell = typical_row end
    end

    -- The chapter bar, then the typical length.
    local function chaptersRows()
        storeChapterBarOnPopup()
        local rows = { chapter_bar }
        if typical_row then
            table.insert(rows, VerticalSpan:new{ width = Size.padding.small })
            table.insert(rows, typical_row)
        end
        return rows
    end

    -- ===== Chapter: This chapter / Next chapter =========================
    -- Tapping the card switches time / pages (onTapClose, _chapter_headers).
    if show_chapter_card then
        local function columnTitle(title, width)
            return TextWidget:new{ text = title, face = fonts.label, bold = true, fgcolor = Colors.section(), max_width = width }
        end

        -- This chapter: what is left of it; how much of it is read as a ring
        -- (Donut chart style) or a bar under the value (Classic style).
        local function thisChapterColumn(width)
            local function value(w)
                if pages_mode then
                    local left_count = stats.chapter_pages_left_count
                    return statCell(left_count and { value = formatCount(left_count), unit = "" } or { value = "—", unit = "" },
                        N_("page left", "pages left", left_count or 0), w)
                end
                return statCell(stats.chapter_time_left_hhmm, _("reading time left"), w)
            end
            local ratio = stats.chapter_progress_ratio
            local col = VerticalGroup:new{ align = "left", columnTitle(_("This chapter"), width) }
            if donut_style and ratio then
                local ring_w = ring(ratio, formatCount(math.floor(100 * ratio + 0.5)) .. "%")
                local gap = Size.padding.large
                table.insert(col, VerticalSpan:new{ width = Size.padding.small + ring_top })
                table.insert(col, HorizontalGroup:new{
                    align = "center",
                    ring_w,
                    HorizontalSpan:new{ width = gap },
                    value(math.max(1, width - ring_w:getSize().w - gap)),
                })
                table.insert(col, VerticalSpan:new{ width = Size.padding.default })
                return col
            end
            table.insert(col, value(width))
            if show_bars and ratio then
                table.insert(col, VerticalSpan:new{ width = Size.padding.small })
                table.insert(col, UI.buildRoundBar(ratio, width, bar_h))
            end
            return col
        end

        -- Next chapter(s): how long they are. With the progress bars on and
        -- something to compare with (the typical length or a second
        -- chapter), each one is a value over a bar as long as the chapter,
        -- the typical length dashed across it; otherwise the values side by
        -- side.
        local function nextChaptersColumn(width)
            local next_title = show_two_next and _("Next 2 chapters") or _("Next chapter")
            local col = VerticalGroup:new{ align = "left", columnTitle(next_title, width) }
            local chapters = { { pages = stats.next_chapter_pages_count, time = stats.next_chapter_time_hhmm } }
            if show_two_next then
                table.insert(chapters, { pages = stats.chapter_after_next_pages_count, time = stats.chapter_after_next_time_hhmm })
            end
            if show_bars and (typical_pages or show_two_next) then
                -- The chapter times are pages * the average time per page,
                -- so the page counts give the bar lengths in both views.
                local longest = typical_pages or 0
                for _idx, ch in ipairs(chapters) do longest = math.max(longest, ch.pages or 0) end
                local scale = 1.25 * longest
                for _idx, ch in ipairs(chapters) do
                    local val, label
                    if pages_mode then
                        val = ch.pages and formatCount(ch.pages) or "—"
                        label = N_("page", "pages", ch.pages or 0)
                    else
                        val = ch.time.value
                        label = show_two_next and "" or _("reading time")
                    end
                    table.insert(col, VerticalSpan:new{ width = Size.padding.small })
                    table.insert(col, UI.buildInlineCell(card_fonts, width, val, label))
                    if ch.pages and scale > 0 then
                        table.insert(col, UI.buildMarkerBar(ch.pages / scale,
                            typical_pages and typical_pages / scale, width, bar_h, true))
                    end
                end
                return col
            end
            if show_two_next then
                local sub_layout = { col_width = H.splitHalfWidth(ilayout), column_gap = ilayout.column_gap }
                local function side(ch)
                    if not pages_mode then
                        return H.buildSplitCellValue(fonts.value, fonts.label, ch.time.value, nil)
                    end
                    if not ch.pages then return H.buildSplitCellValue(fonts.value, fonts.label, "—", nil) end
                    return H.buildPagesSplitValue(fonts.value, fonts.label, formatCount(ch.pages), ch.pages, sub_layout.col_width)
                end
                table.insert(col, UI.buildTwoColRow(side(chapters[1]), side(chapters[2]),
                    sub_layout, false, nil, Size.line.thin, divider))
            elseif pages_mode then
                local count = chapters[1].pages
                table.insert(col, statCell(count and { value = formatCount(count), unit = "" } or UI.emptyValue(),
                    count and N_("page", "pages", count) or "", width))
            else
                table.insert(col, statCell(chapters[1].time, _("reading time"), width))
            end
            return col
        end

        local row
        if show_cur and show_next then
            local cur_col = thisChapterColumn(ilayout.col_width)
            local next_col = nextChaptersColumn(ilayout.col_width)
            local col_h = math.max(cur_col:getSize().h, next_col:getSize().h)
            row = twoCol(UI.padBottom(cur_col, col_h - cur_col:getSize().h),
                UI.padBottom(next_col, col_h - next_col:getSize().h))
        elseif show_cur then
            row = thisChapterColumn(inner_w)
        else
            row = nextChaptersColumn(inner_w)
        end
        local switch = (not readonly)
            and UI.buildSegmented({ _("Time"), _("Pages") }, pages_mode and 2 or 1, small) or nil
        if merge_chapters then
            -- Only the top part switches time / pages: the chip, the bar and
            -- the typical length have taps of their own.
            local top = H.tappableWrap(VerticalGroup:new{
                align = "left",
                UI.cardHeader("chapters", _("Chapters"), fonts.section, inner_w, false, switch, count_chip),
                VerticalSpan:new{ width = Size.padding.small },
                row,
            }, inner_w)
            if popup then popup._chapter_headers = top end
            local rows = { VerticalSpan:new{ width = Size.padding.default } }
            for _idx, w in ipairs(chaptersRows()) do table.insert(rows, w) end
            addCard(UI.buildCard(cardBody(top, rows), layout.content_width), "chapter")
        else
            local card = UI.buildCard(cardBody(
                UI.cardHeader("bookmark", _("Chapter"), fonts.section, inner_w, false, switch),
                { row }), layout.content_width)
            local wrap = H.tappableWrap(card, card:getSize().w)
            if popup then popup._chapter_headers = wrap end
            addCard(wrap, "chapter")
        end
    end

    -- ===== Chapters =====================================================
    if show_chapters_card and not merge_chapters then
        addCard(UI.buildCard(cardBody(
            UI.cardHeader("chapters", _("Chapters"), fonts.section, inner_w, false, nil, count_chip), chaptersRows()),
            layout.content_width), "chapters")
    end

    -- ===== This book ====================================================
    -- Tapping the card opens Book info (onTapClose, _this_book_header).
    -- Two cells side by side; with only one of them on it keeps the left
    -- position (the other half stays blank, without a separator).
    local function cellsRow(left, right)
        if left and right then return twoCol(left, right) end
        return UI.buildTwoColRow(left or right, VerticalSpan:new{ width = 0 }, ilayout, true)
    end
    if has_book_rows or skim_in_book then
        local header = UI.cardHeader("book", _("This book"), fonts.section, inner_w, false,
            (not readonly) and chevron() or nil)

        local rows = {}
        if skim_in_book then
            storeChapterBarOnPopup()
            table.insert(rows, skim_bar)
        end
        if has_book_rows and donut_style then
            local stack = VerticalGroup:new{ align = "left" }
            local stack_w = inner_w - ring_d - Size.padding.large
            local function line(data, label)
                table.insert(stack, H.buildValueLine(fonts.value, fonts.label, stack_w, data, label))
            end
            if show_read_row then line(stats.book_pages_read, "") end
            if show_time_row then
                line(stats.book_time_left_hhmm, _("reading time left"))
                line(stats.book_time_spent_hhmm, _("read so far"))
            end
            table.insert(rows, VerticalSpan:new{ width = ring_top })
            table.insert(rows, HorizontalGroup:new{
                align = "center",
                ring(stats.book_progress_ratio, stats.book_progress.value) or VerticalSpan:new{ width = 0 },
                HorizontalSpan:new{ width = Size.padding.large },
                stack,
            })
            -- Text rows end with the room under their letters; the ring
            -- doesn't, so it gets that room here (as the bar below does).
            table.insert(rows, VerticalSpan:new{ width = Size.padding.default })
        elseif has_book_rows then
            if show_read_row then
                table.insert(rows, cellsRow(
                    show_pct and statCell(stats.book_progress, stats.book_progress.value ~= "" and _("read") or "") or nil,
                    show_pages and statCell(stats.book_pages_read, "") or nil))
                if show_bars and show_pct then
                    table.insert(rows, VerticalSpan:new{ width = Size.padding.default })
                    table.insert(rows, UI.buildRoundBar(stats.book_progress_ratio, inner_w, bar_h))
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
        local card = UI.buildCard(cardBody(header, rows), layout.content_width)
        local wrap = H.tappableWrap(card, card:getSize().w)
        if popup then popup._this_book_header = wrap end
        addCard(wrap, "book")
    end

    -- ===== Pace =========================================================
    -- Header tap: Book progress calendar; tap on the first row or the
    -- switch: time / pages (onTapClose, _pace_header / _pace_row).
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
                (not readonly and stats.book_id) and chevron(true) or nil),
            inner_w)
        if popup then popup._pace_header = header end

        local rows = {}
        if show_pace_today then
            local today_val, today_label, avg_val, avg_label = H.paceTodayValues(stats, pace_pages)
            -- With the progress bars on: today's value over a bar with a mark
            -- at the daily average (on the scale of the larger of the two),
            -- the average under the bar against the right edge.
            local today_n = pace_pages and stats.today_pages_count or stats.today_secs
            local avg_n = pace_pages and stats.avg_pages_per_day_count or stats.avg_secs_per_day
            local content
            if show_bars and show_today and show_avg and today_n and avg_n and avg_n > 0 then
                local scale = math.max(today_n, avg_n)
                content = VerticalGroup:new{
                    align = "left",
                    UI.buildInlineCell(card_fonts, inner_w, today_val.value, joinLabel(today_val.unit, today_label)),
                    VerticalSpan:new{ width = Size.padding.small },
                    UI.buildMarkerBar(today_n / scale, avg_n / scale, inner_w, bar_h),
                    VerticalSpan:new{ width = Size.padding.small },
                    UI.buildInlineCell(card_fonts, inner_w, avg_val.value, joinLabel(avg_val.unit, avg_label),
                        { align = "right" }),
                }
            else
                content = cellsRow(show_today and statCell(today_val, today_label) or nil,
                    show_avg and statCell(avg_val, avg_label) or nil)
            end
            local pace_row = H.tappableWrap(content, inner_w)
            if popup then popup._pace_row = pace_row end
            table.insert(rows, pace_row)
        end
        if show_dates_row then
            if show_pace_today then
                table.insert(rows, VerticalSpan:new{ width = Size.padding.default })
            end
            if show_started and show_finish then
                -- With the progress bars on: a line from the start to the
                -- expected finish with a dot at today, the two values under
                -- its ends.
                local done_days = show_bars and stats.started_days_count or nil
                local started_tap = H.tappableWrap(statCell(stats.started_days_ago, ""), ilayout.col_width)
                local finish_tap  = H.tappableWrap(statCell(H.finishDaysValue(stats), "", nil,
                    done_days and { align = "right" } or nil), ilayout.col_width)
                if popup then
                    popup._started_widget = started_tap
                    popup._finish_widget  = finish_tap
                end
                if done_days then
                    table.insert(rows, UI.buildTimeline(
                        done_days / math.max(1, done_days + stats.finish_days_left),
                        inner_w, timeline_h))
                    table.insert(rows, VerticalSpan:new{ width = Size.padding.small })
                    table.insert(rows, UI.buildTwoColRow(started_tap, finish_tap, ilayout, true))
                else
                    table.insert(rows, twoCol(started_tap, finish_tap))
                end
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
        makeLead = function() return VerticalSpan:new{ width = UI.gap() } end,
    })

    -- The full-width sheet hanging from the top edge closes with a thick
    -- line, as in the Classic look; the centered box has its own border.
    local closing_line = not (popup and popup._centered) and LineWidget:new{
        dimen      = Geom:new{ w = layout.full_width, h = Size.line.thick },
        background = Blitbuffer.COLOR_BLACK,
    } or nil
    local room = (avail_h or math.huge) - (closing_line and Size.line.thick or 0)

    -- The sleep screen can't turn pages: when the cards don't fit, they are
    -- drawn again without the rings and bars.
    if readonly and not plain and sections:getSize().h > room then
        return M.buildSections(stats, fonts, layout, popup, H, avail_h, true)
    end

    local content = sections
    if popup then popup._page_count = 1 end
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
