-- DimFort language-server client for Neovim.
--
-- Mirrors the VSCode companion's feature set: registers `dimfort lsp`
-- with the built-in LSP client, forwards `initializationOptions`,
-- exposes the same per-feature toggle commands, and wires up
-- `dimfort.insertSnippet` so the U005 code action works.

local M = {}

---@class DimFortConfig
---@field executable string                    -- path to the `dimfort` binary
---@field inlay_hints_enabled boolean
---@field completion_enabled boolean
---@field code_actions_enabled boolean
---@field goto_definition_enabled boolean
---@field code_lens_enabled boolean
---@field max_workset_size integer
---@field external_modules string[]
---@field filetypes string[]                   -- buffers DimFort attaches to
---@field root_markers string[]                -- files marking the workspace root
---@field auto_attach boolean                  -- attach automatically via FileType autocmd
local defaults = {
  executable = "dimfort",
  inlay_hints_enabled = true,
  completion_enabled = true,
  code_actions_enabled = true,
  goto_definition_enabled = true,
  code_lens_enabled = true,
  max_workset_size = 40,
  external_modules = {},
  filetypes = { "fortran" },
  root_markers = { ".dimfort.toml", ".git" },
  auto_attach = true,
}

---@type DimFortConfig
M.config = vim.deepcopy(defaults)

-- The currently-active LSP client id for DimFort, if any. We track it
-- ourselves rather than re-scanning vim.lsp.get_clients() each time so
-- :DimFortRestart is fast and unambiguous.
local active_client_id = nil

-- Internal: builds the initializationOptions table the server expects.
local function init_options()
  return {
    inlayHintsEnabled = M.config.inlay_hints_enabled,
    completionEnabled = M.config.completion_enabled,
    codeActionsEnabled = M.config.code_actions_enabled,
    gotoDefinitionEnabled = M.config.goto_definition_enabled,
    codeLensEnabled = M.config.code_lens_enabled,
    maxWorksetSize = M.config.max_workset_size,
    externalModules = M.config.external_modules,
  }
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

  -- Strip `${N}` and `${N:default}` placeholders, capturing where the
  -- final cursor (`$0` or `${0}`) lands so we can move there after.
  local cursor_offset = nil
  local plain = snippet
    :gsub("%${0}", function()
      cursor_offset = 0
      return ""
    end)
    :gsub("%$0", function()
      cursor_offset = 0
      return ""
    end)
    :gsub("%${%d+:([^}]*)}", "%1")
    :gsub("%${%d+}", "")

  local lines = vim.split(plain, "\n", { plain = true })
  vim.api.nvim_buf_set_text(bufnr, line, character, line, character, lines)

  -- Show the buffer and move the cursor if the snippet had a `$0`.
  vim.api.nvim_set_current_buf(bufnr)
  if cursor_offset and #lines > 0 then
    local last = lines[#lines]
    local target_line = line + #lines - 1
    local target_col = (#lines == 1) and (character + #last) or #last
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line + 1, target_col })
  end
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
function M.restart()
  if active_client_id then
    local client = vim.lsp.get_client_by_id(active_client_id)
    if client then
      client:stop()
    end
    active_client_id = nil
  end
  -- Defer the re-attach so vim.lsp.stop's cleanup finishes first.
  vim.defer_fn(function()
    M.attach()
    vim.notify("DimFort: language server restarted", vim.log.levels.INFO)
  end, 100)
end

-- Run the workspace check via workspace/executeCommand.
function M.check_workspace()
  local client = active_client_id and vim.lsp.get_client_by_id(active_client_id)
  if not client then
    vim.notify("DimFort: no active language client", vim.log.levels.WARN)
    return
  end
  client:request("workspace/executeCommand", {
    command = "dimfort.checkWorkspace",
    arguments = {},
  }, function(err)
    if err then
      vim.notify("DimFort: checkWorkspace failed — " .. tostring(err.message),
                 vim.log.levels.ERROR)
    end
  end)
end

-- Flip a feature flag and restart so the new initializationOptions
-- take effect. ``key`` is the field name on M.config (snake_case).
local function toggle(key, label)
  M.config[key] = not M.config[key]
  vim.notify(
    string.format("DimFort: %s %s", label, M.config[key] and "on" or "off"),
    vim.log.levels.INFO
  )
  M.restart()
end

M.toggle_inlay_hints      = function() toggle("inlay_hints_enabled",      "inlay hints")        end
M.toggle_completion       = function() toggle("completion_enabled",       "unit completion")    end
M.toggle_code_actions     = function() toggle("code_actions_enabled",     "code actions")       end
M.toggle_goto_definition  = function() toggle("goto_definition_enabled",  "go-to-definition")   end
M.toggle_code_lens        = function() toggle("code_lens_enabled",        "code lens")          end

-- Print the current feature flags + client state. Bound to
-- :DimFortStatus, so users don't have to count toggles to figure out
-- where they are.
function M.status()
  local function flag(v) return v and "on" or "off" end
  local lines = {
    "DimFort status",
    string.format("  executable        : %s", M.config.executable),
    string.format("  inlay hints       : %s", flag(M.config.inlay_hints_enabled)),
    string.format("  completion        : %s", flag(M.config.completion_enabled)),
    string.format("  code actions      : %s", flag(M.config.code_actions_enabled)),
    string.format("  go-to-definition  : %s", flag(M.config.goto_definition_enabled)),
    string.format("  code lens         : %s", flag(M.config.code_lens_enabled)),
    string.format("  max workset size  : %d", M.config.max_workset_size),
    string.format("  external modules  : %s",
                  (next(M.config.external_modules) == nil) and "(none)"
                  or table.concat(M.config.external_modules, ", ")),
    string.format("  active client id  : %s", tostring(active_client_id or "(none)")),
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Run on every LspAttach for a DimFort client. Enables Neovim's
-- buffer-local inlay-hint rendering when the server flag is on,
-- disables it otherwise — so the user doesn't have to manage the
-- client-side toggle separately from the server one.
local function on_attach(args)
  local client = vim.lsp.get_client_by_id(args.data.client_id)
  if not client or client.name ~= "dimfort" then return end
  active_client_id = client.id
  if vim.lsp.inlay_hint and vim.lsp.inlay_hint.enable then
    pcall(vim.lsp.inlay_hint.enable,
          M.config.inlay_hints_enabled,
          { bufnr = args.buf })
  end
end

-- One-shot setup. Call from your init.lua / lazy spec:
--   require("dimfort").setup({ executable = "/path/to/dimfort" })
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

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
  vim.api.nvim_create_user_command("DimFortToggleCodeLens",
    function() M.toggle_code_lens() end,
    { desc = "DimFort: toggle code lens" })

  local group = vim.api.nvim_create_augroup("DimFort", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = on_attach,
  })
  if M.config.auto_attach then
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = M.config.filetypes,
      callback = function(ev) M.attach(ev.buf) end,
    })
  end
end

return M
