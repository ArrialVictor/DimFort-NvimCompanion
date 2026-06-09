# Changelog

All notable changes to the DimFort Neovim companion are documented
here. Format inspired by [Keep a Changelog](https://keepachangelog.com/).

This plugin is a thin LSP client for [DimFort](https://github.com/ArrialVictor/DimFort);
behavioural changes mostly land in the DimFort server itself. Entries
below cover client-side changes only (commands, defaults, packaging).

## [Unreleased]

### Recommended server version

Pair this companion with DimFort **0.2.5+**. The workspace bar listens
for the new server-fired `dimfort/workspaceCheckCompleted` notification
(introduced by DimFort 0.2.5's async workspace check refactor). Earlier
servers don't emit it; the bar would stay on the spinner state forever
after a refresh trigger.

### Added

- **Async workspace check** — `:DimFortCheckWorkspace` now sends an
  executeCommand that the server acks immediately (the work runs
  server-side on a daemon thread). The fresh workspace coverage
  payload arrives via the new `dimfort/workspaceCheckCompleted` LSP
  notification; the bar updates when that lands. A duplicate trigger
  while a check is in flight surfaces a `vim.notify` info popup
  instead of silently coalescing. New `M.install_handlers()`
  registers the global notification handler at setup time. Requires
  DimFort 0.2.5+.

- **Workspace coverage bar** — side-panel footer now renders a unified
  coverage bar showing per-file and whole-workspace stats:
  `File: 78% (🟡 18 🔴 2)   Project: 12.9% (🟡 N 🔴 M)`. File-scope numbers
  refresh live on every `DiagnosticChanged` event; workspace-scope is
  populated only by `:DimFortCheckWorkspace` (a new
  `:DimFortRefreshWorkspace` alias is provided for parity with
  VSCompanion's command name). Three WS states: `Project: –` (dimmed) before
  the first refresh, a Braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, 80 ms cadence)
  while a refresh is in flight, and `Project: <pct>%` after. Numbers dim
  once any file's diagnostics change after the last successful refresh
  so the user knows the snapshot may be stale. Requires DimFort 0.2.5+
  (relies on the unified `dimfort.checkWorkspace` server command). New
  module `lua/dimfort/stats.lua` carries the provider; mirrors the
  VSCompanion `CoverageStatsProvider`. Replaces the previous footer
  that surfaced only raw 🔴 / 🟡 diagnostic counts for the active file.

- **Coverage visualisation** — per-line status decoration driven by
  the server's `dimfort/lineStatus` LSP method (requires DimFort
  0.2.4+). Setting `coverage_mode` (`disabled` | `gutter` |
  `background`) controls the layer; default is `disabled` (opt-in).
  Command `:DimFortCycleCoverage` cycles through the three modes.
  `gutter` and `background` are mutually-exclusive visual encodings
  of the same per-line tier (green / yellow / red / blue); pick the
  visual weight you prefer. Refresh is driven by Neovim's
  `DiagnosticChanged` autocmd so the layer stays in lock-step with
  the squiggles — no separate debounce race against the server's
  own check pipeline. Setting `coverage_debounce_ms` (default 200)
  coalesces bursts of diagnostic-change events. Coverage settings
  are companion-only — flipping the mode does not restart the
  language server. New module `lua/dimfort/coverage.lua` carries
  the rendering provider; the four sign defs and eight highlight
  groups (`DimFortCoverGreen` / `Yellow` / `Red` / `Blue` for the
  gutter dots, `DimFortCoverBg*` for the line tint) are
  user-overridable via `:hi`.

## [0.2.3] — 2026-06-07

### Track DimFort 0.2.3.1's polymorphism feature + in-editor UX polish

This release tracks DimFort's polymorphism feature shipped over
0.2.3 + 0.2.3.1. Recommended pairing is **server 0.2.3.1** for the
full hover/panel rendering; the plugin is forward-compatible with
0.2.3 servers too.

Server-side (read transparently — no client config added):
parametric polymorphism (`'a`, `'b`, …) in `@unit{}` annotations,
four new diagnostic codes (H020 polymorphic-call-site unification
failure, H021 type-variable-in-forbidden-position, H022
cannot-bind-tyvar-to-affine-unit (e.g. passing a `degC` actual into
a `'a` slot — type variables range over the multiplicative algebra
only), H023
dishonest-polymorphic-body), the 40-item pre-release audit fix
series, and the 37 in-source docstring-drift fixes. The eight
0.2.3.1 follow-up fixes (panel/hover marker propagation, H020
collides-trailer rendering, message multi-line reformat, clean-call
no-trailer convention, polymorphic-function return resolution, and
the `'a = ?` unbound-return form) are similarly server-side — they
just need the client to render the new fields exposed below.

Client-side (this plugin):

- **`(collides with …)` row tail** on H020 polymorphic-conflict rows.
  The server's `dimfort/panelInfo` now ships a `collides` field on
  `ExpressionNode` carrying the partner-arg list (`"arg 2"` /
  `"arg 1, arg 3"`); the panel renders it as `(collides with <X>)`
  (Comment highlight on the trailer), alongside the existing
  `(expected …)` and `(assumed: …)` row tails. Forward-compatible:
  0.2.3 servers omit the field and the trailer doesn't render.
- **Dimmed trailing `?`** on the new `'a = ?` unbound-polymorphic-return
  form. The Comment highlight applied to bare-`?` / bare-`-` cells
  is now scoped to the trailing `?` only when the unit ends in
  `= ?`; the bound prefix stays full-weight. The suffix check is
  tight enough not to false-positive — concrete units never end in
  `= ?`.
- **Polymorphism QA annex** in MANUAL_QA.md (Cases A–G + interactive
  H021 / H022 probes) — pins every behaviour the 0.2.3.1 server-
  side fixes deliver.

### Recommended server version

`dimfort >= 0.2.3.1` for the full polish. Earlier 0.2.3 servers
work — the `collides` field stays absent and the panel renders the
binding form without the trailer, the rest is unchanged.

## [0.2.2] — 2026-06-03

### Passthrough: DimFort 0.2.2's configurable comment delimiters

This release tracks DimFort 0.2.2. The plugin itself is unchanged
— the new `[parser]` keys
(`unit_comment_delimiters` / `unit_assume_comment_delimiters` /
`unit_affine_comment_delimiters`) are read by the server from
`.dimfort.toml`, no client config is added.

The new U021 / U023 / U002-suggested-rewrite diagnostics render
through `vim.lsp.diagnostic`; the U002 "Replace with `<X>`"
quick-fix surfaces via `vim.lsp.buf.code_action()` (it's a direct
`WorkspaceEdit`, no command delegation) so it just works.

### Min server version

`dimfort >= 0.2.2` recommended. Earlier servers still run as a
fallback, but won't expose the new toml keys.

## [0.2.1] — 2026-05-30

### Polish: render `assumed` marker (🔵) + `(assumed: <reason>)` tail on the RHS row

Tracks the new server-side `ExpressionNode.marker = "assumed"` value
and `ExpressionNode.assumed: string | null` field. When the server
flags a row as accepted via `@unit_assume{<unit> : <reason>}`, the
panel paints 🔵 and appends `(assumed: <reason>)` to the row tail
(same column as `(expected …)`; both can coexist).

The overlay lives on the **RHS row** of the assignment — the
directive's syntactic subject — not on the assignment row itself.
The companion needs no code changes for this routing (the server
sets `marker`/`assumed` on the RHS child of the assignment
payload); this entry tracks the wire-format expectation.

🔵 is a per-row overlay, NOT a severity tier — it doesn't
propagate up. The assignment row stays `marker: "ok"` (🟢) when
the homogeneity check passes; H001 still fires (🔴) if the
declared LHS unit conflicts with the asserted RHS unit. See
DimFort design/markers.md §4.6.

### Polish: dim `?` and `-` glyphs across every panel section

Absence-of-information glyphs (`?` for unknown, `-` for
structural-no-unit) now render with the `Comment` highlight in
**every** panel section that shows units — Scope, Imports,
Expression tree, and Interactions. Three glyphs, three meanings,
consistent visual treatment everywhere. The `emit` helper grew an
optional fifth `ranges` arg (per-byte-range highlights inside a
row) to support the Expression-tree case where labels have
variable Unicode width.

### Change: scope / import unannotated vars render `?`, not `(none)`

Aligns with the server-side glyph unification (see DimFort
design/markers.md §4.5): `(none)` is now reserved for empty
(sub-)section headers only (`Scope: (none)`, `Imports: (none)`).
Individual unannotated variables in the Scope and Imports sections
read `?` — the same glyph used inside the Expression tree for
unknown units. Imported subroutines (no return by design) read `-`
instead of `?` to distinguish "no unit by structure" from "we
don't know yet". (The Nvim Imports row previously used `—`; that
becomes `-` for the same reason — a single glyph across both
companions and across surfaces.)

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

### Add: `hover_border` setup option, default `"rounded"`

A new `hover_border` field in `require("dimfort").setup({ … })`
controls the border style of DimFort hover floats. Defaults to
`"rounded"` so hover popups read as a distinct card regardless of
the user's colorscheme `NormalFloat` styling. Set to `"none"` to
inherit colorscheme defaults. Installed via a buffer-local `K`
mapping on attach, so it's scoped to DimFort-managed buffers and
doesn't touch other LSP servers' hovers.

### Polish: auto-attach now listens on `BufEnter` too

The auto-attach autocmd used to listen only on `FileType`. That
event doesn't always re-fire when navigating to an already-buffered
file (e.g. via netrw's `:e .` directory listing or some buffer
switchers), so the second-and-subsequent Fortran buffer in a session
would leave the LSP unattached. Now also listens on `BufEnter` with
a cheap "already-attached?" pre-check — first BufEnter attaches,
subsequent BufEnters into the same buffer no-op.

### Polish: scope/imports `unitNormalized` column + uniform scale-mode display

The Scope-var and Imports rows now render the `unitNormalized` field
as a second cell next to the source unit when they differ (e.g.
`Pa  kg·m⁻¹·s⁻²`). Server-side gating means the multiplicative
factor appears only when scale mode is on (`hPa  100×kg·m⁻¹·s⁻²`
vs `hPa  kg·m⁻¹·s⁻²`) — the panel just renders whatever the server
emits, so the same rule lands across every surface.

### Polish: module procedures show up in the Scope panel

For module/program scopes, the panel now lists the module's defined
functions / subroutines as `name(args)` rows alongside variables,
mirroring how the Imports section formats imported procedures.
Zero renderer changes — the server emits these as pre-formatted
rows in `ScopeVar` shape.

### Change: Interactions label `"Undetermined read"` → `"Undetermined"`

The panel's Interactions section header for the `uses` kind now
reads `Undetermined` (was `Undetermined read`). Matches the rename
on the server side; the underlying `kind` value is unchanged.

### Add: link to the canonical `demos/tour.f90` in the README

The README's intro now points at `demos/tour.f90` in the DimFort
repo — a short, self-contained moist-thermodynamics file that
exercises six high-impact diagnostics on a single page. Going
forward, README screenshots will be taken from this file so they
stay reproducible.

### Docs: project rule — no validation-workspace name in tracked files

Internal hygiene: an explicit reference to the specific Fortran
codebase used as the validation target in `CHANGELOG.md` was
replaced with neutral phrasing. No behavioural change.

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
  unchanged files (a benchmark workspace measured ~33 s cold → ~20 s warm).
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
