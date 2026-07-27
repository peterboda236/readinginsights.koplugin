--[[
Reading Insights - the shared book list widget.

Every book list this plugin opens (the books read in a period, the books
that count towards the reading goal, the "mark book finished" checklist and
the hand-kept list of manually added books) is drawn by this one widget, so
they all look and behave the same:

  - a title bar with a sort menu on the left ("hamburger") and a close "X"
    on the right,
  - paged rows, one book per row, optionally with a checkbox,
  - a bottom bar with the page navigation, and - only for the lists where
    the reader is editing something - a cancel "X" on the left and an
    accept "check" on the right.

That's exactly KOReader's own SortWidget (the "Manage installed
dictionaries" / "Arrange items in status bar" screen), so this is a thin
subclass of it rather than a reimplementation:

  - item reordering is off (sort_disabled), because these lists are sorted
    by a rule, not dragged into place. SortWidget only draws the title
    bar's left icon when reordering is on, so init() flips the flag around
    the parent's init() call: on while the title bar is built (we want the
    icon), off afterwards (we don't want drag-to-reorder). Row taps then go
    straight to item.callback.
  - the sort menu behind that icon is this plugin's own (by last reading
    entry / by title, each way round) instead of SortWidget's A-Z one, and
    the chosen order is remembered per list in the settings.
  - the two footer edit buttons are optional: with show_ok_cancel = false
    they're replaced by same-width spacers, so the page navigation stays
    exactly where it is on both kinds of list.

Items are the usual SortWidget items ({ text, callback, checked_func, ... }),
plus three fields this widget reads:

  sort_title   the string title-sorting uses (item.text may carry extra
               decoration like the reading time)
  sort_time    the timestamp last-read-sorting uses
  pinned       kept at the top of the list whatever the sort order is
               (used for the "add a book" row)
  mandatory    a value shown right-aligned at the end of the row (the date
               a hand-added book was read)

  BookListWidget.new{ title = ..., item_table = ..., ... }
  widget:updateItems(item_table)   re-sort, re-page and redraw in place
]]--

