-- DimFort side panel for Neovim.
--
-- Persistent split window, cursor-following with a debounce. Mirrors the
-- VSCode companion's panel — five stacked sections:
--   1. Expression  — unit-algebra tree under the cursor
--   2. Diagnostics — DimFort diagnostics on the cursor line (🔴/🟡/🔵)
--   3. Interactions — cross-site unit constraints for the symbol at cursor
--   4. Actions     — code actions available at the cursor (apply with <CR>)
--   5. Scope       — stacked enclosing-scope declaration tables, with a
--                    name/unit filter (:DimFortPanelFilter)
--
-- Rows are navigable: press <CR> on a declaration / diagnostic / site to
-- jump to it (cross-file for interactions), or on an action to apply it.
--
-- Off by default; toggle via :DimFortTogglePanel. Layout switches via
-- :DimFortPanelLayout {both|expression|routine} — the volatile
-- Diagnostics / Interactions / Actions sections show in the "both" layout.
--
-- Wire protocol: ``dimfort/panelInfo`` + ``dimfort/interactions`` LSP
-- requests and ``textDocument/codeAction`` — see
-- DimFort/docs/design/panel-info.md and interaction-points.md.

local M = {}

---@class DimFortPanelConfig
---@field enabled boolean
---@field layout "both"|"expression"|"routine"
---@field position "right"|"left"|"bottom"
---@field width_fraction number       -- 0.0 - 1.0 of editor width
---@field debounce_ms integer
M.config = {
  enabled = false,
  layout = "both",
  position = "right",
  width_fraction = 0.35,
  width_cols = nil,          -- if set (integer), wins over width_fraction
  debounce_ms = 200,
}

-- Internal state. ``win`` / ``buf`` are the panel's window and buffer
-- handles; both nil when the panel isn't open.
local state = {
  win = nil,
  buf = nil,
  ns = vim.api.nvim_create_namespace("DimFortPanel"),
  pending_timer = nil,
  req_id = 0,                -- bundle sequence; late responses are dropped
  source_winid = nil,        -- the editor window the panel is following
  source_bufnr = nil,
  last_payload = nil,        -- cached last panelInfo response
  last_interactions = nil,   -- cached last interactions report
  last_actions = nil,        -- cached last code-action list
  scope_filter = "",         -- client-side Scope name/unit filter
  -- Per-rendered-line navigation targets, rebuilt on every paint.
  -- targets[i] is nil (inert) or { line=, column=, file=, end_line=,
  -- end_column= } for a jump, or { action = <CodeAction> } to apply.
  targets = {},
}

-- Headers + dividers shown in the panel.
local DIVIDER = string.rep("─", 60)

-- ---------------------------------------------------------------------------
-- Rendering
--
-- A *canvas* accumulates display rows alongside a parallel array of
-- navigation targets, so <CR> on any row knows what (if anything) it
-- points at. ``emit(cv, row[, target])`` keeps the two in lockstep.

local MARKER = { ok = "🟢", warn = "🟡", error = "🔴" }

-- Neovim deserializes JSON ``null`` to ``vim.NIL`` — a userdata value
-- that's NOT equal to Lua ``nil`` and IS truthy. Every field we read
-- off an LSP response must be guarded against it, otherwise indexing
-- explodes with "attempt to index a userdata value".
local function present(v)
  return v ~= nil and v ~= vim.NIL
end

local function val(v, default)
  if present(v) then return v end
  return default
end

local function new_canvas()
  return { rows = {}, targets = {} }
end

