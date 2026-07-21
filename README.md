### 📊 Reading insights plugin

<img width="255" height="340" alt="FileManager_2026-07-18_205310" src="https://github.com/user-attachments/assets/2686e3ea-66cb-4d34-8af4-77fe147c47a3" />
<img width="255" height="340" alt="FileManager_2026-07-17_152344" src="https://github.com/user-attachments/assets/4a3d2fb9-cc51-4342-a952-36f23bb1925c" />
<img width="255" height="340" alt="Reader_Az Elso Torveny vilaga 1  - Hidegen talalva - Abercrombie, Joe #p(878) epub_p1117_2026-07-06_084654" src="https://github.com/user-attachments/assets/555ab8c6-d9ce-4ebc-a6ac-cfdf097ec51d" />
<br/><br/>
<img width="255" height="340" alt="Reader_Eddie Flynn 3  - Esku alatt - Cavanagh, Steve #p(421) epub_p696_2026-07-17_152405" src="https://github.com/user-attachments/assets/371b3119-119a-4ccb-9660-a63879996c48" />
<img width="255" height="340" alt="FileManager_2026-07-17_152315" src="https://github.com/user-attachments/assets/ea6711c7-7c18-4bb5-a15c-871cc0b74888" />
<img width="255" height="340" alt="FileManager_2026-07-17_152332" src="https://github.com/user-attachments/assets/21b311a8-bb10-4ffe-b7f0-3e91b19bb281" />

More screenshots

<img width="192" height="256" alt="reading-insights-v2-0-0-new-book-progress-popup-colors-v0-zoh19sw42rbh1" src="https://github.com/user-attachments/assets/52f851b7-8955-4739-b3a7-96ff8c2cbfe6" />
<img width="192" height="256" alt="FileManager_2026-07-18_211837" src="https://github.com/user-attachments/assets/e4e5d617-98c6-40bc-8844-f23fa5837e95" />
<img width="192" height="256" alt="FileManager_2026-07-02_083320" src="https://github.com/user-attachments/assets/8193ba8b-7f7e-4b35-9efb-81d0d4a1df8e" />
<br/><br/>
This plugin bundles reading-stats popups, powered by KOReader's
statistics database.

### Reading insights (full-screen history)

A full-screen scrollable overlay with a comprehensive overview of your reading history.

**Highlights:**
- **Last week** — 7-day average time and pages per day; tap either value to open its own 8-week trend popup (time trend or pages trend). Its daily bar chart puts today on the left by default, and can be flipped to put it on the right (see **Settings** below)
- **Streaks** — current and best daily & weekly reading streaks; tap any of
  the four to open a popup summarising that streak: its name and date range
  on one line, then reading time and pages side by side (total, and average
  per day), with the number of books read during it below
- **Yearly view** — hours or days read + pages, navigable by year
- **Monthly chart** — bar chart of reading activity per month (tappable to see books)
- **All-time totals** — cumulative hours and pages across all years; tap
  the "Total read" header to open a reading heatmap popup with two grids:
  a GitHub-style **calendar heatmap** covering the most recent period (3,
  4, or 6 months — configurable, see **Settings** below), with 5 shades
  from no reading to that period's busiest day, month-start labels along
  the top, and Mon/Wed/Fri labels down the left side; and a **time of day
  heatmap** below it, showing the same period's reading activity broken
  down by weekday and hour (shaded the same way, hour labels honouring the
  24-hour/12-hour setting). Swipeable left/right to page through
  older/newer periods as far back as there's data (the popup's own header
  shows the year, or a year range on its own line if the period spans a
  Dec/Jan boundary)