local Blitbuffer     = require("ffi/blitbuffer")
local Screen          = require("device").screen
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckMark       = require("ui/widget/checkmark")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Size            = require("ui/size")
local SortWidget      = require("ui/widget/sortwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalSpan    = require("ui/widget/verticalspan")
local gettext         = require("gettext")
local C_              = gettext.pgettext
local Tmpl            = require("ffi/util").template

-- Shared modules, passed in as one named table by main.lua (see there).
local deps = ...
local Locale, Prefs =
    deps.Locale, deps.Prefs
local _ = Locale._

local M = {}

M.DEFAULT_SORT = "recent_desc"

-- The four orders offered by the title bar's sort menu, in menu order.
M.SORT_MODES = { "recent_desc", "recent_asc", "title_asc", "title_desc" }

-- `labels` (optional) overrides the wording per mode, so a list that sorts
-- something other than books (the achievements list, by unlock time / name)
-- can relabel the same four orders without a second menu.
local function sortLabel(mode, labels)
    if labels and labels[mode] then return labels[mode] end
    if mode == "recent_desc" then return _("Last read (newest first)") end
    if mode == "recent_asc"  then return _("Last read (oldest first)") end
    if mode == "title_asc"   then return _("Title (A to Z)") end
    return _("Title (Z to A)")
end

local function isValidSort(mode)
    for _idx, m in ipairs(M.SORT_MODES) do
        if m == mode then return true end
    end
    return false
end

-- Natural title order ("Book 2" before "Book 10") where KOReader's sort
-- helper is available, plain case-insensitive order otherwise.
local natsort
do
    local ok, sort = pcall(require, "sort")
    if ok and sort and sort.natsort_cmp then
        natsort = sort.natsort_cmp()
    end
end

local function titleLess(a, b)
    a, b = a or "", b or ""
    if natsort then return natsort(a, b) end
    local la, lb = a:lower(), b:lower()
    if la == lb then return a < b end
    return la < lb
end

-- A table.sort comparator for one of the four orders. The two getters say
-- how to read a title and a timestamp out of whatever is being sorted, so
-- the same orders work on this widget's items and on plain book records
-- from the queries (which is what the KeyValuePage lists sort).
function M.comparator(mode, get_title, get_time)
    get_title = get_title or function(x) return x.sort_title end
    get_time  = get_time  or function(x) return x.sort_time end
    if mode == "title_asc" then
        return function(x, y) return titleLess(get_title(x), get_title(y)) end
    elseif mode == "title_desc" then
        return function(x, y) return titleLess(get_title(y), get_title(x)) end
    end
    local newest_first = (mode ~= "recent_asc")
    return function(x, y)
        local tx, ty = get_time(x) or 0, get_time(y) or 0
        if tx == ty then return titleLess(get_title(x), get_title(y)) end
        if newest_first then return tx > ty end
        return tx < ty
    end
end

local function comparator(mode)
    return M.comparator(mode)
end

-- The order a list was last left in, or the default if it has none stored.
function M.readSortMode(setting_key)
    local saved = setting_key and Prefs.read(setting_key, nil) or nil
    return isValidSort(saved) and saved or M.DEFAULT_SORT
end

function M.saveSortMode(setting_key, mode)
    if setting_key and isValidSort(mode) then
        Prefs.save(setting_key, mode)
    end
end

-- The sort menu itself: the four orders with the current one ticked, plus
-- anything the caller wants underneath. Shared by this widget's title bar
-- icon and by the KeyValuePage book lists, which have the same icon but
-- none of the rest of this widget.
--
--   opts.current       the order currently in use (gets the tick)
--   opts.callback      called with the chosen order
--   opts.anchor_widget the title bar button to hang the menu under
--   opts.extra_buttons { { text = ..., callback = ... }, ... }
function M.showSortMenu(opts)
    local dialog
    local buttons = {}
    for _idx, mode in ipairs(M.SORT_MODES) do
        local this_mode = mode
        table.insert(buttons, {{
            -- U+2713 CHECK MARK in front of the order currently in use.
            text  = (opts.current == this_mode and "\xe2\x9c\x93 " or "    ")
                .. sortLabel(this_mode, opts.labels),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                if opts.callback then opts.callback(this_mode) end
            end,
        }})
    end
    for _idx, btn in ipairs(opts.extra_buttons or {}) do
        local cb = btn.callback
        table.insert(buttons, {{
            text  = btn.text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                if cb then cb() end
            end,
        }})
    end
    -- Anchored under the title bar's icon - but only if that button is
    -- actually there (older KOReader title bars don't take a left icon, in
    -- which case the dialog is simply centred).
    local anchor_button = opts.anchor_widget
    dialog = ButtonDialog:new{
        -- Modal: the lists this is opened from are either modal themselves
        -- or sit under one, and UIManager inserts non-modal windows *below*
        -- the topmost modal one - a plain dialog would open behind them.
        modal = true,
        shrink_unneeded_width = true,
        buttons = buttons,
        anchor  = anchor_button and function()
            return anchor_button.image.dimen
        end or nil,
    }
    UIManager:show(dialog)
    return dialog
end

-- One row of a list.
--
-- KOReader's own SortItemWidget draws a checkbox and a single stretch of
-- text, which is all its lists need. These ones want a value on the right
-- as well (the date a hand-added book was read), so the row is built here
-- instead: checkbox, then the title text taking whatever width is left,
-- then the value right-aligned against the far edge. Rows without an
-- item.mandatory look exactly as they did before - the value column simply
-- has no width.
local BookListItem = InputContainer:extend{
    item        = nil,
    width       = nil,
    height      = nil,
    face        = nil,
    show_parent = nil,
    no_checkbox = nil,
}

function BookListItem:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.Tap = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    self.ges_events.HoldTouch = {
        GestureRange:new{ ges = "hold", range = self.dimen },
    }

    local face = self.face or Font:getFace("smallinfofont")
    -- Greyed rows (e.g. a not-yet-earned achievement in the achievements
    -- list). nil fgcolor renders as the default black, so a row without
    -- item.dim looks exactly as before.
    local fgcolor = self.item.dim
        and (Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY)
        or nil

    -- Lists that never tick anything (the achievements list) pass
    -- no_checkbox so their rows aren't indented by a whole (blank) checkbox
    -- column - they sit close to the left edge like the KeyValuePage book
    -- lists, with just a small margin instead.
    local show_check = not self.no_checkbox
    local checkmark, check_w
    if show_check then
        local checkable = self.item.checked_func ~= nil
        checkmark = CheckMark:new{
            checkable = checkable,
            checked   = checkable and self.item.checked_func() or self.item.checked,
        }
        -- Sized against a ticked box, so rows line up whether ticked or not
        -- (and whether they have a checkbox at all).
        check_w = CheckMark:new{ checked = true }:getSize().w
    else
        -- No checkbox column: a left margin matching the KeyValuePage book
        -- lists (the read-only lists), so the icon/text starts at the same
        -- inset as e.g. the "books read" list.
        check_w = Size.padding.default
    end

    local value_widget, value_w
    if self.item.mandatory and self.item.mandatory ~= "" then
        value_widget = TextWidget:new{ text = self.item.mandatory, face = face, fgcolor = fgcolor }
        value_w = value_widget:getSize().w + Size.padding.large
    else
        value_w = 0
    end

    -- Optional fixed-width icon column (the achievements list). Different
    -- glyphs have different widths, so putting "<icon>  <text>" in one string
    -- makes the text start at a different x on every row (a ragged left
    -- edge). Instead the glyph goes in its own fixed-width column - the
    -- font's line height, identical for every row - with the text starting
    -- right after it, so every row lines up.
    local icon_container, icon_col_w
    if self.item.icon and self.item.icon ~= "" then
        local iw = TextWidget:new{ text = self.item.icon, face = face, fgcolor = fgcolor, bold = self.item.bold }
        local col_w = iw:getSize().h
        icon_col_w = col_w + Size.padding.small
        -- Left-aligned inside the fixed column (not centered), so the glyph
        -- hugs the left edge and there's no extra centering gap before it;
        -- the text after the column still starts at the same x on every row.
        icon_container = HorizontalGroup:new{
            LeftContainer:new{ dimen = Geom:new{ w = col_w, h = self.height }, iw },
            HorizontalSpan:new{ width = Size.padding.small },
        }
    end

    -- Matching right inset (padding.default), so the value column (e.g. the
    -- achievement dates) sits the same distance from the right edge as the
    -- KeyValuePage book lists' values do - symmetric with the left inset.
    local text_w = self.width - check_w - (icon_col_w or 0) - value_w - Size.padding.default

    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, show_check
        and CenterContainer:new{
            dimen = Geom:new{ w = check_w, h = self.height },
            checkmark,
        }
        or HorizontalSpan:new{ width = check_w })
    if icon_container then
        table.insert(row, icon_container)
    end
    table.insert(row, LeftContainer:new{
        dimen = Geom:new{ w = text_w, h = self.height },
        TextWidget:new{
            text      = self.item.text,
            max_width = text_w,
            face      = face,
            fgcolor   = fgcolor,
            -- Per-row bold (earned achievements); nil/false = normal
            -- weight, exactly as the book lists render.
            bold      = self.item.bold,
        },
    })
    if value_widget then
        table.insert(row, RightContainer:new{
            dimen = Geom:new{ w = value_w, h = self.height },
            value_widget,
        })
    end

    self[1] = FrameContainer:new{
        padding           = 0,
        bordersize        = 0,
        focusable         = true,
        focus_border_size = Size.border.thin,
        LeftContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            row,
        },
    }
