-- Coverage stats provider for the side-panel footer bar.
--
-- Mirrors the VSCompanion ``CoverageStatsProvider`` (src/stats.ts).
-- Owns three pieces of state:
--   1. File-scope cache keyed by buffer URI. Refreshed live via
--      ``dimfort/coverageStats`` whenever the active buffer's diagnostics
--      change (cheap; the server keeps a per-file cache).
--   2. Workspace-scope snapshot. Populated ONLY by the user invoking
--      :DimFortCheckWorkspace (workspace/executeCommand
--      dimfort/checkWorkspace). The wire response carries the fresh
--      aggregate so we don't have to round-trip a second request.
--   3. wsStale flag — set once any diagnostics change after the last
--      successful workspace refresh, so the panel dims the Project segment
--      to signal "may no longer reflect current state."
--
-- The panel subscribes via ``M.on_change(fn)`` and re-renders its footer.
--
-- Spinner: while a workspace refresh is in flight, ``wsRefreshing`` is
-- true and a 80 ms repeating timer paints frames of the Braille spinner
-- (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) by firing on_change. The panel renders the current
-- frame in place of the WS value. The timer self-cancels when refresh
-- ends.

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 80

local state = {
  file = {},               -- uri (string) -> FileCoverage
  workspace = nil,         -- WorkspaceCoverage | nil
  ws_stale = false,
  ws_refreshing = false,
  ws_req_seq = 0,
  file_req_seq = {},       -- uri -> sequence
  spinner_frame = 1,
  spinner_timer = nil,
  listeners = {},
}

local function present(v)
  return v ~= nil and v ~= vim.NIL
end

local function fire()
  for _, cb in ipairs(state.listeners) do
    -- audited(0.2.7): silent-OK — a listener throwing here must not
    -- block other listeners from firing or take down the workspace-
    -- stats refresh flow. A listener bug surfaces as that listener's
    -- specific UI element going stale; the rest stay current. The
    -- alternative (raise + abort fan-out) would couple unrelated UI
    -- elements to each other.
    pcall(cb)
  end
end

-- Subscribe to stats-change events. Returns nothing; there's no
-- unsubscribe — the panel is the only consumer and lives for the
-- session.
function M.on_change(cb)
  table.insert(state.listeners, cb)
end

function M.snapshot(uri)
  return {
    file = uri and state.file[uri] or nil,
    workspace = state.workspace,
    ws_stale = state.ws_stale,
    ws_refreshing = state.ws_refreshing,
    spinner = FRAMES[state.spinner_frame],
  }
end

local function active_dimfort_client()
  local clients = vim.lsp.get_clients({ name = "dimfort" })
  return clients[1]
end

local function from_row(r)
  return {
    ok = r.ok or 0,
    warn = r.warn or 0,
    fire = r.fire or 0,
    unparsed = r.unparsed or 0,
    coverage_pct = r.coverage_pct or 0,
  }
end

