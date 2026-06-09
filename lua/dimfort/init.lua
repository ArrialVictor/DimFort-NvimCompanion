-- DimFort language-server client for Neovim.
--
-- Mirrors the VSCode companion's feature set: registers `dimfort lsp`
-- with the built-in LSP client, forwards `initializationOptions`,
-- exposes the same per-feature toggle commands, and wires up
-- `dimfort.insertSnippet` so the U005 code action works.

local M = {}

---@alias DimFortCacheMode "off"|"read-only"|"read-write"

---@class DimFortConfig
---@field executable string                    -- path to the `dimfort` binary
---@field inlay_hints_enabled boolean
---@field completion_enabled boolean
---@field code_actions_enabled boolean
---@field goto_definition_enabled boolean
---@field hover "disabled"|"short"|"detailed"  -- hover verbosity (panel unaffected)
---@field scale_mode "auto"|"on"|"off"        -- scale checking; auto = defer to .dimfort.toml
---@field cache_mode DimFortCacheMode
---@field cache_dir string                     -- empty = .dimfort-cache/ under workspace root
---@field panel_enabled boolean                -- open side panel on attach
---@field panel_layout "both"|"expression"|"routine"
---@field panel_position "right"|"left"|"bottom"
---@field panel_width_fraction number          -- fraction of editor width
---@field panel_debounce_ms integer            -- cursor-follow debounce
---@field coverage_mode "disabled"|"gutter"|"background"
                                               -- per-line coverage visualisation (requires DimFort 0.2.4+)
---@field coverage_debounce_ms integer         -- debounce for the coverage refresh
---@field max_workset_size integer
---@field external_modules string[]
---@field filetypes string[]                   -- buffers DimFort attaches to
---@field root_markers string[]                -- files marking the workspace root
---@field auto_attach boolean                  -- attach automatically via FileType autocmd
---@field hover_border "rounded"|"single"|"double"|"solid"|"shadow"|"none"
                                               -- border style for DimFort hover floats
local defaults = {
  executable = "dimfort",
  -- Default UX stance (unified across companions 2026-05-26): the side
  -- panel is ON and hover defaults to "short" — both cursor-following
  -- unit surfaces. Inlay hints are OFF (redundant beside them) and the
  -- (correctness-verified) content-hash cache is ON.
  inlay_hints_enabled = false,
  completion_enabled = true,
  code_actions_enabled = true,
  goto_definition_enabled = true,
  hover = "short",                   -- one-line `name : unit` on hover
  scale_mode = "auto",               -- "auto" defers to .dimfort.toml; "on"/"off" override
  cache_mode = "read-write",         -- cache on by default
  cache_dir = "",
  panel_enabled = true,              -- open the side panel on attach
  panel_layout = "both",
  panel_position = "right",
  panel_width_fraction = 0.35,
  panel_width_cols = nil,         -- if set (integer), wins over fraction
  panel_debounce_ms = 200,
  -- Coverage layer (requires DimFort 0.2.4+). ``disabled`` by default
  -- (opt-in per the design spec); cycle through with
  -- :DimFortCycleCoverage.
  coverage_mode = "disabled",
  coverage_debounce_ms = 200,
  max_workset_size = 40,
  external_modules = {},
  filetypes = { "fortran" },
  root_markers = { ".dimfort.toml", ".git" },
  auto_attach = true,
  -- DimFort hover floats default to a rounded border so they read as
  -- a discrete card even when the user's colorscheme leaves
  -- ``NormalFloat`` un-tinted (a common gap in popular Nvim themes).
  -- Set ``hover_border = "none"`` to opt out and inherit whatever
  -- styling the user's colorscheme provides.
  hover_border = "rounded",
}

---@type DimFortConfig
M.config = vim.deepcopy(defaults)

-- The currently-active LSP client id for DimFort, if any. We track it
-- ourselves rather than re-scanning vim.lsp.get_clients() each time so
-- :DimFortRestart is fast and unambiguous.
local active_client_id = nil