end

function BookListItem:onTap()
    if self.item.callback then
        self.item:callback()
    end
    self.show_parent:_populateItems()
    return true
end

function BookListItem:onHoldTouch()
    if self.item.hold_callback then
        self.item:hold_callback(function() self.show_parent:_populateItems() end)
        return true
    end
    return false
end

local BookListWidget = SortWidget:extend{
    -- Full-screen and modal: these lists are opened on top of the insights
    -- popup, which would otherwise keep receiving the taps that land
    -- outside a row (its own gesture ranges cover the whole screen).
    modal             = true,
    covers_fullscreen = true,
    sort_disabled     = true,
    -- Footer edit buttons: on for the lists the reader is changing
    -- (checklist), off for the read-only ones.
    show_ok_cancel    = false,
    sort_mode         = nil,
    -- Settings key the chosen order is remembered under; nil = don't
    -- remember (the list opens in DEFAULT_SORT every time).
    sort_setting_key  = nil,
    -- Optional per-mode label override for the sort menu (see sortLabel),
    -- so a list sorting something other than books can relabel the four
    -- orders. nil = the default "Last read / Title" wording.
    sort_labels       = nil,
    -- Drop the (blank) checkbox column so rows sit close to the left edge,
    -- for read-only lists that never tick anything (the achievements list).
    no_checkbox       = nil,
    -- Optional: called when the title bar is long-pressed (the achievements
    -- list uses it to force a full re-scan). nil = no title-bar hold.
    title_hold_callback = nil,
    -- Called after the widget is closed, whichever way it was closed. The
    -- two edit buttons get their own callback first (see onClose/onReturn).
    close_callback    = nil,
    ok_callback       = nil,
    cancel_callback   = nil,
}
M.Widget = BookListWidget

