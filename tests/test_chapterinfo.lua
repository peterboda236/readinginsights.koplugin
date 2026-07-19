--[[
Reading Insights - lib/chapterinfo, the chapter/TOC maths behind the book
progress view.

Covers both TOC shapes KOReader hands out, depth filtering, the toc_ticks
fallback, unusable TOCs, the per-book cache and its invalidation when the
page count changes, and the pages-left fallbacks.

Run from the plugin root: lua5.1 tests/test_chapterinfo.lua
]]--

local ChapterInfo = assert(loadfile("lib/chapterinfo.lua"))()
local function check(label, got, want)
    local ok = (math.type ~= nil and got == want) or got == want
    print(string.format("%-46s %-8s %s", label, tostring(got), ok and "ok" or ("EXPECTED "..tostring(want))))
    assert(ok, label)
end

-- TOC shape 1: list of tables with .page (chapters at pages 1, 11, 31)
local toc_tables = { {page=1,depth=1}, {page=11,depth=1}, {page=31,depth=1} }
local counts = {10, 20, 20}   -- 50-page book
local r = ChapterInfo.computeChapterResult(toc_tables, true, 3, counts, 15)
check("page 15 -> chapter 2", r.current, 2)
check("chapter total", r.total, 3)
check("progress ratio (4.5/20)", string.format("%.3f", r.chapter_progress_ratio), "0.225")
check("page 1 -> chapter 1", ChapterInfo.computeChapterResult(toc_tables,true,3,counts,1).current, 1)
check("last page -> chapter 3", ChapterInfo.computeChapterResult(toc_tables,true,3,counts,50).current, 3)
check("ratio capped at 0.95", ChapterInfo.computeChapterResult(toc_tables,true,3,counts,50).chapter_progress_ratio, 0.95)
-- page before the first chapter start must not fall through to 0
check("page 0 clamps to chapter 1", ChapterInfo.computeChapterResult(toc_tables,true,3,counts,0).current, 1)

-- TOC shape 2: plain page numbers (toc_ticks)
local ticks = {1, 11, 31}
check("ticks: page 12 -> chapter 2", ChapterInfo.computeChapterResult(ticks,false,3,counts,12).current, 2)

-- zero-length chapter must not divide by zero
check("zero page count -> ratio 0", ChapterInfo.computeChapterResult(toc_tables,true,3,{0,0,0},15).chapter_progress_ratio, 0)

-- cached path: TOC object exposing getToc(), with depth filtering
local toc = { getToc = function() return {
    {page=1,depth=1},{page=5,depth=2},{page=11,depth=1},{page=31,depth=1} } end }
local info = ChapterInfo.getCachedChapterInfo("book-a", toc, 50, 15)
check("getToc(): depth-2 entries ignored", info.total, 3)
check("getToc(): chapter for page 15", info.current, 2)
check("second call hits the cache", ChapterInfo.getCachedChapterInfo("book-a", toc, 50, 35).current, 3)

-- changed page count invalidates the entry (re-flow) rather than lying
local reparsed = 0
local toc2 = { getToc = function() reparsed = reparsed + 1; return { {page=1},{page=21} } end }
ChapterInfo.getCachedChapterInfo("book-b", toc2, 40, 5)
ChapterInfo.getCachedChapterInfo("book-b", toc2, 40, 5)
check("cached: parsed once", reparsed, 1)
ChapterInfo.getCachedChapterInfo("book-b", toc2, 80, 5)
check("page count change -> reparse", reparsed, 2)

-- toc_ticks fallback and unusable TOCs
check("toc_ticks fallback", ChapterInfo.getCachedChapterInfo("book-c", { toc_ticks = {1,26} }, 50, 30).current, 2)
check("empty TOC -> nil", ChapterInfo.getCachedChapterInfo("book-d", { toc_ticks = {} }, 50, 1), nil)
check("garbage TOC -> nil", ChapterInfo.getCachedChapterInfo("book-e", { toc_ticks = {"x","y"} }, 50, 1), nil)
check("failed parse is remembered", ChapterInfo.getCachedChapterInfo("book-e", { toc_ticks = {"x","y"} }, 50, 1), nil)
check("no book id -> nil", ChapterInfo.getCachedChapterInfo(nil, toc, 50, 1), nil)

-- pages left: chapter first, book as fallback, nil-safe
check("chapter pages left", ChapterInfo.getChapterPagesLeft(
    { toc = { getChapterPagesLeft = function() return 7 end } }, 10), 7)
check("falls back to book pages left", ChapterInfo.getChapterPagesLeft(
    { toc = { getChapterPagesLeft = function() return nil end },
      document = { getTotalPagesLeft = function() return 123 end } }, 10), 123)
check("no ui -> nil", ChapterInfo.getChapterPagesLeft(nil, 10), nil)
check("no toc -> nil", ChapterInfo.getChapterPagesLeft({}, 10), nil)

print("\nALL CHAPTER TESTS PASSED")