local function emit(cv, row, target)
  table.insert(cv.rows, row)
  -- Store the target at the same index (may be nil — a hole is fine).
  cv.targets[#cv.rows] = target
end

local function marker_for(node)
  return MARKER[present(node) and node.marker] or " "
end

-- Strip a leading ``file://`` scheme so a wire path opens with :edit.
local function as_path(s)
  s = tostring(s or "")
  local stripped = s:gsub("^file://", "")
  -- vim.uri_to_fname handles percent-encoding; fall back to the raw text.
  if s:match("^file://") then
    local ok, p = pcall(vim.uri_to_fname, s)
    if ok and p and p ~= "" then return p end
  end
  return stripped
end

local function base_name(p)
  return tostring(p or ""):match("[^/\\]+$") or tostring(p or "")
end

-- Recursively collect tree entries as ``{tree, unit, mark, rule}``
-- records. ``tree`` is the tree-drawing prefix + label; ``unit`` is
-- the unit string (or nil for statements). Kept separate so the
-- renderer can align both the ``: unit`` column and the marker column.
local function collect_expression(node, prefix, is_last, is_root, entries)
  if not present(node) then return end
  local connector
  local next_prefix
  if is_root then
    connector = ""
    next_prefix = prefix
  elseif is_last then
    connector = "└── "
    next_prefix = prefix .. "    "
  else
    connector = "├── "
    next_prefix = prefix .. "│   "
  end
  local has_unit = present(node.unit)
  local rule_id = present(node.ruleId) and node.ruleId or nil
  local rule = rule_id and (" (" .. rule_id .. ")") or ""
  local mark = marker_for(node)
  local label = present(node.label) and node.label or "?"
  table.insert(entries, {
    tree = prefix .. connector .. label,
    unit = has_unit and node.unit or nil,
    mark = mark,
    rule = rule,
  })
  local children = (present(node.children) and node.children) or {}
  for i, c in ipairs(children) do
    collect_expression(c, next_prefix, i == #children, false, entries)
  end
end

-- Render the expression tree into the canvas with two aligned columns:
-- the ``: unit`` block and the 🟢/🟡/🔴 marker. Padding uses display
-- width (``strdisplaywidth``) so multi-byte box-drawing chars and unit
-- glyphs don't throw the alignment off. Statement rows (no unit) leave
-- the unit column blank but still align their markers.
local function render_expression(cv, node)
  local entries = {}
  collect_expression(node, "", true, true, entries)
  -- Column 1: the tree-label width. Column 2: the unit width.
  local tree_w, unit_w = 0, 0
  for _, e in ipairs(entries) do
    tree_w = math.max(tree_w, vim.fn.strdisplaywidth(e.tree))
    if e.unit then unit_w = math.max(unit_w, vim.fn.strdisplaywidth(e.unit)) end
  end
  for _, e in ipairs(entries) do
    local tree_pad = string.rep(" ", tree_w - vim.fn.strdisplaywidth(e.tree))
    local mid
    if e.unit then
      local unit_pad = string.rep(" ", unit_w - vim.fn.strdisplaywidth(e.unit))
      mid = " : " .. e.unit .. unit_pad
    elseif unit_w > 0 then
      -- No unit on this row, but other rows have one — pad the whole
      -- ``: unit`` block with spaces so the marker still lines up.
      mid = string.rep(" ", 3 + unit_w)
    else
      mid = ""
    end
    emit(cv, e.tree .. tree_pad .. mid .. "  " .. e.mark .. e.rule)
  end
end

-- Capitalize the scope kind for the header (subroutine → Subroutine).
local function titlecase(s)
  if not s or s == "" then return s end
  return s:sub(1, 1):upper() .. s:sub(2)
end

-- ``depth`` (0 = outermost) indents inner scopes so the nesting reads
-- visually — a module-contained subroutine sits one level in from the
-- module. Two spaces per level; depth rarely exceeds 1 (module →
-- routine) so the horizontal cost is small.
local function render_scope_vars(cv, scope, vars, depth)
  local pad = string.rep("  ", depth or 0)
  if present(scope) then
    -- e.g. "Subroutine: driver", "Module: constants_mod".
    emit(cv, pad .. string.format("%s: %s",
                                  titlecase(scope.kind), scope.name))
  else
    emit(cv, pad .. "Scope: (file level)")
  end
  emit(cv, "")
  vars = (present(vars) and vars) or {}
  if #vars == 0 then
    emit(cv, pad .. "  (no declarations)")
    return
  end
  -- Compute column widths over the *displayed* strings so the markers
  -- line up — "(none)" for unannotated counts toward the unit width.
  local name_w, unit_w = 4, 4
  for _, v in ipairs(vars) do
    name_w = math.max(name_w, #v.name)
    local shown_unit = present(v.unit) and v.unit or "(none)"
    unit_w = math.max(unit_w, #shown_unit)
  end
  for _, v in ipairs(vars) do
    local unit = present(v.unit) and v.unit or "(none)"
    -- Every row gets a marker: 🟢 annotated, 🟡 unannotated, 🔴 the
    -- annotation is present but failed to parse (U002). Matches the
    -- expression-tree convention so the whole panel reads the same.
    local tail
    if v.kind == "unannotated" then
      tail = " 🟡"
    elseif v.kind == "error" then
      tail = " 🔴"
    else
      tail = " 🟢"
    end
    emit(cv, pad .. string.format("  %4d  %-" .. name_w .. "s  %-" ..
                                  unit_w .. "s%s",
                                  v.line, v.name, unit, tail),
         { line = v.line })
  end
end

-- Case-insensitive substring match used by the Scope filter.
local function matches_filter(v, q)
  if q == "" then return true end
  local name = (v.name or ""):lower()
  if name:find(q, 1, true) then return true end
  local unit = present(v.unit) and v.unit:lower() or ""
  return unit ~= "" and unit:find(q, 1, true) ~= nil
end

-- The Scope section: stacked enclosing scopes, outermost first, with the
-- active name/unit filter applied. Mirrors the VSCode panel's filter box.
local function render_scope(cv, payload)
  local q = (state.scope_filter or ""):lower()
  if q ~= "" then
    emit(cv, 'Filter: "' .. state.scope_filter .. '"  (:DimFortPanelFilter to change)')
    emit(cv, "")
  end
  if present(payload) and present(payload.scopes) and #payload.scopes > 0 then
    local shown_any = false
    for i, sc in ipairs(payload.scopes) do
      local all = (present(sc.vars) and sc.vars) or {}
      local kept = {}
      for _, v in ipairs(all) do
        if matches_filter(v, q) then table.insert(kept, v) end
      end
      -- While filtering, hide scopes with no surviving variables.
      if q == "" or #kept > 0 then
        if shown_any then emit(cv, "") end
        render_scope_vars(cv, sc, kept, i - 1)
        shown_any = true
      end
    end
    if q ~= "" and not shown_any then
      emit(cv, '  (no variables match "' .. state.scope_filter .. '")')
    end
  elseif present(payload) then
    -- Back-compat with older servers that only send a single scope.
    local scope = present(payload.scope) and payload.scope or payload.routine
    local scope_vars = present(payload.scopeVars) and payload.scopeVars
      or payload.routineVars
    render_scope_vars(cv, scope, scope_vars, 0)
  else
    emit(cv, "Scope: (none)")
  end
end

-- Cursor-line diagnostics. The whole 🔴/🟡/🔵 family so any info-level
-- diagnostic (e.g. P001 unparsed regions) reads the same as the others.
local function render_diagnostics(cv, diags)
  diags = (present(diags) and diags) or {}
  if #diags == 0 then
    emit(cv, "  (none)")
    return
  end
  for _, d in ipairs(diags) do
    local sev = present(d.severity) and d.severity or "info"
    local glyph = (sev == "error") and "🔴"
      or (sev == "warning") and "🟡" or "🔵"
    local code = present(d.code) and d.code or "?"
    local msg = present(d.message) and d.message or ""
    emit(cv, "  " .. glyph .. " " .. code .. ": " .. msg, {
      line = d.line, column = d.column,
      end_line = present(d.endLine) and d.endLine or nil,
      end_column = present(d.endColumn) and d.endColumn or nil,
    })
  end
end

-- Interactions: the symbol under the cursor, its use-sites grouped by the
-- constraint each places on its unit, and any X001 conflict. Mirrors the
-- 'dimfort interactions' CLI; rows navigate cross-file.
local INTERACTION_GROUPS = {
  { kind = "declares", label = "Declaration" },
  { kind = "contributes", label = "Write" },
  { kind = "requires", label = "Read" },
  { kind = "uses", label = "Undetermined read" },
}

local function render_interactions(cv, rep)
  if not present(rep) or not present(rep.points) or #rep.points == 0 then
    emit(cv, "  (none)")
    return
  end
  emit(cv, "  " .. (present(rep.symbol) and rep.symbol or "?"))
  -- Conflicts first — the headline.
  for _, c in ipairs((present(rep.conflicts) and rep.conflicts) or {}) do
    emit(cv, "  🔴 " .. val(c.code, "?") .. ": " .. val(c.message, ""), {
      file = c.file, line = c.line, column = c.column,
    })
  end
  for _, group in ipairs(INTERACTION_GROUPS) do
    local pts = {}
    for _, p in ipairs(rep.points) do
      if p.kind == group.kind then table.insert(pts, p) end
    end
    emit(cv, "  " .. group.label)
    if #pts == 0 then
      emit(cv, "      (none)")
    else
      for _, p in ipairs(pts) do
        local loc = base_name(as_path(p.file)) .. ":" .. tostring(p.line)
        -- The Undetermined group has no derived unit by definition.
        local unit = (group.kind ~= "uses" and present(p.unit))
          and ("   " .. p.unit) or ""
        local target = { file = p.file, line = p.line, column = p.column }
        emit(cv, "      " .. loc .. unit, target)
        if present(p.snippet) and p.snippet ~= "" then
          emit(cv, "        " .. p.snippet, target)
        end
      end
    end
  end
end

-- Actions available at the cursor — code actions (Add @unit{} / extract
-- to PARAMETER). <CR> on a row applies it. ``actions`` is the raw
-- CodeAction list as returned by the server.
local function render_actions(cv, actions)
  actions = (present(actions) and actions) or {}
  if #actions == 0 then
    emit(cv, "  (none)")
    return
  end
  for _, a in ipairs(actions) do
    local title = (present(a.title) and a.title or "(action)")
      :gsub("^DimFort:%s*", "")
    emit(cv, "  • " .. title, { action = a })
  end
end

-- Append a titled, divided section to the canvas.
local function add_section(cv, title, body_fn)
  emit(cv, title)
  emit(cv, "")
  body_fn(cv)
  emit(cv, "")
end

local function render_all()
  local cv = new_canvas()
  local payload = state.last_payload
  local layout = M.config.layout

  if layout == "both" or layout == "expression" then
    add_section(cv, "Expression", function(c)
      if present(payload) and present(payload.expression) then
        render_expression(c, payload.expression)
      else
        emit(c, "  (none)")
      end
    end)
  end

  if layout == "both" then
    add_section(cv, "Diagnostics", function(c)
      render_diagnostics(c, present(payload) and payload.diagnostics or {})
    end)
    add_section(cv, "Interactions", function(c)
      render_interactions(c, state.last_interactions)
    end)
    add_section(cv, "Actions", function(c)
      render_actions(c, state.last_actions)
    end)
  end

  if layout == "both" or layout == "routine" then
    if layout == "both" then
      emit(cv, DIVIDER)
      emit(cv, "")
    end
    add_section(cv, "Scope", function(c)
      render_scope(c, payload)
    end)
  end

  -- Footer: whole-file diagnostic counts.
  if layout == "both" and present(payload) and present(payload.fileDiagnosticCounts) then
    local counts = payload.fileDiagnosticCounts
    emit(cv, DIVIDER)
    emit(cv, string.format("File: 🔴 %d   🟡 %d",
                           val(counts.error, 0), val(counts.warning, 0)))
  end

  return cv
end

local function paint(cv, stale)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  state.targets = cv.targets
  vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, cv.rows)
  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
  -- Stale highlight: tint every line as a Comment so the user sees
  -- the panel is mid-update without us blanking the prior content.
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  if stale then
    for i = 0, #cv.rows - 1 do
      vim.api.nvim_buf_set_extmark(state.buf, state.ns, i, 0, {
        end_line = i + 1, hl_group = "Comment",
      })
    end
  end
end

-- Paint a plain message (no targets) — used for transient states.
local function paint_message(lines, stale)
  paint({ rows = lines, targets = {} }, stale)
end

-- ---------------------------------------------------------------------------
-- Navigation + action application (driven by <CR> on a panel row)

-- Jump the source window's cursor to a target's (file, line[, column]).
local function reveal(target)
  local win = state.source_winid
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  vim.api.nvim_set_current_win(win)
  if present(target.file) and target.file ~= "" then
    local path = as_path(target.file)
    if path ~= "" then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    end
  end
  local line = math.max(1, target.line or 1)
  local col = math.max(0, (target.column or 1) - 1)
  pcall(vim.api.nvim_win_set_cursor, 0, { line, col })
  vim.cmd("normal! zz")
end

-- Apply a code action: any workspace edit it carries, then its command
-- (client-registered commands like dimfort.insertSnippet, else a
-- server command via executeCommand).
local function apply_action(action)
  local c = M._client and M._client() or nil
  if not c then
    local clients = vim.lsp.get_clients({ name = "dimfort" })
    c = clients[1]
  end
  -- Re-focus the source window first — the action edits the source buffer.
  if state.source_winid and vim.api.nvim_win_is_valid(state.source_winid) then
    vim.api.nvim_set_current_win(state.source_winid)
  end
  if present(action.edit) then
    local enc = (c and c.offset_encoding) or "utf-16"
    pcall(vim.lsp.util.apply_workspace_edit, action.edit, enc)
  end
  if present(action.command) then
    local cmd = action.command
    local handler = (c and c.commands and c.commands[cmd.command])
      or vim.lsp.commands[cmd.command]
    if handler then
      handler(cmd, { bufnr = state.source_bufnr, client_id = c and c.id })
    elseif c then
      -- Server-side command.
      pcall(function()
        c:exec_cmd(cmd, { bufnr = state.source_bufnr })
      end)
    end
  end
end

-- <CR> handler bound buffer-locally in the panel. Looks up the target for
-- the row under the cursor and either navigates or applies an action.
function M._activate_line()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  local target = state.targets[row]
  if not target then return end
  if present(target.action) then
    apply_action(target.action)
  else
    reveal(target)
  end
end

-- ---------------------------------------------------------------------------
-- Window / buffer lifecycle

local function ensure_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, "DimFort://panel")
  vim.api.nvim_buf_set_option(state.buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.buf, "swapfile", false)
  vim.api.nvim_buf_set_option(state.buf, "filetype", "dimfort-panel")
  -- <CR> on a row navigates / applies; mapped buffer-locally so it
  -- doesn't leak into the user's other buffers.
  vim.keymap.set("n", "<CR>", function() M._activate_line() end, {
    buffer = state.buf, nowait = true, silent = true,
    desc = "DimFort: activate panel row (jump / apply action)",
  })
  return state.buf
end

local function open_window()
  ensure_buffer()
  local total = vim.o.columns
  local width
  if type(M.config.width_cols) == "number" and M.config.width_cols > 0 then
    -- Explicit column count wins. Still clamped to leave at least 30
    -- columns for the source window.
    width = math.min(math.floor(M.config.width_cols),
                     math.max(30, total - 30))
  else
    width = math.max(40, math.min(80,
                                   math.floor(total * M.config.width_fraction)))
  end
  local cmd
  if M.config.position == "left" then
    cmd = "topleft " .. width .. "vnew"
  elseif M.config.position == "bottom" then
    cmd = "botright new"  -- horizontal split
  else
    cmd = "botright " .. width .. "vnew"
  end
  state.source_winid = vim.api.nvim_get_current_win()
  state.source_bufnr = vim.api.nvim_get_current_buf()
  vim.cmd(cmd)
  vim.api.nvim_win_set_buf(0, state.buf)
  state.win = vim.api.nvim_get_current_win()
  -- ``botright`` is supposed to put the new window at the rightmost
  -- (or bottom-most) edge, but with mixed splits it sometimes lands
  -- in the middle. ``wincmd L`` (or ``J`` for bottom) explicitly moves
  -- the current window to the far edge, idempotent if it's already
  -- there. Re-set the width afterwards because the move can reset it.
  if M.config.position == "right" then
    vim.cmd("wincmd L")
    vim.cmd("vertical resize " .. width)
  elseif M.config.position == "left" then
    vim.cmd("wincmd H")
    vim.cmd("vertical resize " .. width)
  elseif M.config.position == "bottom" then
    vim.cmd("wincmd J")
  end
  vim.api.nvim_win_set_option(state.win, "number", false)
  vim.api.nvim_win_set_option(state.win, "relativenumber", false)
  vim.api.nvim_win_set_option(state.win, "signcolumn", "no")
  vim.api.nvim_win_set_option(state.win, "wrap", false)
  vim.api.nvim_win_set_option(state.win, "cursorline", false)
  -- Pin the panel width: when the terminal resizes (or another split
  -- opens / closes), Neovim normally redistributes width across all
  -- windows. ``winfixwidth`` exempts the panel from that, so its
  -- columns stay constant and the source window absorbs all the
  -- flex. Same effect as VSCode's locked sidebars.
  vim.api.nvim_win_set_option(state.win, "winfixwidth", true)
  -- Drop back into the source window so the user keeps editing focus.
  if state.source_winid and vim.api.nvim_win_is_valid(state.source_winid) then
    vim.api.nvim_set_current_win(state.source_winid)
  end
end

-- ---------------------------------------------------------------------------
-- LSP request + debouncing

local function client()
  local clients = vim.lsp.get_clients({ name = "dimfort" })
  return clients[1]
end
M._client = client

local function position_params(winid)
  local buf = vim.api.nvim_win_get_buf(winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = cursor[1] - 1, character = cursor[2] },
  }
end

local function on_cursor_line_uninteresting(winid)
  -- Cheap pre-filter: skip blank or comment-only lines so we don't
  -- round-trip an LSP request to learn the cursor's on whitespace.
  local row = vim.api.nvim_win_get_cursor(winid)[1]
  local line = vim.api.nvim_buf_get_lines(
    vim.api.nvim_win_get_buf(winid), row - 1, row, false
  )[1] or ""
  local trimmed = line:match("^%s*(.-)%s*$") or ""
  if trimmed == "" then return true end
  if trimmed:sub(1, 1) == "!" then return true end
  return false
end

function M.refresh()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  local c = client()
  if not c then
    paint_message({ "(DimFort LSP not attached)" }, false)
    return
  end
  -- Determine the source window to take cursor + buffer from. If the
  -- user is currently inside the panel, fall back to the remembered
  -- source window so we don't introspect ourselves.
  local cur = vim.api.nvim_get_current_win()
  local target_win = (cur == state.win) and state.source_winid or cur
  if not (target_win and vim.api.nvim_win_is_valid(target_win)) then
    return
  end
  state.source_winid = target_win
  state.source_bufnr = vim.api.nvim_win_get_buf(target_win)
  if on_cursor_line_uninteresting(target_win) then
    -- Keep the last payload visible; just don't request.
    paint(render_all(), false)
    return
  end

  -- Mark current content as stale until the responses arrive.
  paint(render_all(), true)
  local req_id = state.req_id + 1
  state.req_id = req_id
  local params = position_params(target_win)
  local bufnr = state.source_bufnr

  -- panelInfo — the expression tree + scope tables + cursor diagnostics.
  c:request("dimfort/panelInfo", params, function(err, result)
    if state.req_id ~= req_id then return end
    if err then
      paint_message({ "(DimFort panel error: " ..
        tostring(err.message or err) .. ")" }, false)
      return
    end
    state.last_payload = result
    paint(render_all(), false)
  end, bufnr)

  -- interactions — cross-site unit constraints for the symbol at cursor.
  -- Best-effort; a failure just leaves the section's last content.
  c:request("dimfort/interactions", params, function(err, result)
    if state.req_id ~= req_id then return end
    state.last_interactions = (not err) and result or nil
    paint(render_all(), false)
  end, bufnr)

  -- code actions — filtered to DimFort's own (Add @unit{} / extract).
  -- The extract-to-PARAMETER action is built from the H010 diagnostics in
  -- the request context (the server keys off them), so populate the
  -- context with the cursor line's published LSP diagnostics — exactly
  -- what VSCode's executeCodeActionProvider does automatically.
  local ctx_diags = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr, { lnum = params.position.line })) do
    local lsp = d.user_data and d.user_data.lsp
    if lsp then table.insert(ctx_diags, lsp) end
  end
  c:request("textDocument/codeAction", {
    textDocument = params.textDocument,
    range = { start = params.position, ["end"] = params.position },
    context = { diagnostics = ctx_diags },
  }, function(err, result)
    if state.req_id ~= req_id then return end
    local actions = {}
    for _, a in ipairs((not err and result) or {}) do
      -- Keep DimFort's actions (command prefix or unit/PARAMETER title).
      local title = present(a.title) and a.title or ""
      local cmd = present(a.command) and a.command.command or ""
      if cmd:match("^dimfort%.") or title:match("[Uu]nit")
        or title:match("PARAMETER") then
        table.insert(actions, a)
      end
    end
    state.last_actions = actions
    paint(render_all(), false)
  end, bufnr)
