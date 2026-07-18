--[[
Reading Insights - chapter/TOC information for the book progress view.

Turns a document's table of contents into the numbers book_stats_view.lua
draws: which chapter the reader is in, how many chapters there are, how many
pages each one spans, and how far into the current one they've read. Split
out of that view because none of it is UI - it's pure computation over a TOC
table plus a page number, which also makes it testable on its own, without
KOReader running.

The TOC parsing is the expensive part, so it's cached: one entry, keyed by
book id and validated against the document's total page count (a changed
page count means a re-flow/re-render, so the cached page spans no longer
mean anything and the entry is dropped). Opening a different book evicts the
previous entry rather than growing the table. A book whose TOC can't be
parsed at all is remembered as `false`, so the failing parse isn't retried
on every single page turn.

KOReader hands out TOCs in more than one shape, and all of them are
accepted here: a list of tables with a `page` field (optionally with `depth`,
in which case only top-level entries count as chapters), or a plain list of
page numbers (`toc_ticks`). Anything else is treated as "no usable TOC".

  M.computeChapterResult(toc_items, items_are_tables, total, page_counts, pageno)
                                current chapter + progress ratio from an
                                already-parsed TOC
  M.getCachedChapterInfo(book_id, toc, pages, pageno)
                                the same, parsing (and caching) the TOC first;
                                nil when there's no usable TOC
  M.getChapterPagesLeft(ui, pageno)
                                pages left in the current chapter, falling
                                back to pages left in the book
]]--

local M = {}

-- TOC cache: single entry keyed by book_id, validated against total page count.
local _toc_cache     = {}   -- [book_id] = entry table, or false on parse failure
local _toc_cache_key = nil  -- book_id of the single cached entry

-- Shared helper: current chapter index + progress ratio from a resolved TOC entry.
function M.computeChapterResult(toc_items, items_are_tables, total_chapters, page_counts, pageno)
    local current_chapter = 0
    if items_are_tables then
        for i = total_chapters, 1, -1 do
            if toc_items[i].page <= pageno then
                current_chapter = i
                break
            end
        end
    else
        for i = total_chapters, 1, -1 do
            if toc_items[i] <= pageno then
                current_chapter = i
                break
            end
        end
    end
    if current_chapter == 0 then current_chapter = 1 end

    local chapter_progress_ratio = 0.0
    local cur_pc = (page_counts or {})[current_chapter] or 1
    if cur_pc > 0 then
        local cur_start = items_are_tables
            and toc_items[current_chapter].page
            or  toc_items[current_chapter]
        local pages_read_in_chapter = math.max(0, pageno - cur_start) + 0.5
        chapter_progress_ratio = math.min(0.95, pages_read_in_chapter / cur_pc)
    end

    return {
        current                = current_chapter,
        total                  = total_chapters,
        page_counts            = page_counts,
        chapter_progress_ratio = chapter_progress_ratio,
    }
end

function M.getCachedChapterInfo(book_id, toc, pages, pageno)
    if not book_id then return nil end

    -- explicit cache-hit / miss / invalidate branches
    local cached = _toc_cache[book_id]
    if cached == false then
        return nil
    elseif cached ~= nil then
        if cached._pages ~= pages then
            _toc_cache[book_id] = nil
            _toc_cache_key      = nil
        else
            return M.computeChapterResult(
                cached._toc_items,
                cached._items_are_tables,
                cached._total,
                cached._page_counts,
                pageno
            )
        end
    end

    -- Cache miss: parse TOC and store (at most 1 entry).
    local chapter_info = nil
    local ok = pcall(function()
        local toc_items = nil

        if toc.getToc and type(toc.getToc) == "function" then
            local raw = toc:getToc()
            if raw and #raw > 0 then
                local chapter_entries = {}
                local has_depth = raw[1] and raw[1].depth ~= nil
                for _, entry in ipairs(raw) do
                    if not has_depth or (entry.depth or 1) == 1 then
                        table.insert(chapter_entries, entry)
                    end
                end
                if #chapter_entries == 0 then chapter_entries = raw end
                toc_items = chapter_entries
            end
        end

        if not toc_items and toc.toc_ticks and #toc.toc_ticks > 0 then
            toc_items = toc.toc_ticks
        end
        if not toc_items and toc.toc and type(toc.toc) == "table" and #toc.toc > 0 then
            toc_items = toc.toc
        end

        if not toc_items or #toc_items == 0 then return end

        local total_chapters   = #toc_items
        local page_counts      = {}
        local items_are_tables = type(toc_items[1]) == "table" and toc_items[1].page ~= nil

        if items_are_tables then
            for i = 1, total_chapters do
                local start_p = toc_items[i].page
                local end_p   = (i < total_chapters) and (toc_items[i + 1].page - 1) or pages
                page_counts[i] = math.max(1, end_p - start_p + 1)
            end
        elseif type(toc_items[1]) == "number" then
            for i = 1, total_chapters do
                local start_p = toc_items[i]
                local end_p   = (i < total_chapters) and (toc_items[i + 1] - 1) or pages
                page_counts[i] = math.max(1, end_p - start_p + 1)
            end
        else
            return  -- unknown TOC format
        end

        -- evict previous entry before storing the new one
        if _toc_cache_key and _toc_cache_key ~= book_id then
            _toc_cache[_toc_cache_key] = nil
        end
        _toc_cache[book_id] = {
            _toc_items        = toc_items,
            _items_are_tables = items_are_tables,
            _page_counts      = page_counts,
            _total            = total_chapters,
            _pages            = pages,
        }
        _toc_cache_key = book_id

        chapter_info = M.computeChapterResult(
            toc_items, items_are_tables, total_chapters, page_counts, pageno
        )
    end)

    if not ok or not chapter_info then
        _toc_cache[book_id] = false
        return nil
    end

    return chapter_info
end

function M.getChapterPagesLeft(ui, pageno)
    if not ui or not ui.toc then return end
    local pages_left = ui.toc:getChapterPagesLeft(pageno, true)
    if pages_left == nil and ui.document then
        pages_left = ui.document:getTotalPagesLeft(pageno)
    end
    return pages_left
end

return M
