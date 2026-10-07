--[[
Reading Insights - star ratings of the books.

KOReader keeps a book's star rating (0-5, set in the book's status page) in
the book's own sidecar file (summary.rating), and the statistics database
knows nothing about it. The only thing the two share is the book's partial
MD5 checksum: stored as `md5` in statistics.sqlite3's `book` table, and as
`partial_md5_checksum` in the sidecar. So the ratings are collected by
walking the reading history, opening each book's sidecar and filing its
rating under that checksum.

The map is rebuilt at most once every TTL seconds - lists are opened a tap
at a time, and walking a few hundred sidecars on every one of them would be
wasteful.

  Ratings.get(md5)      -> 1..5, or nil when the book has no rating (or is
                           not in the reading history)
  Ratings.stars(n)      -> "★★★☆☆" (five glyphs), "☆☆☆☆☆" for no rating
  Ratings.set(md5, n)   store a rating the reader typed in by hand (0 = no
                        rating); kept in its own file and loaded again on the
                        next start, and it wins over the book's sidecar
  Ratings.refresh()     drop the map so the next get() rebuilds it
  Ratings.fileFor(md5)  -> the book's file path (from the reading history /
                        the open book), nil when it is not known
  Ratings.save(md5, n)  set a rating from the Book info popup: written into
                        the book's own sidecar (summary.rating - what KOReader's
                        status page and the file manager read) when the file
                        is known, so a book that had no stars gets them there
                        too; otherwise kept in the plugin's own file as set()
]]--

local M = {}

-- Ratings edited by hand from the book lists: { [md5] = 0..5 }. Own file next
-- to KOReader's settings, so it survives restarts and can be copied to
-- another device on its own.
local STORE_PATH = require("datastorage"):getSettingsDir() .. "/reading_insights_ratings.lua"
local store

local function openStore()
    if store == nil then
        local ok, settings = pcall(function()
            return require("luasettings"):open(STORE_PATH)
        end)
        store = ok and settings or false
    end
    return store or nil
end

local function overrides()
    local st = openStore()
    local t = st and st:readSetting("ratings")
    return type(t) == "table" and t or {}
end

local TTL = 30
local SCAN_TTL = 600          -- the sidecar-folder walk is slower: redo it rarely
local SCAN_BUDGET = 4         -- seconds (CPU) the walk may take, at most
local SCAN_MAX_DEPTH = 12
local map, built_at, file_map
local scan_map, scan_built_at, scan_files

local function fileMD5(file)
    if not file then return nil end
    local ok, md5 = pcall(function()
        local util = require("util")
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(file, "mode") ~= "file" then return nil end
        return util.partialMD5(file)
    end)
    return ok and md5 or nil
end

-- The book a sidecar belongs to, in the document-folder mode: "<book>.sdr"
-- sits next to the book, but its name has the book's extension cut off - the
-- extension is in the settings file's own name ("metadata.epub.lua").
local function bookFileOfSidecar(sdr, meta)
    local base = (sdr:gsub("%.sdr$", ""))
    local ext = tostring(meta or ""):match("^metadata%.(.+)%.lua$")
    if ext then return base .. "." .. ext end
    return base
end

-- `file` (optional) is the book itself: when the sidecar carries a rating but
-- no checksum (older sidecars), the checksum is computed from the file.
local function ratingFrom(settings, file)
    if not settings or not settings.readSetting then return nil, nil end
    local md5 = settings:readSetting("partial_md5_checksum")
    local summary = settings:readSetting("summary")
    local rating = type(summary) == "table" and tonumber(summary.rating) or nil
    if rating then
        rating = math.floor(rating + 0.5)
        if rating < 1 then rating = nil elseif rating > 5 then rating = 5 end
    end
    if (not md5 or md5 == "") and rating then md5 = fileMD5(file) end
    return md5, rating
end

