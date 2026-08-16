### 📊 Reading insights plugin

<img width="255" height="340" alt="FileManager_2026-07-27_074128" src="https://github.com/user-attachments/assets/c12e7ab1-e3a9-4611-be17-0539527b6efc" />
<img width="255" height="340" alt="FileManager_2026-07-17_152344" src="https://github.com/user-attachments/assets/4a3d2fb9-cc51-4342-a952-36f23bb1925c" />
<img width="255" height="340" alt="Reader book progress" src="https://github.com/user-attachments/assets/555ab8c6-d9ce-4ebc-a6ac-cfdf097ec51d" />
<br/><br/>
<img width="255" height="340" alt="Reader chapter view" src="https://github.com/user-attachments/assets/371b3119-119a-4ccb-9660-a63879996c48" />
<img width="255" height="340" alt="FileManager_2026-07-17_152315" src="https://github.com/user-attachments/assets/ea6711c7-7c18-4bb5-a15c-871cc0b74888" />
<img width="255" height="340" alt="FileManager_2026-07-27_074133" src="https://github.com/user-attachments/assets/de2d7a78-a657-40cf-8628-f0787a827147" />

More screenshots

<img width="192" height="256" alt="Book progress popup" src="https://github.com/user-attachments/assets/52f851b7-8955-4739-b3a7-96ff8c2cbfe6" />
<img width="192" height="256" alt="FileManager_2026-07-18_211837" src="https://github.com/user-attachments/assets/e4e5d617-98c6-40bc-8844-f23fa5837e95" />
<img width="192" height="256" alt="FileManager_2026-07-02_083320" src="https://github.com/user-attachments/assets/8193ba8b-7f7e-4b35-9efb-81d0d4a1df8e" />
<img width="192" height="256" alt="FileManager_2026-07-17_152332" src="https://github.com/user-attachments/assets/21b311a8-bb10-4ffe-b7f0-3e91b19bb281" />

A set of reading-stats popups powered by KOReader's own statistics database.
Nothing to configure to get started — install it, and your reading history is
there. Four popups, all reachable from *Tools → Reading insights*:

## 📊 Reading insights

A full-screen overview of your whole reading history.

