--[[
Reading Insights (plugin entry point)

This plugin adds two views, each implemented in its own file:

  insights_view.lua
    "Reading insights" - full-screen, scrollable reading-history popup
    (last week, streaks, yearly/monthly charts, all-time totals). Available
    everywhere (book view and file manager), via the Tools menu and via a
    general gesture/dispatcher action.

  book_stats_view.lua
    "Reading statistics: overview" - compact live overlay for the book
    currently open (chapter/book time left, progress, pace). Book-view only:
    it needs an open document, so it's only offered in the Tools menu while
    reading, and its gesture/dispatcher action only shows up for assignment
    under Reader gestures (not File manager gestures).

This file itself only does the wiring: it loads the shared translation
module (locale.lua) and both view modules, registers the two dispatcher
actions (for gesture/shortcut assignment), builds the Tools menu entries,
and forwards the two "show popup" events to the right view.

Both view files are loaded with loadfile()(...) rather than require(...)
so they don't depend on this plugin's directory being on package.path -
they get the shared Locale module passed straight in as their chunk argument.
]]--

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local Screen = Device.screen

-- Shared plugin bootstrap. A tiny inline loadfile is only needed to reach
-- pluginutil.lua; every other plugin file (including the view modules loaded
-- much further down) goes through PluginUtil.load. The small dependency-free
-- shared modules are loaded here so even this file's own setting helpers can
-- use them. See pluginutil.lua, settings.lua, statsdb.lua, popuputil.lua and
-- bookprogress.lua.
local PluginUtil
do
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*/)") or "./"
    local chunk, err = loadfile(dir .. "pluginutil.lua")
    if not chunk then
        error(("Reading Insights: failed to load pluginutil.lua: %s"):format(tostring(err)))
    end
    PluginUtil = chunk()
end
local loadModule = PluginUtil.load
local Settings     = loadModule("lib/settings.lua")
local StatsDb      = loadModule("lib/statsdb.lua")
local PopupUtil    = loadModule("lib/popuputil.lua")
local BookProgress = loadModule("lib/bookprogress.lua")

--[[
Sleep-screen integration.

Reading insights now registers itself as a genuine value of KOReader's own
"screensaver_type" setting - the same global setting its own Settings >
Screen > Sleep screen menu writes to for "Cover", "Random image", etc. -
instead of keeping a separate on/off setting and overriding/restoring
screensaver_type behind the scenes on every suspend/resume. See
patchCoreScreensaver() below for how the core Screensaver module is taught
to recognize this value, and addToMainMenu() for how "Reading insights"
gets added as a selectable entry directly in that core menu.
]]--
local SCREENSAVER_TYPE_VALUE = "readinginsights"

-- What to show in the title, in place of the (hidden) close button, while
-- acting as a sleep screen: "none" (default) or "text" (appends something
-- like "(sleeping…)" after "Reading insights").
local SCREENSAVER_LABEL_SETTING = "readinginsights_screensaver_label_mode"

local function readScreensaverLabelMode()
    return Settings.read(SCREENSAVER_LABEL_SETTING, "none")
end

local function saveScreensaverLabelMode(mode)
    Settings.save(SCREENSAVER_LABEL_SETTING, mode)
end

--[[
Update settings (Updates menu). Mirrors bookshelf.koplugin's approach
(bookshelf_updater.lua + Bookshelf:checkForUpdates, editDevBranch,
resetToStableRelease, backgroundUpdateCheck): lets the user pull new
plugin code straight from GitHub without an SSH push from a computer.

  readinginsights_dev_branch          empty for stable, branch name for
                                       the dev-branch install path
  readinginsights_last_install_source "release" or "branch:<name>"
  readinginsights_check_updates       boolean: silent wake-time check
]]--
local DEV_BRANCH_SETTING          = "readinginsights_dev_branch"
local LAST_INSTALL_SOURCE_SETTING = "readinginsights_last_install_source"
local CHECK_UPDATES_SETTING       = "readinginsights_check_updates"

local function readDevBranch()
    return Settings.read(DEV_BRANCH_SETTING, "")
end

local function saveDevBranch(branch)
    Settings.save(DEV_BRANCH_SETTING, branch)
end

local function readLastInstallSource()
    return Settings.read(LAST_INSTALL_SOURCE_SETTING, "release")
end

local function saveLastInstallSource(source)
    Settings.save(LAST_INSTALL_SOURCE_SETTING, source)
end

local function readCheckUpdates()
    return Settings.isTrue(CHECK_UPDATES_SETTING)
end

local function saveCheckUpdates(value)
    if value then
        Settings.makeTrue(CHECK_UPDATES_SETTING)
    else
        Settings.makeFalse(CHECK_UPDATES_SETTING)
    end
end

