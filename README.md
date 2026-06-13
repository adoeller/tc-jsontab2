# JSON Tab WLX for Lazarus/FPC

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

The migration keeps the familiar workflow while adding editing, improved
sorting, and better performance for large arrays.

## Differences And Extensions Compared To The Original

This Lazarus/FPC version adds or substantially changes:

- Native Free Pascal implementation with a Lazarus project
- Inline scalar editing and saving
- Virtual owner-data grid for improved large-array handling
- Result-index-based filtering and sorting without rearranging JSON data
- Stable locale-aware natural sorting
- Filter transfer between compatible tree nodes using `Ctrl+Shift`
- Automatic bounded column sizing based on visible results
- Explicit current-cell display and alternating row colors
- Extended context menu and keyboard controls
- Win32 and Win64 release build modes from one project

## Features

- Tree navigation for objects, arrays, and scalar values
- Grid view for objects and arrays
- Formatted JSON text view with syntax highlighting
- Synchronization between selected grid cells and the text view
- Navigation from a double-clicked grid row to its tree element
- Per-column filters with substring, `=`, `!`, `<`, and `>` operators
- Optional filter preservation when changing tree nodes with `Ctrl+Shift`
- Stable natural sorting:
  - JSON numbers are sorted numerically
  - Embedded numbers are sorted naturally, so `20` appears before `100`
  - Text is sorted using Windows locale-aware comparison
- Virtual owner-data grid with a result index for large arrays
- Optional pixel-accurate decimal alignment per column, enabled by default
- Alternating row colors and distinct current-cell highlighting
- Automatically sized columns:
  - Measures the header and the first 1,000 visible rows
  - Uses the header width as the minimum
  - Limits the width to three times the header width
- Hide individual columns or restore all columns
- Copy cell, selected rows, column, JSONPath, or inferred JSON
- Search in grid and text views
- Light and dark themes
- Configurable colors for the grid, filters, selections, splitter, and JSON
  syntax elements
- UTF-8 and UTF-16 LE/BE detection
- Native Win32 user interface without the LCL runtime
- Win32 and Win64 WLX builds

## Editing

Press `Ctrl+R` or use **Edit mode** in the grid context menu to toggle editing.
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
| Toggle edit mode | `Ctrl+R` |
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
- Copy row(s)
- Copy column
- Copy as JSON
- Copy JSONPath
- Hide column
- Show all columns
- Filters
- Edit mode
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
- `max-column-width`: add a pixel limit to automatic multi-column sizing

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