- **Reading goal** — this year's finished-book count next to a target you
  set for that year, shown as two side-by-side cells, each with a large
  number followed by its label, each reading as one phrase (e.g. "12"
  "books finished" next to "30" "books to read" — singular "1 book to read"
  when the target is set to 1);
  swipes left/right on the popup (see **Controls** below) move the goal
  section to that year too, same as the rest of the popup
  - **Tap** the left cell (the finished-book count) to see the books that
    make up it, most recently finished first (or in any other order, from
    the sort menu at the top left). This list shows the **date**
    each book was finished on the right, rather than the reading time the
    other book lists show — it is ordered by that date, and books you added
    yourself have no measured time at all. Those hand-added entries are
    shown as a bare title with a leading `*` on their date
  - **Long-press** the left cell to choose between the two ways of
    correcting that count:
    - **Mark books finished** — a checklist of every book with activity
      that year: checkbox and title on the left, the date of that book's
      last reading entry on the right. Tap a row to toggle whether it
      counts as finished. The check mark at the bottom right keeps your
      changes, the `X` at the bottom left puts them back as they were. Rows you changed yourself
      are marked with a trailing `*`, so it stays clear which entries came
      from the automatic rule and which you set by hand. The list is
      queried fresh every time it is opened, with the running reading
      session written out to the statistics database first, so a book you
      have just finished comes up already ticked; **Reload data** in the
      sort menu re-runs those queries without closing the list
    - **Add books manually** — your own list of books the statistics
      database knows nothing about (read on paper, in another app, on
      another device). Tap **Add book** to enter a title, an author and the
      date you read it (`YYYY-MM-DD`, prefilled with today for the current
      year); tap an entry to edit or delete it. Rows show the title on the
      left and that date on the right. The date stands in for a reading
      entry: it is what both this list and the finished-books list sort
      those entries by. Entries belong to the year the list was opened
      from, are kept in their own file (`reading_insights_manual_books.lua`,
      next to KOReader's settings) and count towards that year's reading
      goal
  - **Long-press** the right cell (the goal number) to open a number
    picker and set/change that year's target (1–999, defaults to 12)
  - A book counts as finished when its **last** reading entry reached at
    least 99% of the book, and it counts for the year that last entry
    falls in — so a book read across New Year counts once, in the year you
    finished it, and a finished book you later reopen and leave partway
    through stops counting. Books whose page count KOReader doesn't know
    (`pages = 0`) can't be judged this way and are never counted
    automatically; tick them in **Mark books finished** (or, if the book
    isn't in the statistics database at all, put it in **Add books
    manually**)
  - The right cell can show what is **still left** of the goal instead of
    the goal itself ("18" "books left") — *Settings → Advanced settings →
    Reading insight popup → Reading goal display*
  - The whole section can be switched off under *Settings → Advanced
    settings → Reading insight popup → Reading goal section* (on by
    default); when off, its data isn't even queried when the popup opens
- **Use as sleep screen** — show this same popup instead of KOReader's own lock screen when the device suspends, with no double flash (see **Sleep screen** below)
- **Reading heatmap range** — how many months the calendar/time-of-day
    heatmap grids show at once: 3, 4, or 6
  - **Time format** — 24-hour or 12-hour (AM/PM) labels for the
    time-of-day heatmap's hour columns
  - **First day of week** — Monday or Sunday, controls which day starts each
    row in both heatmap grids

**Book lists:** every book list has the same sort menu behind the icon at
the top left — by last reading entry (newest or oldest first, newest by
default) or by title (A→Z, Z→A). The read-only lists (books read in a
period, books counted as finished) keep their plain title/author rows with
a value on the right; the two lists you edit — **Mark books finished** and
**Add books manually** — are paged lists with checkboxes and a bottom bar.
The chosen order is remembered separately for each kind of list. The `X` at
the top right closes; **Mark books finished** also has a cancel `X` and an
accept check mark in the bottom bar, since it is the one list where changes
can be thrown away.

**Controls:** swipe left/right to change year, tap the "Total read" header to open the reading heatmap, tap bars to open book lists, tap the chart header to toggle hours/days mode, long-press the title bar to force-reload data (see **Reading goal** above for that section's own tap/long-press targets).

**Query shape:** `page_stat` is a view that rescales pages, joining
`page_stat_data`, `book` and a `numbers` table. Filters written as
`date(start_time, 'unixepoch', 'localtime') = ...` read well but hide the
indexed column inside a function, so SQLite scans instead of seeking - and
converts every row to local time to test it. Where it measurably helps, the
plugin uses a plain `start_time >= lo AND start_time < hi` range instead
(`InsightsData.dayBounds` works the local midnights out in Lua, DST
included). Where it doesn't, the `date()` form stays: with a range predicate
SQLite sometimes reorders the view's internal join and scans `numbers`
first, which is far slower. Both forms are in the code deliberately, each
with a comment saying which measurement put it there.

**Caching:** uses a stale-while-revalidate strategy — the popup opens instantly with cached data while fresh values load in the background. The last known values are also mirrored to disk, so this still holds true for the very first popup open after a KOReader restart — no blocking "Loading data..." wait. The reading goal's finished-book list is cached the same way and only updated incrementally (books read since the last check are re-examined, the rest are left alone); if `statistics.sqlite3` is restored from a backup, merged with another device's, or has rows removed, that is detected and the year is rescanned from scratch. A long press on the title bar force-reloads everything regardless.

Available everywhere (book view and file manager).

### 🏆 Records

A compact, floating card showing your personal reading records and
milestone progress — built on the same statistics database as the other
two popups.

**Highlights:**
- **Most reading time in a day** — most reading time on a single calendar day, with the date
- **Most pages in a day** — most pages read on a single calendar day, with the date
- **Best daily streak** — longest run of consecutive reading days, with the start–end dates
- **Last milestone** — highest total-hours milestone already passed, with the date it was reached
- **Next milestone** — next total-hours milestone ahead, with hours left to reach it

Milestone ladder (total reading hours): 1 → 5 → 10 → 25 → 50 → 100 → 250 →
500 → 1000 → 2500 → 5000 → 10000.

**Controls:** shown as a floating, bordered card centered on screen (not a
full-screen overlay); tap anywhere / swipe / press any key to close.

**Caching:** on first open the six queries run in full and the results are
written to a small cache file next to `statistics.sqlite3`. On later opens,
if nothing changed the cache is used as-is; if only new rows were added,
lightweight incremental queries update just what's needed; if the database
looks different in a way that can't be reconciled (e.g. after a sync or
manual delete), it falls back to a full recompute.

Available everywhere (book view and file manager), since none of this data
is tied to a specific open book.

### 📖 Book progress stats

A per-book overlay showing detailed progress and pace for the book you're currently reading, built on top of the same statistics database as Reading insights.

**Highlights:**
- **Progress** — pages/percentage read in the current book, plus pages remaining
- **Pace** — your average reading speed for this book (pages/hour or minutes/page)
- **Estimated finish** — projected time or date to finish, based on recent pace
- **Session stats** — time spent reading this book today and your average
  per day; tap this row to switch to today's page count and average pages
  per day instead — tap again to switch back
- **This chapter / Next chapter** — estimated reading time left in the
  current chapter and reading time for the next one; tap either value to
  switch to pages left in this chapter / next chapter's page count instead
  — tap again to switch back
- **Chapter breakdown** — progress and time spent per chapter (if chapter metadata is available)

**Controls:** tap to toggle between percentage/page view, tap the "This
chapter"/"Next chapter" row to toggle between reading time and pages left,
tap the "read today" / "avg time/day" row to toggle between time and page
counts, tap the "Pace" title to open the Book progress calendar, long-press to
force-reload data.

**Caching:** shares the same stale-while-revalidate approach as Reading insights — instant open with cached data, refreshed in the background.

### 🗓️ Book progress calendar

Tap the "Pace" section title on the Book progress popup or use the "Show Book
  progress calendar menu entry/gesture — see [Where it shows
  up](#where-it-shows-up) below) to open a month grid for this book,
  colored like a heatmap and showing a bottom progress bar per day (days
  with no reading are left blank — no bar at all); also shows the starting date, 
  the stimated finish day and if the book is finished also showd on the calendar.
  What the small text under each day number shows is configurable
  (*Settings → Advanced settings → Book progress calendar → Book progress
  calendar cell content*):
  - **Percent** (default) — cumulative progress through the whole book as
    of that day, e.g. "+13%"
  - **Pages** — that day's own page count, e.g. "+101" + the localized
    page abbreviation (e.g. "o" for Hungarian "oldal")
  - **Time** — that day's own time spent, formatted the same way as
    KOReader's global *Duration format* setting (classic "0:23", modern
    "23'", or letters "23m")

**Controls:** Tap a day to see its
  exact pages/time/percent, swipe or use the arrows to page between
  months.   

## 😴 Sleep screen

Reading insights can replace KOReader's own sleep/lock screen with itself, so
the last thing you see before the device sleeps is your reading progress
instead of a generic cover or logo.

- **Enable it** from KOReader's own screen: *Settings → Screen → Sleep
  screen → Wallpaper → **Reading insights*** (a radio option alongside
  "Document cover", "Random image", "Leave screen as-is", etc.) — this is
  the same `screensaver_type` setting core uses for all of its own
  wallpaper choices, so it plays nicely with anything else that reads it.
- **Sleep-screen indicator** (*Tools → Reading insights → Settings*, top
  entry): **None** (default) or **"(sleeping…)" after the title**, appended
  to the popup's title while it's shown as the sleep screen.
- No double flash: while active, KOReader's own screensaver (including any
  "Sleeping" message overlay) is fully suppressed for that suspend/resume
  cycle and cleanly restored afterwards — so only this popup's own single
  full-screen refresh happens, instead of the stock screensaver painting
  first and then immediately getting replaced.

