--[[
Reading Insights - About dialog.

Shown from Tools > Reading insights > About (see main.lua's addToMainMenu,
where this entry is placed right after "Updates", separated by a line).

A small, tap-anywhere-to-close box centered on screen with:
  - the plugin's display title, bold and centered, using the same font/size
    as the "insights_value" role (big numbers in the main popup) so it
    matches the rest of the plugin's visual language
  - the installed version, read from _meta.lua via updater.lua so it never
    goes stale when a new release is installed
  - a short description of the plugin, translated (see locale/*.po)
  - the GitHub repository URL, bold and centered

Loaded by main.lua via loadfile(...)( Locale, Updater ), following the same
"small standalone module" pattern as colors.lua/fonts.lua.

Fonts: deliberately hard-coded here (NotoSans-Bold.ttf @ 26 for the title,
NotoSans-Regular.ttf / NotoSans-Bold.ttf @ 15 for everything else) instead
of going through fonts.lua's user-customisable "insights_*" roles - this
dialog's look isn't meant to change with the user's Fonts-menu settings,
unlike the main popups.

The popup widget itself (AboutPopup) is a small local re-implementation of
insights_view.lua's WeeklyTrendPopup (tap/swipe/any-key to close, dimmed
full-screen host, partial "ui" refresh limited to the box). It's kept local
here instead of shared across files, since it's the only such popup needed
by this module and pulling in insights_view.lua just for that one class
isn't worth the coupling.
]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Screen          = Device.screen
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

-- Locale (translations) and Updater (installed-version lookup) plus the
-- shared dismissable-popup helper, all passed in by main.lua.
-- Shared modules, passed in as one named table by main.lua. Named rather
-- than positional on purpose: the list had grown long enough that
-- inserting one module in the middle would silently shift every module
-- after it, and the resulting nil would only surface far from the cause.
local deps = ...
local Locale, Updater, PopupUtil =
    deps.Locale, deps.Updater, deps.PopupUtil
local _ = Locale._

local GITHUB_URL = "https://github.com/peterboda236/readinginsights.koplugin"

local TITLE_SIZE = 22
local BODY_SIZE  = 15

-- Tries the given bundled font file at the given size, falling back to
-- KOReader's own "tfont"/"cfont" aliases if that exact file can't be
-- found (e.g. a device without it bundled) - never errors.
local function loadFace(file, size)
    local ok, face = pcall(Font.getFace, Font, file, size)
    if ok and face then return face end

    ok, face = pcall(Font.getFace, Font, "tfont", size)
    if ok and face then return face end

    return Font:getFace("cfont", size)
end

local AboutPopup = InputContainer:extend{
    modal       = true,
    box_content = nil,
}

function AboutPopup:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    if Device:isTouchDevice() then
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.box_content,
    }
end

-- Any tap / swipe / key dismisses; onShow/onCloseWidget mark the About box
-- region dirty. All five handlers come from the shared helper (see
-- popuputil.lua) since they were byte-for-byte identical across popups.
PopupUtil.makeDismissable(AboutPopup, function(self) return self.box_content.dimen end)

local M = {}

-- Shows the About box. Called directly from the "About" menu entry's
-- callback (no extra data to fetch, so no need for a stale-while-
-- revalidate style split like the main popups).
function M.show()
    local inner_padding = Size.padding.large
    local max_width = math.floor(Screen:getWidth() * 0.80)

    -- Title: bold, centered, 26pt. Version/description/link: 15pt, the
    -- link in bold. All hard-coded (see loadFace above), not tied to the
    -- user's Fonts-menu customisations.
    local title_face   = loadFace("NotoSans-Bold.ttf", TITLE_SIZE)
    local version_face = loadFace("NotoSans-Regular.ttf", BODY_SIZE)
    local body_face    = loadFace("NotoSans-Regular.ttf", BODY_SIZE)
    local link_face    = loadFace("NotoSans-Bold.ttf", BODY_SIZE)

    local title_w = TextWidget:new{
        text = _("Reading insight"),
        face = title_face,
    }

    local version_str = "v" .. (Updater.getInstalledVersion() or "unknown")
    local version_w = TextWidget:new{
        text = version_str,
        face = version_face,
    }

    -- Box hugs the title/version width first, then the description and
    -- link (wrapped to that width) are measured against it, capped so the
    -- box never overflows the screen. Wider baseline (0.78 of max_width)
    -- than before, so the description/link wrap across fewer lines.
    local content_width = math.min(max_width,
        math.max(title_w:getSize().w, version_w:getSize().w, math.floor(max_width * 0.78)))

    local description = _("A full-screen overlay with a comprehensive overview of your reading history, powered by KOReader's statistics database.")
    local desc_w = TextBoxWidget:new{
        text      = description,
        face      = body_face,
        width     = content_width,
        alignment = "center",
    }

    local link_w = TextBoxWidget:new{
        text      = GITHUB_URL,
        face      = link_face,
        width     = content_width,
        alignment = "center",
    }

    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = content_width, h = title_w:getSize().h }, title_w,
    })
    table.insert(content, VerticalSpan:new{ width = Size.padding.default })
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = content_width, h = version_w:getSize().h }, version_w,
    })
    -- VerticalSpan's actual size property is "width" (its getSize() uses
    -- self.width for the height it takes up) - "height" is silently a
    -- no-op, which is why these gaps didn't grow before. Same fix as the
    -- row_gap spans between heatmap grid rows.
    table.insert(content, VerticalSpan:new{ width = Size.padding.large * 2 })
    table.insert(content, desc_w)
    table.insert(content, VerticalSpan:new{ width = Size.padding.large * 2 })
    table.insert(content, link_w)

    local box = FrameContainer:new{
        background     = Blitbuffer.COLOR_WHITE,
        bordersize     = Size.border.window,
        radius         = Size.radius.window,
        padding_top    = inner_padding,
        padding_bottom = inner_padding,
        padding_left   = inner_padding,
        padding_right  = inner_padding,
        content,
    }

    UIManager:show(AboutPopup:new{ box_content = box })
end

return M
