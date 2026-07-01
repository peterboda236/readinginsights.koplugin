### 📊 Reading Insights

<img width="384" height="512" alt="FileManager_2026-06-30_074746" src="https://github.com/user-attachments/assets/cf248698-75d0-4948-8d9c-70ea5c69fd5e" />

A full-screen scrollable overlay with a comprehensive overview of your reading history, powered by KOReader's statistics database.

**Highlights:**
- **Today** — reading time and pages read so far today
- **Last week** — 7-day average time and pages per day; (tap a value to see an 8-week trend popup)
- **Streaks** — current and best daily & weekly reading streaks
- **Yearly view** — hours or days read + pages, navigable by year
- **Monthly chart** — bar chart of reading activity per month (tappable to see books)
- **All-time totals** — cumulative hours and pages across all years

**Controls:** swipe left/right to change year, tap bars to open book lists, tap the chart header to toggle hours/days mode, long-press to force-reload data.

**Caching:** uses a stale-while-revalidate strategy — the popup opens instantly with cached data while fresh values load in the background.

## Install

1. Copy the whole Unpack the latest zip and copy the `readinginsights.koplugin` folder into your KOReader
   `plugins/` directory, so you end up with:
2. Restart KOReader.
3. If you still have `2-reading-insights-popup.lua` in your `patches/`
   folder, **remove it** — running both at once will double-register the
   `ShowReadingInsightsPopup` dispatcher action.

## Where it shows up

- **Menu:** *Tools → Reading insights* — 
- **Gestures/shortcuts:** still available as before, via
  *Settings → Taps and gestures → Reading insights* (it's registered
  with `Dispatcher` under the internal name `reading_insights_popup`,
  same as the original patch).

## Translations

`l10n/en.po` and `l10n/hu.po` hold the ~80 short UI strings (month
names, "Total read", streak labels, etc.) as plain `msgid`/`msgstr`
pairs, e.g.:
