# Changelog

All notable changes to the DimFort Neovim companion are documented
here. Format inspired by [Keep a Changelog](https://keepachangelog.com/).

This plugin is a thin LSP client for [DimFort](https://github.com/ArrialVictor/DimFort);
behavioural changes mostly land in the DimFort server itself. Entries
below cover client-side changes only (commands, defaults, packaging).

## [Unreleased]

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
