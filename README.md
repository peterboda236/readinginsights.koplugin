# Reading insights (KOReader plugin)

Converted from the original `2-reading-insights-popup.lua` **user patch**
into a proper KOReader **plugin**. Same feature set, same behaviour — just
packaged so it (a) shows up as a real menu entry instead of relying on a
gesture/shortcut, and (b) keeps its translated strings in plain `.po`
files instead of a Lua table.

## Install

1. Copy the whole `readinginsights.koplugin` folder into your KOReader
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

```
msgid "TOTAL READ"
msgstr "Összes olvasás"
```

To add another language, copy `l10n/en.po` to `l10n/<lang>.po` (use the
two-letter code KOReader uses for that language, e.g. `de.po`, `fr.po`)
and translate the `msgstr` lines. No code changes needed — the plugin
picks the file matching KOReader's current UI language automatically at
runtime, and falls back to the string itself (English) if a translation
is missing or the file doesn't exist.

Note: this is a small custom loader, not KOReader's central Weblate
translation pipeline — that only covers strings that live in
`koreader/l10n/`. Since this is a standalone plugin, `.po` files
shipped next to it are the closest equivalent without needing to touch
KOReader core.