--[[
Teaching KOReader's own core Screensaver module about the "readinginsights"
screensaver_type value, so that once it's selected in Settings > Screen >
Sleep screen, the core Power/Suspend codepath resolves it correctly on its
own - no runtime save-then-restore of screensaver_type spanning the actual
suspend/resume window, and therefore nothing that can be left stuck if a
session crashes mid-sleep.

Screensaver:setup() (called by core, straight off the raw Power/Suspend
input event, well before the "Suspend" event is ever broadcast to widgets)
normally just copies G_reader_settings' screensaver_type into
self.screensaver_type and resolves any fallbacks for a handful of
hardcoded values it knows about (e.g. "readingprogress" falling back to
"random_image" if the Statistics plugin isn't available - see core's own
screensaver.lua). It doesn't know "readinginsights", so left alone it
would just fall through every branch untouched.

This patch resolves our own value the same way core resolves its own
built-in ones, with one wrinkle: for the "book view falls back to Cover"
case, rather than reimplementing core's cover-mode resource setup
ourselves (image lookup, background mode, etc. - all internal to setup()),
it's simplest and most robust to let core's own logic do that work: swap
the *global* setting to "cover" for the duration of this single, synchronous
call to the original setup() (wrapped in pcall so the swap is always
undone, even if setup() itself errors), then put "readinginsights" straight
back before this function returns - well before "Suspend" is broadcast and
before the next suspend can possibly happen. That's a same-call-stack
round-trip, not a save-now/restore-later spanning an actual sleep, so
there's no crash-recovery bookkeeping needed the way the old override had.

Guarded by Screensaver._readinginsights_patched so re-instantiating this
plugin (book view + file manager both load it) only wraps setup() once.

Only applies to plain suspend (event == nil): poweroff/reboot use their
own separate sleep-screen resolution in core, which this plugin has never
hooked into and still doesn't.
]]--
local function patchCoreScreensaver()
    local Screensaver = require("ui/screensaver")
    if Screensaver._readinginsights_patched then return end
    Screensaver._readinginsights_patched = true

    local orig_setup = Screensaver.setup
    Screensaver.setup = function(self, event, event_message)
        if event ~= nil then
            return orig_setup(self, event, event_message)
        end
        local real_type = G_reader_settings:readSetting("screensaver_type")
        if real_type ~= SCREENSAVER_TYPE_VALUE then
            return orig_setup(self, event, event_message)
        end
        G_reader_settings:saveSetting("screensaver_type", "disable")
        local ok, err = pcall(orig_setup, self, event, event_message)
        G_reader_settings:saveSetting("screensaver_type", real_type)
        if not ok then
            error(err)
        end
    end
end

local Locale = loadModule("lib/locale.lua", PluginUtil)
local _ = Locale._

-- Shared chart/text color settings (Colors menu), used by both views so
-- there's a single, unified place to configure them. See colors.lua.
local Colors = loadModule("menus/colors.lua", Locale, PluginUtil, Settings)

-- Shared popup font settings (Fonts menu), same idea as Colors above but
-- for the section/value/label/small text roles in both popups. See
-- fonts.lua.
local Fonts = loadModule("menus/fonts.lua", Locale, PluginUtil, Settings)

local Insights = loadModule("views/insights_view.lua", Locale, Colors, Fonts, Settings, StatsDb, PopupUtil)

-- Per-book reading calendar (its own file now). Loaded before the book-stats
-- overlay so that overlay can hand tapping the "Pace" title straight to it.
-- Also reached directly from the "current book calendar" gesture and exposes
-- the calendar-cell-content setting used in Advanced settings below. See
-- book_calendar_view.lua.
local BookCalendar = loadModule("views/book_calendar_view.lua", Locale, Colors, Fonts, Settings, StatsDb, BookProgress)

-- Compact live "current book progress" overlay (book view only). See
-- book_stats_view.lua (formerly stats_view.lua).
local StatsPopup = loadModule("views/book_stats_view.lua", Locale, Colors, Fonts, Settings, StatsDb, BookProgress, BookCalendar)

-- Personal reading records / milestone popup (general - works in both
-- Reader view and File manager, same as Insights, since none of its data
-- is tied to a specific open book). See record_view.lua.
local Records = loadModule("views/record_view.lua", Locale, Colors, Fonts, StatsDb, PopupUtil)

-- In-app updater (Updates menu): lets the user check for and install new
-- releases of this plugin straight from GitHub. See updater.lua.
local Updater = loadModule("menus/updater.lua", Locale)

-- About dialog (About menu entry, right after Updates): a small popup
-- with the plugin title, installed version (via Updater, above), a short
-- description, and the GitHub repository URL. Uses its own hard-coded
-- fonts, not the (user-customisable) Fonts module. See about.lua.
local About = loadModule("views/about.lua", Locale, Updater, PopupUtil)

--[[
Plugin wiring.

is_doc_only = false, so KOReader instantiates this plugin both while
reading a book (self.ui = ReaderUI) and in the file browser
(self.ui = FileManager). The insights popup works in both contexts; the
stats popup needs an open document, so it's only offered/registered where
self.ui.document is present (i.e. in Reader view).
]]--
local ReadingInsights = WidgetContainer:extend{
    name = "readinginsights",
    is_doc_only = false,
}

