-- DimFort side panel for Neovim.
--
-- Persistent split window showing two stacked sections:
--   1. Expression tree under the cursor (live, debounced cursor-follow)
--   2. Routine variables table (every declared name + unit)
--
-- Off by default; toggle via :DimFortTogglePanel. Layout switches
-- via :DimFortPanelLayout {both|expression|routine}.
--
-- Wire protocol: ``dimfort/panelInfo`` LSP request — see
-- DimFort/docs/design/panel-info.md.

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
  in_flight_request_id = nil,
  source_winid = nil,        -- the editor window the panel is following
  source_bufnr = nil,
  last_payload = nil,        -- cached last response so we can keep
                              -- showing it during refresh / stale state
}

-- Headers + dividers shown in the panel.
local DIVIDER = string.rep("─", 60)

-- ---------------------------------------------------------------------------
-- Rendering

local MARKER = { ok = "🟢", warn = "🟡", error = "🔴" }

-- Neovim deserializes JSON ``null`` to ``vim.NIL`` — a userdata value
-- that's NOT equal to Lua ``nil`` and IS truthy. Every field we read
-- off an LSP response must be guarded against it, otherwise indexing
-- explodes with "attempt to index a userdata value".
local function present(v)
  return v ~= nil and v ~= vim.NIL
end

local function marker_for(node)
  return MARKER[present(node) and node.marker] or " "
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

-- Render the expression tree into ``rows`` with two aligned columns:
-- the ``: unit`` block and the 🟢/🟡/🔴 marker. Padding uses display
-- width (``strdisplaywidth``) so multi-byte box-drawing chars and unit
-- glyphs don't throw the alignment off. Statement rows (no unit) leave
-- the unit column blank but still align their markers.
local function render_expression(node, rows)
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
    table.insert(rows, e.tree .. tree_pad .. mid .. "  " .. e.mark .. e.rule)
  end
end

-- Capitalize the scope kind for the header (subroutine → Subroutine).
local function titlecase(s)
  if not s or s == "" then return s end
  return s:sub(1, 1):upper() .. s:sub(2)
end

local function render_scope_vars(scope, vars, rows)
  if present(scope) then
    -- e.g. "Subroutine: driver", "Module: constants_mod".
    table.insert(rows, string.format("%s: %s",
                                     titlecase(scope.kind), scope.name))
  else
    table.insert(rows, "Scope: (file level)")
  end
  table.insert(rows, "")
  vars = (present(vars) and vars) or {}
  if #vars == 0 then
    table.insert(rows, "  (no declarations)")
    return
  end
  -- Compute column widths.
  local name_w, unit_w = 4, 4
  for _, v in ipairs(vars) do
    name_w = math.max(name_w, #v.name)
    if present(v.unit) then unit_w = math.max(unit_w, #v.unit) end
  end
  table.insert(rows, string.format("  %4s  %-" .. name_w .. "s  %-" ..
                                   unit_w .. "s",
                                   "line", "name", "unit"))
  for _, v in ipairs(vars) do
    local unit = present(v.unit) and v.unit or "(none)"
    local tail = v.kind == "unannotated" and " 🟡" or ""
    table.insert(rows, string.format("  %4d  %-" .. name_w .. "s  %-" ..
                                     unit_w .. "s%s",
                                     v.line, v.name, unit, tail))
  end
end

local function render_payload(payload)
  local rows = {}
  local has_payload = present(payload)
  if M.config.layout == "both" or M.config.layout == "expression" then
    table.insert(rows, "Expression")
    table.insert(rows, "")
    if has_payload and present(payload.expression) then
      render_expression(payload.expression, rows)
    else
      table.insert(rows, "  (no expression at cursor)")
    end
    table.insert(rows, "")
  end
  if M.config.layout == "both" then
    table.insert(rows, DIVIDER)
    table.insert(rows, "")
  end
  if M.config.layout == "both" or M.config.layout == "routine" then
    if has_payload and present(payload.scopes) and #payload.scopes > 0 then
      -- Stack one section per enclosing scope, outermost first
      -- (e.g. Module then Subroutine), so the user sees the whole
      -- environment hierarchy, not just the innermost frame.
      for i, sc in ipairs(payload.scopes) do
        if i > 1 then table.insert(rows, "") end
        render_scope_vars(sc, sc.vars, rows)
      end
    elseif has_payload then
      -- Back-compat with older servers that only send a single scope.
      local scope = present(payload.scope) and payload.scope or payload.routine
      local scope_vars = present(payload.scopeVars) and payload.scopeVars
        or payload.routineVars
      render_scope_vars(scope, scope_vars, rows)
    else
      table.insert(rows, "Scope: (none)")
    end
  end
  return rows
end

local function paint(rows, stale)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rows)
  vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
  -- Stale highlight: tint every line as a Comment so the user sees
  -- the panel is mid-update without us blanking the prior content.
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  if stale then
    for i = 0, #rows - 1 do
      vim.api.nvim_buf_set_extmark(state.buf, state.ns, i, 0, {
        end_line = i + 1, hl_group = "Comment",
      })
    end
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
    paint({ "(DimFort LSP not attached)" }, false)
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
    paint(render_payload(state.last_payload), false)
    return
  end

  -- Mark current content as stale until the response arrives.
  paint(render_payload(state.last_payload), true)
  local req_id = (state.in_flight_request_id or 0) + 1
  state.in_flight_request_id = req_id

  c:request("dimfort/panelInfo", position_params(target_win),
    function(err, result)
      -- Drop the response if a newer request superseded it.
      if state.in_flight_request_id ~= req_id then return end
      if err then
        paint({ "(DimFort panel error: " .. tostring(err.message or err) .. ")" }, false)
        return
      end
      state.last_payload = result
      paint(render_payload(result), false)
    end
  )
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
    paint(render_payload(state.last_payload), false)
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
