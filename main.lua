--[[
Reading Insights (plugin entry point)

This plugin adds two views, each implemented in its own file:

  insights_view.lua
    "Reading insights" - full-screen, scrollable reading-history popup
    (last week, streaks, yearly/monthly charts, all-time totals). Available
    everywhere (book view and file manager), via the Tools menu and via a
    general gesture/dispatcher action.

  stats_view.lua
    "Reading statistics: overview" - compact live overlay for the book
    currently open (chapter/book time left, progress, pace). Book-view only:
    it needs an open document, so it's only offered in the Tools menu while
    reading, and its gesture/dispatcher action only shows up for assignment
    under Reader gestures (not File manager gestures).

This file itself only does the wiring: it loads the shared translation
module (l10n.lua) and both view modules, registers the two dispatcher
actions (for gesture/shortcut assignment), builds the Tools menu entries,
and forwards the two "show popup" events to the right view.

Both view files are loaded with loadfile()(...) rather than require(...)
so they don't depend on this plugin's directory being on package.path -
they get the shared L10N module passed straight in as their chunk argument.
]]--

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local Screen = Device.screen

-- Sleep-screen setting: "off" (default), "filemanager" (only when locking
-- from the file manager, i.e. no book open), or "always" (file manager and
-- book view alike). Stored as a single G_reader_settings key so it survives
-- restarts, same as every other setting in this plugin.
local SCREENSAVER_SETTING = "readinginsights_screensaver_mode"

local function readScreensaverMode()
    return G_reader_settings:readSetting(SCREENSAVER_SETTING) or "off"
end

local function saveScreensaverMode(mode)
    G_reader_settings:saveSetting(SCREENSAVER_SETTING, mode)
end

-- What to show in the title, in place of the (hidden) close button, while
-- acting as a sleep screen: "none" (default) or "text" (appends something
-- like "(sleeping…)" after "Reading insights").
local SCREENSAVER_LABEL_SETTING = "readinginsights_screensaver_label_mode"

local function readScreensaverLabelMode()
    return G_reader_settings:readSetting(SCREENSAVER_LABEL_SETTING) or "none"
end

local function saveScreensaverLabelMode(mode)
    G_reader_settings:saveSetting(SCREENSAVER_LABEL_SETTING, mode)
end

-- Whether to wait a beat before showing the sleep-screen popup on suspend:
-- "none" (default - shows immediately, since the core screensaver no
-- longer paints anything once suppressed - see suppressCoreScreensaver()
-- below) or "delay" (the old behaviour: wait 0.1s first, in case some
-- other plugin/core codepath still ends up painting something first that
-- the popup should sit on top of instead of racing against).
local SCREENSAVER_DELAY_SETTING = "readinginsights_screensaver_delay_mode"

local function readScreensaverDelayMode()
    return G_reader_settings:readSetting(SCREENSAVER_DELAY_SETTING) or "none"
end

local function saveScreensaverDelayMode(mode)
    G_reader_settings:saveSetting(SCREENSAVER_DELAY_SETTING, mode)
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
    return G_reader_settings:readSetting(DEV_BRANCH_SETTING) or ""
end

local function saveDevBranch(branch)
    G_reader_settings:saveSetting(DEV_BRANCH_SETTING, branch)
end

local function readLastInstallSource()
    return G_reader_settings:readSetting(LAST_INSTALL_SOURCE_SETTING) or "release"
end

local function saveLastInstallSource(source)
    G_reader_settings:saveSetting(LAST_INSTALL_SOURCE_SETTING, source)
end

local function readCheckUpdates()
    return G_reader_settings:isTrue(CHECK_UPDATES_SETTING)
end

local function saveCheckUpdates(value)
    if value then
        G_reader_settings:makeTrue(CHECK_UPDATES_SETTING)
    else
        G_reader_settings:makeFalse(CHECK_UPDATES_SETTING)
    end
end

