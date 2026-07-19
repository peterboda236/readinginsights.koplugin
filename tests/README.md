# Tests

Everything here runs on a development machine with **lua5.1 and luac5.1**
installed — no KOReader, no device, no network.

```sh
./tests/run.sh
```

Exit status is 0 only if everything passed.

| file | what it covers |
| --- | --- |
| `static_checks.lua` | Parses every source file and checks the whole tree: accidental globals, unused `require`s, `popup:method()` calls that no longer resolve, module surfaces (every `Mod.name` used is one the module defines), translation coverage against each `.po`, and formatting. |
| `test_modules.lua` | `lib/prefs`, `lib/insights_settings`, `lib/insights_cache`, `lib/statsdb`: setting defaults and round-trips, per-minute/per-day caching with its stale mirror, the reading-goal state's disk round-trip, the shared-connection wrappers. |
| `test_chapterinfo.lua` | `lib/chapterinfo`: both TOC shapes, depth filtering, `toc_ticks` fallback, unusable TOCs, the per-book cache and its invalidation, pages-left fallbacks. |
| `test_daybounds.lua` | The local-midnight arithmetic used by the range-filtered queries: the 23- and 25-hour DST days, month/year boundaries, a leap day. Run under `TZ=Europe/Budapest` so a DST-observing zone is actually exercised. |
| `test_records.lua` | `lib/records_data`: the milestone ladder's edges, the record queries, streak boundaries, empty history, and the DB fingerprint choosing between cache and full recompute. |
| `test_wiring.lua` | Loads every module the way `main.lua` does, with KOReader's UI stubbed, and checks the wiring: no module receives nil where it expects another, every export exists under the name its caller uses. |

## What this does not cover

Anything that draws. Every file under `views/` builds widgets, and widgets
need a real KOReader to lay out, paint and receive gestures. Two of the bugs
found during the refactor were of exactly that kind — a query called as a
popup method after it had moved into a module — which is why
`static_checks.lua` now looks for that pattern specifically. It is a
substitute for, not a replacement of, opening each popup on a device before
a release.

## Adding a test

`test_*.lua` files are plain Lua scripts run from the plugin root. Stub
whatever KOReader modules the code under test requires (see the top of
`test_wiring.lua` for the catch-all pattern), then `assert` — a failed
assertion is a failed run. Add the new file to `run.sh`.

## Releases

The release zip shouldn't carry the tests onto people's readers:

```sh
zip -r readinginsights.koplugin.zip readinginsights.koplugin -x '*/tests/*' -x '*/.git/*'
```
