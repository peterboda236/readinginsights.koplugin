--[[
Reading Insights - words per page of the open book.

KOReader's statistics database stores pages and seconds, never words, so the
"words per minute" of the Pace section is an estimate: the words on a sample
of pages (evenly spread over the book, the median of them, so a picture page
or a chapter's last short page does not skew it) multiplied by the pages per
minute the popup already knows.

  WordCount.perPage(ui, pages)   -> words per page, or nil when the document
                                   gives no text (the caller then shows "—")

The result is cached per book file and page count (the page count changes
with the font size, and so do the words per page). Every document call is
pcall-guarded: a format without text access just yields nil.

Reflowable books (EPUB, FB2, ...) are read with the text between the start
of one page and the start of the next; paged ones (PDF, DjVu, ...) with the
document's own page text. A Han / kana character counts as one word, since
those languages do not put spaces between words.
]]--

local M = {}

local SAMPLE_PAGES = 9
-- page count + file -> words per page (false: tried, nothing found)
local cache = {}

-- Words in `text`: whitespace-separated tokens, plus one per Han / kana
-- character.
local function countWords(text)
    if type(text) ~= "string" or text == "" then return 0 end
    local n = 0
    local function cjk() n = n + 1; return " " end
    text = text:gsub("[\228-\233][\128-\191][\128-\191]", cjk)  -- U+4E00..U+9FFF
    text = text:gsub("\227[\129-\131][\128-\191]", cjk)         -- kana
    for _tok in text:gmatch("%S+") do n = n + 1 end
    return n
end

-- Words of a paged document's page text: a list of blocks, each a list of
-- lines, each a list of words with a `word` field. Anything else is skipped.
local function countPagedWords(blocks)
    if type(blocks) ~= "table" then return 0 end
    local n = 0
    for _b, block in ipairs(blocks) do
        if type(block) == "table" then
            for _l, line in ipairs(block) do
                if type(line) == "table" then
                    for _w, word in ipairs(line) do
                        if type(word) == "table" and type(word.word) == "string" then
                            n = n + countWords(word.word)
                        end
                    end
                end
            end
        end
    end
    return n
end

-- `count` page numbers spread over the middle 80% of 1..pages (the front and
-- back matter are not typical pages).
local function samplePages(pages, count)
    local list = {}
    if pages <= count then
        for p = 1, pages do list[#list + 1] = p end
        return list
    end
    local first, last = math.max(1, math.floor(pages * 0.1)), math.min(pages, math.ceil(pages * 0.9))
    for i = 0, count - 1 do
        local p = first + math.floor((last - first) * i / (count - 1) + 0.5)
        if list[#list] ~= p then list[#list + 1] = p end
    end
    return list
end

local function median(values)
    if #values == 0 then return nil end
    table.sort(values)
    local mid = math.floor((#values + 1) / 2)
    if #values % 2 == 1 then return values[mid] end
    return (values[mid] + values[mid + 1]) / 2
end

local function samplePageWords(doc, pages, is_paged)
    local counts = {}
    for _i, page in ipairs(samplePages(pages, SAMPLE_PAGES)) do
        local ok, words = pcall(function()
            if is_paged then
                return countPagedWords(doc:getPageText(page))
            end
            local from = doc:getPageXPointer(page)
            local to   = page < pages and doc:getPageXPointer(page + 1) or nil
            if not from then return 0 end
            -- The last page has no next page start: take the end of the book.
            to = to or (doc.getDocumentEnd and doc:getDocumentEnd()) or nil
            if not to then return 0 end
            local text = doc:getTextFromXPointers(from, to)
            if type(text) == "table" then text = text.text end
            return countWords(text)
        end)
        if ok and words and words > 0 then counts[#counts + 1] = words end
    end
    return median(counts)
end

function M.perPage(ui, pages)
    local doc = ui and ui.document
    if not doc or not pages or pages <= 0 then return nil end
    local key = tostring(doc.file or "") .. "|" .. tostring(pages)
    local hit = cache[key]
    if hit ~= nil then return hit or nil end

    local is_paged = doc.info and doc.info.has_pages and true or false
    local ok, wpp = pcall(samplePageWords, doc, pages, is_paged)
    wpp = ok and wpp or nil
    cache[key] = wpp or false
    return wpp
end

return M