function ReadingInsights:onDispatcherRegisterActions()
    Dispatcher:registerAction("reading_insights_popup", {
        category = "none",
        event    = "ShowReadingInsightsPopup",
        title    = _("Reading insights: all time statistics"),
        general  = true,
    })
    -- reader = true (not general): only assignable to gestures/shortcuts
    -- while in book view, matching the popup's book-only requirement.
    Dispatcher:registerAction("reading_stats_popup", {
        category = "none",
        event    = "ShowReadingStatsPopup",
        title    = _("Reading insights: current book progress"),
        reader   = true,
    })
    -- reader = true: opens the per-book reading calendar directly (see
    -- BookCalendar.show in book_calendar_view.lua), skipping the
    -- "This book" popup - lets a gesture/shortcut jump straight to the
    -- calendar instead of needing to tap through the progress row first.
    Dispatcher:registerAction("reading_calendar_popup", {
        category = "none",
        event    = "ShowBookCalendarPopup",
        title    = _("Reading insights: current book calendar"),
        reader   = true,
    })
    -- general = true (not reader): records are personal, all-time data
    -- not tied to any open book, so this action (and therefore any
    -- gesture/shortcut assigned to it) is available in both Reader view
    -- and the File manager, same as reading_insights_popup above.
    Dispatcher:registerAction("reading_records_popup", {
        category = "none",
        event    = "ShowReadingRecordsPopup",
        title    = _("Reading insights: records"),
        general  = true,
    })
end

