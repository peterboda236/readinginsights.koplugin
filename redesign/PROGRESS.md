# Reading insights page redesign — handoff

Started 2026-11-04, branch `update-insights-ui`. Steps 1-3 committed in e2688a7; steps 4-5 (2026-11-05) uncommitted.
This folder (`redesign/`) is temporary: delete it when the redesign is finished.
Line numbers below are from 2026-11-05 and drift — grep before citing them.

## Design source (the base for EVERYTHING)
- The mockup artifact is the design to follow: https://claude.ai/artifact/9uDiXhUKKhr1xr3PMgQB9q (read it with Artifact action "read").
  Local copy: redesign/mockup.html (open in a browser), the right-hand "Öneri" screen is the target.
- The user got upset twice when I deviated from the mockup ("neden artifact'daki gibi yapmadin", "you dont follow artifact version again"). Follow it exactly; if something can't be done, say so and ask before deviating.

## Rules the user set
- Cards is optional (author's request): default look = Classic, and Classic must not change at all vs. main.
- All data currently on the page must stay visible — only the look changes. User language: Turkish/English mix; answer short.
- No new color settings: reuse lib/colors.lua keys (activeBar/inactiveBar/separator/value/label/section…), defaults are gray.
- Performance matters (e-ink): cache-free but cheap widgets; Donut computes its pixel runs only on first paint.
- Not scrolling: when the page doesn't fit one screen it is split into PAGES (like the SimpleUI plugin): swipe up = next page, swipe down = previous page (on page 1 closes), footer "‹ 1 / 2 ›" with KOReader chevron icons. Left/right swipes stay for year/week.
- Sleep screen (readonly popup) can't page: keeps old behavior (one screen, bars down to AUTO_MIN=10, fonts shrink).
- Card inner padding stays Size.padding.default (lib/uikit.lua buildCard / cardInnerWidth). Asked about more side padding for the streak card; user decided to keep it as is (only-one-card padding would be inconsistent).
- Pen icon = "long-press edits" hint. User asked what it means → it is not self-explanatory. Open proposal (not yet answered): make the pen tappable (same action as long-press); for "Last 7 days" use "▾" instead (its long-press opens Last 7 days / Current week view picker, not edit).

## Done
Shared helpers in lib/uikit.lua:
- cards: cardBorder 449, cardInnerWidth 461, cardLayout 467 (layout for inside a full-width card, padding_h 0), buildCard 471 (rounded frame, separator color as gray), addCard 488 (adds top gap if first item, gap below).
- buildSegmented 498 (pill "Time | Pages" switch), icon 528 (plugin icons/<name>.svg via IconWidget), cardHeader 539 (icon + title + optional pen + optional right widget; NB never call row:getSize() before all children are inserted — HorizontalGroup caches offsets → crash), Dot 578 / buildDots 622, RoundBar 596 / buildRoundBar 617 (round-ended progress bar), buildStatCell 635 (value + "›" + label below + bold delta line).
- buildColumnSeparator / buildTwoColRow got optional `line_w` (thin divider).
- icons/: target.svg, calendar.svg, pen.svg (gray), flame.svg. KOReader has no calendar/target/flame/clock/trophy icons, so the plugin ships its own (mockup's line icons). main.lua passes PluginUtil to uikit.
lib/colors.lua: HatchBar + newHatchBar (diagonal stripes + outline) — today's bar in the weekly chart (views/insights_charts.lua:723).

Sections in views/insights_view.lua (buildInsightsSections):
1. Daily/Weekly goal (goalCard ~413): two cards side by side; header = target icon + title + pen; ring (widgets/donutwidget.lua, thickness 11%, % inside, ✓ when met) + big time + "of 00:30". Tap = goal streak, hold = edit goal. Setting "Daily / weekly goal ring" (lib/menu.lua, renamed from "goal bar") turns ring off → title + "done / goal". New string "of %1" (7 locales).
2. Last 7 days (~524-660): card; header = calendar icon + "Last 7 days" + pen + Time|Pages pill (tap toggles chart mode; hold header = week view picker). Stacked stat cells with "›" (tap = 8-week trend); delta "▲/▼ value vs prev. 7d" under each value (only if the vs-prev setting is on; replaced the old separate vs row). Old chart caption + showWeeklyChartModePicker removed. Calendar-week mode: nav header kept, switch on its own line above the chart.
3. Streaks (~676-767): one card; flame icon + "Streaks" + "›"; columns "Current" / "Best": "4 days · 7 weeks" (two lines if too wide); under Current 7 dots (last 7 days read, today right), under Best only the line "N days to beat your record" (N = best - current + 1). The current/best progress bar was removed on request (user found it unclear). RoundBar (lib/uikit.lua) is kept for step 5 (reading goal / achievements bars). Tap card = Streak.show. New strings "Streaks", "Current", "Best", "%1 day(s) to beat your record" (7 locales). Bottom padding added.
Pagination: sections mark their start with newBlock() (sections._breaks); _paginate 2804, _buildPageFooter 2859, _dropHiddenTargets 2894 (removes hold/swipe targets of the hidden page — they'd have 0,0 positions), _goToPage 2924; onSwipe north/south. _buildUI: fit loop min = AUTO_MIN_SCROLL (lib/insights_settings.lua:160, =60 points) for the open popup (2075); paginate when still too tall (2177); scroll + narrow layout only as a fallback when a single section is taller than the screen; ScrollableContainer ignore_events hold* and passes east/west + south-at-top swipes to the popup (2205).

4. Year card (views/insights_view.lua "One card: year header"): buildYearHeader (views/insights_headers.lua) now = chart icon + year + "›" in the centre (tap = year shelf), no header background, built for the card's inner layout; buildYearlyRow returns stacked stat cells (tap = books of the year); caption = UI.buildChip (lib/uikit.lua) "… per month ▾" (tap = mode picker, no ▾ when readonly); chart built with the card's inner layout; monthly_extra_px span inside the card. The whole card is one _year_swipe_targets entry (goal row still tracked separately). icons/chart.svg added.

5. Reading goal + Achievements (views/insights_view.lua "Reading goal and Achievements: two cards"): side by side (full width if only one is on), equal height. Goal: book icon + pen, "5 / 12 books finished", RoundBar, pace as UI.buildPill (existing strings: "▲ 2 books ahead of pace", "Goal reached", "On track", "N% of yearly goal"); tap = finished books, hold = finished-books menu; goal card is a _year_swipe_targets entry. Achievements: trophy + "›", "19 / 81 earned" + "★ new" pill (new string "new", 7 locales), RoundBar, "Latest: ☾ …" (existing "Latest: "); tap = achievements list. Own newBlock (before: goal row was in the year block). icons/book.svg, trophy.svg. Now unused: buildGoalYearLabel, msgid "Latest" -> step 7.

## Left to do (in this order, each like the mockup)
5. (done above) Reading goal + Achievements: two cards side by side; book icon + "Reading goal" + pen, "24 / 30 books finished", round progress bar, pace as filled pill ("▲ 2 ahead of pace"); trophy icon + "Achievements" + "›", "18 / 42 earned", "★ new" pill, round bar, "Latest: ☾ Night owl". Keep tap/hold actions (openFinished / showFinishedBooksMenu / editReadingGoal / openAchievementsList). Both are optional sections (VS.Opt.readShowReadingGoal / readShowAchievements).
6. All time: card, clock icon + "All time" + "›" (tap = heatmap), "reading time" | "pages read", tap values = all books.
7. Then: pen-as-button decision, remove now-unused helpers/strings if any, README (gestures, pages), commit when the user asks.
8. Look setting "Classic / Cards" (plugin author's request, 2026-11-05): menu option in Settings > Reading insights popup (lib/insights_settings.lua + lib/menu.lua), DEFAULT = Classic.
   Classic must be EXACTLY main's behaviour, nothing changed: old section builders, old year header, old chart captions/pickers, old scrolling (no pages, no footer), old fit loop, old strings/settings ("goal bar" name etc.). Take the old code from `git show main:<file>` and branch per section on the setting; Cards = everything from steps 1-6.
   Watch shared code changed by the redesign that Classic also goes through (buildYearHeader, buildTwoColRow line_w, weekly chart hatch, ScrollableContainer changes, _buildUI fit/paginate, menu rename) - each must behave like main when Classic.
9. One PR from update-insights-ui (or into a branch the author creates). PR description gets a short (~5 min) test checklist for both looks. Delete redesign/ before the PR.

## How to test
- KOReader emulator on this Mac: /Users/nijat/Documents/Projects/Others/koreader/koreader-emulator-arm64-apple-darwin25.6.0-debug/koreader (540x720). Plugin is a symlink to this repo; the user runs `make run`; KOReader must be fully restarted to load changes. The user sends screenshots.
- Syntax check: `$E/luajit -e "assert(loadfile('views/insights_view.lua'))"` with E = path above (lua5.1 is not installed, tests/run.sh can't run).
- KOReader sources for checking APIs: same emulator dir (frontend/, ffi/blitbuffer.lua).
- Translations: `python3 tools/check_po.py` — compare before/after, no new MISSING allowed. Every new string → add to all 7 locale/*.po.
- Long-press in the emulator was unreliable while the page scrolled; real device worked.