-- Internal: builds the initializationOptions table the server expects.
-- Mirrors the field set the VSCompanion sends so the two clients
-- present an identical surface to the server.
local function init_options()
  local opts = {
    inlayHintsEnabled = M.config.inlay_hints_enabled,
    completionEnabled = M.config.completion_enabled,
    codeActionsEnabled = M.config.code_actions_enabled,
    gotoDefinitionEnabled = M.config.goto_definition_enabled,
    hover = M.config.hover,
    maxWorksetSize = M.config.max_workset_size,
    externalModules = M.config.external_modules,
    cacheMode = M.config.cache_mode,
  }
  -- Only forward cacheDir if the user set one; an empty string would
  -- shadow the server's default-cache-dir fallback.
  if M.config.cache_dir and M.config.cache_dir ~= "" then
    opts.cacheDir = M.config.cache_dir
  end
  -- Scale checking is tri-state: "auto" omits scaleMode so the server's
  -- .dimfort.toml [scale] enabled wins; "on"/"off" send an explicit
  -- boolean that overrides the toml for the session.
  if M.config.scale_mode == "on" then
    opts.scaleMode = true
  elseif M.config.scale_mode == "off" then
    opts.scaleMode = false
  end
  return opts
end

-- Resolve the workspace root from any of the configured markers, or
-- fall back to the file's containing directory.
local function find_root(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if fname == "" then
    return vim.uv.cwd()
  end
  local found = vim.fs.find(M.config.root_markers, {
    upward = true,
    path = vim.fs.dirname(fname),
  })[1]
  if found then
    return vim.fs.dirname(found)
  end
  return vim.fs.dirname(fname)
end

-- Insert a literal LSP snippet at (line, character) into the buffer
-- showing ``uri``. Neovim's built-in LSP client doesn't natively
-- expand `${1:placeholder}` syntax, but the server only uses simple
-- `${0}` cursor placeholders in DimFort, so strip those and place
-- the cursor manually.
local function handle_insert_snippet(args)
  local uri, line, character, snippet = args[1], args[2], args[3], args[4]
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)

  -- Mark the final-cursor placeholder (`$0` / `${0}`) with a sentinel
  -- before stripping the other placeholders, so we can recover its
  -- position in the plain text and place the cursor exactly there
  -- (between the braces of `@unit{}`), not at the end of the line.
  local SENTINEL = "\1"
  local marked = snippet
    :gsub("%${0}", SENTINEL)
    :gsub("%$0", SENTINEL)
    :gsub("%${%d+:([^}]*)}", "%1")
    :gsub("%${%d+}", "")
  local sidx = marked:find(SENTINEL, 1, true)   -- 1-based byte index, or nil
  local plain = marked:gsub(SENTINEL, "")

  local lines = vim.split(plain, "\n", { plain = true })
  vim.api.nvim_buf_set_text(bufnr, line, character, line, character, lines)

  -- Show the buffer and move the cursor to where the `$0` sat.
  vim.api.nvim_set_current_buf(bufnr)
  if sidx then
    -- ``before`` is the text preceding the sentinel (== the plain text
    -- preceding the cursor, since the sentinel is one byte). Count the
    -- newlines in it for the row, and the bytes after the last newline
    -- for the 0-based column.
    local before = marked:sub(1, sidx - 1)
    local nl = select(2, before:gsub("\n", ""))
    local on_line = before:match("[^\n]*$") or ""
    local target_line = line + nl
    local target_col = (nl == 0) and (character + #on_line) or #on_line
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line + 1, target_col })
  end
end

