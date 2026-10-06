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
local map, built_at
local scan_map, scan_built_at

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
    local out = {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then return out end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls or not LuaSettings then return out end

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
        -- <book>.sdr sits next to <book> in the document-folder mode
        local book_file = sdr:gsub("%.sdr$", "")
        local md5, rating = ratingFrom(settings, book_file)
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
    return out
end

local function build()
    local out = {}
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return out end

    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if ok_rh and ReadHistory and type(ReadHistory.hist) == "table" then
        for _idx, item in ipairs(ReadHistory.hist) do
            local file = item and item.file
            if file then
                pcall(function()
                    local md5, rating = ratingFrom(DocSettings:open(file), file)
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
            local md5, rating = ratingFrom(ui.doc_settings, ui.document and ui.document.file)
            if md5 then out[md5] = rating end
        end
    end)

    -- Books the history does not know about: fill the gaps from the sidecar
    -- folders (never overriding what the history / the open book said).
    local now = os.time()
    if not scan_map or not scan_built_at or now - scan_built_at > SCAN_TTL or now < scan_built_at then
        local ok, res = pcall(scanSidecars)
        scan_map, scan_built_at = ok and res or {}, now
    end
    for md5, rating in pairs(scan_map) do
        if out[md5] == nil then out[md5] = rating end
    end
    return out
end

function M.refresh()
    map, built_at = nil, nil
    scan_map, scan_built_at = nil, nil
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
    local now = os.time()
    if not map or not built_at or now - built_at > TTL or now < built_at then
        map, built_at = build(), now
    end
    return map[md5]
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