--[[
Suppressing KOReader's own built-in sleep screen for the duration of a
single suspend, so it doesn't paint (full e-ink refresh) and then get
immediately replaced by our own popup (another full refresh) a moment
later - the "flash of the other sleep screen" effect.

This is only ever applied right before showing our own popup in onSuspend()
below, and undone again in onResume(), so it's scoped to exactly the
suspend/resume window where our popup is actually going to be shown. If,
say, the sleep-screen mode is "filemanager" and the device suspends while a
book is open, _screensaverShouldShow() is false, these functions are never
called, and the user's own built-in screensaver (cover/image/message/etc.)
runs completely untouched, as if this plugin didn't exist.

Two separate core settings need overriding, not just one: screensaver_type
== "disable" alone is *not* enough to stop KOReader's Screensaver:show()
from painting something - if screensaver_show_message is also on, it still
draws its own "Sleeping" text box on top of the (disabled) background
before anything else happens, i.e. exactly the flash this is meant to
avoid. Both are saved/restored together as a single override.

SCREENSAVER_OVERRIDE_ACTIVE_SETTING guards against overwriting the saved
"previous value" a second time if suppressCoreScreensaver() were ever
called twice without a restore in between, and also lets init() detect and
clean up a leftover override from a session that crashed or was killed
between onSuspend() and onResume() - without it, the user's built-in
screensaver could otherwise stay stuck disabled.
]]--
local SCREENSAVER_OVERRIDE_ACTIVE_SETTING  = "readinginsights_screensaver_override_active"
local SCREENSAVER_PREV_TYPE_SETTING        = "readinginsights_screensaver_prev_type"
local SCREENSAVER_PREV_SHOW_MSG_SETTING    = "readinginsights_screensaver_prev_show_message"

local function suppressCoreScreensaver()
    -- If our override is already flagged active, check whether the live
    -- screensaver_type is still what we forced it to ("disable"). If the
    -- user has since gone into KOReader's own Settings > Screen > Sleep
    -- screen menu and changed it there, the live value will no longer be
    -- "disable" even though our flag says "already applied". In that case
    -- our previously saved "prev" snapshot is stale - it holds whatever
    -- was set *before* the user's latest change, not the user's latest
    -- change itself. Re-snapshot now so we don't clobber it later in
    -- restoreCoreScreensaver().
    if G_reader_settings:isTrue(SCREENSAVER_OVERRIDE_ACTIVE_SETTING) then
        if G_reader_settings:readSetting("screensaver_type") == "disable" then
            return -- already applied, and still ours - nothing to do
        end
        -- else: fall through and re-snapshot the user's new live value
    end
    G_reader_settings:saveSetting(SCREENSAVER_PREV_TYPE_SETTING, G_reader_settings:readSetting("screensaver_type"))
    G_reader_settings:saveSetting(SCREENSAVER_PREV_SHOW_MSG_SETTING, G_reader_settings:isTrue("screensaver_show_message"))
    G_reader_settings:makeTrue(SCREENSAVER_OVERRIDE_ACTIVE_SETTING)
    G_reader_settings:saveSetting("screensaver_type", "disable")
    G_reader_settings:makeFalse("screensaver_show_message")
end

local function restoreCoreScreensaver()
    if not G_reader_settings:isTrue(SCREENSAVER_OVERRIDE_ACTIVE_SETTING) then return end
    -- If the live screensaver_type is no longer "disable", the user must
    -- have gone into KOReader's own Sleep screen menu and changed it
    -- themselves while our override was active. That live value is what
    -- the user actually wants now, so leave it untouched instead of
    -- overwriting it with our (now stale) saved prev_type - just clear
    -- our bookkeeping keys as if the override never happened.
    if G_reader_settings:readSetting("screensaver_type") ~= "disable" then
        G_reader_settings:delSetting(SCREENSAVER_PREV_TYPE_SETTING)
        G_reader_settings:delSetting(SCREENSAVER_PREV_SHOW_MSG_SETTING)
        G_reader_settings:makeFalse(SCREENSAVER_OVERRIDE_ACTIVE_SETTING)
        return
    end
    G_reader_settings:saveSetting("screensaver_type", G_reader_settings:readSetting(SCREENSAVER_PREV_TYPE_SETTING))
    G_reader_settings:delSetting(SCREENSAVER_PREV_TYPE_SETTING)
    -- Only touch screensaver_show_message if we actually recorded an
    -- original value for it. A leftover SCREENSAVER_OVERRIDE_ACTIVE_SETTING
    -- from an older version of this plugin (from before this setting was
    -- tracked) would otherwise have no recorded value here, and reading a
    -- missing setting as "false" would incorrectly force the user's real
    -- "Show message" preference off instead of leaving it alone.
    if G_reader_settings:has(SCREENSAVER_PREV_SHOW_MSG_SETTING) then
        if G_reader_settings:isTrue(SCREENSAVER_PREV_SHOW_MSG_SETTING) then
            G_reader_settings:makeTrue("screensaver_show_message")
        else
            G_reader_settings:makeFalse("screensaver_show_message")
        end
        G_reader_settings:delSetting(SCREENSAVER_PREV_SHOW_MSG_SETTING)
    end
    G_reader_settings:makeFalse(SCREENSAVER_OVERRIDE_ACTIVE_SETTING)
end

local function pluginDir()
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*/)")
    return dir or "./"
end

local PLUGIN_DIR = pluginDir()

