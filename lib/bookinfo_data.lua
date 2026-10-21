--[[
Reading Insights - data behind the Book info popup.

Everything the popup shows about the open book, gathered into one plain
table, the same way (and with the same clean-up rules) as the Book card
plugin's card data (bookcard.koplugin, lib/bookdata.lua):

  title         display title (falls back to the file name)
  authors       one string; several authors are joined with a
                language-appropriate "and": "A and B" / "A, B and C"
                (hu: "A és B" / "A, B és C"), nil when there is none
  series        series name, nil when the book is not part of one
  series_index  its number, as text ("2", "2.5"), nil when unknown
  description   plain-text description (paragraphs kept as line breaks),
                nil when the book has none

  BookInfoData.gather(ui)      -> the table above (nil without a document)
  BookInfoData.gatherForFile(file, book)
                               -> the same table for a book that is not the
                                  open one (a row of a book list): read from
                                  the book's file when it is known, with the
                                  statistics DB's title / authors as fallback
  BookInfoData.totals(ui, id_book)
                               -> pages read, seconds read (whole history)
  BookInfoData.md5(ui)         -> the open book's checksum
  BookInfoData.getCover(ui, file)
                               -> a fresh cover BlitBuffer (the caller owns
                                  it and must free it - or hand it to a
                                  widget with image_disposable = true), or
                                  nil when the book has no usable cover
]]--

local deps = ...
local Locale, BookStatsData = deps.Locale, deps.BookStatsData
local CoverThumbs = deps.CoverThumbs   -- optional: the on-disk cover cache
local _ = Locale._

local M = {}

local function filenameTitle(file)
    local name = tostring(file or ""):match("([^/]+)$") or ""
    return (name:gsub("%.[^.]+$", ""))
end

-- Several authors (newline-separated in doc_props.authors) are joined with a
-- language-appropriate "and" before the last name instead of a comma.
local function joinAuthors(list)
    local n = #list
    if n == 0 then return nil end
    if n == 1 then return list[1] end
    return table.concat(list, ", ", 1, n - 1) .. " " .. _("and") .. " " .. list[n]
end