--[[
Add "Reading insights" as a genuine selectable entry directly inside
KOReader's own Settings > Screen > Sleep screen > Wallpaper radio group
(alongside "Document cover", "Random image", etc.), instead of only
inside this plugin's own Tools menu.

Core builds that submenu like this (readermenu.lua / filemanagermenu.lua):

    if Device:supportsScreensaver() then
        local screensaver_sub_item_table = dofile("frontend/ui/elements/screensaver_menu.lua")
        ...
        self.menu_items.screensaver = { ..., sub_item_table = screensaver_sub_item_table }
    end

Note it's dofile(), not require() - core deliberately re-executes that
file fresh every time the menu is (re)built, rather than caching it as a
module. That means we can't reach the finished menu_items.screensaver
table reliably from our own addToMainMenu() (its presence there depends
on load order between plugins, which isn't guaranteed - see this
version's changelog/commit message for the concrete failure this used to
hit). What we *can* do reliably is hook the dofile() call itself: wrap the
global dofile so that, only for this one specific path, the table it
returns gets our entry appended before core ever touches it. That
guarantees our entry is baked into menu_items.screensaver.sub_item_table
itself, however and whenever core assembles it - no dependence on plugin
order at all.

If a device build never calls dofile() on that path in the first place
(Device:supportsScreensaver() returning false - a real, documented
KOReader limitation on some devices/platforms, unrelated to this plugin -
see e.g. koreader/koreader issues #13877, #14139, #2198), this patch
simply never fires, same as core's own Sleep screen menu never appearing
for that device either. The Tools > Reading insights > Settings > "Use as
sleep screen" quick toggle remains available either way.
]]--
local function patchScreensaverMenuBuilder()
    if _G._readinginsights_dofile_patched then return end
    _G._readinginsights_dofile_patched = true

    local orig_dofile = dofile
    _G.dofile = function(path, ...)
        local result = orig_dofile(path, ...)
        if type(path) == "string" and path:match("ui/elements/screensaver_menu%.lua$")
                and type(result) == "table" then
            local our_entry = {
                text = _("Reading insights"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return G_reader_settings:readSetting("screensaver_type") == SCREENSAVER_TYPE_VALUE
                end,
                callback = function()
                    G_reader_settings:saveSetting("screensaver_type", SCREENSAVER_TYPE_VALUE)
                end,
            }

            --[[
            core's screensaver_menu.lua returns a *top-level* table with just
            two entries - "Wallpaper" and "Sleep screen message" - each with
            its own sub_item_table. The actual radio group we want to join
            ("Document cover", "Random image", "Leave screen as-is", etc.,
            all built via that file's local genMenuItem() helper, which
            always sets radio = true) lives *inside* the "Wallpaper" entry's
            sub_item_table, not at this top level. Simply appending to
            `result` (the old approach) therefore landed our entry as a
            sibling of "Wallpaper" itself, one level too high.

            So: walk `result`'s entries looking for the first one whose own
            sub_item_table contains a contiguous run of radio = true items
            (that's "Wallpaper"), then insert our entry right before that
            run's separator-marked item (core flags the last radio item -
            currently "Leave screen as-is" - with separator = true to draw
            the divider before the non-radio settings below it). That keeps
            "Reading insights" grouped with the other wallpaper choices and
            the divider trailing after all of them, exactly where core's own
            options live, without hard-coding index numbers or exact label
            text that could change between KOReader versions.
            ]]--
            local inserted = false
            for _, entry in ipairs(result) do
                if type(entry) == "table" and type(entry.sub_item_table) == "table" then
                    local items = entry.sub_item_table
                    local insert_at = nil
                    for i, item in ipairs(items) do
                        if type(item) == "table" and item.radio then
                            if item.separator then
                                insert_at = i
                                break
                            end
                        elseif insert_at == nil and i > 1 then
                            -- Ran into the end of a radio block with no
                            -- separator-flagged item (shouldn't normally
                            -- happen, but just in case) - insert here.
                            insert_at = i
                            break
                        end
                    end
                    if insert_at then
                        table.insert(items, insert_at, our_entry)
                        inserted = true
                        break
                    end
                end
            end

            -- Fallback: if core ever restructures this menu so the Wallpaper
            -- radio group can't be located this way, append at the top level
            -- as before, so the option never disappears entirely - it'll
            -- just be a sibling of "Wallpaper" again instead of inside it.
            if not inserted then
                table.insert(result, our_entry)
            end
        end
        return result
    end
end

function ReadingInsights:init()
    -- One-time migration: remove the flat-layout files (colors.lua,
    -- stats_view.lua, l10n/, ...) left behind on disk when an in-app update
    -- unpacked this folder-structured release on top of an older flat one -
    -- see Updater.cleanupLegacyFiles(). Guarded so it runs at most once per
    -- KOReader session even though this plugin instantiates twice (Reader
    -- view + File manager); the guard resets on restart, so a transient
    -- failure is retried next launch. Fully pcall-guarded inside, so it can
    -- never block the plugin from loading.
    if not _G._readinginsights_legacy_cleaned then
        _G._readinginsights_legacy_cleaned = true
        Updater.cleanupLegacyFiles()
    end

    -- Teach core's Screensaver module about the "readinginsights"
    -- screensaver_type value (see patchCoreScreensaver() above). Safe to
    -- call from both the Reader-view and File-manager instantiations of
    -- this plugin - it's a no-op after the first call.
    patchCoreScreensaver()

    -- Bake our entry into core's own Sleep screen menu at the source (see
    -- patchScreensaverMenuBuilder() above). Also safe to call from both
    -- instantiations - no-op after the first call.
    patchScreensaverMenuBuilder()

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- Silent wake-time check also fires once at startup (opt-in via
    -- "Notify on wake when update available"), so a newly-available update
    -- can surface without waiting for the first suspend/resume cycle.
    self:backgroundUpdateCheck()
    -- Force this plugin's entry to the top of the Tools menu
    -- (both in Reader view and in the File manager)
    UIManager:scheduleIn(1, function()
        local function forceFirst(module_path_new, module_path_old)
            local ok_new, order_module = pcall(require, module_path_new)
            if not ok_new then
                local ok_old, res_old = pcall(require, module_path_old)
                if ok_old then order_module = res_old end
            end
            if order_module then
                if order_module.insertSorted then
                    order_module.insertSorted("tools", "reading_insights_popup", 1)
                elseif order_module.tools then
                    for i, v in ipairs(order_module.tools) do
                        if v == "reading_insights_popup" then
                            table.remove(order_module.tools, i)
                            break
                        end
                    end
                    table.insert(order_module.tools, 1, "reading_insights_popup")
                end
            end
        end

        forceFirst("ui/elements/reader_menu_order", "apps/reader/modules/readermenuorder")
        forceFirst("ui/elements/filemanager_menu_order", "apps/filemanager/modules/filemanagermenuorder")
    end)
end

-- True only when there's a book currently open (Reader view, not File manager).
function ReadingInsights:_hasOpenDocument()
    return self.ui ~= nil and self.ui.document ~= nil
end

-- True when this suspend should show the Reading insights popup itself,
-- i.e. screensaver_type is our value.
function ReadingInsights:_screensaverShouldShow()
    return G_reader_settings:readSetting("screensaver_type") == SCREENSAVER_TYPE_VALUE
end

--[[
Sleep-screen integration.

"Reading insights" is a genuine selectable entry in KOReader's own
Settings > Screen > Sleep screen menu (see addToMainMenu() below), backed
by patchCoreScreensaver() teaching core's Screensaver module to recognize
it. Core's own Screensaver:show() (which runs off the raw Power/Suspend
input event, before the "Suspend" event below is even broadcast) already
resolved screensaver_type == "disable" for this case by the time we get
here - see patchCoreScreensaver() - so it painted nothing, and this is
free to show the actual popup without racing or flashing against it.

The popup is created with readonly = true so a stray tap, swipe-down, or
the wake key itself can't dismiss it early while the device is still
"asleep"; onResume below is what actually closes it again.
]]--
function ReadingInsights:onSuspend()
    if not self:_screensaverShouldShow() then return end
    if self._screensaver_widget then return end -- already showing
    if Device:hasEinkScreen() then
        Screen:clear()
        Screen:refreshFull(0, 0, Screen:getWidth(), Screen:getHeight())
    end
    local label_mode = readScreensaverLabelMode()
    local screensaver_label = (label_mode == "text") and _("sleeping…") or nil
    local popup = Insights.Popup:new{
        ui = self.ui,
        readonly = true,
        screensaver_label = screensaver_label,
    }
    local orig_on_close_widget = popup.onCloseWidget
    popup.onCloseWidget = function(popup_self, ...)
        if orig_on_close_widget then orig_on_close_widget(popup_self, ...) end
        if self._screensaver_widget == popup_self then
            self._screensaver_widget = nil
        end
    end
    self._screensaver_widget = popup
    UIManager:show(popup, "full")
