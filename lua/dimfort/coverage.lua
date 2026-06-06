-- Per-line coverage visualisation driven by the server's
-- `dimfort/lineStatus` LSP method (requires DimFort 0.2.4+).
--
-- Mirrors the VSCompanion's coverage layer: three mutually-exclusive
-- modes (disabled | gutter | background) toggled via
-- :DimFortCycleCoverage. `gutter` paints a coloured dot per line in
-- the sign column; `background` paints a low-alpha line tint. Both
-- encode the same per-line tier data, just with different visual
-- weight — the user picks the encoding they prefer.
--
-- Refresh is driven by Neovim's DiagnosticChanged autocmd so the
-- coverage layer stays in lock-step with the squiggles, never racing
-- the server's own debounce. See
-- `docs/design/future/coverage-visualization.md` in the DimFort repo
-- for the design spec.

local M = {}

---@alias DimFortCoverageMode "disabled"|"gutter"|"background"
---@alias DimFortCoverageTier "green"|"yellow"|"red"|"blue"

---@class DimFortCoverageConfig
---@field mode DimFortCoverageMode
---@field debounce_ms integer
M.config = {
  mode = "disabled",
  debounce_ms = 200,
}

-- Namespace for the extmark-based background tint. The sign-column
-- gutter dots use ``vim.fn.sign_place`` with our ``DimFortCoverage``
-- group; the two are cleared independently when the mode flips.
local ns = vim.api.nvim_create_namespace("DimFortCoverage")
local SIGN_GROUP = "DimFortCoverage"

-- Per-buffer debounce timers keyed by bufnr.
local timers = {}

-- The four tiers we paint. Order matches the design spec §3 taxonomy
-- (green / yellow / red / blue + no decoration).
local TIERS = { "green", "yellow", "red", "blue" }

-- Sign and highlight names per tier. Both naming patterns are
-- documented for users who want to ``:hi DimFortCover*`` override
-- the defaults — the same names are used in the design spec §9.2
-- sketch.
local function tier_sign_name(tier) return "DimFortCover" .. tier:sub(1,1):upper() .. tier:sub(2) end
local function tier_sign_hl(tier)   return "DimFortCover" .. tier:sub(1,1):upper() .. tier:sub(2) end
local function tier_bg_hl(tier)     return "DimFortCoverBg" .. tier:sub(1,1):upper() .. tier:sub(2) end

-- Default tier colours for the gutter dot. Picked to match the
-- VSCompanion's SVGs so the layer reads identically across editors.
local FG_COLOURS = {
  green  = "#28a745",
  yellow = "#ffc107",
  red    = "#dc3545",
  blue   = "#0d6efd",
}

-- Default tier background tints for ``background`` mode. Pre-darkened
-- hexes rather than the full-saturation FG_COLOURS because Neovim's
-- ``line_hl_group`` does NOT respect the ``blend`` attribute (blend
-- only applies to floating windows and a few conceal contexts), so a
-- saturated bg would dominate the line. These shades read as a
-- subtle tint on dark backgrounds; users on light themes can
-- override via ``:hi DimFortCoverBg<Tier> guibg=...``.
local BG_COLOURS = {
  green  = "#0a3320",
  yellow = "#3b2e00",
  red    = "#3b0a13",
  blue   = "#0a1c3b",
}

-- Install the four sign defs + the eight highlight groups. Idempotent
-- — safe to call multiple times. Re-run from a ColorScheme autocmd so
-- the highlights survive ``:hi clear`` (which every colorscheme runs
-- on activation, wiping unrelated definitions including ours).
local function install_definitions()
  for _, tier in ipairs(TIERS) do
    -- Foreground highlight for the sign-column dot. NO ``default =
    -- true`` here: that flag makes the definition vulnerable to
    -- ``:hi clear`` wiping it, after which the sign renders with
    -- terminal-default colour (white-on-default). Users who want
    -- to override can ``:hi DimFortCoverGreen guifg=...`` after
    -- setup — that takes precedence over a plain ``nvim_set_hl``.
    vim.api.nvim_set_hl(0, tier_sign_hl(tier), {
      fg = FG_COLOURS[tier],
    })
    -- Line-background tint. Uses a pre-darkened hex (see
    -- BG_COLOURS) because ``line_hl_group`` does NOT respect the
    -- ``blend`` attribute, so a saturated bg dominates the line.
    vim.api.nvim_set_hl(0, tier_bg_hl(tier), {
      bg = BG_COLOURS[tier],
    })
    -- Sign definition. ``●`` is a U+25CF Black Circle, matching
    -- the VSCompanion's SVG dot for visual parity. ``sign_define``
    -- resolves ``texthl`` by name at sign-render time, so re-
    -- defining the same name on subsequent ``install_definitions``
    -- calls is harmless.
    vim.fn.sign_define(tier_sign_name(tier), {
      text = "●",
      texthl = tier_sign_hl(tier),
    })
  end
end