-- Loads <name> from this plugin's directory and calls the resulting chunk
-- with `...` as its arguments (e.g. the shared L10N module).
local function loadModule(name, ...)
    local path = PLUGIN_DIR .. name
    local chunk, err = loadfile(path)
    if not chunk then
        error(("Reading Insights: failed to load %s: %s"):format(name, tostring(err)))
    end
    return chunk(...)
end

local L10N = loadModule("l10n.lua")
local _ = L10N._

-- Shared chart/text color settings (Colors menu), used by both views so
-- there's a single, unified place to configure them. See colors.lua.
local Colors = loadModule("colors.lua", L10N)

-- Shared popup font settings (Fonts menu), same idea as Colors above but
-- for the section/value/label/small text roles in both popups. See
-- fonts.lua.
local Fonts = loadModule("fonts.lua", L10N)

local Insights = loadModule("insights_view.lua", L10N, Colors, Fonts)
local StatsPopup = loadModule("stats_view.lua", L10N, Colors, Fonts)

-- In-app updater (Updates menu): lets the user check for and install new
-- releases of this plugin straight from GitHub. See updater.lua.
local Updater = loadModule("updater.lua", L10N)

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

--[[
KOReader's core Screensaver:show() (the thing that paints the default
logo / cover / message screen) runs from Device:onPowerEvent(), which
fires directly off the Power/Suspend input event - well *before* the
"Suspend" event is ever broadcast to widgets/plugins. That means doing
the override only in onSuspend() below is always one step too late: the
core screensaver has already painted (and refreshed the e-ink panel)
with whatever screensaver_type was set *before* the user even pressed
the power button, and our own popup then replaces it a moment later -
the double-flash the user sees.

The fix is to keep G_reader_settings.screensaver_type synced to whether
our popup *should* show *proactively*, at every point the answer could
have changed (plugin init, opening/closing a book, changing the sleep-
screen setting) - not reactively at suspend time. By the time an actual
suspend happens, the value is already correct and Screensaver:show()
either does nothing (screensaver_type == "disable") or runs the user's
own untouched screensaver, with no extra repaint in either case.

assume_no_document lets a caller override the "is a document open"
check for a single call: onCloseDocument (see below) fires while
self.ui.document is technically still non-nil, but we already know
we're on our way back to the file manager.
]]--
function ReadingInsights:_syncCoreScreensaverOverride(assume_no_document)
    local mode = readScreensaverMode()
    local should_show
    if mode == "always" then
        should_show = true
    elseif mode == "filemanager" then
        should_show = assume_no_document or not self:_hasOpenDocument()
    else -- "off"
        should_show = false
    end
    if should_show then
        suppressCoreScreensaver()
    else
        restoreCoreScreensaver()
    end
end

function ReadingInsights:onDispatcherRegisterActions()
    Dispatcher:registerAction("reading_insights_popup", {
        category = "none",
        event    = "ShowReadingInsightsPopup",
        title    = _("Reading insights"),
        general  = true,
    })
    -- reader = true (not general): only assignable to gestures/shortcuts
    -- while in book view, matching the popup's book-only requirement.
    Dispatcher:registerAction("reading_stats_popup", {
        category = "none",
        event    = "ShowReadingStatsPopup",
        title    = _("Book progress"),
        reader   = true,
    })
end

function ReadingInsights:init()
    -- Safety net: if a previous session crashed or was force-closed between
    -- onSuspend() and onResume(), this restores the user's own
    -- screensaver_type now rather than leaving it stuck on "disable". A
    -- no-op the vast majority of the time, since the override is normally
    -- only ever active for the few hundred ms between those two events.
    restoreCoreScreensaver()
    -- Then immediately (re)apply it if the current context calls for it -
    -- e.g. starting up straight into the file manager with mode ==
    -- "filemanager" or "always" should already have it suppressed before
    -- the very first suspend, not just from the second one onwards.
    self:_syncCoreScreensaverOverride()

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

function ReadingInsights:_screensaverShouldShow()
    local mode = readScreensaverMode()
    if mode == "off" then return false end
    if mode == "always" then return true end
    if mode == "filemanager" then return not self:_hasOpenDocument() end
    return false
end