-- Handle the H010 D1.5 "Extract literal to a named PARAMETER" quick-fix.
-- Server-side payload mirrors what the VSCompanion handles: prompt the
-- user for a name, validate it, then apply the two-edit refactor
-- (insert a typed PARAMETER decl at the end of the enclosing routine's
-- decl block + replace the literal at the use site).
local function handle_extract_to_parameter(args)
  local uri          = args[1]
  local range_start  = args[2]
  local range_end    = args[3]
  local insert_line  = args[4]
  local indent       = args[5]
  local literal_text = args[6]
  local target_unit  = args[7]
  local default_name = args[8]

  local prompt = string.format(
    "Parameter name for %s (%s): ", literal_text, target_unit
  )

  -- vim.ui.input gives plugin overlays (e.g. dressing.nvim, snacks.nvim)
  -- a chance to render a nice prompt; falls back to the builtin input
  -- otherwise. Async callback model.
  vim.ui.input({
    prompt = prompt,
    default = default_name,
  }, function(name)
    if not name or name == "" then return end  -- cancelled
    if not name:match("^[A-Za-z][A-Za-z0-9_]*$") then
      vim.notify(
        "DimFort: invalid Fortran identifier — must start with a letter, "
        .. "then letters/digits/_",
        vim.log.levels.ERROR
      )
      return
    end

    local decl_line = string.format(
      "%sreal, parameter :: %s = %s   !< @unit{%s}\n",
      indent, name, literal_text, target_unit
    )
    local edit = {
      changes = {
        [uri] = {
          {
            range = {
              ["start"] = { line = insert_line, character = 0 },
              ["end"]   = { line = insert_line, character = 0 },
            },
            newText = decl_line,
          },
          {
            range = {
              ["start"] = range_start,
              ["end"]   = range_end,
            },
            newText = name,
          },
        },
      },
    }
    -- Neovim 0.11+ accepts the position-encoding hint as third arg.
    vim.lsp.util.apply_workspace_edit(edit, "utf-16")
  end)
end

-- Build the vim.lsp.start config for a given buffer.
local function client_config(bufnr)
  return {
    name = "dimfort",
    cmd = { M.config.executable, "lsp" },
    filetypes = M.config.filetypes,
    root_dir = find_root(bufnr),
    init_options = init_options(),
    commands = {
      ["dimfort.insertSnippet"] = function(cmd)
        handle_insert_snippet(cmd.arguments or {})
      end,
      ["dimfort.extractToParameter"] = function(cmd)
        handle_extract_to_parameter(cmd.arguments or {})
      end,
    },
  }
end

-- Attach DimFort to the current buffer (or ``bufnr`` if given). Safe
-- to call repeatedly; vim.lsp.start dedupes by name+root_dir.
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local id = vim.lsp.start(client_config(bufnr), { bufnr = bufnr })
  if id then
    active_client_id = id
  end
  return id
end

-- Stop the active client, then attach to the current buffer.
-- Restart the language server. ``opts.message`` (string) is the
-- notification shown *after* the re-attach — pass the meaningful
-- confirmation (e.g. "hover → detailed") so it is the last thing
-- written and isn't stomped by a generic "restarted" message 100ms
-- later. Defaults to a plain restart notice for :DimFortRestart.
function M.restart(opts)
  opts = opts or {}
  if active_client_id then
    local client = vim.lsp.get_client_by_id(active_client_id)
    if client then
      client:stop()
    end
    active_client_id = nil
  end
  -- Drop coverage caches — the new client may be different version /
  -- workspace and any cached numbers are stale.
  require("dimfort.stats").reset()
  -- Defer the re-attach so vim.lsp.stop's cleanup finishes first.
  vim.defer_fn(function()
    M.attach()
    vim.notify(opts.message or "DimFort: language server restarted",
               vim.log.levels.INFO)
    -- Force one panel refresh once the new LSP client is actually
    -- attached. Polling rather than a fixed delay because the
    -- attach timeline depends on cache state (initial scan
    -- ~600 ms warm / ~4 s cold), and a fixed delay would either
    -- fire too early (request hits no server, panel rebuilds
    -- against empty payload) or feel sluggish on warm restarts.
    -- Without this, a scale-toggle / hover-mode / cache-mode flip
    -- would leave the panel showing the prior server's payload
    -- until the user moved the cursor.
    M._restart_wait_and_refresh(vim.uv.hrtime() + 10 * 1e9)
  end, 100)
end