-- Walks the folders KOReader keeps sidecars in and files every rating found
-- under its checksum. This catches books that are no longer in the reading
-- history (cleared, or the file is gone) but whose sidecar survived.
local function scanSidecars()
    local out, files_out = {}, {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then return out, files_out end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls or not LuaSettings then return out, files_out end

    local roots, seen_root = {}, {}
    local function addRoot(path)
        if type(path) == "string" and path ~= "" and not seen_root[path]
           and lfs.attributes(path, "mode") == "directory" then
            seen_root[path] = true
            roots[#roots + 1] = path
        end
    end
    pcall(function()
        local DataStorage = require("datastorage")
        if DataStorage.getDocSettingsDir then addRoot(DataStorage:getDocSettingsDir()) end
        if DataStorage.getDocSettingsHashDir then addRoot(DataStorage:getDocSettingsHashDir()) end
    end)
    pcall(function()
        addRoot(G_reader_settings:readSetting("home_dir"))
    end)

    local started = os.clock()
    local function over_budget() return os.clock() - started > SCAN_BUDGET end

    local function readSidecar(sdr, meta)
        local ok, settings = pcall(function() return LuaSettings:open(sdr .. "/" .. meta) end)
        if not ok or not settings then return end
        local book_file = bookFileOfSidecar(sdr, meta)
        local md5, rating = ratingFrom(settings, book_file)
        if (not md5 or md5 == "") then md5 = settings:readSetting("partial_md5_checksum") end
        if md5 and md5 ~= "" and files_out[md5] == nil then files_out[md5] = book_file end
        if md5 and rating and out[md5] == nil then out[md5] = rating end
    end

    local function walk(dir, depth)
        if depth > SCAN_MAX_DEPTH or over_budget() then return end
        local ok, iter, state, ctl = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, state, ctl do
            if name:sub(1, 1) ~= "." or name:match("%.sdr$") then
                local path = dir .. "/" .. name
                if lfs.attributes(path, "mode") == "directory" then
                    if name:match("%.sdr$") then
                        local ok2, it2, st2, ct2 = pcall(lfs.dir, path)
                        if ok2 then
                            for f in it2, st2, ct2 do
                                if f:match("^metadata%..+%.lua$") then
                                    readSidecar(path, f)
                                end
                            end
                        end
                    else
                        walk(path, depth + 1)
                    end
                end
            end
            if over_budget() then return end
        end
    end

    for _idx, root in ipairs(roots) do walk(root, 0) end
    return out, files_out
end

local function build()
    local out, files = {}, {}
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return out, files end

    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if ok_rh and ReadHistory and type(ReadHistory.hist) == "table" then
        for _idx, item in ipairs(ReadHistory.hist) do
            local file = item and item.file
            if file then
                pcall(function()
                    local settings = DocSettings:open(file)
                    local md5, rating = ratingFrom(settings, file)
                    if not md5 or md5 == "" then
                        md5 = settings:readSetting("partial_md5_checksum")
                    end
                    if md5 and md5 ~= "" then files[md5] = file end
                    if md5 and rating then out[md5] = rating end
                end)
            end
        end
    end

    -- The book that is open right now: its rating may have been changed
    -- since and is only written to the sidecar when the book is closed, so
    -- the in-memory settings are the fresher source.
    pcall(function()
        local ReaderUI = require("apps/reader/readerui")
        local ui = ReaderUI.instance
        if ui and ui.doc_settings then
            local file = ui.document and ui.document.file
            local md5, rating = ratingFrom(ui.doc_settings, file)
            if md5 and md5 ~= "" then
                out[md5] = rating
                if file then files[md5] = file end
            end
        end
    end)

    -- Books the history does not know about: fill the gaps from the sidecar
    -- folders (never overriding what the history / the open book said).
    local now = os.time()
    if not scan_map or not scan_built_at or now - scan_built_at > SCAN_TTL or now < scan_built_at then
        local ok, res, res_files = pcall(scanSidecars)
        scan_map, scan_files, scan_built_at = ok and res or {}, ok and res_files or {}, now
    end
    for md5, f in pairs(scan_files or {}) do
        if files[md5] == nil then files[md5] = f end
    end
    for md5, rating in pairs(scan_map) do
        if out[md5] == nil then out[md5] = rating end
    end
    return out, files
end

local function ensure()
    local now = os.time()
    if not map or not built_at or now - built_at > TTL or now < built_at then
        map, file_map = build()
        built_at = now
    end
end

function M.refresh()
    map, built_at, file_map = nil, nil, nil
    scan_map, scan_files, scan_built_at = nil, nil, nil
end

function M.set(md5, n)
    if not md5 or md5 == "" then return false end
    n = tonumber(n) or 0
    n = math.max(0, math.min(5, math.floor(n + 0.5)))
    local st = openStore()
    if not st then return false end
    local t = overrides()
    t[md5] = n
    st:saveSetting("ratings", t)
    local ok = pcall(function() st:flush() end)
    return ok
end

function M.get(md5)
    if not md5 or md5 == "" then return nil end
    local own = overrides()[md5]
    if own ~= nil then return own > 0 and own or nil end
    ensure()
    return map[md5]
end

local function isFile(file)
    local ok, mode = pcall(function()
        return require("libs/libkoreader-lfs").attributes(file, "mode")
    end)
    return ok and mode == "file"
end

-- A targeted search for one book: walks the library folders (the home folder,
-- the sidecar folders and the folders the reading history's books live in)
-- looking for the sidecar that carries this checksum, and stops at the first
-- hit. Used when the history and the (budgeted, cached) full scan did not
-- know the book - e.g. a finished book whose history entry was cleared, in a
-- library too big for the full scan to get through. A sidecar without a
-- stored checksum is matched by hashing its book file.
-- Titles and file names compared loosely: lower case, accents (the Hungarian
-- ones and the usual Latin-1 ones) folded to plain letters, everything that
-- is not a letter or digit dropped.
local FOLD = {
    ["á"]="a", ["Á"]="a", ["é"]="e", ["É"]="e", ["í"]="i", ["Í"]="i",
    ["ó"]="o", ["Ó"]="o", ["ö"]="o", ["Ö"]="o", ["ő"]="o", ["Ő"]="o",
    ["ú"]="u", ["Ú"]="u", ["ü"]="u", ["Ü"]="u", ["ű"]="u", ["Ű"]="u",
    ["ä"]="a", ["Ä"]="a", ["ë"]="e", ["ï"]="i", ["ô"]="o", ["â"]="a",
    ["à"]="a", ["è"]="e", ["ê"]="e", ["ç"]="c", ["ñ"]="n", ["ß"]="ss",
}
local function fold(s)
    s = tostring(s or "")
    s = s:gsub("[\195-\197][\128-\191]", function(ch) return FOLD[ch] or "" end)
    return (s:lower():gsub("[^%w]", ""))
end

local function nameMatchesTitle(file, title)
    local t = fold(title)
    local fname = tostring(file):match("([^/]+)$") or ""
    if #t >= 4 then
        return fold(fname):find(t, 1, true) ~= nil
    end
    -- A very short title ("Az", "It") would be inside half the library's
    -- file names, and a file name merely *starting* with it is no better
    -- ("Az Elso Torveny vilaga - ..." is another book). So the first part of
    -- the file name - everything before the first " - ", without the
    -- extension and a trailing "#p(1488)" - has to be exactly the title:
    -- "Az - King, Stephen #p(1488).epub".
    if #t < 1 then return false end
    local stem = fname:gsub("%.[%w]+$", "")
    local first = stem:match("^(.-)%s+%-%s+") or stem
    first = first:gsub("%s*#p%(%d+%)%s*$", "")
    return fold(first) == t
end

local function authorWords(s)
    s = tostring(s or ""):gsub("[\195-\197][\128-\191]", function(ch) return FOLD[ch] or ch end)
    s = s:lower()
    return coroutine.wrap(function()
        for w in s:gmatch("%w+") do
            if #w >= 2 then coroutine.yield(w) end
        end
    end)
end

-- Does the file name carry the author? `authors` is the statistics DB's
-- author string ("Stephen King", "King, Stephen", several authors joined by
-- a newline / ";" / "&"). Every word of at least one author has to be in the
-- file name, so the order ("King, Stephen" / "Stephen King") doesn't matter.
-- true when no author is known - nothing to compare then.
local function authorKnown(authors)
    authors = tostring(authors or "")
    return authors:match("%S") ~= nil and authors ~= "N/A"
end

local function nameMatchesAuthor(file, authors)
    if not authorKnown(authors) then return true end
    local fname = fold((tostring(file):match("([^/]+)$") or ""))
    for one in (authors .. "\n"):gmatch("(.-)[\n;&]") do
        local words, all = 0, true
        for word in authorWords(one) do
            words = words + 1
            if not fname:find(word, 1, true) then all = false break end
        end
        if words > 0 and all then return true end
    end
    return false
end

local FIND_BUDGET = 8             -- seconds (CPU), at most
local find_misses = {}            -- md5 -> time of the last failed search

local function findFileByChecksum(md5, title, authors)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_lfs and lfs and ok_ls and LuaSettings) then return nil end

    local roots, seen_root = {}, {}
    local function addRoot(path)
        if type(path) == "string" and path ~= "" and not seen_root[path]
           and lfs.attributes(path, "mode") == "directory" then
            seen_root[path] = true
            roots[#roots + 1] = path
        end
    end
    pcall(function()
        addRoot(G_reader_settings:readSetting("home_dir"))
    end)
    pcall(function()
        local ReadHistory = require("readhistory")
        for _idx, item in ipairs(ReadHistory.hist or {}) do
            local dir = item and item.file and item.file:match("^(.*)/[^/]+$")
            if dir then addRoot(dir) end
        end
    end)
    pcall(function()
        local DataStorage = require("datastorage")
        if DataStorage.getDocSettingsDir then addRoot(DataStorage:getDocSettingsDir()) end
        if DataStorage.getDocSettingsHashDir then addRoot(DataStorage:getDocSettingsHashDir()) end
    end)

    local found, candidate, weak
    local started = os.clock()
    local function done() return found ~= nil or os.clock() - started > FIND_BUDGET end

    local function check(sdr, meta)
        local ok, settings = pcall(function() return LuaSettings:open(sdr .. "/" .. meta) end)
        if not ok or not settings then return end
        local book_file = bookFileOfSidecar(sdr, meta)
        local sid = settings:readSetting("partial_md5_checksum")
        if not sid or sid == "" then sid = fileMD5(book_file) end
        if sid == md5 and isFile(book_file) then found = book_file end
        -- the checksum can differ (the file was replaced since it was read):
        -- keep a book whose file name carries the title as a second choice
        -- title and author both in the name = a good guess; the title alone
        -- is only good enough when it is distinctive (4+ letters) and no
        -- better guess turns up - "Az" alone would be any number of books.
        if not found and not candidate and title and nameMatchesTitle(book_file, title)
           and isFile(book_file) then
            if nameMatchesAuthor(book_file, authors) then
                candidate = book_file
            elseif not weak and #fold(title) >= 4 then
                weak = book_file
            end
        end
    end

    local function walk(dir, depth)
        if depth > SCAN_MAX_DEPTH or done() then return end
        local ok, iter, state, ctl = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, state, ctl do
            if name:sub(1, 1) ~= "." or name:match("%.sdr$") then
                local path = dir .. "/" .. name
                if lfs.attributes(path, "mode") == "directory" then
                    if name:match("%.sdr$") then
                        local ok2, it2, st2, ct2 = pcall(lfs.dir, path)
                        if ok2 then
                            for f in it2, st2, ct2 do
                                if f:match("^metadata%..+%.lua$") then check(path, f) end
                                if done() then break end
                            end
                        end
                    else
                        walk(path, depth + 1)
                    end
                end
            end
            if done() then return end
        end
    end

    for _idx, root in ipairs(roots) do
        walk(root, 0)
        if done() then break end
    end
    return found or candidate or weak
end

function M.fileFor(md5, title, authors)
    if not md5 or md5 == "" then return nil end
    ensure()
    local file = file_map and file_map[md5]
    if file and isFile(file) then return file end

    local now = os.time()
    local missed = find_misses[md5]
    if missed and now >= missed and now - missed < 120 then return nil end
    file = findFileByChecksum(md5, title, authors)
    if file then
        file_map = file_map or {}
        file_map[md5] = file
        return file
    end
    find_misses[md5] = now
    return nil
end

-- Writes `n` (0..5) into a sidecar's summary table, the way KOReader's own
-- book status page does.
local function writeSummary(doc_settings, n)
    local summary = doc_settings:readSetting("summary")
    if type(summary) ~= "table" then summary = {} end
    summary.rating = n
    summary.modified = os.date("%Y-%m-%d", os.time())
    doc_settings:saveSetting("summary", summary)
end

-- The sidecar-folder walk is cached for SCAN_TTL and only fills the gaps the
-- reading history leaves. Without this a rating that was just cleared (0)
-- would come straight back from the stale walk: the history sidecar no longer
-- has a rating, so the old one from the cached walk would fill the gap.
local function forgetScanned(md5, n)
    if not md5 or md5 == "" or not scan_map then return end
    n = tonumber(n) or 0
    scan_map[md5] = n >= 1 and n or nil
end

-- A rating chosen in the Book info popup. Goes into the book's sidecar
-- (summary.rating) when the file is known - the open book through its live
-- settings, any other through its sidecar file - so the rating is the book's
-- own and shows in the file manager and the status page. A book without a
-- known file keeps it in the plugin's own file (see M.set). Returns true when
-- the rating was stored somewhere.
function M.save(md5, n, file)
    n = tonumber(n) or 0
    n = math.max(0, math.min(5, math.floor(n + 0.5)))
    file = file or M.fileFor(md5)

    local saved = false
    if file then
        local ok = pcall(function()
            local ui
            local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
            if ok_r and ReaderUI then ui = ReaderUI.instance end
            local doc_settings
            if ui and ui.doc_settings and ui.document and ui.document.file == file then
                doc_settings = ui.doc_settings
            else
                doc_settings = require("docsettings"):open(file)
            end
            writeSummary(doc_settings, n)
            doc_settings:flush()
        end)
        saved = ok
    end

    if saved then
        -- The sidecar is the source of truth now: an older hand-set value
        -- would otherwise keep winning over it.
        local st = openStore()
        local t = st and overrides()
        if t and t[md5] ~= nil then
            t[md5] = nil
            st:saveSetting("ratings", t)
            pcall(function() st:flush() end)
        end
        forgetScanned(md5, n)
        map, built_at = nil, nil
        return true
    end
    if not md5 or md5 == "" then return false end
    local ok = M.set(md5, n)
    forgetScanned(md5, n)
    map, built_at = nil, nil
    return ok
end

-- Five glyphs, filled ones first: the width is the same for every rating,
-- so the column lines up.
function M.stars(n)
    n = tonumber(n)
    if not n or n < 1 then n = 0 end                  -- unrated: five empty stars
    if n > 5 then n = 5 end
    n = math.floor(n)
    return string.rep("\xe2\x98\x85", n)               -- U+2605 BLACK STAR
        .. string.rep("\xe2\x98\x86", 5 - n)           -- U+2606 WHITE STAR
end

return M