-- Some sources report several authors as one comma-joined line ("Jane Doe,
-- John Smith") instead of newline-separating them, which would otherwise
-- read as a single author with a literal comma in the name. Split such a
-- line on commas, but only when EVERY piece contains a space (i.e. looks
-- like a full "First Last" name) - a genuine inverted single name
-- ("Smith, John") has one-word pieces and is left alone.
local function splitCommaJoinedNames(line)
    if not line:find(",") then return { line } end
    local pieces = {}
    for piece in (line .. ","):gmatch("(.-),") do
        local trimmed = piece:match("^%s*(.-)%s*$")
        if trimmed ~= "" then pieces[#pieces + 1] = trimmed end
    end
    if #pieces < 2 then return { line } end
    for _idx, piece in ipairs(pieces) do
        if not piece:find("%s") then return { line } end
    end
    return pieces
end

local function cleanAuthors(authors)
    if type(authors) ~= "string" or authors == "" then return nil end
    local list = {}
    for line in (authors .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            for _idx, name in ipairs(splitCommaJoinedNames(trimmed)) do
                list[#list + 1] = name
            end
        end
    end
    return joinAuthors(list)
end

local function cleanSeries(props)
    if type(props) ~= "table" then return nil, nil end
    local series = props.series
    if type(series) ~= "string" or series == "" or series == "N/A" then return nil, nil end
    local idx = tonumber(props.series_index)
    if idx then
        if idx == math.floor(idx) then
            idx = string.format("%d", idx)
        else
            idx = string.format("%g", idx)
        end
    end
    return series, idx
end

-- The book's description as plain text: publishers ship it as HTML, so the
-- tags are turned into paragraph breaks / dropped (KOReader's own helper
-- when it has one, a crude fallback otherwise). nil when there is none.
local function cleanDescription(desc)
    if type(desc) ~= "string" or desc == "" then return nil end
    local ok, util = pcall(require, "util")
    local done = false
    if ok and util and util.htmlToPlainTextIfHtml then
        local ok2, res = pcall(util.htmlToPlainTextIfHtml, desc)
        if ok2 and type(res) == "string" then desc = res; done = true end
    end
    if not done and desc:find("<[%a/!][^>]*>") then
        desc = desc:gsub("</p>", "\n\n"):gsub("<br%s*/?>", "\n")
        desc = desc:gsub("<[^>]+>", "")
        desc = desc:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">")
            :gsub("&quot;", '"'):gsub("&amp;", "&")
    end
    desc = desc:gsub("\r\n?", "\n"):gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
    desc = desc:match("^%s*(.-)%s*$")
    if desc == "" then return nil end
    return desc
end

function M.gather(ui)
    if not ui or not ui.document then return nil end
    local props = ui.doc_props or {}
    local info = {}
    info.title = props.display_title or props.title or filenameTitle(ui.document.file)
    info.authors = cleanAuthors(props.authors)
    info.series, info.series_index = cleanSeries(props)
    info.description = cleanDescription(props.description)
    return info
end

-- The properties of a book that is not open: KOReader's own book-info helper
-- (either calling style, it has changed between versions), then the sidecar.
local function fileProps(file)
    local function valid(p)
        return type(p) == "table"
            and (p.title or p.display_title or p.authors or p.description) ~= nil
    end
    local ok, BI = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if ok and type(BI) == "table" and type(BI.getDocProps) == "function" then
        local ok1, p1 = pcall(BI.getDocProps, file)
        if ok1 and valid(p1) then return p1 end
        local ok2, p2 = pcall(BI.getDocProps, BI, file)
        if ok2 and valid(p2) then return p2 end
    end
    local ok3, p3 = pcall(function()
        return require("docsettings"):open(file):readSetting("doc_props")
    end)
    if ok3 and valid(p3) then return p3 end
    return nil
end

-- Opens a book's document (to read its properties / cover); the caller
-- closes it. nil when it can't be opened.
M.last_cover_error = nil

local function openDoc(file)
    local ok, doc = pcall(function()
        return require("document/documentregistry"):openDocument(file)
    end)
    if ok and doc then return doc end
    return nil
end

-- The properties read straight from the book itself: the last resort, and
-- what supplies a description the cached properties did not carry.
-- Remembered for the session (false = "tried, nothing there"): opening a
-- whole book just to read its properties costs seconds on a big EPUB / PDF,
-- and the answer does not change between two popups.
local props_memo = {}

local function docProps(file)
    local memo = props_memo[file]
    if memo ~= nil then return memo or nil end
    local doc = openDoc(file)
    if not doc then
        props_memo[file] = false
        return nil
    end
    local ok, props = pcall(function() return doc:getProps() end)
    pcall(function() doc:close() end)
    if ok and type(props) == "table" then
        props_memo[file] = props
        return props
    end
    props_memo[file] = false
    return nil
end

function M.gatherForFile(file, book)
    local cached_props = file and fileProps(file) or nil
    if type(cached_props) ~= "table" then cached_props = nil end
    local props = cached_props or {}
    if file and not cached_props then
        -- KOReader has no properties for this book at all: only then is the
        -- book itself opened and asked. A book KOReader does know, but that
        -- has no description, really has none - opening the whole file for
        -- that on every popup was the slow part.
        local dp = docProps(file)
        if dp then
            local base = props
            props = setmetatable({}, { __index = function(_t, k)
                local v = base[k]
                if v == nil or v == "" then v = dp[k] end
                return v
            end })
        end
    end
    -- No file (or nothing readable in it): the statistics DB still knows the
    -- title, the author and the series of the book.
    local row = book and book.id_book and BookStatsData
        and BookStatsData.getBookRow(book.id_book) or nil
    if row then
        if (not props.authors or props.authors == "") and row.authors and row.authors ~= "" and row.authors ~= "N/A" then
            props = setmetatable({ authors = row.authors }, { __index = props })
        end
        if (not props.series or props.series == "") and row.series and row.series ~= "" and row.series ~= "N/A" then
            props = setmetatable({ series = row.series, series_index = false }, { __index = props })
        end
        if not (props.display_title or props.title) and row.title and row.title ~= "" then
            props = setmetatable({ title = row.title }, { __index = props })
        end
    end
    -- A book the reader added by hand has neither a file nor a statistics
    -- row; the series they typed in is kept with the entry itself.
    if book and book.manual and (not props.series or props.series == "")
        and type(book.series) == "string" and book.series ~= "" then
        props = setmetatable({ series = book.series, series_index = book.series_index },
            { __index = props })
    end
    local info = {}
    info.title = props.display_title or props.title
        or (book and book.title ~= "" and book.title)
        or (file and filenameTitle(file)) or ""
    info.authors = cleanAuthors(props.authors) or cleanAuthors(book and book.authors)
    info.series, info.series_index = cleanSeries(props)
    info.description = cleanDescription(props.description)
    return info
end

-- The open book's checksum (the key its rating is filed under).
function M.md5(ui)
    if not ui then return nil end
    local md5
    pcall(function()
        if ui.doc_settings then md5 = ui.doc_settings:readSetting("partial_md5_checksum") end
        if (not md5 or md5 == "") and ui.document and ui.document.file then
            md5 = require("util").partialMD5(ui.document.file)
        end
    end)
    if md5 == "" then md5 = nil end
    return md5
end

-- Pages and seconds read, over the book's whole history. For the open book
-- KOReader's statistics plugin is asked first (it knows what has not been
-- written to the DB yet).
function M.totals(ui, id_book)
    local pages, secs
    local plugin = ui and ui.statistics
    if plugin and plugin.id_curr_book and tostring(plugin.id_curr_book) == tostring(id_book) then
        pcall(function() plugin:insertDB() end)
        if plugin.getPageTimeTotalStats then
            local ok, p, t = pcall(plugin.getPageTimeTotalStats, plugin, id_book)
            if ok then pages, secs = tonumber(p), tonumber(t) end
        end
    end
    if (not pages or not secs) and BookStatsData then
        local p, t = BookStatsData.getBookTotals(id_book)
        pages = pages or p
        secs  = secs or t
    end
    return pages, secs
end

-- The "Series / #N" line, in the language's own shape ("{series} / #{index}"
-- by default; some languages spell the number sign differently).
function M.seriesLine(info)
    if not info or not info.series or info.series == "" then return nil end
    if not info.series_index then return info.series end
    local tpl = _("{series} / #{index}")
    return (tpl:gsub("{(%w+)}", function(k)
        if k == "series" then return info.series end
        if k == "index" then return tostring(info.series_index) end
        return "{" .. k .. "}"
    end))
end

-- The last few covers read from a book's file, kept as copies: reading a
-- cover means opening the book, and the same list row is often tapped twice.
-- The caller still gets its own buffer to free (see the header).
local COVER_CACHE_MAX = 3
local cover_cache, cover_order = {}, {}
-- Largest size a cover is kept at in memory (and on disk, see diskWrite).
local DISK_W, DISK_H = 700, 1050

local function coverFromCache(file)
    local cached = cover_cache[file]
    if not cached then return nil end
    local ok, copy = pcall(function() return cached:copy() end)
    if ok and copy then return copy end
    return nil
end

local function coverToCache(file, bb)
    if not bb or cover_cache[file] then return end
    -- Never keep a full-size original: a scan can be several MB, times 3.
    local ok, copy = pcall(function()
        local scale = math.min(DISK_W / bb:getWidth(), DISK_H / bb:getHeight())
        if scale >= 1 then return bb:copy() end
        return require("ui/renderimage"):scaleBlitBuffer(bb:copy(),
            math.max(1, math.floor(bb:getWidth() * scale)),
            math.max(1, math.floor(bb:getHeight() * scale)), true)
    end)
    if not (ok and copy) then return end
    cover_cache[file] = copy
    cover_order[#cover_order + 1] = file
    while #cover_order > COVER_CACHE_MAX do
        local old = table.remove(cover_order, 1)
        local buf = cover_cache[old]
        cover_cache[old] = nil
        if buf then pcall(function() buf:free() end) end
    end
end

-- On-disk copy of the covers this popup shows, so that the first popup after
-- a restart does not have to open the book either. Kept apart from the
-- calendar's / shelf's thumbnails (those are small, 300 x 450): the popup can
-- show a large cover. Keyed by file path + size + modification time, so a
-- replaced book (or cover) is read again by itself.
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

local function diskKey(file)
    if not (lfs_ok and CoverThumbs and CoverThumbs.coverDir) then return nil end
    local dir = CoverThumbs.coverDir()
    if not dir then return nil end
    local attr = lfs.attributes(file)
    if not attr or attr.mode ~= "file" then return nil end
    local raw = file .. "|" .. tostring(attr.size) .. "|" .. tostring(attr.modification)
    local ok, sha2 = pcall(require, "ffi/sha2")
    local name
    if ok and sha2 and sha2.md5 then
        local ok2, h = pcall(sha2.md5, raw)
        if ok2 and type(h) == "string" then name = h end
    end
    if not name then return nil end
    return dir .. "/bi_" .. name
end

local function diskRead(base)
    if lfs.attributes(base .. ".none", "mode") == "file" then return false end
    for _i, ext in ipairs({ ".jpg", ".png" }) do
        local f = base .. ext
        if lfs.attributes(f, "mode") == "file" then
            local ok, bb = pcall(function()
                return require("ui/renderimage"):renderImageFile(f, false)
            end)
            if ok and bb then return bb end
        end
    end
    return nil
end

local function diskWrite(base, bb)
    local ok, small = pcall(function()
        local scale = math.min(DISK_W / bb:getWidth(), DISK_H / bb:getHeight())
        if scale >= 1 then return bb:copy() end   -- never enlarged
        return require("ui/renderimage"):scaleBlitBuffer(bb:copy(),
            math.max(1, math.floor(bb:getWidth() * scale)),
            math.max(1, math.floor(bb:getHeight() * scale)), true)
    end)
    if ok and small then
        CoverThumbs.writeThumb(base, small)
        pcall(function() small:free() end)
    end
end

function M.getCover(ui, file)
    local bb
    M.last_cover_error = nil
    if file then
        bb = coverFromCache(file)
        if bb then return bb end
        -- Not in memory (e.g. right after a restart): the disk copy next.
        local base = diskKey(file)
        if base then
            local d = diskRead(base)
            if d == false then
                M.last_cover_error = "the book has no cover image"
                return nil
            elseif d then
                coverToCache(file, d)
                return d
            end
        end
        bb = M._getCoverFromFile(file)
        if bb then
            coverToCache(file, bb)
            if base then pcall(diskWrite, base, bb) end
        elseif base and lfs.attributes(file, "mode") == "file"
            and (M.last_cover_error == nil
                or M.last_cover_error == "the book has no cover image") then
            -- the book opened fine and has no cover: remember that
            pcall(CoverThumbs.markNoCover, base)
        end
        return bb
    end
    if not ui or not ui.document then return nil end
    pcall(function()
        local bookinfo = ui.bookinfo
        if not bookinfo then
            bookinfo = require("apps/filemanager/filemanagerbookinfo")
        end
        bb = bookinfo:getCoverImage(ui.document)
    end)
    return bb
end

function M._getCoverFromFile(file)
    local bb
    if file then
        -- a book that is not open: the cover is read from the file
        local ok_bi, bookinfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
        if ok_bi and bookinfo then
            local ok_c, err_c = pcall(function() bb = bookinfo:getCoverImage(nil, file) end)
            if not ok_c then M.last_cover_error = "getCoverImage: " .. tostring(err_c) end
        end
        if not bb then
            -- older KOReader: the helper only takes an open document
            local doc = openDoc(file)
            if doc then
                if ok_bi and bookinfo then
                    pcall(function() bb = bookinfo:getCoverImage(doc) end)
                end
                if not bb then
                    local ok_p, err_p = pcall(function() bb = doc:getCoverPageImage() end)
                    if not ok_p then M.last_cover_error = "getCoverPageImage: " .. tostring(err_p) end
                end
                pcall(function() doc:close() end)
                if not bb and not M.last_cover_error then
                    M.last_cover_error = "the book has no cover image"
                end
            else
                M.last_cover_error = M.last_cover_error or "the book could not be opened"
            end
        end
        return bb
    end
    return nil
end

return M