-- Poll every 300 ms (up to a 10 s deadline) for an attached
-- DimFort client, then fire one panel refresh once one is found.
function M._restart_wait_and_refresh(deadline_ns)
  local clients = vim.lsp.get_clients({ name = "dimfort" })
  if #clients > 0 then
    local ok, panel = pcall(require, "dimfort.panel")
    if ok and panel and panel.refresh then
      pcall(panel.refresh)
    end
    return
  end
  if vim.uv.hrtime() >= deadline_ns then return end
  vim.defer_fn(function()
    M._restart_wait_and_refresh(deadline_ns)
  end, 300)
end

-- Run the workspace check via workspace/executeCommand. Since 0.2.5,
-- the server-side command publishes squiggles, refreshes the workspace
-- coverage cache, AND returns the fresh aggregate inline — so this one
-- call drives the workspace bar's spinner + final value. The stats
-- module handles request bookkeeping (sequence numbers, spinner,
-- listener fan-out); we just trigger it.
function M.check_workspace()
  local client = active_client_id and vim.lsp.get_client_by_id(active_client_id)
  if not client then
    vim.notify("DimFort: no active language client", vim.log.levels.WARN)
    return
  end
  local stats = require("dimfort.stats")
  stats.refresh_workspace(function(ok)
    if not ok then
      vim.notify("DimFort: checkWorkspace failed", vim.log.levels.ERROR)
    end
  end)
end

-- Flip a feature flag and restart so the new initializationOptions
-- take effect. ``key`` is the field name on M.config (snake_case).
local function toggle(key, label)
  M.config[key] = not M.config[key]
  M.restart({
    message = string.format("DimFort: %s %s", label,
                            M.config[key] and "on" or "off"),
  })
end