-- True iff a buffer is a normal file buffer worth painting. Skips
-- scratch, terminal, prompt, and the like — those have no Fortran
-- source and don't have an LSP client.
local function should_paint(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.bo[bufnr].buftype ~= "" then return false end
  return true
end

-- Remove all coverage decorations from ``bufnr``. Called when the
-- mode flips away from a visible tier, or when the buffer is closed.
local function clear_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- Apply a server response of {lines = [{line, status}, ...]} to a
-- buffer. Clears first so a mode switch removes the previous layer.
local function apply_decorations(bufnr, lines)
  clear_buffer(bufnr)
  if M.config.mode == "disabled" then return end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, entry in ipairs(lines or {}) do
    local lnum = entry.line  -- 1-based per wire format
    local status = entry.status
    if lnum and lnum >= 1 and lnum <= line_count and status then
      if M.config.mode == "gutter" then
        vim.fn.sign_place(0, SIGN_GROUP, tier_sign_name(status), bufnr,
                          { lnum = lnum })
      elseif M.config.mode == "background" then
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
          line_hl_group = tier_bg_hl(status),
        })
      end
    end
  end
end

-- Return the active DimFort LSP client attached to ``bufnr``, or nil.
local function dimfort_client(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "dimfort" })) do
    return c
  end
  return nil
end

-- Query the server for the buffer's per-line status and paint. Called
-- post-debounce from `schedule_refresh`.
local function refresh_now(bufnr)
  if not should_paint(bufnr) then return end
  if M.config.mode == "disabled" then
    clear_buffer(bufnr)
    return
  end
  local client = dimfort_client(bufnr)
  if not client then return end
  local uri = vim.uri_from_bufnr(bufnr)
  client:request("dimfort/lineStatus", { uri = uri }, function(err, result)
    if err or not result then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    apply_decorations(bufnr, result.lines)
  end, bufnr)
end

-- Schedule a refresh after the configured debounce. Coalesces bursts
-- of diagnostic-change events so a flurry of edits doesn't fire one
-- LSP request per keystroke.
function M.schedule_refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not should_paint(bufnr) then return end
  if M.config.mode == "disabled" then
    clear_buffer(bufnr)
    return
  end
  local existing = timers[bufnr]
  if existing then
    existing:stop()
    existing:close()
  end
  local timer = vim.uv.new_timer()
  timers[bufnr] = timer
  timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(function()
    timer:stop()
    timer:close()
    timers[bufnr] = nil
    refresh_now(bufnr)
  end))
end

-- Refresh every visible buffer immediately. Used when the mode flips
-- so the new encoding paints without waiting for an edit.
function M.refresh_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    refresh_now(bufnr)
  end
end

-- Switch mode. Clears all coverage decorations first (so a flip from
-- gutter → background removes the previous gutter dots) then paints
-- the new encoding on every visible buffer.
---@param mode DimFortCoverageMode
function M.set_mode(mode)
  if mode == M.config.mode then return end
  M.config.mode = mode
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    clear_buffer(bufnr)
  end
  if mode ~= "disabled" then
    M.refresh_all()
  end
end

-- Cycle disabled → gutter → background → disabled.
function M.cycle()
  local order = { "disabled", "gutter", "background" }
  local current = M.config.mode
  local idx = 1
  for i, v in ipairs(order) do
    if v == current then idx = i break end
  end
  local next_mode = order[(idx % #order) + 1]
  M.set_mode(next_mode)
  vim.notify("DimFort: coverage " .. next_mode, vim.log.levels.INFO)
end

-- One-shot setup: register sign defs and highlight groups, install
-- the DiagnosticChanged autocmd that drives refresh, and respect any
-- configured initial mode.
---@param opts DimFortCoverageConfig|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  install_definitions()

  local group = vim.api.nvim_create_augroup("DimFortCoverage", { clear = true })

  -- Colorscheme swaps call ``:hi clear``, which wipes every highlight
  -- group — including ours. Re-install the sign defs + highlights
  -- whenever the colorscheme changes so the gutter dots and the
  -- background tints keep their colour. Also re-paints every
  -- visible buffer so the new highlights show without waiting for
  -- the next edit.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      install_definitions()
      if M.config.mode ~= "disabled" then
        M.refresh_all()
      end
    end,
  })

  -- The primary refresh trigger. Neovim 0.10+ fires DiagnosticChanged
  -- after every vim.diagnostic.set, which is what the LSP client
  -- calls when the server publishes — i.e. post the server's own
  -- debounce. Hooking here keeps the coverage layer in lock-step
  -- with the squiggles. The event's `data.bufnr` field is the
  -- affected buffer; `data` may be nil on older Neovim builds, in
  -- which case we fall back to the current buffer.
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function(ev)
      local bufnr = ev.buf or vim.api.nvim_get_current_buf()
      M.schedule_refresh(bufnr)
    end,
  })

  -- Refresh on entering a buffer so a freshly-focused window paints
  -- from the last cached server result without waiting for an edit.
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      M.schedule_refresh(ev.buf)
    end,
  })

  -- Clean up buffer-keyed timer state on buffer wipeout so we don't
  -- leak timers across reload cycles.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      local t = timers[ev.buf]
      if t then
        t:stop()
        t:close()
        timers[ev.buf] = nil
      end
    end,
  })
end

return M
