# JSON Tab WLX for Lazarus/FPC

![grid](json_grid.png)![text](json_text.png)

JSON Tab WLX is a native Windows Lister plugin for
[Total Commander](https://www.ghisler.com/) that displays JSON documents as a
combined tree, table, and formatted text view.

Both regular JSON documents (`.json`) and JSON Lines documents (`.jsonl`) are
supported. JSONL records are shown as the elements of one root array and are
saved back as one compact JSON value per line.

This project is a Lazarus/Free Pascal migration of the original
[jsontab-wlx](https://github.com/little-brother/jsontab-wlx) plugin by
little-brother. The original program established the user interface, behavior,
and core feature set on which this port is based.

The migration keeps the familiar workflow and turns it into a faster, more
interactive JSON workbench for Total Commander.

## Feature Highlights

JSON Tab WLX is built for the moment when a JSON file is too structured for a
plain text viewer, but too quick-and-dirty for a full editor. Open it in
Lister, jump through the tree, flatten useful structures into columns, filter
the result, edit a scalar value, copy exactly what you need, and move on.

- **Tree, table, and text at once**: browse objects and arrays in the tree,
  inspect rows in the grid, and switch to syntax-highlighted formatted JSON
  when the raw structure matters.
- **JSONL feels like normal JSON**: `.jsonl` files are shown as one root array,
  while saving keeps the compact one-record-per-line format.
- **Flat views for nested data**: `FlatViewLevel` can unfold uniform nested
  objects and arrays into practical columns such as `message`,
  `meta.message`, or `modulation_params.audio_freq`. The status bar shows the
  active level, and `Flat: 1*` tells you when flattening is really in effect.
- **Filters that stay usable**: every column can be filtered with substring
  matching or operators like `=`, `!`, `<`, and `>`. The filter row follows
  horizontal scrolling and column resizing smoothly, so it keeps feeling like
  part of the grid.
- **Sorting that understands data**: JSON numbers sort numerically, embedded
  numbers sort naturally, and text sorting uses Windows locale-aware
  comparison. A third click restores the original order.
- **Readable numbers, even in proportional fonts**: decimal alignment is
  enabled by default. Decimal separators line up per column, and integers sit
  correctly at the same numeric anchor.
- **Fast on large arrays**: the grid is virtual and keeps filtering/sorting in
  a result index instead of rearranging the JSON data itself.
- **Inline editing when you need it**: toggle edit mode with `Ctrl+E`, edit
  scalar cells directly, insert structurally matching rows, delete rows or
  columns, and save back with `Ctrl+S`.
- **Keyboard-friendly grid work**: arrow keys move the current cell, scrolling
  the view at the edges; `Ctrl+Arrow` jumps to the first or last row/column.
- **Useful right-click tools**: copy cells, rows, columns, JSONPath, or inferred
  JSON; hide columns; restore all columns; select the corresponding tree item.
- **Comfort details**: automatic column sizing, alternating row colors,
  current-cell highlighting, light/dark themes, configurable colors, UTF-8 and
  UTF-16 detection, plus native Win32 and Win64 WLX builds without the LCL
  runtime.

## Editing

Press `Ctrl+E` or use **Edit mode** in the grid context menu to toggle editing.
While edit mode is active, double-clicking a scalar cell opens an inline
editor.

- `Enter` or focus loss accepts an edit
- `Escape` cancels the active edit
- `Ctrl+S` saves modified JSON back to the source file
- Unsaved changes are marked in the status bar
- The detected source-file encoding is retained when saving
- Floating-point JSON values with a zero fractional part retain their decimal
  form, for example `10000000.0`

Arrays and objects remain read-only as cells; edit their scalar descendants
instead.

## Keyboard And Mouse

| Action | Shortcut |
| --- | --- |
| Toggle edit mode | `Ctrl+E` |
| Save changes | `Ctrl+S` |
| Sort current column | `Ctrl+0` |
| Sort visible column 1 through 9 | `Ctrl+1` through `Ctrl+9` |
| Show all columns | `Ctrl+Space` |
| Preserve matching filters during tree navigation | Hold `Ctrl+Shift` |
| Change the current grid column | `Left` / `Right` |
| Open a URL from the current cell | `Alt+Click` |
| Change font size | `Ctrl+Mouse wheel` |

Additional Total Commander Lister keys are forwarded to the host where
supported.

## Context Menu

Right-click the grid to access:

- Copy
- Copy row(s) (`Shift+C`)
- Copy column (`Ctrl+C`)
- Copy as JSON
- Copy JSONPath
- Hide column
- Show all columns (`Ctrl+Space`)
- Filters
- Edit mode (`Ctrl+E`)
- Dark theme

## Installation

Use the build matching your Total Commander installation:

- `jsontab.wlx64` for 64-bit Total Commander
- `jsontab.wlx` for 32-bit Total Commander

Install the file as a Total Commander Lister plugin through:

`Configuration` > `Options` > `Plugins` > `Lister plugins`

The default detection string handles files with the `.json` and `.jsonl`
extensions.

## Building

Requirements:

- Lazarus with Free Pascal 3.2.2 or compatible
- Windows target support for Win32 and/or Win64

Open `jsontab.lpi` in Lazarus and select one of the supplied build modes:

- `Release 64`, producing `jsontab.wlx64`
- `Release 32`, producing `jsontab.wlx`

Command-line builds:

```powershell
lazbuild jsontab.lpi --build-mode="Release 64"
lazbuild jsontab.lpi --build-mode="Release 32"
```

## Configuration

If an INI file exists beside the WLX plugin, it takes precedence over the
default plugin INI path supplied by Total Commander. Otherwise, the supplied
path is used. If Total Commander supplies no path, the INI beside the plugin is
used and created when settings are written.

Inline comments are supported when separated from the value by whitespace:

```ini
font-size=16 ; use a larger font
```
Settings belong in the `[jsontab]` section.

The plugin stores the selected tab, splitter position, filter-row visibility,
font size, and dark-theme state. It also supports configuration values inherited
from the original plugin, including colors, filter behavior, font settings,
missing-value text, parsing limits, and the detection string.

Original layout and interaction settings are supported as well:

- `copy-column`: copy the current column with plain `C` when multiple rows are
  selected
- `decimal-align`: align decimal values with `,` or `.` at their decimal
  separator and right-align signed or unsigned integers (`0`/`1`, default `1`).
  In columns containing both integers and decimals, integers end directly at
  the shared decimal anchor.
- `disable-grid-lines`: hide grid lines
- `filter-align`: align filter text left (`-1`), centered (`0`), or right (`1`)
- `font-weight`: select a font weight from `0` through `9`
- `max-column-width`: limit automatic multi-column sizing; in two-column grids only the first column is capped, while the second uses its full measured header/content width

Decimal alignment measures the integer part using the active grid font, so it
also works with proportional fonts. Non-numeric values and values containing
multiple decimal separators retain their normal display.

## Tests

- `tests/decimal_align_test.lpr` verifies decimal and integer recognition.
- `tests/jsonl_model_test.lpr` verifies JSONL loading and saving.
- `tests/wlx_viewer_test.lpr` loads the compiled WLX and exercises decimal
  owner-draw after filtering, sorting, font zoom, editing, and structural tree
  changes.

## Original Project

Original jsontab-WLX project:
[github.com/little-brother/jsontab-wlx](https://github.com/little-brother/jsontab-wlx)

Please refer to the original repository for its history, documentation, issue
tracker, and releases.
