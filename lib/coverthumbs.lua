--[[
Reading Insights - the on-disk cover thumbnail cache.

Used by the Reading streak calendar (day cells) and the year shelf, which
both draw book covers and used to carry byte-identical copies of everything
in here.

Covers are kept on disk so they survive a restart of KOReader: one small
thumbnail per book (JPEG, PNG when JPEG cannot be written) in
<settings>/readinginsights/covercache/<md5>.jpg, plus an empty <md5>.none for
a book that has no cover - so it is not opened again and again. Reading a
thumbnail is far quicker than opening the book.

Only the disk side lives here. Each view keeps its own in-memory cache of
scaled covers (their sizes and limits differ), and a view that throws its
cache away calls clearDisk() as well.

No dependencies; loaded once by main.lua and handed to those views as
`deps.CoverThumbs`.
]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local M = {}

-- Size every thumbnail is stored at (aspect kept, never enlarged).
M.THUMB_W, M.THUMB_H = 300, 450

local COVER_DIR

-- The cache folder (created on first use); nil when it cannot be made.
function M.coverDir()
    if COVER_DIR == nil then
        local d = DataStorage:getSettingsDir() .. "/readinginsights/covercache"
        if lfs.attributes(d, "mode") ~= "directory" then
            pcall(require("util").makePath, d .. "/")
        end
        COVER_DIR = (lfs.attributes(d, "mode") == "directory") and d or false
    end
    return COVER_DIR or nil
end

-- The thumbnail's path without extension, nil when the book has no usable id.
function M.diskBase(book)
    local md5 = book and book.md5
    if type(md5) ~= "string" or not md5:match("^%x+$") then return nil end
    local dir = M.coverDir()
    return dir and (dir .. "/" .. md5) or nil
end

-- Scales `bb` to fit w x h, aspect kept (never enlarging with no_upscale).
-- Frees `bb`.
function M.scaleTo(bb, w, h, no_upscale)
    local rw, rh = bb:getWidth(), bb:getHeight()
    local scale = math.min(w / rw, h / rh)
    if no_upscale and scale > 1 then scale = 1 end
    local nw = math.max(1, math.floor(rw * scale))
    local nh = math.max(1, math.floor(rh * scale))
    return require("ui/renderimage"):scaleBlitBuffer(bb, nw, nh, true)
end

-- The stored thumbnail as a blitbuffer, nil when there is none.
function M.readThumb(base)
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

function M.writeThumb(base, bb)
    local jpg = base .. ".jpg"
    pcall(bb.writeToFile, bb, jpg, "jpg", 85)
    local size = lfs.attributes(jpg, "size")
    if size and size > 0 then return end
    pcall(os.remove, jpg)
    pcall(bb.writeToFile, bb, base .. ".png", "png")
end

-- Remembers that the book has no cover.
function M.markNoCover(base)
    local f = io.open(base .. ".none", "w")
    if f then f:close() end
end

-- Deletes every thumbnail and "no cover" marker on disk, so each cover is
-- read again from its book. (The caller drops its own in-memory covers.)
function M.clearDisk()
    local dir = M.coverDir()
    if not dir then return end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if ok and iter then
        for name in iter, dir_obj do
            if name:match("%.jpg$") or name:match("%.png$") or name:match("%.none$") then
                pcall(os.remove, dir .. "/" .. name)
            end
        end
    end
end

return M
