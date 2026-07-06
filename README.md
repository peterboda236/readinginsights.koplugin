### 📊 Reading insights

<img width="384" height="512" alt="FileManager_2026-06-30_074746" src="https://github.com/user-attachments/assets/cf248698-75d0-4948-8d9c-70ea5c69fd5e" />

More screenshots

<img width="96" height="128" alt="FileManager_2026-07-02_083320" src="https://github.com/user-attachments/assets/8193ba8b-7f7e-4b35-9efb-81d0d4a1df8e" /><img width="96" height="128" alt="FileManager_2026-07-02_083306" src="https://github.com/user-attachments/assets/3026267b-d29d-4487-99a5-6efdcc4baa37" /><img width="96" height="128" alt="FileManager_2026-07-02_083257" src="https://github.com/user-attachments/assets/8a5857fb-f313-4d04-ab26-f604bdee7e52" />

This plugin bundles two reading-stats popups, powered by KOReader's
statistics database.

### Reading insights (full-screen history)

A full-screen scrollable overlay with a comprehensive overview of your reading history.

**Highlights:**
- **Today** — reading time and pages read so far today
- **Last week** — 7-day average time and pages per day; (tap a value to see an 8-week trend popup)
- **Streaks** — current and best daily & weekly reading streaks
- **Yearly view** — hours or days read + pages, navigable by year
- **Monthly chart** — bar chart of reading activity per month (tappable to see books)
- **All-time totals** — cumulative hours and pages across all years

**Controls:** swipe left/right to change year, tap bars to open book lists, tap the chart header to toggle hours/days mode, long-press to force-reload data.

**Caching:** uses a stale-while-revalidate strategy — the popup opens instantly with cached data while fresh values load in the background. The last known values are also mirrored to disk, so this still holds true for the very first popup open after a KOReader restart — no blocking "Loading data..." wait.

Available everywhere (book view and file manager).


**Controls:** tap to toggle between percentage/page view, long-press to force-reload data.

**Caching:** shares the same stale-while-revalidate approach as Reading insights — instant open with cached data, refreshed in the background.

---

### 📖 Book progress stats

<img width="384" height="512" alt="Reader_Az Elso Torveny vilaga 1  - Hidegen talalva - Abercrombie, Joe #p(878) epub_p1117_2026-07-06_084654" src="https://github.com/user-attachments/assets/555ab8c6-d9ce-4ebc-a6ac-cfdf097ec51d" />

A per-book overlay showing detailed progress and pace for the book you're currently reading, built on top of the same statistics database as Reading insights.

**Highlights:**
- **Progress** — pages/percentage read in the current book, plus pages remaining
- **Pace** — your average reading speed for this book (pages/hour or minutes/page)
- **Estimated finish** — projected time or date to finish, based on recent pace
- **Session stats** — time spent reading this book today and across recent sessions
- **Chapter breakdown** — progress and time spent per chapter (if chapter metadata is available)

**Controls:** tap on "This Book" opens statistics plugin book stat screen.

---

## Install

1. Unpack the latest zip and copy the `readinginsights.koplugin` folder into
   your KOReader `plugins/` directory.
2. Restart KOReader.
3. If you still have `2-reading-insights-popup.lua` and/or
   `2-reading-stats-popup.lua` in your `patches/` folder, **remove them** —
   running the patches alongside this plugin will double-register the same
   dispatcher actions.

## Where it shows up

- **Menu:** *Tools → Reading insights* — a submenu with "Show Reading
  insights", "Show Book progress" (book view only), and, below a
  separator, a **Settings** submenu holding the two options below plus a
  **Colors** submenu:
  - **Full-screen refresh on open/close** — toggle
  - **8-week chart order** — newest-first or oldest-first
  - **Colors** — pick your own hex color for every bar/line/label the two
    popups draw (active/inactive bars, the 8-week trend line, and the
    label/value/section/chart-label text colors); each one can be reset
    back to its black-on-gray default individually or all at once.
- **Gestures/shortcuts:** both popups are registered with `Dispatcher`, so
  they can be assigned under *Settings → Taps and gestures*:
  - `reading_insights_popup` — available everywhere (general action).
  - `reading_stats_popup` — book view only (reader action), matching the
    popup's requirement that a document be open.

## File layout

- `main.lua` — plugin entry point: loads the shared translation module and
  both views, registers the two dispatcher actions, builds the Tools menu.
- `l10n.lua` — shared translation lookup (`l10n/<lang>.po`) and locale-aware
  number formatting, used by both views.
- `colors.lua` — shared chart/text color settings (the "Colors" submenu)
  used by both views, so there's a single place to configure every
  color.
- `insights_view.lua` — the full-screen "Reading insights" popup.
- `stats_view.lua` — the compact "Reading statistics: overview" popup.

## Translations

`l10n/en.po` and `l10n/hu.po` hold the UI strings for both popups (month
names, "Total read", streak labels, chapter/pace labels, etc.) as plain
`msgid`/`msgstr` pairs, e.g.:

```
msgid "Current streak"
msgstr "Aktuális sorozat"
```

To add another language, drop a new `l10n/<lang>.po` file next to the
existing ones — no code changes needed.