end

local function schedule_refresh()
  if state.pending_timer then
    state.pending_timer:stop()
    state.pending_timer:close()
    state.pending_timer = nil
  end
  local timer = vim.uv.new_timer()
  state.pending_timer = timer
  timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(function()
    state.pending_timer = nil
    timer:close()
    M.refresh()
  end))
end

-- ---------------------------------------------------------------------------
-- Public API

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    -- Already open; just refresh.
    M.refresh()
    return
  end
  open_window()
  M.refresh()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.set_layout(layout)
  if layout ~= "both" and layout ~= "expression" and layout ~= "routine" then
    vim.notify("DimFort: panel layout must be 'both', 'expression', or 'routine'",
               vim.log.levels.ERROR)
    return
  end
  M.config.layout = layout
  vim.notify("DimFort: panel layout → " .. layout, vim.log.levels.INFO)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    paint(render_all(), false)
  end
end

-- Set (or clear, with no argument) the Scope section's name/unit filter.
-- Client-side: no LSP round-trip, repaints from the cached payload.
function M.set_filter(query)
  state.scope_filter = query or ""
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    paint(render_all(), false)
  end
end

-- Bind autocmds for cursor-follow updates. Called from the plugin's
-- main setup once, not every time the panel opens.
function M.install_autocmds()
  local group = vim.api.nvim_create_augroup("DimFortPanel", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = group,
    callback = function(args)
      if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
        return
      end
      -- Don't refresh in response to cursor moves inside the panel
      -- itself — those don't change the source position we care about.
      local win = vim.api.nvim_get_current_win()
      if win == state.win then return end
      -- Only react to Fortran buffers; ignore the panel buffer and
      -- any non-Fortran files the user switched to.
      local buf = args.buf or vim.api.nvim_get_current_buf()
      local ft = vim.bo[buf].filetype
      if ft ~= "fortran" then return end
      schedule_refresh()
    end,
  })
end

return M
