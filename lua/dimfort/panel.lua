-- DimFort side panel for Neovim.
--
-- Persistent split window, cursor-following with a debounce. Mirrors the
-- VSCode companion's panel — five stacked sections:
--   1. Expression  — unit-algebra tree under the cursor
--   2. Diagnostics — DimFort diagnostics on the cursor line (🔴/🟡/🔵)
--   3. Interactions — cross-site unit constraints for the symbol at cursor
--   4. Actions     — code actions available at the cursor (apply with <CR>)
--   5. Scope       — stacked enclosing-scope declaration tables, with a
--                    name/unit filter (:DimFortScopeFilter)
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
  imports_filter = "",       -- client-side Imports name/unit/module filter
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

local MARKER = { ok = "🟢", assumed = "🔵", warn = "🟡", error = "🔴" }

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

local function emit(cv, row, target, hl, ranges)
  table.insert(cv.rows, row)
  -- Store the target at the same index (may be nil — a hole is fine).
  cv.targets[#cv.rows] = target
  -- Optional per-row highlight group (e.g. a diagnostic severity colour).
  -- nil for ordinary rows.
  if hl then
    cv.hls = cv.hls or {}
    cv.hls[#cv.rows] = hl
  end
  -- Optional per-row sub-range highlights. ``ranges`` is a list of
  -- ``{col=<byte>, end_col=<byte>, hl=<group>}`` records. Used to dim
  -- absence-of-information glyphs (``?``/``-``) inside a row that
  -- otherwise renders in normal colour.
  if ranges and #ranges > 0 then
    cv.range_hls = cv.range_hls or {}
    cv.range_hls[#cv.rows] = ranges
  end
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
  local expected = present(node.expected) and node.expected or nil
  local assumed = present(node.assumed) and node.assumed or nil
  local collides = present(node.collides) and node.collides or nil
  -- Row tail: '(expected …)' on call-arg / RHS mismatch, '(collides
  -- with …)' on H020 polymorphic-call-site conflicts, '(assumed:
  -- <reason>)' on @unit_assume rows. May apply together; concatenate
  -- with separating spaces.
  local extra = ""
  if expected then extra = extra .. " (expected " .. expected .. ")" end
  if collides then extra = extra .. " (collides with " .. collides .. ")" end
  if assumed then extra = extra .. " (assumed: " .. assumed .. ")" end
  local mark = marker_for(node)
  local label = present(node.label) and node.label or "?"
  table.insert(entries, {
    tree = prefix .. connector .. label,
    unit = has_unit and node.unit or nil,
    mark = mark,
    extra = extra,
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
    local ranges
    if e.unit then
      local unit_pad = string.rep(" ", unit_w - vim.fn.strdisplaywidth(e.unit))
      mid = " : " .. e.unit .. unit_pad
      -- Dim absence-of-information glyphs ("?" = unknown, "-" =
      -- structural-no-unit) so real units pop. The unit cell starts at
      -- the byte offset of (tree + tree_pad + " : "). Pads are ASCII
      -- spaces so byte length = display width for that segment; the
      -- tree label itself uses Unicode box-drawing chars, so we sum
      -- their BYTE lengths to get the byte column.
      if e.unit == "?" or e.unit == "-" then
        local unit_col = #e.tree + #tree_pad + 3  -- 3 = #" : "
        ranges = { { col = unit_col, end_col = unit_col + #e.unit, hl = "Comment" } }
      elseif #e.unit >= 4 and string.sub(e.unit, -4) == " = ?" then
        -- ``'a = ?`` (H020 unbound polymorphic return): dim only the
        -- trailing ``?`` so it reads at the same visual weight as a
        -- bare ``?``; the bound prefix stays full-weight. The suffix
        -- check is tight enough not to false-positive — concrete units
        -- never end in ``= ?``.
        local q_col = #e.tree + #tree_pad + 3 + #e.unit - 1
        ranges = { { col = q_col, end_col = q_col + 1, hl = "Comment" } }
      end
    elseif unit_w > 0 then
      -- No unit on this row, but other rows have one — pad the whole
      -- ``: unit`` block with spaces so the marker still lines up.
      mid = string.rep(" ", 3 + unit_w)
    else
      mid = ""
    end
    emit(cv, e.tree .. tree_pad .. mid .. "  " .. e.mark .. e.extra,
         nil, nil, ranges)
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
    emit(cv, pad .. "  (no declarations)", nil, "Comment")
    return
  end
  -- Compute column widths over the *displayed* strings so the markers
  -- line up — "?" for unannotated counts toward the unit width. The
  -- normalized column (``unit ⟶ base-SI``) shows the base-SI expansion
  -- — and, in scale mode, the multiplicative factor (``hPa ⟶
  -- 100×kg·m⁻¹·s⁻²``) — for any row whose annotation differs from its
  -- normalized form. Server-side ``unitNormalized`` already encodes the
  -- scale-mode-aware rendering; we just show it.
  local name_w, unit_w, norm_w = 4, 4, 0
  for _, v in ipairs(vars) do
    name_w = math.max(name_w, vim.fn.strdisplaywidth(v.name))
    local shown_unit = present(v.unit) and v.unit or "?"
    unit_w = math.max(unit_w, vim.fn.strdisplaywidth(shown_unit))
    if present(v.unitNormalized) and v.unitNormalized ~= v.unit then
      norm_w = math.max(norm_w, vim.fn.strdisplaywidth(v.unitNormalized))
    end
  end
  -- Precompute the column-block width for rows that DO carry a
  -- normalized form, and pad rows that don't to the same width so
  -- markers stay aligned. Two-space gap between source-unit and
  -- normalized columns matches the side-by-side ``<td>`` convention
  -- used by the VSCode panel — no arrow / separator glyph (column
  -- spacing already conveys the second cell).
  local norm_block_w = (norm_w > 0) and norm_w or 0
  for _, v in ipairs(vars) do
    local unit = present(v.unit) and v.unit or "?"
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
    local name_pad = string.rep(" ", name_w - vim.fn.strdisplaywidth(v.name))
    local unit_pad = string.rep(" ", unit_w - vim.fn.strdisplaywidth(unit))
    -- Normalized block: ``<norm>`` for rows with a differing
    -- expansion; equal-width blank padding for rows without (or when
    -- no row in this group has one — ``norm_block_w == 0``).
    local norm_block = ""
    if norm_block_w > 0 then
      if present(v.unitNormalized) and v.unitNormalized ~= v.unit then
        local nw = vim.fn.strdisplaywidth(v.unitNormalized)
        norm_block = "  " .. v.unitNormalized
                     .. string.rep(" ", norm_w - nw)
      else
        norm_block = "  " .. string.rep(" ", norm_block_w)
      end
    end
    -- Dim absence-of-information glyphs (`?` = unknown, `-` =
    -- structural-no-unit) so real units pop visually. The unit cell
    -- starts at `#prefix + name_w + 2` (bytes — pads are ASCII).
    local ranges
    if unit == "?" or unit == "-" then
      local prefix = pad .. string.format("  %4d  ", v.line)
      local unit_col = #prefix + name_w + 2
      ranges = { { col = unit_col, end_col = unit_col + #unit, hl = "Comment" } }
    end
    emit(cv, pad .. string.format("  %4d  ", v.line)
         .. v.name .. name_pad .. "  " .. unit .. unit_pad
         .. norm_block .. tail,
         { line = v.line }, nil, ranges)
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
    emit(cv, 'Filter: "' .. state.scope_filter .. '"  (:DimFortScopeFilter to change)')
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
      emit(cv, '  (no variables match "' .. state.scope_filter .. '")', nil, "Comment")
    end
  elseif present(payload) then
    -- Back-compat with older servers that only send a single scope.
    local scope = present(payload.scope) and payload.scope or payload.routine
    local scope_vars = present(payload.scopeVars) and payload.scopeVars
      or payload.routineVars
    render_scope_vars(cv, scope, scope_vars, 0)
  else
    emit(cv, "Scope: (none)", nil, "Comment")
  end
end

-- Cursor-line diagnostics. The whole 🔴/🟡/🔵 family so any info-level
-- diagnostic (e.g. P001 unparsed regions) reads the same as the others.
local function render_diagnostics(cv, diags)
  diags = (present(diags) and diags) or {}
  if #diags == 0 then
    emit(cv, "  (none)", nil, "Comment")
    return
  end
  for _, d in ipairs(diags) do
    local sev = present(d.severity) and d.severity or "info"
    local glyph = (sev == "error") and "🔴"
      or (sev == "warning") and "🟡" or "🔵"
    -- Colour the row by severity with Neovim's standard diagnostic highlight
    -- groups, so it follows the colourscheme and matches native diagnostic
    -- styling (virtual text / signs / underlines).
    local hl = (sev == "error") and "DiagnosticError"
      or (sev == "warning") and "DiagnosticWarn" or "DiagnosticInfo"
    local code = present(d.code) and d.code or "?"
    local msg = present(d.message) and d.message or ""
    -- Multi-line diagnostic messages (e.g. H020's per-arg conflict
    -- list — server emits each arg on its own line with a leading
    -- 2-space indent). ``nvim_buf_set_lines`` rejects strings with
    -- embedded ``\n``, so split into one panel row per source line
    -- and prefix each continuation line with the same 2-space
    -- gutter the message indent uses. Every row carries the same
    -- target dict so clicking any of them navigates to the
    -- diagnostic span.
    local target = {
      line = d.line, column = d.column,
      end_line = present(d.endLine) and d.endLine or nil,
      end_column = present(d.endColumn) and d.endColumn or nil,
    }
    local lines = vim.split(msg, "\n", { plain = true })
    emit(cv,
      "  " .. glyph .. " " .. code .. ": " .. (lines[1] or ""),
      target, hl)
    for i = 2, #lines do
      emit(cv, "  " .. lines[i], target, hl)
    end
  end
end

-- Interactions: the symbol under the cursor, its use-sites grouped by the
-- constraint each places on its unit, and any X001 conflict. Mirrors the
-- 'dimfort interactions' CLI; rows navigate cross-file.
local INTERACTION_GROUPS = {
  { kind = "declares", label = "Declaration" },
  { kind = "contributes", label = "Write" },
  { kind = "requires", label = "Read" },
  { kind = "uses", label = "Undetermined" },
}

local function render_interactions(cv, rep)
  if not present(rep) or not present(rep.points) or #rep.points == 0 then
    emit(cv, "  (none)", nil, "Comment")
    return
  end
  emit(cv, "  " .. (present(rep.symbol) and rep.symbol or "?"))
  -- Conflicts first — the headline.
  for _, c in ipairs((present(rep.conflicts) and rep.conflicts) or {}) do
    emit(cv, "  🔴 " .. val(c.code, "?") .. ": " .. val(c.message, ""), {
      file = c.file, line = c.line, column = c.column,
    }, "DiagnosticError")
  end
  for _, group in ipairs(INTERACTION_GROUPS) do
    local pts = {}
    for _, p in ipairs(rep.points) do
      if p.kind == group.kind then table.insert(pts, p) end
    end
    emit(cv, "  " .. group.label)
    if #pts == 0 then
      emit(cv, "      (none)", nil, "Comment")
    else
      for _, p in ipairs(pts) do
        local loc = base_name(as_path(p.file)) .. ":" .. tostring(p.line)
        -- The Undetermined group has no derived unit by definition.
        local has_unit = group.kind ~= "uses" and present(p.unit)
        local unit = has_unit and ("   " .. p.unit) or ""
        local target = { file = p.file, line = p.line, column = p.column }
        -- Dim absence-of-information glyphs ("?" / "-") so real units pop.
        -- The unit starts at byte offset 6 ("      ") + #loc + 3 ("   ").
        local ranges
        if has_unit and (p.unit == "?" or p.unit == "-") then
          local unit_col = 6 + #loc + 3
          ranges = { { col = unit_col, end_col = unit_col + #p.unit, hl = "Comment" } }
        end
        emit(cv, "      " .. loc .. unit, target, nil, ranges)
        if present(p.snippet) and p.snippet ~= "" then
          emit(cv, "        " .. p.snippet, target, "Comment")
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
    emit(cv, "  (none)", nil, "Comment")
    return
  end
  for _, a in ipairs(actions) do
    local title = (present(a.title) and a.title or "(action)")
      :gsub("^DimFort:%s*", "")
    emit(cv, "  • " .. title, { action = a })
  end
end

-- Display name for an import row: a callable (imported function /
-- subroutine) reads as ``name()``.
local function import_label(im)
  local n = present(im.name) and im.name or "?"
  if im.callable ~= true then return n end
  -- ``signature`` is the parenthesised argument units, e.g. "(kg, m)".
  return n .. (present(im.signature) and im.signature or "()")
end

-- Case-insensitive match of an import against the shared filter, over
-- the displayed name, the unit, and the source module.
local function import_matches(im, q)
  if q == "" then return true end
  local name = import_label(im):lower()
  if name:find(q, 1, true) then return true end
  local unit = present(im.unit) and im.unit:lower() or ""
  if unit ~= "" and unit:find(q, 1, true) then return true end
  local m = present(im.module) and im.module:lower() or ""
  return m ~= "" and m:find(q, 1, true) ~= nil
end

-- Imports: variables + procedures a 'use' clause brings into scope,
-- grouped by source module. Each row navigates (cross-file) to where the
-- imported symbol — and its @unit{} — is declared. Has its own name/unit/
-- module filter (state.imports_filter, set via :DimFortImportsFilter).
local function render_imports(cv, imports)
  imports = (present(imports) and imports) or {}
  local q = (state.imports_filter or ""):lower()
  if q ~= "" then
    emit(cv, 'Filter: "' .. state.imports_filter
            .. '"  (:DimFortImportsFilter to change)')
    emit(cv, "")
  end
  -- Filter first, then group (so empty groups disappear under a filter).
  local kept = {}
  for _, im in ipairs(imports) do
    if import_matches(im, q) then table.insert(kept, im) end
  end
  if #kept == 0 then
    if q ~= "" and #imports > 0 then
      emit(cv, '  (no imports match "' .. state.imports_filter .. '")', nil, "Comment")
    else
      emit(cv, "  (none)", nil, "Comment")
    end
    return
  end
  -- Group by module, preserving first-seen order.
  local order, groups = {}, {}
  for _, im in ipairs(kept) do
    local m = present(im.module) and im.module or "?"
    if not groups[m] then
      groups[m] = {}
      table.insert(order, m)
    end
    table.insert(groups[m], im)
  end
  for _, m in ipairs(order) do
    emit(cv, "  from " .. m)
    local name_w, unit_w, norm_w = 4, 4, 0
    for _, im in ipairs(groups[m]) do
      name_w = math.max(name_w, vim.fn.strdisplaywidth(import_label(im)))
      unit_w = math.max(unit_w,
        vim.fn.strdisplaywidth(present(im.unit) and im.unit or "?"))
      if present(im.unitNormalized) and im.unitNormalized ~= im.unit then
        norm_w = math.max(norm_w, vim.fn.strdisplaywidth(im.unitNormalized))
      end
    end
    local norm_block_w = (norm_w > 0) and norm_w or 0
    for _, im in ipairs(groups[m]) do
      -- A subroutine (callable, no unit, not a missing annotation) reads
      -- as "-" (structural-no-unit) rather than "?" — it has no return
      -- value to annotate. Unannotated declarations get "?" (unknown).
      local unit
      if present(im.unit) then
        unit = im.unit
      elseif im.callable == true and im.kind == "annotated" then
        unit = "-"
      else
        unit = "?"
      end
      local tail = (im.kind == "unannotated") and " 🟡" or " 🟢"
      local label = import_label(im)
      local name_pad = string.rep(" ", name_w - vim.fn.strdisplaywidth(label))
      local unit_pad = string.rep(" ", unit_w - vim.fn.strdisplaywidth(unit))
      -- Normalized block: ``<norm>`` for rows whose annotation
      -- expands to something different (e.g. ``Pa`` → ``kg·m⁻¹·s⁻²``).
      local norm_block = ""
      if norm_block_w > 0 then
        if present(im.unitNormalized) and im.unitNormalized ~= im.unit then
          local nw = vim.fn.strdisplaywidth(im.unitNormalized)
          norm_block = "  " .. im.unitNormalized
                       .. string.rep(" ", norm_w - nw)
        else
          norm_block = "  " .. string.rep(" ", norm_block_w)
        end
      end
      -- Dim absence-of-information glyphs so real units pop. Prefix is
      -- 6 spaces + label_padded(name_w) + "  " — all ASCII, so byte
      -- count = display width.
      local ranges
      if unit == "?" or unit == "-" then
        local unit_col = 6 + name_w + 2
        ranges = { { col = unit_col, end_col = unit_col + #unit, hl = "Comment" } }
      end
      emit(cv, "      " .. label .. name_pad .. "  " .. unit .. unit_pad
           .. norm_block .. tail,
           { file = present(im.file) and im.file or nil,
             line = im.line, column = im.column },
           nil, ranges)
    end
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
        emit(c, "  (none)", nil, "Comment")
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
    add_section(cv, "Imports", function(c)
      render_imports(c, present(payload) and payload.imports or {})
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
  else
    -- Per-row highlights (e.g. diagnostic severity colours). Skipped while
    -- stale, where the Comment tint takes over the whole panel.
    for idx, hl in pairs(cv.hls or {}) do
      vim.api.nvim_buf_set_extmark(state.buf, state.ns, idx - 1, 0, {
        end_line = idx, hl_group = hl,
      })
    end
    -- Per-row sub-range highlights (e.g. dimming the unit glyph ``?``/``-``
    -- inside an otherwise normal row).
    for idx, ranges in pairs(cv.range_hls or {}) do
      for _, r in ipairs(ranges) do
        vim.api.nvim_buf_set_extmark(state.buf, state.ns, idx - 1, r.col, {
          end_col = r.end_col, hl_group = r.hl,
        })
      end
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

-- Set (or clear) the Imports section's name/unit/module filter — its own
-- filter, independent of the Scope one.
function M.set_imports_filter(query)
  state.imports_filter = query or ""
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