--[[
Sleep-screen integration.

KOReader's own sleep-screen picker (Settings > Screen > Sleep screen) is a
fixed list rebuilt from a core file every time it's opened, and its
"reading progress" option is hardcoded to the built-in Statistics plugin -
there's no supported way for a third-party plugin to add itself there.
Instead, this hooks the same Suspend/Resume events every screensaver mode
ultimately relies on, and shows the Reading insights popup on top,
independently of whatever G_reader_settings.screensaver_type is set to.

The popup is created with readonly = true so a stray tap, swipe-down, or
the wake key itself can't dismiss it early while the device is still
"asleep"; onResume below is what actually closes it again.
]]--
function ReadingInsights:onSuspend()
    if not self:_screensaverShouldShow() then return end
    -- Belt-and-braces: the override should already be active by now (it's
    -- applied proactively - see _syncCoreScreensaverOverride() and its
    -- call sites), since by the time the "Suspend" event reaches us here,
    -- KOReader's own Screensaver:show() has *already run* off the raw
    -- Power/Suspend input event. This call is a no-op in the normal case;
    -- it only matters as a fallback if some context change was missed.
    suppressCoreScreensaver()
    -- With the override active (screensaver_type == "disable" and
    -- screensaver_show_message == false), KOReader's own Screensaver:show()
    -- returns immediately without painting anything, so by default this
    -- shows right away rather than after an artificial delay. The old
    -- 0.1s-delay behaviour is still available (Settings > "Sleep-screen
    -- transition") for anyone who wants to wait a beat first.
    local function showPopup()
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

    if readScreensaverDelayMode() == "delay" then
        UIManager:scheduleIn(0.1, showPopup)
    else
        showPopup()
    end
end

function ReadingInsights:onResume()
    -- Re-sync rather than unconditionally restoring: with mode == "always"
    -- (or "filemanager" while still in the file manager), the override is
    -- meant to stay active across suspend/resume cycles, not just the
    -- first one - unconditionally restoring here would undo it right
    -- after every wake-up, bringing back the flash on every suspend after
    -- the first.
    self:_syncCoreScreensaverOverride()
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

-- A document has just finished opening (Reader view): re-sync, since
-- _hasOpenDocument() now correctly reflects "book open" and may need to
-- restore the user's own screensaver (mode == "filemanager").
function ReadingInsights:onReaderReady()
    self:_syncCoreScreensaverOverride()
end

-- A document is about to close, heading back to the file manager.
-- self.ui.document is still non-nil at this exact point (ReaderUI clears
-- it right after broadcasting this event), so _hasOpenDocument() can't be
-- trusted here - explicitly sync as if no document were open instead.
function ReadingInsights:onCloseDocument()
    self:_syncCoreScreensaverOverride(true)
end

function ReadingInsights:onShowReadingInsightsPopup()
    local popup = Insights.Popup:new{ ui = self.ui }
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
    end

    -- Separator after the two "open a popup" entries, before the
    -- settings submenu below.
    sub_item_table[#sub_item_table].separator = true

    local settings_sub_item_table = {}

    table.insert(settings_sub_item_table, {
        text_func = function()
            local mode = readScreensaverMode()
            local mode_label = (mode == "always" and _("File manager + book"))
                or (mode == "filemanager" and _("File manager only"))
                or _("Off")
            return _("Use as sleep screen") .. ": " .. mode_label
        end,
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("Off"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return readScreensaverMode() == "off" end,
                callback = function()
                    saveScreensaverMode("off")
                    self:_syncCoreScreensaverOverride()
                end,
            },
            {
                text = _("Only when locking from the file manager"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return readScreensaverMode() == "filemanager" end,
                callback = function()
                    saveScreensaverMode("filemanager")
                    self:_syncCoreScreensaverOverride()
                end,
            },
            {
                text = _("File manager and book view"),
                keep_menu_open = true,
                radio = true,
                checked_func = function() return readScreensaverMode() == "always" end,
                callback = function()
                    saveScreensaverMode("always")
                    self:_syncCoreScreensaverOverride()
                end,
            },
            {
                text_func = function()
                    return _("Transition") .. ": " ..
                        ((readScreensaverDelayMode() == "delay") and _("Slight delay") or _("Instant"))
                end,
                keep_menu_open = true,
                sub_item_table = {
                    {
                        text = _("Instant"),
                        keep_menu_open = true,
                        radio = true,
                        checked_func = function() return readScreensaverDelayMode() == "none" end,
                        callback = function() saveScreensaverDelayMode("none") end,
                    },
                    {
                        text = _("Slight delay (0.1s)"),
                        keep_menu_open = true,
                        radio = true,
                        checked_func = function() return readScreensaverDelayMode() == "delay" end,
                        callback = function() saveScreensaverDelayMode("delay") end,
                    },
                },
            },
            {
                text_func = function()
                    local label_mode = readScreensaverLabelMode()
                    return _("Indicator") .. ": " ..
                        ((label_mode == "text") and _("\"(sleeping…)\" after the title") or _("None"))
                end,
                keep_menu_open = true,
                separator = true,
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
            },
        },
        separator = true,
    })

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
    })

    menu_items.reading_insights_popup = {
        text = _("Reading insights"),
        sorting_hint = "tools",
        sub_item_table = sub_item_table,
    }
end

return ReadingInsights