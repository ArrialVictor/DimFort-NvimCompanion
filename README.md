# DimFort — Neovim companion

![preview](social_preview.png)

[![CI](https://github.com/ArrialVictor/DimFort-NvimCompanion/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/ArrialVictor/DimFort-NvimCompanion/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/ArrialVictor/DimFort-NvimCompanion/blob/main/LICENSE)

Neovim companion for [DimFort](https://github.com/ArrialVictor/DimFort) —
the dimensional-homogeneity checker for Fortran. Thin LSP client +
user commands; the heavy lifting is done by the `dimfort lsp` server.

Want a hands-on look first? See the [DimFort tour](https://github.com/ArrialVictor/DimFort/blob/main/demos/README.md) —
a short, self-contained Fortran file that exercises the most common
diagnostics, with a line-by-line walkthrough.

> **Neovim-only.** The plugin uses Neovim's built-in `vim.lsp.*` Lua
> APIs, which classic Vim doesn't share. Classic Vim users can still
> talk to `dimfort lsp` via a third-party LSP client like
> [`vim-lsp`](https://github.com/prabirshrestha/vim-lsp) or
> [`coc.nvim`](https://github.com/neoclide/coc.nvim) — the server is
> editor-agnostic — but the per-feature toggle commands and inlay
> rendering polish below are Neovim-only.

## Requirements

- Neovim ≥ 0.11 (uses `vim.lsp.start` and `vim.fs.find`).
- DimFort installed and `dimfort lsp` reachable from `$PATH` (or pass
  an absolute path via the `executable` option). Install instructions:
  https://github.com/ArrialVictor/DimFort.

## Installation

### lazy.nvim

```lua
{
  "ArrialVictor/DimFort-NvimCompanion",
  ft = "fortran",
  opts = {
    -- Override the executable if `dimfort` isn't on $PATH.
    -- executable = "/path/to/.venv/bin/dimfort",
  },
}
```

### packer.nvim

```lua
use {
  "ArrialVictor/DimFort-NvimCompanion",
  ft = "fortran",
  config = function()
    require("dimfort").setup({})
  end,
}
```

### Manual

Clone into your `runtimepath`:

```bash
git clone https://github.com/ArrialVictor/DimFort-NvimCompanion.git \
  ~/.local/share/nvim/site/pack/dimfort/start/DimFort-NvimCompanion
```

Then add to your `init.lua`:

```lua
require("dimfort").setup({})
```

## Configuration

All options shown with their defaults:

```lua
require("dimfort").setup({
  executable = "dimfort",                       -- path to the dimfort binary

  -- Feature toggles. Each maps to a server initializationOption.
  -- Default stance: the side panel and a short hover are the unit
  -- surfaces, so inlay hints are OFF (redundant beside them).
  inlay_hints_enabled = false,
  completion_enabled = true,
  code_actions_enabled = true,
  goto_definition_enabled = true,

  -- Hover verbosity. "short" = compact `name : unit` (the default);
  -- "detailed" = full unit-algebra tree; "disabled" = no hover. The
  -- panel is unaffected.
  -- See https://github.com/ArrialVictor/DimFort/blob/main/docs/editor-integration/hover-ui.md
  hover = "short",                              -- "disabled" | "short" | "detailed"

  -- Scale/magnitude checking (S001 multiplicative, S002 affine-offset).
  -- "auto" defers to the project dimfort.toml [scale] enabled;
  -- "on"/"off" override it. Cycle with :DimFortCycleScale.
  scale_mode = "auto",                          -- "auto" | "on" | "off"

  -- Content-hash cache (https://github.com/ArrialVictor/DimFort/blob/main/docs/usage.md#content-hash-cache).
  cache_mode = "read-write",                    -- "off" | "read-only" | "read-write"
  cache_dir  = "",                              -- "" = .dimfort-cache/ under workspace root

  -- Side panel (on by default; :DimFortTogglePanel to close).
  panel_enabled        = true,
  -- Per-section visibility (0.2.6). Toggle in-session with
  -- :DimFortToggleCursor / -Scope / -Imports; set defaults here for
  -- cross-session persistence.
  panel_show_cursor    = true,                  -- Expression / Diagnostics / Interactions / Actions
  panel_show_scope     = true,
  panel_show_imports   = true,
  panel_position       = "right",               -- "right" | "left" | "bottom"
  panel_width_fraction = 0.35,                  -- fraction of editor width
  panel_width_cols     = nil,                   -- explicit cols; wins over fraction
  panel_debounce_ms    = 200,                   -- cursor-follow debounce

  -- Workspace plumbing.
  max_workset_size = 40,                        -- cap on workset size
  external_modules = {},                        -- modules treated as known-out-of-workset
  filetypes        = { "fortran" },             -- buffers DimFort attaches to
  root_markers     = { "dimfort.toml" },        -- `.git` removed in 0.2.7; pass `{ "dimfort.toml", ".git" }` to restore
  auto_attach      = true,                      -- attach via FileType autocmd
})
```

If `auto_attach = false`, call `require("dimfort").attach()` manually
from your own autocommand or keymap.

## Commands

| Command                                  | Effect                                                              |
|------------------------------------------|---------------------------------------------------------------------|
| `:DimFortCheckWorkspace`                 | Run the workspace-wide unit check; also refreshes the panel footer's `Project:` segment. |
| `:DimFortRestart`                        | Restart the language server.                                        |
| `:DimFortStatus`                         | Print current feature toggles and client id.                        |
| `:DimFortToggleInlayHints`               | Toggle inlay hints; restarts the server.                            |
| `:DimFortToggleCompletion`               | Toggle unit-name completion; restarts the server.                   |
| `:DimFortToggleCodeActions`              | Toggle code actions; restarts the server.                           |
| `:DimFortToggleGotoDefinition`           | Toggle go-to-definition; restarts the server.                       |
| `:DimFortCycleHover`                     | Cycle hover verbosity (disabled → short → detailed); restarts.      |
| `:DimFortCycleCache`                     | Cycle content-hash cache through `off` → `read-only` → `read-write`. |
| `:DimFortClearCache`                     | Delete the `.dimfort-cache/` directory and restart the server.       |
| `:DimFortOpenConfig`                     | Quick-pick between `dimfort.toml` (workspace config) and the project units file. Each opens if it exists, or creates a commented stub if not. When creating a units file: sub-pick `Empty file` or `Reference template (bundled defaults, all commented out)`. Auto-wires `[units].file = "units.toml"` into `dimfort.toml`. |
| `:DimFortCycleScale`                     | Cycle scale checking (`auto` → `on` → `off`); `auto` defers to `dimfort.toml`. |
| `:DimFortCycleCoverage`                  | Cycle coverage visualisation (`disabled` → `gutter` → `background`); companion-only (no LSP restart). |
| `:DimFortTogglePanel`                    | Open / close the side panel.                                        |
| `:DimFortToggleCursor`                   | Show / hide the Cursor section (Expression / Diagnostics / Interactions / Actions). |
| `:DimFortToggleScope`                    | Show / hide the Scope section.                                       |
| `:DimFortToggleImports`                  | Show / hide the Imports section.                                     |
| `:DimFortPanelRefresh`                   | Force a panel refresh (debugging).                                  |
| `:DimFortScopeFilter [query]`            | Filter the panel's Scope section by name/unit (no argument clears). |
| `:DimFortImportsFilter [query]`          | Filter the panel's Imports section by name/unit/module (no argument clears). |
| `:DimFortCycleSortMode`                  | Cycle the panel sort mode shared by Scope and Imports (`line` → `alphabetic` → `status`). |
| `:DimFortCycleUnitDisplay`               | Cycle the unit-display mode shared by Scope and Imports (`input` → `canonical` → `both`). |
| `:DimFortCoverageReport`                 | Open a floating window with the per-tier coverage breakdown (Verified / Unverified / Violation / Unparsed, for both file and project scope). Press `q` or `<Esc>` to close. |

## Side panel

A cursor-following split rendering the six DimFort sections —
Expression, Diagnostics, Interactions, Actions, Scope, Imports.
The full description of what each section shows is the canonical
[side-panel reference](https://github.com/ArrialVictor/DimFort/blob/main/docs/editor-integration/side-panel.md);
the controls below are the Neovim-specific bits.

**Toggle**: open by default on attach. `:DimFortTogglePanel` opens
or closes the persistent split (right by default).

**Settings**:

- `panel_enabled` — set to `false` to keep the panel closed on
  attach.
- `panel_width_cols` / `panel_width_fraction` — fix the panel
  width (the source window absorbs resize).

**Filters**:

- `:DimFortScopeFilter <query>` — narrow the Scope section to
  variables whose name or unit matches.
- `:DimFortImportsFilter <query>` — same for Imports.

**Navigation**: press `<CR>` on any declaration, diagnostic,
interaction-site, or import row to jump to it (cross-file for
interaction sites and imports).

**Coverage bar**: a footer below the sections shows the active file's
coverage percentage and tier counts on the left, and the
whole-workspace aggregate on the right —
`File: 78% (🟡 18 🔴 2)   Project: 12.9% (🟡 N 🔴 M)`. File-scope updates
live; workspace-scope is populated when you run
`:DimFortCheckWorkspace`. Pre-refresh the bar shows `Project: –`; during a
refresh it shows a Braille spinner; once any file's diagnostics change
the Project numbers dim to signal they may no longer reflect current state.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-nvim-hero_dark.png">
  <img width="640" src="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-nvim-hero_light.png" alt="DimFort side panel in Neovim — the unit-algebra tree for q = 0.5 * rho * v * v with the stacked module/function scope below">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-nvim-mismatch_dark.png">
  <img width="640" src="https://raw.githubusercontent.com/ArrialVictor/DimFort/main/docs/img/panel-nvim-mismatch_light.png" alt="DimFort side panel in Neovim — a kg ≠ m homogeneity violation, the assignment root marked red">
</picture>

## What you get

Same surface as the VSCode companion:

- Diagnostics (H001–H004, U001/U002/U005–U007/U010, …) per file in the
  loclist / quickfix / `vim.diagnostic` panel.
- Hover (`K`) for variable units.
- Inlay hints, go-to-definition, completion, code actions (toggleable).
- The cursor-following **side panel** above.
- Workspace-wide cross-file checks driven from `use` clauses.
- **Coverage visualisation** (requires DimFort 0.2.4+) — per-line
  status in one of two mutually-exclusive visual encodings:
  - **Gutter** — coloured dot in the sign column. By default DimFort
    paints **green** (verified) and **blue** (unparsed) dots only;
    yellow and red lines are flagged by `vim.diagnostic`'s native
    `W` / `E` gutter signs, which carry the same signal without
    competing for the sign-column slot. Override via
    `require("dimfort.coverage").config.gutter_tiers = { "green",
    "yellow", "red", "blue" }` if you run with
    `vim.diagnostic.config({ signs = false })`.
  - **Background** — line tint behind the text in all four tiers
    (green / yellow / red / blue). The tint sits in a different
    visual region from the gutter, so it doesn't compete with the
    diagnostic signs.

  Off by default; toggle with `:DimFortCycleCoverage`. Customise the
  colours via the highlight groups `DimFortCoverGreen` /
  `DimFortCoverYellow` / `DimFortCoverRed` / `DimFortCoverBlue` (for
  the gutter dots) and `DimFortCoverBg*` (for the line tint). The
  background-tint hexes are **theme-aware**: the layer picks dark
  shades when `vim.o.background == "dark"` and pre-lightened
  shades when `light`, refreshing automatically on every
  `ColorScheme` change or `:set background=light/dark` flip.

  **Terminal note**: the coverage layer uses truecolor hex colours
  with 256-colour `cterm` fallbacks. On MacOS Terminal (which doesn't
  reliably advertise 24-bit truecolor) the fallbacks may produce
  approximate or washed-out colours; switch to a truecolor-capable
  terminal (Ghostty, iTerm2, kitty, wezterm, Alacritty) for full
  fidelity.

## Notes

- Inlay hints render automatically once the plugin attaches — no need
  to call `vim.lsp.inlay_hint.enable` manually. The `LspAttach`
  handler enables them whenever the server flag is on and disables
  them otherwise, so `:DimFortToggleInlayHints` does the right thing
  both client- and server-side.
- `dimfort.insertSnippet` (used by the "add `@unit{}`" code action)
  inserts the snippet literally and places the cursor at the `$0`
  position; Neovim doesn't have full LSP snippet expansion built in,
  so tab-stops `${1:placeholder}` are flattened to their default text.
- `dimfort.extractToParameter` (used by the H010 D1.5 "Extract literal
  to PARAMETER" quick-fix) prompts via `vim.ui.input` — plug in
  `dressing.nvim` or `snacks.nvim` for a nicer prompt UI than the
  builtin one.

## License

MIT.
