# Changelog

All notable changes to the DimFort Neovim companion are documented
here. Format inspired by [Keep a Changelog](https://keepachangelog.com/).

This plugin is a thin LSP client for [DimFort](https://github.com/ArrialVictor/DimFort);
behavioural changes mostly land in the DimFort server itself. Entries
below cover client-side changes only (commands, defaults, packaging).

## [Unreleased]

### Change: panel tree drops rule IDs; renders `(expected …)` on call-arg mismatches

Tracks the server's wire-format rename `ExpressionNode.ruleId` →
`ExpressionNode.expected`. The Expression section no longer trails
rule-ID tags like `(R4.2)` on every node — debug noise that wasn't
helpful for the target audience. In their place, when a call
argument's resolved unit dimensionally differs from the callee's
formal, the row now ends with `(expected <formal>)` so the reader
sees what the call-site demanded without reading the diagnostic
text. Mismatched argument rows paint 🟡 (the new 🟡-on-`expected`
override, server-side; see DimFort design/markers.md §4.4), so a
row with `(expected …)` will never read `marker: "ok"`.

## [0.2.0] — 2026-05-28

### Changed

- **Default UX stance** (unified across the VS / Nvim / Emacs companions).
  Inlay hints default **off** (redundant beside the panel/hover), the side
  panel defaults **on**, `hover` defaults to **`short`**, and the content-hash
  cache defaults to **read-write**. Override any of them in `setup{}`.

### Added

- **Scale-checking toggle** — a new `scale_mode` setting
  (`"auto"` / `"on"` / `"off"`, default `"auto"`) and a
  `:DimFortCycleScale` command. `"auto"` defers to the project's
  `.dimfort.toml` `[scale] enabled`; `"on"`/`"off"` force the magnitude
  layer (S001/S002) for the session, overriding the toml. Shown in
  `:DimFortStatus`.
- **Side panel** (`:DimFortTogglePanel`) — a persistent split, cursor-
  following with a debounce, at full feature parity with the VSCode
  companion. Six stacked sections (the volatile middle three show in the
  `both` layout):
  - **Expression** — the unit-algebra tree for the expression under
    the cursor (the same content as the Detailed hover, but it stays
    put while you edit). Markers and units align in columns.
  - **Diagnostics** — DimFort diagnostics on the cursor line, with the
    🔴/🟡/🔵 severity-circle vocabulary (info-level diagnostics such as
    P001 unparsed regions read the same as the rest). Each row is
    severity-coloured with Neovim's standard `DiagnosticError` /
    `DiagnosticWarn` / `DiagnosticInfo` groups, so it follows the
    colourscheme and matches native diagnostic styling.
  - **Interactions** — cross-site unit constraints for the symbol under
    the cursor (the `dimfort interactions` query): the X001 conflict, if
    any, then the Declaration / Write / Read / Undetermined-read groups,
    each site showing its location, unit, and source snippet (the snippet
    dimmed with the `Comment` highlight). Driven by the
    `dimfort/interactions` LSP request.
  - Empty-state placeholders (`(none)` / `(no … match)`) across all
    sections are dimmed with `Comment`, matching the VSCode panel.
  - **Actions** — the code actions available at the cursor (Add `@unit{}`
    / extract literal to a PARAMETER), applied in place with `<CR>`.
  - **Scope** — the declarations of every *enclosing* scope, stacked
    outermost-first and indented by nesting depth (e.g. a module's
    declarations, then a contained subroutine's locals). Each row is
    marked 🟢 (annotated), 🟡 (unannotated), or 🔴 (unparseable
    annotation). A name/unit filter (`:DimFortScopeFilter`) narrows long
    declaration lists. Driven by the `dimfort/panelInfo` LSP request.
  - **Imports** — variables **and procedures** a `use` clause brings into
    scope (usable here but declared elsewhere), grouped by source module
    under a `from <module>` header (functions read as `name(argunits)`,
    showing their argument + return units, e.g. `force(kg)`). `<CR>` navigates cross-file to where the imported
    symbol — and its `@unit{}` — is declared. Has its own name/unit/
    module filter, `:DimFortImportsFilter`.
  - **Row navigation** — `<CR>` on a declaration, diagnostic, interaction
    site, or import jumps to it (cross-file for interactions and imports);
    the file-wide diagnostic counts pin the footer.
  - Settings: `panel_enabled` (default `false`), `panel_layout`
    (`both` / `expression` / `routine`), `panel_position`
    (`right` / `left` / `bottom`), `panel_width_fraction` /
    `panel_width_cols`, `panel_debounce_ms`.
  - Commands: `:DimFortTogglePanel`, `:DimFortPanelLayout {kind}`,
    `:DimFortPanelRefresh`, `:DimFortScopeFilter [query]`.

## [0.1.1] — 2026-05-22

Feature-parity with the VSCode companion 0.1.3. All settings that
the VSCompanion forwards as `initializationOptions` are now mirrored
here as Lua config options + restart-on-change toggles.

### Added

- **`cache_mode` setting** — content-hash cache for the workspace
  check: `"off"` (default), `"read-only"`, or `"read-write"`. With
  `"read-write"`, warm re-runs replay cached diagnostics for
  unchanged files (LMDZ-scale: ~33 s cold → ~20 s warm).
- **`cache_dir` setting** — optional cache directory override.
  Empty (default) lets the server use `.dimfort-cache/` under the
  workspace root.
- **`:DimFortToggleCache` command** — flips `cache_mode` between
  `"off"` and `"read-write"` and restarts the server.

- **Per-surface hover settings** — three independent Lua options:
  - `hover_function_calls = "short" | "detailed"`
  - `hover_subroutine_calls = "short" | "detailed"`
  - `hover_expressions = "short" | "detailed"`

  Each governs the corresponding hover layout. `Short` keeps the
  compact `name : unit` / formal-vs-actual view; `Detailed`
  expands to the full unit-algebra rule-chain tree.
- **`:DimFortToggleHoverFunctionCalls`, `:DimFortToggleHoverSubroutineCalls`,
  `:DimFortToggleHoverExpressions`** — cycle each setting through
  Short ↔ Detailed.

- **`trace_hover_enabled` setting** + **`:DimFortToggleTrace`
  command** — legacy master switch that upgrades all hover
  surfaces still on `"short"` to `"detailed"`. Per-surface
  settings still win.

- **`dimfort.extractToParameter` command handler** — the H010 D1.5
  "Extract literal to named PARAMETER" quick-fix now works in
  Neovim. The plugin prompts via `vim.ui.input` (so dressing /
  snacks overlays work), validates the Fortran identifier, then
  applies the two-edit refactor via `vim.lsp.util.apply_workspace_edit`.

### Changed

- `code_lens_enabled` default flipped from `true` to `false`,
  matching the VSCompanion. Code lens is opt-in via
  `:DimFortToggleCodeLens` or `setup({ code_lens_enabled = true })`.
- `:DimFortStatus` output extended with the new fields.

## [0.1.0] — 2026-05-19

First public release. Install via your Neovim plugin manager
pointing at this repository — there's nothing to download
separately. Requires Neovim ≥ 0.11 and DimFort itself on PATH
(`pipx install 'dimfort[lsp]'`).

```lua
-- lazy.nvim
{ "ArrialVictor/DimFort-NvimCompanion", ft = { "fortran" } }
```

### 2026-05-17

- **Repo rename**: `DimFort-VimCompanion` → `DimFort-NvimCompanion`.
  Reflects the scope decision below.
- **Scope to Neovim only.** The plugin is now Neovim-only (≥ 0.11),
  built on the in-tree `vim.lsp.*` APIs. Classic Vim doesn't share
  those APIs; trying to support both led to silently divergent
  behaviour. Classic-Vim users should drive the server through
  another LSP client (coc.nvim, vim-lsp, …).
- **Drop the 800 ms inlay refresh hack**. DimFort server now emits
  `workspace/inlayHint/refresh` after every check, so the local
  delay-and-poll workaround is no longer needed.
- **Diagnostic rendering**: errors and warnings now appear as virtual
  text inline; inlay-hint colour clamps to a 256-color-safe dim grey
  on terminal Neovim.
- **`:DimFortStatus`**: at-a-glance list of feature flags, server
  status, and active workspace. Surfaces `init_options` so a user can
  see what the running server thinks is enabled.
- **Branding**: ship `icon.png`, `icon_alt.png`, and `social_preview.png`.

### Earlier

Initial release as `DimFort-VimCompanion`. Spawns `dimfort lsp` over
stdio. Auto-attaches on Fortran filetypes; provides `:DimFortStart`,
`:DimFortRestart`, `:DimFortStop`, `:DimFortToggleInlay`. Diagnostics,
hover, inlay hints, go-to-definition wire through the standard
`vim.lsp` handlers.
