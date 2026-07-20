# winnow

**winnow:** _verb_ — to separate the good from the chaff

Fast photo viewer for culling. Compare multiple photos side-by-side
with synchronized zoom and pan. Rate, filter, and quickly separate keepers
from rejects. Built for batch culling JPEGs without the weight of a full DAM.

```
winnow /path/to/photos
```

State is entirely in-memory and ephemeral: no config files, no thumbnail
cache, nothing persisted between runs. Deletion is two-phase — mark in-app
(undoable), confirm and delete on quit — so a stray keystroke can't lose a
whole cull pass.

Linux and macOS, JPEG only. A few hundred photos per directory is the sweet
spot; comparisons top out around 5 photos before things degrade.

## Keys

The whole cull loop is keyboard-driven. The status bar shows the keys for
the current context; press `?` in the app for the full map.

| Key               | Action                                                                                     |
| ----------------- | ------------------------------------------------------------------------------------------ |
| h / l (or arrows) | previous / next photo                                                                      |
| Space             | mark keeper and advance                                                                    |
| x                 | mark delete and advance                                                                    |
| c                 | clear mark                                                                                 |
| u / Ctrl+r        | undo / redo a mark                                                                         |
| v                 | visual mode: h/l grow a comparison span, Space/x/c mark it all, Enter commits, Esc cancels |
| h/l/j/k, 1-9      | move or jump the focus ring in a comparison                                                |
| Esc               | leave comparison for the focused photo                                                     |
| gg / G            | first / last photo                                                                         |
| tu / tk / td      | toggle unmarked / keepers / deletes in the strip                                           |
| - / = / 0 / f     | zoom out / in / 100% / fit                                                                 |
| Shift+h/j/k/l     | pan the view                                                                               |
| Ctrl+h/j/k/l      | nudge the focused tile to align a mismatched shot                                          |
| Ctrl+0            | reset the focused tile's alignment                                                         |
| ?                 | key map overlay                                                                            |
| q                 | quit (confirms when marks exist)                                                           |

Selecting one photo shows the single-image view; selecting 2+ switches to
an automatic comparison grid with synchronized zoom/pan. Marking a
comparison tile as delete drops it from the grid; the last tile standing
collapses back to single view.

## Non-goals

Persistent state, thumbnail caching to disk, RAW support, editing,
metadata beyond keeper/delete, catalogs, export, cloud sync, video,
printing. This is a culling tool, not a DAM.

## Structure

`src/winnow/core/` is the headless logic (scanner, session state,
thumbnailer, LRU image cache, undo stack) — no Qt imports, unit-tested on
its own. `src/winnow/ui/` is the Qt/PySide6 layer (main window, thumbnail
strip, viewing area, image widget, keyboard controller) that drives it.

Thumbnailing and full-resolution decode both run on `QThreadPool` worker
threads, off the UI thread, to keep navigation responsive.

## Development

```
nix develop .#winnow
pytest          # unit + pytest-qt UI tests, runs headless via QT_QPA_PLATFORM=offscreen
ruff check .
ruff format .
```

This is a personal project. Contributions and feedback are welcome, but
the scope is intentionally focused on my own workflow and needs.