## Updates

*Tools → Reading insights → Updates* checks GitHub for new releases and can
install them directly on the device — no computer/SSH needed:

- **Notify on wake when update available** — opt-in silent background check
  (at most once an hour), fired at startup and on every wake from sleep;
  shows a small notification when a newer release is found.
- The main **Installed version** / **Update available** row shows the
  currently installed version and, when applicable, the version it would
  update to; tapping it fetches the release notes for every release newer
  than what's installed and offers **Update and restart**.
- **Developer updates** — a pocket for testing pre-release code:
  - **Development branch** — point the updater at a specific branch instead
    of the latest stable release; the update row above then installs that
    branch's current tip.
  - **Reset to latest stable release** — clears the development branch and
    reinstalls the latest non-prerelease release.

Behind the scenes this downloads the release/branch zip from
[peterboda236/readinginsights.koplugin](https://github.com/peterboda236/readinginsights.koplugin),
unpacks it over the installed plugin folder, and prompts to restart
KOReader to load the new code.

Because it unpacks *over* the existing install rather than wiping the folder
first, a module that was moved or renamed between releases would otherwise
leave its old copy behind, loaded by nothing. A cleanup step removes those on
the next start, from a fixed list of known former paths (never a recursive
purge): the flat root-level modules from before the `lib/ views/ widgets/`
layout, the old `l10n/` translation folder, and the modules since renamed
inside `lib/` — `settings.lua`, `insightssettings.lua`, `insightscache.lua`.
Anything not on that list is left alone.

## Install

1. Unpack the latest zip and copy the `readinginsights.koplugin` folder into
   your KOReader `plugins/` directory.
2. Restart KOReader.
3. If you still have `2-reading-insights-popup.lua` and/or
   `2-reading-stats-popup.lua` in your `patches/` folder, **remove them** —
   running the patches alongside this plugin will double-register the same
   dispatcher actions.

Once installed, future updates can be installed in-app — see
[Updates](#updates) above.

## Where it shows up

- **Menu:** *Tools → Reading insights* — a submenu with "Show Reading
  insights", "Show Records", "Show Book progress" and "Show Book progress
  calendar" (the latter two book view only), and, below a separator, a
  **Settings** submenu and an **Updates** submenu (see
  [Updates](#updates) above).
  - **Settings** holds:
    - **Sleep-screen indicator** — None (default) or "(sleeping…)" after
      the title, appended while the popup is shown as the sleep screen
      (see [Sleep screen](#-sleep-screen) above)
    - **Full-screen refresh on open/close** — toggle
    - **Colors** — pick your own hex color for every bar/line/label the
      three popups draw (active/inactive bars, the 8-week trend line,
      section/column separator lines, the label/value/section/
      chart-label text colors, and the 5 year-heatmap shades - defaulting
      to 0/25/50/75/100% black); each one can be reset back to its
      default individually or all at once. Each color can be set either by
      typing a hex code directly, or by tapping **Pick with color wheel**
      to open a touch color wheel (hue/saturation dial plus a brightness
      slider) that opens pre-set to the color's current value and shows a
      live preview + hex readout while you drag.
    - **Fonts** — pick your own font (name + size) for every text role in
      all three popups, grouped under **Reading insights** (section
      headers, values, labels, chart/axis labels), **Records** (row
      values, row labels, sub-values — the date/book title under a value)
      and **Book progress** (section headers, values, labels,
      chapter-bar arrows); choose from a pick-from-list menu of every
      font file KOReader/you have installed, or type a custom font
      name/alias manually; each role can be reset to its bundled default
      individually or all at once.
    - **Advanced settings** holds two settings that apply everywhere,
      followed by one group per area:
      - **Bar chart height** — **Automatic (Reading insights)** (on by default)
        sizes the two Reading insights charts while the popup is built so
        the page ends up one screen tall, using whatever vertical space the
        other sections leave over and never spilling into a scroll bar.
        Both charts always get the identical height (it is one computed
        value, not two), and a further point is taken off it so the page
        keeps a few pixels of headroom rather than ending exactly on the
        screen edge. Switch it off to go back to fixed, hand-set heights
        (Reading insights: Last week / Months — greyed out while automatic
        is on). Book progress: Chapters is always set by hand
      - **Show long durations (24h+) as days** — off by default; when on,
        any duration of 24h or more (yearly/streak totals, weekly
        averages, all-time totals, book progress) is shown as a day count
        with one decimal place (e.g. "1.2 days") instead of clock time
      - **Date & time** — how clock times and dates are spelled out
        wherever the plugin prints one:
        - **Time format** — 24-hour or 12-hour (AM/PM) labels for the
          time-of-day heatmap's hour columns
        - **First day of week** — Monday or Sunday, controls which day
          starts each row in both heatmap grids
        - **Date format** — how every numeric date the plugin prints is
          spelled out: `YYYY-MM-DD` (2026-07-20), `YYYY.MM.DD.`
          (2026.07.20.), `DD/MM/YYYY` (20/07/2026) or `MM/DD/YYYY`
          (07/20/2026). Covers the book lists, the streak/records/stats
          popups, the Book progress calendar's day detail, and the date
          field of the manual book list (which is also read back in the
          chosen format — entries are stored as `YYYY-MM-DD` either way, so
          changing the setting never disturbs a date already saved). Dates
          that aren't numeric — weekday names, month names, the 8-week
          chart's axis labels — are unaffected. Defaults to `YYYY.MM.DD.`
          in Hungarian and `DD/MM/YYYY` elsewhere, which is what the plugin
          did before this setting existed
      - **Reading insight popup** — what the insights popup itself shows:
        - **Reading goal section** — show or hide the Reading goal section
          (on by default)
        - **Reading heatmap range** — how many months the calendar/time-of-
          day heatmap grids show at once: 3, 4, or 6
        - **8-week chart order** — newest-first or oldest-first
        - **Last week chapter bar order** — which end of the "Last week"
          bar chart today sits at: **Today on the left** (default, the week
          running backwards from there) or **Today on the right**. Today's
          bar keeps its highlight and its tap-to-open-the-Today-Timeline
          either way
        - **Reading goal display** — what the Reading goal section's
          right-hand value counts: **Goal total** (default, the year's goal
          itself — "30 books to read") or **Remaining** (what is still left
          of it after the finished books on the left — "18 books left",
          never going below 0). A long press on that cell edits the goal in
          both cases
      - **Book progress calendar**:
        - **Book progress calendar cell content** — Percent (default),
          Pages, or Time; controls what the calendar's day cells show
          (see [Book progress calendar](#️-book-progress-calendar) above)
- **Gestures/shortcuts:** all four actions below are registered with
  `Dispatcher`, so they can be assigned under *Settings → Taps and
  gestures*:
  - `reading_insights_popup` — available everywhere (general action).
  - `reading_records_popup` — available everywhere (general action), same
    as the insights popup, since none of the Records data is tied to a
    specific open book.
  - `reading_stats_popup` — book view only (reader action), matching the
    popup's requirement that a document be open.
  - `reading_calendar_popup` — book view only (reader action); opens the
    Book progress calendar directly, without going through "Show Book
    progress" first.

## File layout

Files load each other by explicit path from the plugin directory (not via
`require`), so the modules are grouped into folders. `_meta.lua`, `main.lua`
and `pluginutil.lua` must stay at the plugin root (KOReader loads the first
two by name; `pluginutil.lua` is the bootstrap that resolves the plugin
directory every other path is built from). The `locale/` translation folder
also stays at the root, since `lib/locale.lua` reads `locale/<lang>.po` from
there.

```
readinginsights.koplugin/
├── _meta.lua            plugin identity (name, description, version)
├── main.lua             entry point: bootstraps the shared modules, loads
│                        the views, registers dispatcher actions, handles the
│                        sleep-screen integration, and hands the Tools menu
│                        over to lib/menu.lua
├── pluginutil.lua       shared plugin-dir + module loader (the bootstrap
│                        anchor; replaces the old per-file pluginDir copies)
├── locale/              one .po file per language (en.po, hu.po, de.po)
├── tests/               checks that run without KOReader (see tests/README.md)
├── lib/                 shared modules: data queries, settings, caching,
│                        and the layout/menu building blocks
│   ├── book_calendar_data.lua  the Book progress calendar's queries (per-day
│   │                         pages/time for a month, cumulative progress,
│   │                         which months have data)
│   ├── book_stats_data.lua   the book progress overlay's query (days read,
│   │                         today's pages/time for this book and for all
│   │                         books, when the book was started)
│   ├── bookprogress.lua      per-book reading-position helpers (progress percent /
│   │                         pages left / page counts)
│   ├── chapterinfo.lua       chapter/TOC maths for the book progress view: which
│   │                         chapter you're in, how many there are, pages per
│   │                         chapter, progress within the current one (with the
│   │                         parsed TOC cached per book)
│   ├── colors.lua            chart/text color settings (the "Colors" submenu)
│   ├── fonts.lua             font settings (the "Fonts" submenu)
│   ├── insights_data.lua     every figure the insights popup shows: streaks,
│   │                         yearly/monthly aggregates for all three modes,
│   │                         the last-week and 8-week series, all-time
│   │                         totals, the heatmap matrices and the
│   │                         reading-goal count
│   ├── insights_cache.lua    the insights popup's data cache: per-minute /
│   │                         per-day in-memory caches, the "stale" copies behind
│   │                         stale-while-revalidate, the "up to yesterday" base
│   │                         aggregates, the persisted finished-books lists for
│   │                         the reading goal, and the disk mirror of all of it
│   ├── manual_books.lua      the books the reader adds by hand (ones the
│   │                         statistics DB knows nothing about) with the
│   │                         date each was read, one list per year, in its
│   │                         own settings file
│   ├── insights_settings.lua every user-settable option of the insights
│   │                         popup (bar-chart heights + automatic mode, heatmap
│   │                         options, reading goal + finished-book overrides,
│   │                         week start day, chart display modes)
│   ├── locale.lua            translation lookup (locale/<lang>.po) + locale-aware
│   │                         number/duration formatting
│   ├── menu.lua              the whole *Tools → Reading insights* menu tree
│   │                         (actions, Settings, Advanced settings, Updates, About)
│   ├── popuputil.lua         shared "any tap/swipe/key dismisses" popup handlers
│   ├── records_data.lua      the Records popup's queries and their cache
│   │                         (record values + a DB fingerprint that decides
│   │                         between an incremental update and a full
│   │                         recompute)
│   ├── prefs.lua             nil-guarded G_reader_settings wrappers + the shared
│   │                         week-start-day setting (named prefs, not
│   │                         settings, so it isn't confused with the
│   │                         insights view's own options above)
│   ├── statsdb.lua           access to KOReader's statistics.sqlite3 (one db path
│   │                         + PRAGMAs; open / withDb / withConn / withShared /
│   │                         withStatement)
│   ├── uikit.lua             the section/two-column layout helpers all three
│   │                         popups build their rows with (one merged copy of
│   │                         what used to be three drifting ones)
│   └── updater.lua           in-app updater (the "Updates" submenu): checks GitHub
│                             for new releases/branches and installs them
├── views/               the user-facing popups
│   ├── about.lua               plugin info + version/update status
│   ├── book_calendar_view.lua  the Book progress calendar (opened from the
│   │                           book progress view)
│   ├── book_stats_view.lua     compact "current book progress" overlay
│   │                           (formerly stats_view.lua)
│   ├── booklist_view.lua       the book lists the insights popup opens on a
│   │                           tap or long press: books read in a period and
│   │                           books counted towards the reading goal (plain
│   │                           KeyValuePage lists), plus the checklist for
│   │                           correcting that count by hand and the list
│   │                           of books added manually (both drawn with
│   │                           widgets/booklistwidget.lua)
│   ├── heatmap_view.lua        both reading heatmaps (calendar-style range,
│   │                           and weekday x hour-of-day) plus their
│   │                           full-screen popup
│   ├── insights_view.lua       full-screen "Reading insights" popup: the page
│   │                           itself (its figures come from
│   │                           lib/insights_data.lua)
│   ├── records_view.lua        personal records and milestones (the popup;
│   │                           its data lives in lib/records_data.lua)
│   └── trend_view.lua          the 8-week trend line chart popup
└── widgets/             reusable UI widgets
    ├── booklistwidget.lua    the list widget the two editable book lists are
    │                         drawn with: paged rows (checkbox + title left,
    │                         date right) and optional cancel/accept buttons -
    │                         a subclass of KOReader's SortWidget with its own
    │                         row widget. Also holds the sort menu and the
    │                         comparators behind it, which the plain
    │                         KeyValuePage book lists share
    ├── chapterbarwidget.lua  the per-chapter bar under "This book" in the
    │                         book progress view (plus its own height
    │                         setting), paged with the arrows either side
    └── colorwheelwidget.lua  touch color wheel (hue/saturation + brightness +
                              live hex preview) used by the Colors submenu

Modules receive their dependencies from `main.lua` as one **named table**
rather than as positional chunk arguments:

```lua
local Insights = loadModule("views/insights_view.lua", {
    Locale = Locale, Colors = Colors, ... , Trend = Trend, Heatmap = Heatmap,
})
```

The lists had grown long enough (ten modules for the book progress view)
that inserting one in the middle would silently shift everything after it,
and the resulting nil would only surface far from the cause. Two modules -
`heatmap_view.lua` and `booklist_view.lua` - also need things from
`insights_view.lua`, which loads *after* them; rather than requiring back
into the view and creating a cycle, the view calls their `bind()` once at
load time to hand those over.
```

**A note on the splits:** Lua allows at most 200 active local variables per
function scope, and the top level of a file is one such scope.
`views/insights_view.lua` had crept to within a handful of that ceiling, at
which point the next feature would have failed to compile with *"main
function has more than 200 local variables"*. Its settings and cache layers
became `lib/insights_settings.lua` and `lib/insights_cache.lua`. Anything
added there in future is best kept as fields on one table rather than as new
top-level locals.

The other splits are about duplication and cohesion rather than that limit:

- `views/trend_view.lua`, `views/heatmap_view.lua` and
  `views/booklist_view.lua` are the three self-contained popup modules the
  insights view opens (the book list one covers four lists). The view file now holds the insights page itself rather than
  every popup reachable from it, and went from ~5600 lines to ~3600.
- `lib/uikit.lua` replaces three copies of the same layout helpers that had
  begun to diverge (`buildLayout`, `buildSectionHeader`, `buildTwoColRow`,
  `addSectionWithRow`, `padded`, `fixedCol`, `buildColumnSeparator`,
  `hitTest`, `emptyValue`). Where the copies differed, the merged version
  keeps the more capable behaviour and makes the extra part optional.
  `buildValueLine` is deliberately *not* shared: the two versions really do
  different jobs.
- `lib/chapterinfo.lua` and `widgets/chapterbarwidget.lua` split the book
  progress view's chapter handling into "work out the numbers" and "draw
  them". The first has no UI at all, which makes it testable on its own.
- Every popup now has its figures in `lib/` and its widgets in `views/`:
  `insights_data.lua`, `records_data.lua`, `book_stats_data.lua` and
  `book_calendar_data.lua`, alongside the older `chapterinfo.lua` and
  `bookprogress.lua`. The split is symmetric on purpose - a new figure has
  one obvious place to go, and none of the query code needs KOReader's UI
  to be exercised - no file under `views/` contains a single SQL statement
  or opens the statistics DB any more. The insights queries were already
  plain functions in
  disguise - written as methods on the popup class, but not one of them
  touched popup state - so the move cost them only the `self` they never
  used, and took `insights_view.lua` from ~3600 lines to ~2300. The records
  cache file keeps the path and key layout it always had, so upgrading
  doesn't cost a recompute; only the hand-written serializer behind it was
  replaced with LuaSettings.
- `lib/menu.lua` takes the ~500-line Tools menu out of `main.lua`.

## Tests

```sh
./tests/run.sh
```

Needs `lua5.1` and `luac5.1`, nothing else — the `lib/` modules are all
plain computation over the statistics DB, so they load and run outside
KOReader. The suite covers the settings, cache, chapter maths and records
queries, loads every module the way `main.lua` does to verify the wiring,
and statically checks the tree for accidental globals, unused requires,
`popup:method()` calls that no longer resolve, module surfaces and
translation coverage. See `tests/README.md`.

It cannot cover drawing: everything under `views/` builds widgets, which
need a real device. Open each popup once before releasing.

The release zip should leave the tests behind:

```sh
zip -r readinginsights.koplugin.zip readinginsights.koplugin -x '*/tests/*' -x '*/.git/*'
```

## Translations

`locale/en.po`, `locale/hu.po` and `locale/de.po` hold the UI strings for
every popup (month names, "Total read", streak labels, records labels,
chapter/pace labels, menu entries, etc.) as plain `msgid`/`msgstr` pairs,
e.g.:

```
msgid "Current streak"
msgstr "Aktuális sorozat"
```

To add another language, drop a new `locale/<lang>.po` file next to the
existing ones — no code changes needed. Every string the code passes to
`_()` or `N_()` should have an entry in each file; a missing one falls back
to the English original, so a gap shows up as a stray English label rather
than as an error.


## Acknowledgements
- The statistics based on [(https://github.com/quanganhdo/koreader-user-patches)](https://github.com/quanganhdo/koreader-user-patches).
- Colorwheel comes from [(https://github.com/Euphoriyy/KOReader.patches#-colorwheelwidgetlua)](https://github.com/Euphoriyy/KOReader.patches#-colorwheelwidgetlua).
- In-plugin updater adapted from [(https://github.com/AndyHazz/bookshelf.koplugin)](https://github.com/AndyHazz/bookshelf.koplugin).

## License

AGPL-3.0 -- see [LICENSE](LICENSE)

## Support
[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/peterboda236)