-- Refresh file-scope stats for ``uri`` (e.g. ``file:///path/to/x.f90``).
-- Returns immediately; the LSP callback fires on_change once the
-- response lands.
function M.refresh_file(uri)
  if not uri or uri == "" then return end
  local client = active_dimfort_client()
  if not client then return end
  local seq = (state.file_req_seq[uri] or 0) + 1
  state.file_req_seq[uri] = seq
  client:request("dimfort/coverageStats", { uri = uri }, function(err, resp)
    if err or not resp then return end
    -- Drop stale responses (another request for the same URI raced ahead).
    if (state.file_req_seq[uri] or 0) ~= seq then return end
    if not present(resp.files) or #resp.files == 0 then
      state.file[uri] = nil
    else
      state.file[uri] = from_row(resp.files[1])
    end
    fire()
  end)
end

local function stop_spinner()
  if state.spinner_timer then
    state.spinner_timer:stop()
    state.spinner_timer:close()
    state.spinner_timer = nil
  end
end

local function start_spinner()
  stop_spinner()
  local timer = vim.uv.new_timer()
  state.spinner_timer = timer
  timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, vim.schedule_wrap(function()
    state.spinner_frame = (state.spinner_frame % #FRAMES) + 1
    fire()
  end))
end

-- Handler for ``dimfort/workspaceCheckCompleted`` notifications.
-- Since DimFort 0.2.5 the workspace check runs on a server-side
-- daemon thread; the executeCommand returns an ack immediately, and
-- the fresh coverage payload arrives later via this notification.
-- The handler clears the in-flight spinner and updates state.
local function handle_workspace_check_completed(_, resp, _ctx)
  if not state.ws_refreshing then return end
  state.ws_refreshing = false
  stop_spinner()
  if present(resp) and not resp.failed and present(resp.total) then
    state.workspace = from_row(resp.total)
    state.ws_stale = false
  end
  fire()
end

-- Register the notification handler. Called once at setup; safe to
-- call multiple times (assigns into the same global table).
function M.install_handlers()
  vim.lsp.handlers["dimfort/workspaceCheckCompleted"] =
    handle_workspace_check_completed
end

-- Run a workspace refresh via workspace/executeCommand dimfort/checkWorkspace.
-- Async since 0.2.5: the server returns {started: bool} immediately and
-- fires dimfort/workspaceCheckCompleted when the actual check finishes.
-- Spinner runs continuously until the completion notification arrives.
function M.refresh_workspace(on_done)
  local client = active_dimfort_client()
  if not client then
    if on_done then on_done(false) end
    return
  end
  if state.ws_refreshing then
    -- Local coalesce: don't send a duplicate executeCommand, but do
    -- tell the user. The server-side coalesce toast (kicked off
    -- from cross-client triggers) never reaches us because we never
    -- sent the request — so the user-feedback responsibility lives
    -- here on the client.
    vim.notify("DimFort: workspace check already in progress",
               vim.log.levels.INFO)
    if on_done then on_done(true) end
    return
  end
  state.ws_refreshing = true
  state.spinner_frame = 1
  start_spinner()
  fire()
  client:request("workspace/executeCommand", {
    command = "dimfort/checkWorkspace",
    arguments = {},
  }, function(err, ack)
    -- We're acknowledging the ack only. The real payload arrives
    -- later via the dimfort/workspaceCheckCompleted notification.
    if err then
      -- audited(0.2.7): error-surfacing — workspace/executeCommand
      -- error response (transport error, server unavailable, etc.)
      -- previously silently cleared the spinner and the user saw
      -- nothing happen after :DimFortCheckWorkspace. Toast so the
      -- user knows the request failed at the wire level (distinct
      -- from the server-toasted started:false refusal handled
      -- below).
      state.ws_refreshing = false
      stop_spinner()
      fire()
      vim.notify(
        "DimFort: workspace check request failed — "
          .. (err.message or vim.inspect(err)),
        vim.log.levels.ERROR
      )
      if on_done then on_done(false) end
      return
    end
    if present(ack) and ack.started == false then
      -- audited(0.2.7): silent-OK — the server toasts the user-
      -- visible refusal reason ("already in progress" / "index not
      -- ready" / "no files found") via window/showMessage BEFORE
      -- returning the started:false ack. Nvim's stock LSP handler
      -- for window/showMessage routes that to vim.notify, so the
      -- user already sees an explanatory popup. Adding a second
      -- vim.notify here would double-warn the same event.
      -- Companion's silence on this branch is by design — we just
      -- reset the spinner state so the panel reflects the
      -- non-refreshing condition.
      state.ws_refreshing = false
      stop_spinner()
      fire()
    end
    if on_done then on_done(true) end
  end)
end

-- Called from the DiagnosticChanged autocmd. Refreshes the active
-- file's stats. Stale-marking for the workspace snapshot is NOT
-- done here — it lives in M.on_text_changed below. DiagnosticChanged
-- fires from the server's own post-check publishDiagnostics fan-out
-- (~2435 files on a real-world codebase), which would immediately
-- flip ws_stale back to true after the workspace check completion
-- handler had just cleared it.
function M.on_diagnostics_changed(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local ok, uri = pcall(vim.uri_from_bufnr, buf)
  if ok and uri and uri ~= "" then
    M.refresh_file(uri)
  end
end

-- Called from the TextChanged / TextChangedI autocmds. Marks the
-- workspace snapshot stale once we have one. User-edit signal only;
-- doesn't fire on server-side publishDiagnostics or other LSP traffic.
function M.on_text_changed()
  if state.workspace ~= nil and not state.ws_stale then
    state.ws_stale = true
    fire()
  end
end

-- Reset all caches (LSP restart). Workspace snapshot is intentionally
-- preserved across the active-editor change so the bar doesn't flash a
-- ``Project: –`` between every file switch; only the LSP restart drops it.
function M.reset()
  state.file = {}
  state.workspace = nil
  state.ws_stale = false
  state.ws_refreshing = false
  stop_spinner()
  fire()
end

return M