- **Last week** — average time and pages per day; tap either to see its 8-week trend.
- **Streaks** — current and best daily & weekly streaks; tap any of them (or
  see the separate [Reading streak](#-reading-streak) popup below).
- **Yearly & monthly** — hours/days read and pages, navigable by year; a
  monthly bar chart you can tap to see the books behind each month.
- **All-time totals** — cumulative hours and pages. Tap the "Total read"
  header for a GitHub-style **heatmap** and a **time-of-day** breakdown of when
  you read (shown as a bar chart or an hour × weekday grid).
- **Reading goal** — this year's finished books over your target (e.g. 18/30),
  next to how many **achievements** you've earned. Tap to see the finished
  books; long-press to mark books finished, add books you read elsewhere, or
  change the goal. A book counts as finished once its last reading entry
  reaches 99% of the book.

**Controls:** swipe to change year, tap headers/bars to drill in, long-press
the title bar to force a data reload.

Available everywhere (book view and file manager).

## 🔥 Reading streak

Your current and best daily & weekly streaks in one popup, openable straight
from *Tools → Reading insights → Show Reading streak* (or by tapping a streak
in the Reading insights popup).

- A **calendar** of your reading with the streaks marked — page back through
  your whole history to your very first reading day.
- **Current** and **best** streak side by side, each with its date range and
  days | weeks.

The calendar's colours (daily-streak days and weekly-streak gap days) and its
week-start day (Monday or Sunday) are configurable in Settings. Available
everywhere.

## 🏆 Records

A compact card with your personal records and milestone progress:

- **Most reading time in a day** and **most pages in a day**, each with the date
- **Best daily streak**, with its start–end dates
- **Last** and **next total-hours milestone**, with hours left to the next

Milestone ladder (total hours): 1 → 5 → 10 → 25 → 50 → 100 → 250 → 500 →
1000 → 2500 → 5000 → 10000.

Tap / swipe / press any key to close. Available everywhere.

## 🏅 Achievements

Over 80 all-time achievements you unlock as you read — across books finished,
reading time, pages, streaks, single-day feats, time of day, pace and variety.
A few examples:

- **First book** — finish your first book
- **100 hours** — read for 100 hours in total
- **Weekly streak** — read on 7 days in a row
- **Night owl** — read between midnight and 4 a.m.

Open the list from the Reading goal cell, or via *Tools → Reading insights →
Show Achievements*. Newly earned ones are marked with a **★** until you open
the list. Once unlocked, an achievement is never lost. Available everywhere.

## 📖 Book progress

A per-book overlay for the book you're currently reading:

- **Progress** — pages/percentage read, plus pages remaining
- **Pace** — your average reading speed for this book
- **Estimated finish** — projected time or date to finish, based on recent pace
- **Today / averages** — time and pages read today and your daily average
- **This / next chapter** — estimated reading time (or pages) left
- **Chapter breakdown** — progress and time per chapter, when available

Many rows toggle between time/pages or percent/page on tap. Tap the "Pace"
title to open the **Book progress calendar** — a month grid coloured like a
heatmap, showing your progress each day plus the start and estimated finish
dates. Book view only.

## 😴 Sleep screen

Reading insights can replace KOReader's sleep/lock screen with itself, so the
last thing you see before the device sleeps is your reading progress. Enable it
from *Settings → Screen → Sleep screen → Wallpaper → Reading insights*.

## 🔄 Updates

*Tools → Reading insights → Updates* checks GitHub for new releases and installs
them directly on the device — no computer or SSH needed. It can also notify you
on wake when an update is available, and (for testers) track a specific
development branch.

## Install

1. Unpack the latest zip and copy the `readinginsights.koplugin` folder into
   your KOReader `plugins/` directory.
2. Restart KOReader.
3. If you still have `2-reading-insights-popup.lua` or
   `2-reading-stats-popup.lua` in your `patches/` folder, **remove them** —
   they double-register the same actions.

Future updates can be installed in-app — see [Updates](#-updates) above.

## Uninstalling

Delete the plugin from KOReader's *Plugin management*. Ticking **"Also delete
plugin settings"** makes the plugin clean up after itself (its cache/store
files and every setting it wrote, including the sleep-screen choice). Leaving it
unticked keeps everything, so a later reinstall picks up where you left off.

## Settings

*Tools → Reading insights → Settings* lets you customise:

- **Colors** — a hex colour (or a touch colour wheel) for every bar, line and
  label the popups draw.
- **Fonts** — your own font and size for each text role.
- **Advanced settings** — chart heights, date/time and week-start formats,
  which sections the insights popup shows, the heatmap range, achievement
  refresh frequency, and the Book progress calendar's cell content.

The popups are also registered with `Dispatcher`, so you can assign them to
gestures under *Settings → Taps and gestures*.

## For developers

- **Tests:** `./tests/run.sh` (needs `lua5.1` and `luac5.1`). The `lib/`
  modules are plain computation over the statistics DB, so they run outside
  KOReader; drawing under `views/` needs a real device. See `tests/README.md`.
- **Translations:** UI strings live in `locale/<lang>.po` (English, Hungarian,
  German, Portuguese, Simplified Chinese). Add a language by dropping in a new
  `locale/<lang>.po` — no code changes needed. Missing strings fall back to the
  English original.

## Acknowledgements
- Statistics based on [quanganhdo/koreader-user-patches](https://github.com/quanganhdo/koreader-user-patches).
- Colorwheel from [Euphoriyy/KOReader.patches](https://github.com/Euphoriyy/KOReader.patches#-colorwheelwidgetlua).
- In-plugin updater and settings cleanup adapted from [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin).

## License

AGPL-3.0 — see [LICENSE](LICENSE)

## Support
[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/peterboda236)
