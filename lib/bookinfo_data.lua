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
  BookInfoData.getCover(ui)    -> a fresh cover BlitBuffer (the caller owns
                                  it and must free it - or hand it to a
                                  widget with image_disposable = true), or
                                  nil when the book has no usable cover
]]--

local deps = ...
local Locale = deps.Locale
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

function M.getCover(ui)
    if not ui or not ui.document then return nil end
    local bb
    pcall(function()
        local bookinfo = ui.bookinfo
        if not bookinfo then
            bookinfo = require("apps/filemanager/filemanagerbookinfo")
        end
        bb = bookinfo:getCoverImage(ui.document)
    end)
    return bb
end

return M
