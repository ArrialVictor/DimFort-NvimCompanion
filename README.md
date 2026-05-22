# DimFort — Neovim companion

![preview](social_preview.png)

Neovim companion for [DimFort](https://github.com/ArrialVictor/DimFort) —
the dimensional-homogeneity checker for Fortran. Thin LSP client +
user commands; the heavy lifting is done by the `dimfort lsp` server.

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
  inlay_hints_enabled = true,
  completion_enabled = true,
  code_actions_enabled = true,
  goto_definition_enabled = true,
  code_lens_enabled = false,                    -- opt-in; visually busy

  -- Hover layout per surface. "short" = compact `name : unit` /
  -- formal-vs-actual pairing; "detailed" = full unit-algebra rule
  -- chain. See https://github.com/ArrialVictor/DimFort/blob/main/docs/hover-ui.md
  hover_function_calls   = "short",             -- "short" | "detailed"
  hover_subroutine_calls = "short",
  hover_expressions      = "short",
  trace_hover_enabled    = false,               -- legacy master switch

  -- Content-hash cache (https://github.com/ArrialVictor/DimFort/blob/main/docs/usage.md#content-hash-cache).
  cache_mode = "off",                           -- "off" | "read-only" | "read-write"
  cache_dir  = "",                              -- "" = .dimfort-cache/ under workspace root

  -- Workspace plumbing.
  max_workset_size = 40,                        -- cap on workset size
  external_modules = {},                        -- modules treated as known-out-of-workset
  filetypes        = { "fortran" },             -- buffers DimFort attaches to
  root_markers     = { ".dimfort.toml", ".git" },
  auto_attach      = true,                      -- attach via FileType autocmd
})
```

If `auto_attach = false`, call `require("dimfort").attach()` manually
from your own autocommand or keymap.

## Commands

| Command                                  | Effect                                                              |
|------------------------------------------|---------------------------------------------------------------------|
| `:DimFortCheckWorkspace`                 | Run the workspace-wide unit check.                                  |
| `:DimFortRestart`                        | Restart the language server.                                        |
| `:DimFortStatus`                         | Print current feature toggles and client id.                        |
| `:DimFortToggleInlayHints`               | Toggle inlay hints; restarts the server.                            |
| `:DimFortToggleCompletion`               | Toggle unit-name completion; restarts the server.                   |
| `:DimFortToggleCodeActions`              | Toggle code actions; restarts the server.                           |
| `:DimFortToggleGotoDefinition`           | Toggle go-to-definition; restarts the server.                       |
| `:DimFortToggleCodeLens`                 | Toggle code lens; restarts the server.                              |
| `:DimFortToggleTrace`                    | Toggle the legacy full-unit-trace hover master switch.              |
| `:DimFortToggleHoverFunctionCalls`       | Cycle the function-call hover detail (Short ↔ Detailed).            |
| `:DimFortToggleHoverSubroutineCalls`     | Cycle the subroutine-call hover detail.                             |
| `:DimFortToggleHoverExpressions`         | Cycle the expression hover detail.                                  |
| `:DimFortToggleCache`                    | Toggle content-hash cache between `off` and `read-write`.           |

## What you get

Same surface as the VSCode companion:

- Diagnostics (H001–H004, U001/U002/U005–U007/U010, …) per file in the
  loclist / quickfix / `vim.diagnostic` panel.
- Hover (`K`) for variable units.
- Inlay hints, code lens, go-to-definition, completion, code actions
  (toggleable).
- Workspace-wide cross-file checks driven from `use` clauses.

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
