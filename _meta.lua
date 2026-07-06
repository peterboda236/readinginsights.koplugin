local _ = require("gettext")

return {
    name = "readinginsights",
    fullname = _("Reading insights"),
    description = _([[Two reading-stats popups built on top of statistics.sqlite3. "Reading insights": full-screen, scrollable history with last-week bar chart, streaks, yearly/monthly stats and charts, and all-time totals - available everywhere. "Reading statistics: overview": a compact live overlay for the book you're currently reading (chapter/book time left, progress, pace) - available in book view only. Adds an entry under Tools > Reading insights.]]),
}
