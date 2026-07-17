--[[
Reading Insights - shared per-book reading-position helpers.

These read the current position / page counts of the open book straight
from the live ReaderUI (honouring page maps and hidden flows), and were
needed both by the compact book-stats overlay (book_stats_view.lua) and by
the per-book reading calendar's standalone entry point
(book_calendar_view.lua, which needs the book's total page count to draw
its cumulative-progress cells). Keeping them here avoids a second copy once
the calendar moved into its own file.

  BookProgress.data(ui)      raw table { current_page, total_pages,
                             current_page_idx, total_pages_idx, pagemap }
                             or nil when there's no usable open document
  BookProgress.pagesLeft(ui) pages remaining
  BookProgress.percent(ui)   integer 0..100 progress
  BookProgress.counts(ui)    current_page, total_pages (page-map aware)
]]--

local Math = require("optmath")

local M = {}

function M.data(ui)
    if not ui or not ui.document then return end
    local current_page = ui:getCurrentPage()
    local total_pages  = ui.document:getPageCount()
    if not current_page or not total_pages or total_pages == 0 then return end

    local pagemap = ui.pagemap and ui.pagemap:wantsPageLabels()
    local current_page_idx
    local total_pages_idx
    if pagemap then
        local _, page_idx, pages_idx = ui.pagemap:getCurrentPageLabel()
        current_page_idx = page_idx
        total_pages_idx  = pages_idx
    elseif ui.document:hasHiddenFlows() then
        local flow = ui.document:getPageFlow(current_page)
        current_page = ui.document:getPageNumberInFlow(current_page)
        total_pages  = ui.document:getTotalPagesInFlow(flow)
    end

    return {
        current_page     = current_page,
        total_pages      = total_pages,
        current_page_idx = current_page_idx,
        total_pages_idx  = total_pages_idx,
        pagemap          = pagemap,
    }
end

function M.pagesLeft(ui)
    local progress = M.data(ui)
    if not progress then return end
    return progress.total_pages - progress.current_page
end

function M.percent(ui)
    local progress = M.data(ui)
    if not progress then return end
    if progress.pagemap and progress.current_page_idx and progress.total_pages_idx and progress.total_pages_idx > 0 then
        return Math.round(100 * progress.current_page_idx / progress.total_pages_idx)
    end
    return Math.round(100 * progress.current_page / progress.total_pages)
end

function M.counts(ui)
    local progress = M.data(ui)
    if not progress then return end
    if progress.pagemap and progress.current_page_idx and progress.total_pages_idx and progress.total_pages_idx > 0 then
        return progress.current_page_idx, progress.total_pages_idx
    end
    return progress.current_page, progress.total_pages
end

return M
