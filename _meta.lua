local _ = require("gettext")

return {
    -- KEEP `name`: some KOReader releases load a DISABLED plugin's identity
    -- from _meta.lua rather than main.lua, and key the plugin-manager
    -- enable/disable toggle off whatever name they find there. Without it,
    -- re-enabling this plugin after disabling it could get stuck (see
    -- bookshelf.koplugin's _meta.lua for the full writeup of this issue).
    name = "readinginsights",
    fullname = _("Reading insights"),
    description = _([[Two reading-stats popups built on top of statistics.sqlite3. "Reading insights": full-screen, scrollable history with last-week bar chart, streaks, yearly/monthly stats and charts, and all-time totals - available everywhere. "Reading statistics: overview": a compact live overlay for the book you're currently reading (chapter/book time left, progress, pace) - available in book view only. Adds an entry under Tools > Reading insights.]]),
    -- Bumped by the in-app updater (updater.lua) as new versions are
    -- installed. Keep in sync with the GitHub release tag (without the
    -- leading "v") each time a new release is cut.
    version = "3.5.1",
}
