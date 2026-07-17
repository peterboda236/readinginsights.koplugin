### 📊 Reading insights

<img width="384" height="512" alt="FileManager_2026-06-30_074746" src="https://github.com/user-attachments/assets/cf248698-75d0-4948-8d9c-70ea5c69fd5e" />


More screenshots

<img width="96" height="128" alt="reading-insights-v2-0-0-new-book-progress-popup-colors-v0-zoh19sw42rbh1" src="https://github.com/user-attachments/assets/52f851b7-8955-4739-b3a7-96ff8c2cbfe6" /><img width="96" height="128" alt="FileManager_2026-06-30_074746" src="https://github.com/user-attachments/assets/cf248698-75d0-4948-8d9c-70ea5c69fd5e" /><img width="96" height="128" alt="FileManager_2026-07-02_083320" src="https://github.com/user-attachments/assets/8193ba8b-7f7e-4b35-9efb-81d0d4a1df8e" /><img width="96" height="128" alt="FileManager_2026-07-02_083306" src="https://github.com/user-attachments/assets/3026267b-d29d-4487-99a5-6efdcc4baa37" />

<img width="96" height="128" alt="FileManager_2026-07-02_083257" src="https://github.com/user-attachments/assets/8a5857fb-f313-4d04-ab26-f604bdee7e52" /><img width="96" height="128" alt="FileManager_2026-07-10_103932" src="https://github.com/user-attachments/assets/ee35d8c8-7160-4e57-998a-2d4e3a26fa70" /><img width="96" height="128" alt="Reader_Eddie Flynn 3  - Esku alatt - Cavanagh, Steve #p(421) epub_p333_2026-07-12_121742" src="https://github.com/user-attachments/assets/91661f4b-82bc-4f39-baea-fcbdb3edbad1" />




This plugin bundles three reading-stats popups, powered by KOReader's
statistics database.

### Reading insights (full-screen history)

A full-screen scrollable overlay with a comprehensive overview of your reading history.

**Highlights:**
- **Today** — reading time and pages read so far today
- **Last week** — 7-day average time and pages per day; tap either value to open its own 8-week trend popup (time trend or pages trend)
- **Streaks** — current and best daily & weekly reading streaks
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
- **Use as sleep screen** — show this same popup instead of KOReader's own lock screen when the device suspends, with no double flash (see **Sleep screen** below)
- **Reading heatmap range** — how many months the calendar/time-of-day
    heatmap grids show at once: 3, 4, or 6
  - **Heatmap hour format** — 24-hour or 12-hour (AM/PM) labels for the
    time-of-day heatmap's hour columns
  - **Week start day** — Monday or Sunday, controls which day starts each
    row in both heatmap grids

**Controls:** swipe left/right to change year, tap the "Total read" header to open the reading heatmap, tap bars to open book lists, tap the chart header to toggle hours/days mode, long-press to force-reload data.

**Caching:** uses a stale-while-revalidate strategy — the popup opens instantly with cached data while fresh values load in the background. The last known values are also mirrored to disk, so this still holds true for the very first popup open after a KOReader restart — no blocking "Loading data..." wait.

Available everywhere (book view and file manager).

### 🏆 Records

<img width="384" height="512" alt="FileManager_2026-07-16_151137" src="https://github.com/user-attachments/assets/203b2f12-8219-43d8-ba30-ad10bc2d1053" />


A compact, floating card showing your personal reading records and
milestone progress — built on the same statistics database as the other
two popups.

**Highlights:**
- **Most reading time in a day** — most readin time on a single calendar day, with the date
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

<img width="384" height="512" alt="Reader_Az Elso Torveny vilaga 1  - Hidegen talalva - Abercrombie, Joe #p(878) epub_p1117_2026-07-06_084654" src="https://github.com/user-attachments/assets/555ab8c6-d9ce-4ebc-a6ac-cfdf097ec51d" />

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
- **Reading calendar** — tap the "Pace" section title (or use the "Show Book
  progress calendar" menu entry/gesture — see [Where it shows
  up](#where-it-shows-up) below) to open a month grid for this book,
  colored like a heatmap and showing a bottom progress bar per day (days
  with no reading are left blank — no bar at all); tap a day to see its
  exact pages/time/percent, swipe or use the arrows to page between
  months. What the small text under each day number shows is configurable
  (*Settings → Advanced settings → Book calendar cell content*):
  - **Percent** (default) — cumulative progress through the whole book as
    of that day, e.g. "+13%"
  - **Pages** — that day's own page count, e.g. "+101" + the localized
    page abbreviation (e.g. "o" for Hungarian "oldal")
  - **Time** — that day's own time spent, formatted the same way as
    KOReader's global *Duration format* setting (classic "0:23", modern
    "23'", or letters "23m")