function BookListWidget:init()
    self.show_page = self.show_page or 1
    if not isValidSort(self.sort_mode) then
        self.sort_mode = M.readSortMode(self.sort_setting_key)
    end
    self:applySort()

    -- SortWidget only builds the title bar's left button when reordering is
    -- enabled - and that button is where our sort menu lives. Turn the flag
    -- off again immediately afterwards so rows stay plain tap targets.
    local disabled = self.sort_disabled
    self.sort_disabled = false
    SortWidget.init(self)
    self.sort_disabled = disabled

    if not self.show_ok_cancel then
        -- Same-width spacers rather than removing the buttons: the page
        -- navigation in the middle stays put, and the button objects
        -- themselves are still around for SortWidget's own _populateItems,
        -- which reconfigures them on every redraw.
        self.page_info[1] = HorizontalSpan:new{ width = self.footer_button_width }
        self.page_info[#self.page_info] = HorizontalSpan:new{ width = self.footer_button_width }
        local footer_row = self.layout and self.layout[#self.layout]
        if footer_row and #footer_row > 2 then
            table.remove(footer_row, 1)
            table.remove(footer_row)
        end
    end

    -- Long-press on the title bar -> title_hold_callback (the achievements
    -- list's "re-scan everything"). Scoped to just the title-bar band at the
    -- top, so it doesn't steal holds meant for the rows below it.
    if self.title_hold_callback and self.title_bar then
        local th = self.title_bar:getSize().h or 0
        if th > 0 then
            self.ges_events = self.ges_events or {}
            self.ges_events.TitleHold = {
                GestureRange:new{
                    ges   = "hold",
                    range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = th },
                },
            }
        end
    end
end

function BookListWidget:onTitleHold()
    if self.title_hold_callback then self.title_hold_callback() end
    return true
end

-- Sorts item_table in place, keeping pinned items (the "add a book" row) at
-- the top in the order they were given.
function BookListWidget:applySort()
    local items = self.item_table
    if not items or #items < 2 then return end

    local pinned, rest = {}, {}
    for _idx, item in ipairs(items) do
        table.insert(item.pinned and pinned or rest, item)
    end
    table.sort(rest, comparator(self.sort_mode))

    for i = #items, 1, -1 do items[i] = nil end
    for _idx, item in ipairs(pinned) do table.insert(items, item) end
    for _idx, item in ipairs(rest)   do table.insert(items, item) end
end

-- Re-sorts, re-pages and redraws after the caller changed item_table (a
-- book added or deleted in the manual list, a row's text updated).
function BookListWidget:updateItems(item_table)
    if item_table then self.item_table = item_table end
    self:applySort()
    self.pages = math.max(1, math.ceil(#self.item_table / self.items_per_page))
    if self.show_page > self.pages then self.show_page = self.pages end
    self:_populateItems()
end

function BookListWidget:setSortMode(mode)
    if not isValidSort(mode) or mode == self.sort_mode then return end
    self.sort_mode = mode
    M.saveSortMode(self.sort_setting_key, mode)
    self.show_page = 1
    self:updateItems()
end

-- Replaces SortWidget's own A-Z menu with the four orders these book lists
-- offer (see M.showSortMenu, which the KeyValuePage lists share).
function BookListWidget:onShowWidgetMenu()
    M.showSortMenu{
        current       = self.sort_mode,
        labels        = self.sort_labels,
        anchor_widget = self.title_bar and self.title_bar.left_button,
        extra_buttons = self.extra_menu_buttons,
        callback      = function(mode) self:setSortMode(mode) end,
    }
    return true
end

-- The title bar's "X", the footer's "X" (when shown), a swipe down and the
-- Back key all end up here: discard, then close.
function BookListWidget:onClose()
    if self.cancel_callback then self.cancel_callback() end
    return self:_close()
end

-- The footer's check mark: accept, then close.
function BookListWidget:onReturn()
    if self.ok_callback then self.ok_callback() end
    return self:_close()
end

function BookListWidget:_close()
    UIManager:close(self)
    UIManager:setDirty(nil, "ui")
    if self.close_callback then
        local cb = self.close_callback
        -- After the widget is off-screen, so a callback that reopens the
        -- insights popup doesn't draw underneath this one.
        UIManager:scheduleIn(0, function() cb() end)
    end
    return true
end

function BookListWidget:onCancelOrClose()
    return self:onClose()
end

-- Lays out one page of rows. A copy of SortWidget's own, with the
-- item-moving parts left out (reordering is off here) and BookListItem in
-- place of SortItemWidget, so rows can carry a right-hand value.
function BookListWidget:_populateItems()
    self.main_content:clear()
    self.layout = { self.layout[#self.layout] } -- keep the footer row

    local idx_offset = (self.show_page - 1) * self.items_per_page
    local page_last  = math.min(idx_offset + self.items_per_page, #self.item_table)
    for idx = idx_offset + 1, page_last do
        table.insert(self.main_content, VerticalSpan:new{ width = self.item_margin })
        local row = BookListItem:new{
            height      = self.item_height,
            width       = self.item_width,
            item        = self.item_table[idx],
            index       = idx,
            show_parent = self,
            no_checkbox = self.no_checkbox,
        }
        table.insert(self.layout, #self.layout, { row })
        table.insert(self.main_content, row)
    end
    self:moveFocusTo(1, 1)

    self.footer_page:setText(
        Tmpl(C_("Pagination", "%1 / %2"), self.show_page, self.pages),
        self.footer_center_width)
    if self.pages > 1 then
        self.footer_page:enable()
    else
        self.footer_page:disableWithoutDimming()
    end
    self.footer_left:enableDisable(self.show_page > 1)
    self.footer_right:enableDisable(self.show_page < self.pages)
    self.footer_first_up:enableDisable(self.show_page > 1)
    self.footer_last_down:enableDisable(self.show_page < self.pages)

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function M.new(opts)
    return BookListWidget:new(opts)
end

return M
