# Contributing to the DimFort Neovim companion

Thanks for considering a contribution. This plugin is a **thin LSP client**
for [DimFort](https://github.com/ArrialVictor/DimFort) — behavioural changes
(diagnostics, annotation parsing, unit algebra, …) usually belong in the server
repo. The contribution surface here is the editor-side experience: the side
panel, hover surfaces, user commands, defaults, packaging.

## Reporting issues

Open an issue using the **Bug report** template. The version block (DimFort
server + Neovim + companion git ref + OS) and the `:LspLog` trace are the most
useful things to include — most bugs are routed to the server repo on the basis
of that trace.

## Development setup

```bash
git clone https://github.com/ArrialVictor/DimFort-NvimCompanion.git
```

Add the checkout to Neovim's runtime path. The simplest way during development:

```lua
-- in init.lua
vim.opt.rtp:prepend("/absolute/path/to/DimFort-NvimCompanion")
require("dimfort").setup({
  executable = "/absolute/path/to/DimFort/.venv/bin/dimfort",  -- point at your local server
})
```

That picks up `lua/dimfort/*` immediately — no build step (pure Lua).

## Parse-checking

There are no unit tests yet; quick sanity check that the Lua files load
without syntax errors:

```bash
nvim --headless --noplugin \
  -c "lua local f,e=loadfile('lua/dimfort/panel.lua'); print(e and ('ERR '..e) or 'OK')" \
  -c qa
```

There are no unit tests in this repo. Behavioural QA is split:

- **Server-side wire behaviour** (diagnostic codes, hover / panel /
  inlay / workspace / coverage / code-action / completion payloads)
  is verified by the DimFort LSP integration test suite at
  `tests/lsp_integration/` in the server repo. Changes that don't
  affect rendering can rely on that suite alone.
- **Display behaviour** (`vim.diagnostic` signs / underline / virtual
  text, hover floating window, panel layout, fidget progress, notify
  messages, command UIs) is covered by `MANUAL_QA.md`, run before
  each release.

## Style + scope

- Keep the plugin thin. Use the built-in `vim.lsp` client where possible;
  treat the server's JSON response as authoritative.
- Match the surface of the VSCode and Emacs companions where it makes sense
  — the three are intentionally feature-parallel. Cross-companion design notes
  live in the DimFort server repo's `docs/design/shipped/panel-info.md`.
- Panel rendering uses `vim.fn.strdisplaywidth` + manual padding for column
  alignment (Lua's `#` byte-length and `string.format("%-Ns", …)` mis-pad
  multi-byte unit chars like `·` and `⁻¹`).

## Releases

Tag-based: `git tag v0.X.Y && git push --tags` then create a GitHub release
attaching the relevant CHANGELOG entry. No MELPA / package-registry publish at
present.