**Controls:** tap to toggle between percentage/page view, tap the "This
chapter"/"Next chapter" row to toggle between reading time and pages left,
tap the "read today" / "avg time/day" row to toggle between time and page
counts, tap the "Pace" title to open the reading calendar, long-press to
force-reload data.

**Caching:** shares the same stale-while-revalidate approach as Reading insights — instant open with cached data, refreshed in the background.

## 😴 Sleep screen

Reading insights can replace KOReader's own sleep/lock screen with itself, so
the last thing you see before the device sleeps is your reading progress
instead of a generic cover or logo.

- **Enable it** from KOReader's own screen: *Settings → Screen → Sleep
  screen → Wallpaper → **Reading insights*** (a radio option alongside
  "Document cover", "Random image", "Leave screen as-is", etc.) — this is
  the same `screensaver_type` setting core uses for all of its own
  wallpaper choices, so it plays nicely with anything else that reads it.
- **Sleep-screen indicator** (*Settings → Advanced settings*, top entry):
  **None** (default) or **"(sleeping…)" after the title**, appended to the
  popup's title while it's shown as the sleep screen.
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
    - **Advanced settings** holds:
      - **Sleep-screen indicator** — None (default) or "(sleeping…)" after
        the title, appended while the popup is shown as the sleep screen
        (see [Sleep screen](#-sleep-screen) above)
      - **Bar chart height** — per-chart bar height (Reading insights: Last
        week / Months; Book progress: Chapters)
      - **Reading heatmap range** — how many months the calendar/time-of-
        day heatmap grids show at once: 3, 4, or 6
      - **Heatmap hour format** — 24-hour or 12-hour (AM/PM) labels for the
        time-of-day heatmap's hour columns
      - **Week start day** — Monday or Sunday, controls which day starts
        each row in both heatmap grids
      - **8-week chart order** — newest-first or oldest-first
      - **Show long durations (24h+) as days** — off by default; when on,
        any duration of 24h or more (yearly/streak totals, weekly
        averages, all-time totals, book progress) is shown as a day count
        with one decimal place (e.g. "1.2 days") instead of clock time
      - **Book calendar cell content** — Percent (default), Pages, or
        Time; controls what the per-book reading calendar's day cells show
        (see [Reading calendar](#-book-progress-stats) above)
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
    per-book reading calendar directly, without going through "Show Book
    progress" first.

## File layout

- `main.lua` — plugin entry point: loads the shared translation module and
  all three views, registers the four dispatcher actions, builds the Tools
  menu.
- `_meta.lua` — plugin identity for KOReader's plugin manager: name,
  description, and the version string the updater bumps on install.
- `about.lua` — the "About" dialog (Tools > Reading insights > About):
  title, installed version, description, and repo link.
- `l10n.lua` — shared translation lookup (`l10n/<lang>.po`) and locale-aware
  number formatting, used by both views.
- `colors.lua` — shared chart/text color settings (the "Colors" submenu)
  used by all three views, so there's a single place to configure every
  color.
- `colorwheelwidget.lua` — the touch color wheel dialog (hue/saturation
  wheel + brightness slider + live hex preview) used by the "Pick with
  color wheel" option in the Colors submenu.
- `fonts.lua` — shared font settings (the "Fonts" submenu) used by all
  three views, so there's a single place to configure every text role's
  font name and size.
- `insights_view.lua` — the full-screen "Reading insights" popup.
- `record_view.lua` — the floating "Records" popup (personal reading
  records and milestone progress).
- `stats_view.lua` — the compact "Reading statistics: overview" popup.
- `updater.lua` — the in-app updater (the "Updates" submenu): checks
  GitHub for new releases/branches and installs them on the device.
- `l10n/` — one `.po` file per language (`en.po`, `hu.po`, `de.po`), see

## Translations

`l10n/en.po` and `l10n/hu.po` hold the UI strings for all three popups
(month names, "Total read", streak labels, records labels, chapter/pace
labels, etc.) as plain `msgid`/`msgstr` pairs, e.g.:

```
msgid "Current streak"
msgstr "Aktuális sorozat"
```

To add another language, drop a new `l10n/<lang>.po` file next to the
existing ones — no code changes needed.


## Acknowledgements
- The statistics based on [(https://github.com/quanganhdo/koreader-user-patches)](https://github.com/quanganhdo/koreader-user-patches).
- Colorwheel comes from [(https://github.com/Euphoriyy/KOReader.patches#-colorwheelwidgetlua)](https://github.com/Euphoriyy/KOReader.patches#-colorwheelwidgetlua).
- In-plugin updater adapted from [(https://github.com/AndyHazz/bookshelf.koplugin)](https://github.com/AndyHazz/bookshelf.koplugin).

## License

AGPL-3.0 -- see [LICENSE](LICENSE)

## Support
[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/peterboda236)
