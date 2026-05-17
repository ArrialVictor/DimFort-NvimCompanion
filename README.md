# DimFort — Vim/Neovim companion

Neovim companion for [DimFort](https://github.com/ArrialVictor/DimFort) —
the dimensional-homogeneity checker for Fortran. Thin LSP client +
user commands; the heavy lifting is done by the `dimfort lsp` server.

## Requirements

- Neovim ≥ 0.11 (uses `vim.lsp.start` and `vim.fs.find`).
- DimFort installed and `dimfort lsp` reachable from `$PATH` (or pass
  an absolute path via the `executable` option). Install instructions:
  https://github.com/ArrialVictor/DimFort.

## Installation

### lazy.nvim

```lua
{
  "ArrialVictor/DimFort-VimCompanion",
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
  "ArrialVictor/DimFort-VimCompanion",
  ft = "fortran",
  config = function()
    require("dimfort").setup({})
  end,
}
```

### Manual

Clone into your `runtimepath`:

```bash
git clone https://github.com/ArrialVictor/DimFort-VimCompanion.git \
  ~/.local/share/nvim/site/pack/dimfort/start/DimFort-VimCompanion
```

Then add to your `init.lua`:

```lua
require("dimfort").setup({})
```

## Configuration

All options shown with their defaults:

```lua
require("dimfort").setup({
  executable = "dimfort",            -- path to the dimfort binary
  inlay_hints_enabled = true,
  completion_enabled = true,
  code_actions_enabled = true,
  goto_definition_enabled = true,
  code_lens_enabled = true,
  max_workset_size = 40,             -- cap on workset size
  external_modules = {},             -- modules treated as known-out-of-workset
  filetypes = { "fortran" },         -- buffers DimFort attaches to
  root_markers = { ".dimfort.toml", ".git" },
  auto_attach = true,                -- attach via FileType autocmd
})
```

If `auto_attach = false`, call `require("dimfort").attach()` manually
from your own autocommand or keymap.

## Commands

| Command                        | Effect                                              |
|--------------------------------|-----------------------------------------------------|
| `:DimFortCheckWorkspace`       | Run the workspace-wide unit check.                  |
| `:DimFortRestart`              | Restart the language server.                        |
| `:DimFortToggleInlayHints`     | Toggle inlay hints; restarts the server.            |
| `:DimFortToggleCompletion`     | Toggle unit-name completion; restarts the server.   |
| `:DimFortToggleCodeActions`    | Toggle code actions; restarts the server.           |
| `:DimFortToggleGotoDefinition` | Toggle go-to-definition; restarts the server.      |
| `:DimFortToggleCodeLens`       | Toggle code lens; restarts the server.              |

## What you get

Same surface as the VSCode companion:

- Diagnostics (H001–H004, U001/U002/U005–U007/U010, …) per file in the
  loclist / quickfix / `vim.diagnostic` panel.
- Hover (`K`) for variable units.
- Inlay hints, code lens, go-to-definition, completion, code actions
  (toggleable).
- Workspace-wide cross-file checks driven from `use` clauses.

## Notes

- `dimfort.insertSnippet` (used by the "add `@unit{}`" code action)
  inserts the snippet literally and places the cursor at the `$0`
  position; Neovim doesn't have full LSP snippet expansion built in,
  so tab-stops `${1:placeholder}` are flattened to their default text.

## License

MIT.