-- Cycle an enum-valued setting through ``values`` and restart. Used
-- for the hover Short ↔ Detailed and cache off ↔ read-write toggles.
local function cycle(key, label, values)
  local current = M.config[key]
  local idx = 1
  for i, v in ipairs(values) do
    if v == current then idx = i break end
  end
  local next_v = values[(idx % #values) + 1]
  M.config[key] = next_v
  M.restart({ message = string.format("DimFort: %s → %s", label, next_v) })
end

M.toggle_inlay_hints      = function() toggle("inlay_hints_enabled",      "inlay hints")        end
M.toggle_completion       = function() toggle("completion_enabled",       "unit completion")    end
M.toggle_code_actions     = function() toggle("code_actions_enabled",     "code actions")       end
M.toggle_goto_definition  = function() toggle("goto_definition_enabled",  "go-to-definition")   end
-- Hover verbosity: a single tri-state cycled disabled -> short ->
-- detailed. "disabled" = no hover (panel is the unit surface); "short"
-- = compact `name : unit`; "detailed" = full unit-algebra tree. The
-- panel is unaffected. See DimFort's docs/hover-ui.md.
M.cycle_hover = function()
  cycle("hover", "hover", { "disabled", "short", "detailed" })
end

-- Content-hash cache toggle flips between the two useful modes (off
-- and read-write). The middle "read-only" mode is reachable via
-- :lua require('dimfort').config.cache_mode = "read-only" + restart,
-- since the binary-toggle ergonomics from the palette aren't useful
-- for that mid-state.
M.toggle_cache = function()
  cycle("cache_mode", "cache", { "off", "read-write" })
end

-- Scale checking is tri-state: "auto" defers to the project .dimfort.toml
-- ([scale] enabled), "on"/"off" override it for the session. Cycled
-- auto -> on -> off; restarts so the new scaleMode reaches the server.
M.cycle_scale = function()
  cycle("scale_mode", "scale checking", { "auto", "on", "off" })
end

-- Coverage visualisation is tri-state (disabled / gutter / background).
-- Gutter and background are mutually-exclusive visual encodings of
-- the same per-line tier; the user picks the visual weight they
-- prefer. The coverage module owns the state and the refresh logic;
-- this entry point just delegates. Coverage settings are companion-
-- only, so the LSP is NOT restarted on a mode flip.
M.cycle_coverage = function()
  require("dimfort.coverage").cycle()
end

-- Print the current feature flags + client state. Bound to
-- :DimFortStatus, so users don't have to count toggles to figure out
-- where they are.
function M.status()
  local function flag(v) return v and "on" or "off" end
  local lines = {
    "DimFort status",
    string.format("  executable          : %s", M.config.executable),
    string.format("  inlay hints         : %s", flag(M.config.inlay_hints_enabled)),
    string.format("  completion          : %s", flag(M.config.completion_enabled)),
    string.format("  code actions        : %s", flag(M.config.code_actions_enabled)),
    string.format("  go-to-definition    : %s", flag(M.config.goto_definition_enabled)),
    string.format("  hover               : %s", M.config.hover),
    string.format("  cache               : %s", M.config.cache_mode),
    string.format("  scale checking      : %s", M.config.scale_mode),
    string.format("  cache dir           : %s",
                  (M.config.cache_dir == "") and "(default)" or M.config.cache_dir),
    string.format("  max workset size    : %d", M.config.max_workset_size),
    string.format("  external modules    : %s",
                  (next(M.config.external_modules) == nil) and "(none)"
                  or table.concat(M.config.external_modules, ", ")),
    string.format("  active client id    : %s", tostring(active_client_id or "(none)")),
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Run on every LspAttach for a DimFort client. Enables Neovim's
-- buffer-local inlay-hint rendering when the server flag is on,
-- disables it otherwise — so the user doesn't have to manage the
-- client-side toggle separately from the server one.
--
-- There's a race on initial attach: vim.lsp.inlay_hint.enable fires
-- a request before the server has finished its initial workspace
-- check, so the server returns nothing and Neovim caches "no
-- hints". We kick a refresh a moment later (toggle off→on) to
-- coerce Neovim into re-requesting; by then the server has
-- ``_last_result`` populated and returns real hints. The refresh
-- becomes redundant once DimFort itself emits
-- ``workspace/inlayHint/refresh`` after each check, but the
-- belt-and-braces is cheap and works against older server builds.
local function on_attach(args)
  local client = vim.lsp.get_client_by_id(args.data.client_id)
  if not client or client.name ~= "dimfort" then return end
  active_client_id = client.id

  -- Show "H001: Assignment unit mismatch: …" as end-of-line virtual
  -- text. Scoped to DimFort's diagnostic namespace via the second
  -- argument to vim.diagnostic.config, so it doesn't affect other
  -- LSP servers the user might have running.
  --
  -- The config table replaces (does not merge with) the namespace's
  -- prior render config — so we re-state ``signs`` and ``underline``
  -- here, otherwise the gutter sign and squiggle vanish. The whole
  -- call is wrapped in pcall so any failure here can't abort the
  -- on_attach handler before the inlay-hint setup below runs.
  local ok_ns, ns = pcall(vim.lsp.diagnostic.get_namespace, client.id)
  if ok_ns and ns then
    pcall(vim.diagnostic.config, {
      signs = true,
      underline = true,
      virtual_text = {
        spacing = 2,
        format = function(d)
          local code = d.code
            or (d.user_data and d.user_data.lsp and d.user_data.lsp.code)
          if code then
            return string.format("%s: %s", code, d.message)
          end
          return d.message
        end,
      },
      severity_sort = true,
    }, ns)
  end

  -- Hover border: install a buffer-local ``K`` mapping that calls
  -- vim.lsp.buf.hover with the configured border. Buffer-local so it
  -- only applies to DimFort-attached buffers (other LSPs' hovers
  -- untouched) and so ``vim.lsp.buf.hover``'s ``config`` reliably
  -- flows through to ``open_floating_preview`` (the global-handler
  -- wrap approach was unreliable across Neovim versions because the
  -- LSP response-routing doesn't always pass ``config`` through).
  if M.config.hover_border ~= "none"
    and vim.lsp.buf and vim.lsp.buf.hover then
    pcall(vim.keymap.set, "n", "K", function()
      vim.lsp.buf.hover({ border = M.config.hover_border })
    end, { buffer = args.buf, desc = "DimFort hover" })
  end

  if not (vim.lsp.inlay_hint and vim.lsp.inlay_hint.enable) then return end
  pcall(vim.lsp.inlay_hint.enable,
        M.config.inlay_hints_enabled,
        { bufnr = args.buf })
  -- DimFort emits ``workspace/inlayHint/refresh`` after every check
  -- completes; Neovim re-queries automatically. No client-side
  -- defer dance needed.
end

-- One-shot setup. Call from your init.lua / lazy spec:
--   require("dimfort").setup({ executable = "/path/to/dimfort" })
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Muted slate fg + italic so inlay-hint ghost text reads as
  -- annotation rather than code. We set ``ctermfg`` alongside the
  -- truecolor ``fg`` so 256-color terminals (notably macOS
  -- Terminal.app) get a sensible value rather than a poor
  -- approximation of the hex. No ``default = true`` — stock
  -- Neovim's ``LspInlayHint`` inherits from ``NonText`` or
  -- ``Comment`` which on plain colorschemes can come out
  -- visually identical to code, so we actively override. Users
  -- who want custom styling can `:hi LspInlayHint …` after setup.
  vim.api.nvim_set_hl(0, "LspInlayHint", {
    fg = "#7c8499",
    ctermfg = 245,
    italic = true,
  })

  -- Hover border is installed per-buffer in ``on_attach`` (see comment
  -- there) — buffer-local so it scopes correctly to DimFort buffers
  -- without touching other LSPs and so vim.lsp.buf.hover's config
  -- reaches open_floating_preview reliably across Neovim versions.

  vim.api.nvim_create_user_command("DimFortCheckWorkspace",
    function() M.check_workspace() end,
    { desc = "DimFort: run the workspace-wide unit check" })
  vim.api.nvim_create_user_command("DimFortRestart",
    function() M.restart() end,
    { desc = "DimFort: restart the language server" })
  vim.api.nvim_create_user_command("DimFortStatus",
    function() M.status() end,
    { desc = "DimFort: print current feature toggles and client state" })
  vim.api.nvim_create_user_command("DimFortToggleInlayHints",
    function() M.toggle_inlay_hints() end,
    { desc = "DimFort: toggle inlay hints" })
  vim.api.nvim_create_user_command("DimFortToggleCompletion",
    function() M.toggle_completion() end,
    { desc = "DimFort: toggle unit-name completion" })
  vim.api.nvim_create_user_command("DimFortToggleCodeActions",
    function() M.toggle_code_actions() end,
    { desc = "DimFort: toggle code actions" })
  vim.api.nvim_create_user_command("DimFortToggleGotoDefinition",
    function() M.toggle_goto_definition() end,
    { desc = "DimFort: toggle go-to-definition" })
  vim.api.nvim_create_user_command("DimFortCycleHover",
    function() M.cycle_hover() end,
    { desc = "DimFort: cycle hover verbosity (disabled/short/detailed)" })
  vim.api.nvim_create_user_command("DimFortToggleCache",
    function() M.toggle_cache() end,
    { desc = "DimFort: toggle content-hash cache between off and read-write" })
  vim.api.nvim_create_user_command("DimFortCycleScale",
    function() M.cycle_scale() end,
    { desc = "DimFort: cycle scale checking (auto/on/off); auto defers to .dimfort.toml" })
  vim.api.nvim_create_user_command("DimFortCycleCoverage",
    function() M.cycle_coverage() end,
    { desc = "DimFort: cycle coverage visualisation (disabled/gutter/background)" })

  -- Coverage layer setup. The module installs its sign defs +
  -- highlight groups, registers the DiagnosticChanged autocmd that
  -- drives refresh, and applies the configured initial mode. Runs
  -- regardless of `coverage_mode` so the cycle command is wired
  -- even when the layer is `disabled` (the listener no-ops in that
  -- case; cost is one autocmd dispatch per diagnostics event).
  local coverage = require("dimfort.coverage")
  coverage.setup({
    mode = M.config.coverage_mode,
    debounce_ms = M.config.coverage_debounce_ms,
  })

  -- Side panel — opt-in persistent split with the unit-algebra tree
  -- and routine-vars table. Off by default; see
  -- DimFort/docs/design/panel-info.md.
  local panel = require("dimfort.panel")
  panel.config.layout         = M.config.panel_layout
  panel.config.position       = M.config.panel_position
  panel.config.width_fraction = M.config.panel_width_fraction
  panel.config.width_cols     = M.config.panel_width_cols
  panel.config.debounce_ms    = M.config.panel_debounce_ms
  panel.install_autocmds()
  -- Coverage stats: refresh the active buffer's file-coverage on every
  -- DiagnosticChanged event from DimFort, and mark any cached workspace
  -- snapshot stale so the footer's WS segment dims. See lua/dimfort/stats.lua.
  do
    local stats_mod = require("dimfort.stats")
    -- Register the dimfort/workspaceCheckCompleted notification
    -- handler used by the async workspace check (DimFort 0.2.5+).
    -- See stats.lua.
    stats_mod.install_handlers()
    local stats_group = vim.api.nvim_create_augroup("DimFortStats", { clear = true })
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      group = stats_group,
      callback = function(args)
        local buf = args.buf or vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype ~= "fortran" then return end
        stats_mod.on_diagnostics_changed(buf)
      end,
    })
    -- Stale-mark on user edits only (not on server publishDiagnostics
    -- events, which DiagnosticChanged also fires for — including the
    -- big post-workspace-check fan-out that would otherwise dim the
    -- bar instantly after every refresh completed).
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = stats_group,
      callback = function(args)
        local buf = args.buf or vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype ~= "fortran" then return end
        stats_mod.on_text_changed()
      end,
    })
  end
  vim.api.nvim_create_user_command("DimFortRefreshWorkspace",
    function() M.check_workspace() end,
    { desc = "DimFort: refresh whole-workspace coverage (alias for "
      .. ":DimFortCheckWorkspace)" })
  vim.api.nvim_create_user_command("DimFortTogglePanel",
    function() panel.toggle() end,
    { desc = "DimFort: open/close the side panel" })
  vim.api.nvim_create_user_command("DimFortPanelLayout",
    function(args) panel.set_layout(args.args) end,
    {
      nargs = 1,
      complete = function() return { "both", "expression", "routine" } end,
      desc = "DimFort: switch panel layout (both | expression | routine)",
    })
  vim.api.nvim_create_user_command("DimFortPanelRefresh",
    function() panel.refresh() end,
    { desc = "DimFort: force-refresh the side panel" })
  vim.api.nvim_create_user_command("DimFortScopeFilter",
    function(args) panel.set_filter(args.args) end,
    {
      nargs = "?",
      desc = "DimFort: filter the panel's Scope section by name/unit "
        .. "(no argument clears it)",
    })
  vim.api.nvim_create_user_command("DimFortImportsFilter",
    function(args) panel.set_imports_filter(args.args) end,
    {
      nargs = "?",
      desc = "DimFort: filter the panel's Imports section by name/unit/"
        .. "module (no argument clears it)",
    })
  if M.config.panel_enabled then
    -- Open after the LSP attach has had time to settle.
    vim.defer_fn(function() panel.open() end, 500)
  end

  local group = vim.api.nvim_create_augroup("DimFort", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = on_attach,
  })
  if M.config.auto_attach then
    -- FileType fires on initial buffer load (covers the ``-c`` startup
    -- path and any direct ``:edit`` of a not-yet-buffered file).
    -- BufEnter additionally covers entering an already-loaded buffer
    -- whose FileType event has already fired and won't fire again —
    -- e.g. navigating between files via netrw's directory listing
    -- (``:e .``), where the second-and-subsequent fortran buffers
    -- otherwise leave the LSP unattached. ``M.attach`` is idempotent
    -- (``vim.lsp.start`` dedupes by name+root_dir AND by bufnr); the
    -- cheap pre-check below avoids even that round-trip on every
    -- BufEnter into an already-attached buffer.
    vim.api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
      group = group,
      callback = function(ev)
        local buf = ev.buf
        if not vim.tbl_contains(M.config.filetypes, vim.bo[buf].filetype) then
          return
        end
        if #vim.lsp.get_clients({ name = "dimfort", bufnr = buf }) > 0 then
          return
        end
        M.attach(buf)
      end,
    })
  end
end

return M
