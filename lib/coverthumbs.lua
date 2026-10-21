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

-- Wall-clock seconds (os.clock() is CPU time only; reading from flash / an SD
-- card is mostly waiting). Used to give batches of cover loading a time budget.
local ok_time, TimeMod = pcall(require, "ui/time")
function M.clock()
    if ok_time and TimeMod and TimeMod.now and TimeMod.to_s then
        return TimeMod.to_s(TimeMod.now())
    end
    return os.clock()
end

local function be16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function be32(s, i) return be16(s, i) * 65536 + be16(s, i + 2) end

-- Width and height of an image file read from its header only - no decoding,
-- so it costs a few bytes of I/O instead of a full JPEG decode. nil when the
-- file is neither a readable PNG nor JPEG (the caller then decodes it).
local function imageSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local w, h
    local head = f:read(24)
    if head and #head >= 24 and head:sub(1, 8) == "\137PNG\r\n\26\n" then
        w, h = be32(head, 17), be32(head, 21)
    elseif head and head:sub(1, 2) == "\255\216" then
        f:seek("set", 2)
        for _i = 1, 400 do
            local b = f:read(1)
            if not b then break end
            if b == "\255" then
                local m = f:read(1)
                while m == "\255" do m = f:read(1) end
                if not m then break end
                local mb = m:byte()
                if mb == 0xDA then break end   -- start of scan: no frame header after it
                -- 0x00 (stuffed byte), 0x01 and RSTn / SOI carry no length
                if mb ~= 0 and mb ~= 0x01 and not (mb >= 0xD0 and mb <= 0xD8) then
                    local lb = f:read(2)
                    if not lb or #lb < 2 then break end
                    local len = be16(lb, 1)
                    -- SOF0..SOF15 except DHT (C4), JPG (C8) and DAC (CC)
                    if mb >= 0xC0 and mb <= 0xCF and mb ~= 0xC4 and mb ~= 0xC8 and mb ~= 0xCC then
                        local d = f:read(5)   -- precision, height (2), width (2)
                        if d and #d == 5 then h, w = be16(d, 2), be16(d, 4) end
                        break
                    end
                    f:seek("cur", len - 2)
                end
            end
        end
    end
    f:close()
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
end

-- Width / height of the stored thumbnail (see readThumb), nil when there is
-- none or its header can't be read.
function M.thumbSize(base)
    for _i, ext in ipairs({ ".jpg", ".png" }) do
        local f = base .. ext
        if lfs.attributes(f, "mode") == "file" then
            local ok, w, h = pcall(imageSize, f)
            if ok and w then return w, h end
        end
    end
    return nil
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