end

function ReadingInsights:onResume()
    if self._screensaver_widget then
        UIManager:close(self._screensaver_widget)
        self._screensaver_widget = nil
    end
    -- Wake-from-sleep also fires a silent background update check, mirroring
    -- bookshelf.koplugin. Updater's own 1-hour internal cache prevents
    -- wake-spam.
    self:backgroundUpdateCheck()
end

-- ---------------------------------------------------------------------------
-- Updates / dev-branch install
-- ---------------------------------------------------------------------------
-- Mirrors bookshelf.koplugin's update flow (lib/bookshelf_updater.lua +
-- Bookshelf:checkForUpdates, editDevBranch, resetToStableRelease,
-- backgroundUpdateCheck). Lets the user bring new plugin code onto the
-- device without an SSH push from a computer - useful when away from the
-- home network.

-- Branch-aware update entry: if a dev branch is configured, install that
-- branch's latest tip (no release needed). Otherwise hit the GitHub
-- releases API and offer the latest stable. Both paths share the same
-- download / unpack / restart-prompt pipeline inside Updater.install.
function ReadingInsights:checkForUpdates()
    local branch = readDevBranch()
    if branch ~= "" then
        Updater.installBranch(branch, function()
            saveLastInstallSource("branch:" .. branch)
        end)
    else
        Updater.check(function()
            saveLastInstallSource("release")
        end)
    end
end

-- Open a single-line dialog to set / change / clear the dev branch.
function ReadingInsights:editDevBranch(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title       = _("Development branch"),
        input       = readDevBranch(),
        input_hint  = _("Branch name (leave empty for stable)"),
        buttons = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local raw = dlg:getInputText() or ""
                    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    saveDevBranch(trimmed)
                    UIManager:close(dlg)
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Clear dev branch + install latest stable release. Used when escaping a
-- broken branch back to a known-good release.
function ReadingInsights:resetToStableRelease()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("This will clear the development branch setting and install the latest stable release of Reading insights, then restart KOReader. Continue?"),
        ok_text = _("Reset"),
        ok_callback = function()
            saveDevBranch("")
            Updater.installLatestStable(function()
                saveLastInstallSource("release")
            end)
        end,
    })
end

-- Silent background poll: checks at most once an hour, only when the user
-- has opted in via "Notify on wake when update available". Surfaces a
-- short notification if a newer release tag is found.
function ReadingInsights:backgroundUpdateCheck()
    if not readCheckUpdates() then return end
    Updater.checkBackground(function(ver)
        local Notification = require("ui/widget/notification")
        Notification:notify(_("Reading insights update available: v") .. ver,
            Notification.SOURCE_ALWAYS_SHOW)
    end)
end

