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

The disk side lives here, and so does newMemCache(): a bounded in-memory
cache of scaled covers. Each view keeps its own instance (their sizes and
limits differ); a view that throws its cache away calls clearDisk() as well.

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

-- Bounded in-memory cache of scaled covers (blitbuffer, or false for "no
-- cover"). Bounded twice: by entries (max_n) and by bytes (max_bytes, counted
-- as stride * height). When a limit is hit the oldest entries are dropped
-- first-in-first-out - never the whole cache at once - down to ~70% of the
-- limits, and the garbage collector is then run once: a blitbuffer's pixels
-- live outside the Lua heap, so the collector would otherwise not notice them
-- and could leave the dropped covers around for a long time.
--
-- The covers that are on screen are never dropped. A view calls beginFrame()
-- at the start of every (re)build; every entry it reads or stores from then on
-- belongs to that frame, and the entries of the current and the previous frame
-- are protected from eviction. Without this a screen with more covers than the
-- limits (a busy month, a long year) threw out the very covers just loaded, so
-- the next build found them missing again and the loading never ended. The
-- limits can therefore be exceeded by what one screen needs - which has to be
-- in memory to be drawn anyway.
-- Covers are NOT freed explicitly: dropping the reference lets the buffer's
-- own finaliser free it, so a popup still showing a cover never loses it.
function M.newMemCache(max_n, max_bytes)
    local C = { map = {}, order = {}, head = 1, tail = 0, n = 0, bytes = 0, seq = 0,
               gen = 0, trig_n = max_n, trig_b = max_bytes }

    local function sizeOf(bb)
        if not bb then return 0 end
        local ok, b = pcall(function()
            local h = bb:getHeight()
            local stride = bb.stride
            if type(stride) == "number" and stride > 0 then return stride * h end
            return bb:getWidth() * h * 4
        end)
        return (ok and b) or 0
    end

    -- A view calls this at the start of each (re)build of its screen.
    function C:beginFrame()
        self.gen = self.gen + 1
    end

    function C:get(key)
        local e = self.map[key]
        if e == nil then return nil end
        e.gen = self.gen
        return e.v
    end   -- nil: unknown, false: no cover

    local function evict(self)
        local target_n, target_b = math.floor(max_n * 0.7), math.floor(max_bytes * 0.7)
        local protect_from = self.gen - 1
        local kept, nk, dropped = {}, 0, false
        for i = self.head, self.tail do
            local slot = self.order[i]
            local k = slot and slot[1]
            local e = k and self.map[k]
            if e and e.seq == slot[2] then   -- (a replaced entry's old slot is skipped)
                if (self.n > target_n or self.bytes > target_b) and e.gen < protect_from then
                    self.map[k] = nil
                    self.n = self.n - 1
                    self.bytes = self.bytes - e.bytes
                    dropped = true
                else
                    nk = nk + 1
                    kept[nk] = slot
                end
            end
        end
        self.order, self.head, self.tail = kept, 1, nk
        -- Still over the limits: what is left is protected (on screen). Do not
        -- scan again for every further put, only once a good few more came in.
        self.trig_n = math.max(max_n, self.n + math.max(8, math.floor(max_n * 0.1)))
        self.trig_b = math.max(max_bytes, self.bytes + math.floor(max_bytes * 0.1))
        if dropped then collectgarbage("collect") end
    end

    function C:put(key, bb)
        local old = self.map[key]
        if old then
            self.bytes = self.bytes - old.bytes
            self.n = self.n - 1
            self.map[key] = nil
        end
        local b = sizeOf(bb)
        self.seq = self.seq + 1
        self.map[key] = { v = bb or false, bytes = b, seq = self.seq, gen = self.gen }
        self.tail = self.tail + 1   -- (not #order: its front is nil-ed out)
        self.order[self.tail] = { key, self.seq }
        self.n = self.n + 1
        self.bytes = self.bytes + b
        if self.n > self.trig_n or self.bytes > self.trig_b then evict(self) end
    end

    function C:clear()
        self.map, self.order, self.head, self.tail, self.n, self.bytes = {}, {}, 1, 0, 0, 0
        self.trig_n, self.trig_b = max_n, max_bytes
        -- (seq keeps counting, so no old slot can match a new entry)
        collectgarbage("collect")
    end

    return C
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