-- Drill-down menu for the in-app updater: a "Notify" toggle, a primary
-- update row that auto-relabels when an update is queued, and a
-- "Developer updates" pocket for the dev-branch picker + reset-to-stable.
--
-- Reads every value fresh from G_reader_settings (via readDevBranch() /
-- readLastInstallSource() / readCheckUpdates()) rather than caching on
-- self: this plugin runs one instance per context (Reader and File
-- manager, is_doc_only = false), and both build this same menu, so a
-- self-cached value edited in one instance would go stale in the other
-- until the next restart. Same reasoning as the screensaver-mode settings
-- above.
function ReadingInsights:_updateSubItems()
    local outer = self
    return {
        {
            text         = _("Notify on wake when update available"),
            checked_func = function() return readCheckUpdates() end,
            callback     = function()
                saveCheckUpdates(not readCheckUpdates())
            end,
        },
        {
            text_func = function()
                local current   = Updater.getInstalledVersion()
                local available = Updater.getAvailableUpdate()
                local source    = readLastInstallSource()
                local source_suffix = ""
                if source ~= "release" then
                    local branch = source:match("^branch:(.+)$") or source
                    source_suffix = " (branch: " .. branch .. ")"
                end
                if available then
                    return _("Update available") .. ": v" .. current .. source_suffix
                        .. " \xE2\x86\x92 v" .. available
                end
                return _("Installed version") .. ": v" .. current .. source_suffix
            end,
            keep_menu_open = true,
            callback = function() outer:checkForUpdates() end,
        },
        {
            text = _("Developer updates"),
            sub_item_table = {
                {
                    text_func = function()
                        local b = readDevBranch()
                        if b == "" then return _("Development branch") end
                        return _("Development branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        outer:editDevBranch(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        local b = readDevBranch()
                        if b == "" then return _("Check for updates") end
                        return _("Install branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function() outer:checkForUpdates() end,
                },
                {
                    text           = _("Reset to latest stable release"),
                    keep_menu_open = true,
                    callback       = function() outer:resetToStableRelease() end,
                },
                {
                    -- Disabled status row: shows "Installed: vX (release)" /
                    -- "(branch: foo)". Tap is a no-op via enabled_func=false.
                    text_func = function()
                        local current = Updater.getInstalledVersion()
                        local source  = readLastInstallSource()
                        if source == "release" then
                            return _("Installed: v") .. current .. " (release)"
                        end
                        local branch = source:match("^branch:(.+)$") or source
                        return _("Installed: v") .. current .. " (branch: " .. branch .. ")"
                    end,
                    enabled_func   = function() return false end,
                    keep_menu_open = true,
                },
            },
        },
    }
end

function ReadingInsights:onShowReadingInsightsPopup()
    local popup = Insights.Popup:new{ ui = self.ui }
    UIManager:show(popup)
    return true
end

-- General, like onShowReadingInsightsPopup above: works in both Reader
-- view and the File manager, since none of the Records data is tied to a
-- specific open book.
function ReadingInsights:onShowReadingRecordsPopup()
    local popup = Records.Popup:new{ ui = self.ui }
    UIManager:show(popup)
    return true
end

function ReadingInsights:onShowReadingStatsPopup()
    -- Book-view only: silently ignore if there's no document open (e.g. if
    -- somehow triggered from the file manager).
    if not self:_hasOpenDocument() then return true end
    local popup = StatsPopup:new{ ui = self.ui }
    UIManager:show(popup)
    return true
end

-- Book-view only, same restriction as onShowReadingStatsPopup above: opens
-- the per-book reading calendar directly, without going through "This
-- book" first.
function ReadingInsights:onShowBookCalendarPopup()
    if not self:_hasOpenDocument() then return true end
    BookCalendar.show{ ui = self.ui }
    return true
end

-- Adds "Reading insights" under Tools as a submenu.
-- Sub-entries: open the insights popup, open the stats popup (book view
-- only), a separator, then a "Settings" submenu holding the two
-- persistent settings for the insights popup plus the Colors submenu.
function ReadingInsights:addToMainMenu(menu_items)
    local sub_item_table = {
        {
            text = _("Show Reading insights"),
            keep_menu_open = false,
            callback = function()
                self:onShowReadingInsightsPopup()
            end,
        },
        {
            text = _("Show Records"),
            keep_menu_open = false,
            callback = function()
                self:onShowReadingRecordsPopup()
            end,
        },
    }

    local has_open_document = self:_hasOpenDocument()
    if has_open_document then
        table.insert(sub_item_table, {
            text = _("Show Book progress"),
            keep_menu_open = false,
            callback = function()
                self:onShowReadingStatsPopup()
            end,
        })
        table.insert(sub_item_table, {
            text = _("Show Book progress calendar"),
            keep_menu_open = false,
            callback = function()
                self:onShowBookCalendarPopup()
            end,
        })
    end

    -- Separator after the two "open a popup" entries, before the
    -- settings submenu below.
    sub_item_table[#sub_item_table].separator = true

    local settings_sub_item_table = {}

    -- Whether/how it's used as a sleep screen is normally set directly in
    -- KOReader's own Settings > Screen > Sleep screen menu (see the
    -- menu_items.screensaver injection at the end of this function).
    --
    -- That injection depends on menu_items.screensaver already existing
    -- (with a sub_item_table) by the time this addToMainMenu() runs, which
    -- isn't a guaranteed, documented part of KOReader's plugin API - just
    -- an observed implementation detail. If it ever doesn't hold (older/
    -- newer core versions, a different frontend, plugin load order, an
    -- interaction with another sleep-screen plugin, etc.) the injection
    -- silently does nothing, and without a fallback here there would be no
    -- way at all to turn this on. So the same control is duplicated here,
    -- inside our own Settings submenu, guaranteed to always work
    -- regardless of what core's menu looks like.
    --[[
    table.insert(settings_sub_item_table, {
        text = _("Use as sleep screen"),
        keep_menu_open = true,
        checked_func = function()
            return G_reader_settings:readSetting("screensaver_type") == SCREENSAVER_TYPE_VALUE
        end,
        callback = function()
            if G_reader_settings:readSetting("screensaver_type") == SCREENSAVER_TYPE_VALUE then
                G_reader_settings:saveSetting("screensaver_type", "disable")
            else
                G_reader_settings:saveSetting("screensaver_type", SCREENSAVER_TYPE_VALUE)
            end
        end,
    })
    ]]--

    -- Sleep-screen indicator now lives at the top of Advanced settings
    -- instead of here - see advanced_settings_sub_item_table below.

    table.insert(settings_sub_item_table, {
        text = _("Full-screen refresh on open/close"),
        keep_menu_open = true,
        checked_func = function()
            return Insights.readFullRefreshSetting()
        end,
        callback = function()
            Insights.saveFullRefreshSetting(not Insights.readFullRefreshSetting())
        end,
    })

    -- Bar-chart height settings: one entry per chart, each opening a
    -- SpinWidget (KOReader's standard numeric-value picker) with the
    -- current value pre-filled and a "default" value to reset to. The
    -- default matches the value that was hardcoded before this setting
    -- existed, so "reset to default" reproduces the original look exactly.
    local function buildBarHeightMenuEntry(text, read_fn, save_fn, default_value, value_min, value_max)
        return {
            text_func = function()
                return text .. ": " .. tostring(read_fn())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text    = text,
                    value         = read_fn(),
                    value_min     = value_min,
                    value_max     = value_max,
                    value_step    = 1,
                    value_hold_step = 5,
                    default_value = default_value,
                    ok_text       = _("Set"),
                    callback      = function(spin)
                        save_fn(spin.value)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }
    end

    -- Unified color settings for every chart/diagram and label in both
    -- popups (insights and stats). Any change here applies to both, next
    -- time each popup is (re)opened.
    table.insert(settings_sub_item_table, {
        text = _("Colors"),
        keep_menu_open = true,
        sub_item_table = Colors.buildMenu(),
    })

    -- Unified font settings (name + size) for every text role in both
    -- popups. Same idea as Colors above. Any change here applies to both,
    -- next time each popup is (re)opened.
    table.insert(settings_sub_item_table, {
        text = _("Fonts"),
        keep_menu_open = true,
        separator = true,
        sub_item_table = Fonts.buildMenu(),
    })

    -- "Advanced settings": less commonly touched settings, tucked away in
    -- their own submenu (bar chart height, reading heatmap range, and the
    -- 8-week chart order, in that order - no separators inside). A
    -- separator is placed above this entry itself (set on the preceding
    -- "Fonts" entry) to set it apart from the rest of the Settings menu.
    local advanced_settings_sub_item_table = {}

    -- Moved here (to the very top) from the Settings submenu, keeping its
    -- separator so it still visually stands apart from the entries below.
    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local label_mode = readScreensaverLabelMode()
            return _("Sleep-screen indicator") .. ": " ..
                ((label_mode == "text") and _("\"(sleeping…)\" after the title") or _("None"))
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("None"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return readScreensaverLabelMode() == "none" end,
                callback = function() saveScreensaverLabelMode("none") end,
            },
            {
                text = _("\"(sleeping…)\" after the title"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return readScreensaverLabelMode() == "text" end,
                callback = function() saveScreensaverLabelMode("text") end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text = _("Bar chart height"),
        keep_menu_open = true,
        sub_item_table = {
            buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Last week"),
                Insights.readWeeklyBarHeightSetting,
                Insights.saveWeeklyBarHeightSetting,
                Insights.DEFAULT_WEEKLY_BAR_HEIGHT,
                10, 200
            ),
            buildBarHeightMenuEntry(
                _("Reading insights") .. ": " .. _("Months"),
                Insights.readMonthlyBarHeightSetting,
                Insights.saveMonthlyBarHeightSetting,
                Insights.DEFAULT_MONTHLY_BAR_HEIGHT,
                10, 200
            ),
            buildBarHeightMenuEntry(
                _("Book progress") .. ": " .. _("Chapters"),
                StatsPopup.readChapterBarHeightSetting,
                StatsPopup.saveChapterBarHeightSetting,
                StatsPopup.DEFAULT_CHAPTER_BAR_HEIGHT,
                10, 200
            ),
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local months = Insights.readHeatmapMonthsSetting()
            local label
            if months == 3 then label = _("3 months")
            elseif months == 6 then label = _("6 months")
            else label = _("4 months") end
            return _("Reading heatmap range") .. ": " .. label
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("3 months"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return Insights.readHeatmapMonthsSetting() == 3 end,
                callback = function() Insights.saveHeatmapMonthsSetting(3) end,
            },
            {
                text = _("4 months"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return Insights.readHeatmapMonthsSetting() == 4 end,
                callback = function() Insights.saveHeatmapMonthsSetting(4) end,
            },
            {
                text = _("6 months"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return Insights.readHeatmapMonthsSetting() == 6 end,
                callback = function() Insights.saveHeatmapMonthsSetting(6) end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local fmt = Insights.readHeatmapHourFormatSetting() == "12"
                and _("12-hour (AM/PM)")
                or  _("24-hour")
            return _("Heatmap hour format") .. ": " .. fmt
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("24-hour"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return Insights.readHeatmapHourFormatSetting() == "24"
                end,
                callback = function() Insights.saveHeatmapHourFormatSetting("24") end,
            },
            {
                text = _("12-hour (AM/PM)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return Insights.readHeatmapHourFormatSetting() == "12"
                end,
                callback = function() Insights.saveHeatmapHourFormatSetting("12") end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local start_day = Insights.readWeekStartSetting() == "sunday"
                and _("Sunday")
                or  _("Monday")
            return _("Week start day") .. ": " .. start_day
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Monday"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return Insights.readWeekStartSetting() == "monday"
                end,
                callback = function() Insights.saveWeekStartSetting("monday") end,
            },
            {
                text = _("Sunday"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return Insights.readWeekStartSetting() == "sunday"
                end,
                callback = function() Insights.saveWeekStartSetting("sunday") end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local order = Insights.readAscendingSetting()
                and _("Oldest first")
                or  _("Newest first")
            return _("8-week chart order") .. ": " .. order
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Newest first (descending)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return not Insights.readAscendingSetting()
                end,
                callback = function()
                    Insights.saveAscendingSetting(false)
                end,
            },
            {
                text = _("Oldest first (ascending)"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return Insights.readAscendingSetting()
                end,
                callback = function()
                    Insights.saveAscendingSetting(true)
                end,
            },
        },
    })

    table.insert(advanced_settings_sub_item_table, {
        text         = _("Show long durations (24h+) as days"),
        keep_menu_open = true,
        checked_func = function() return Locale.readDurationDaysSetting() end,
        callback     = function()
            Locale.saveDurationDaysSetting(not Locale.readDurationDaysSetting())
        end,
    })

    -- What the per-book reading calendar's day cells show: cumulative
    -- "+13%" progress through the whole book (default), that day's own
    -- page count ("+101o"), or that day's own time spent (honoring
    -- KOReader's global "Duration format" setting) - see
    -- BookCalendar.readCalendarCellModeSetting in book_calendar_view.lua.
    table.insert(advanced_settings_sub_item_table, {
        text_func = function()
            local mode_key = BookCalendar.readCalendarCellModeSetting()
            local mode = (mode_key == "pages" and _("Pages"))
                or (mode_key == "time" and _("Time"))
                or _("Percent")
            return _("Book calendar cell content") .. ": " .. mode
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Percent"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return BookCalendar.readCalendarCellModeSetting() == "percent"
                end,
                callback = function() BookCalendar.saveCalendarCellModeSetting("percent") end,
            },
            {
                text = _("Pages"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return BookCalendar.readCalendarCellModeSetting() == "pages"
                end,
                callback = function() BookCalendar.saveCalendarCellModeSetting("pages") end,
            },
            {
                text = _("Time"),
                keep_menu_open = true,
                radio = true,
                checked_func = function()
                    return BookCalendar.readCalendarCellModeSetting() == "time"
                end,
                callback = function() BookCalendar.saveCalendarCellModeSetting("time") end,
            },
        },
    })

    table.insert(settings_sub_item_table, {
        text = _("Advanced settings"),
        keep_menu_open = true,
        sub_item_table = advanced_settings_sub_item_table,
    })

    table.insert(sub_item_table, {
        text = _("Settings"),
        keep_menu_open = true,
        sub_item_table = settings_sub_item_table,
    })

    -- In-app updater: check for / install new releases straight from
    -- GitHub. See updater.lua and the ReadingInsights:_updateSubItems()
    -- family of methods above.
    table.insert(sub_item_table, {
        text                = _("Updates"),
        sub_item_table_func = function() return self:_updateSubItems() end,
        separator           = true,
    })

    -- About: plugin title, installed version, short description, and the
    -- GitHub repository URL. See about.lua.
    table.insert(sub_item_table, {
        text = _("About"),
        keep_menu_open = true,
        callback = function()
            About.show()
        end,
    })

    menu_items.reading_insights_popup = {
        text = _("Reading insights"),
        sorting_hint = "tools",
        sub_item_table = sub_item_table,
    }

    --[[
    No standalone top-level "Reading insights sleep screen" entry anymore -
    the "Reading insights" choice already lives inside KOReader's own
    Settings > Screen > Sleep screen > Wallpaper radio group (alongside
    "Document cover", "Random image", etc.), baked in by
    patchScreensaverMenuBuilder() above. Having a second, separate entry
    right next to the Sleep screen submenu just duplicated that same
    screensaver_type toggle in a confusing spot, so it's been removed -
    the Wallpaper-submenu entry is now the only place to pick it from
    (besides the Tools > Reading insights > Settings > "Use as sleep
    screen" quick toggle below, which stays).
    ]]--
end

return ReadingInsights