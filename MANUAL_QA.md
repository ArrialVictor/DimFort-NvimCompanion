# Manual QA — DimFort Neovim companion

A precise visual smoke test to run **before tagging a release**. It
checks the parts only a human can see in the editor; the server's
verdicts are unit-tested upstream, so this deliberately does *not*
re-verify them. The Emacs and VSCode companions carry the same
checklist with their own commands — running all three confirms the
companions stay in parity.

Every step lists the **exact** expected result. Anything that differs
is a regression to file.

## Scene

Save this as `qa.f90` and open it. It is self-contained (one module,
no cross-file `use`) and fires exactly one of each interesting
diagnostic.

```fortran
module qa_mod
  real, parameter :: c_sound = 340.0   !< @unit{m/s}
  real :: ref_pressure                 !< @unit{Pa}
contains
  function dynamic_pressure(v) result(q)
    real, intent(in) :: v    !< @unit{m/s}
    real             :: q    !< @unit{Pa}
    real             :: rho  !< @unit{kg/m^3}
    rho = 1.225
    q = 0.5 * rho * v * v
  end function dynamic_pressure

  subroutine checks()
    real :: t          !< @unit{s}
    real :: d          !< @unit{m}
    real :: bogus      !< @unit{kg}
    real :: t_celsius                  ! no annotation -> U005
    d         = c_sound * t            ! OK:   m = (m/s)*s
    bogus     = c_sound * t            ! H001: kg = m  (mismatch)
    t_celsius = t - 273.15             ! H010: bare 273.15 literal
    ref_pressure = dynamic_pressure(0.5 * c_sound)
    call scale_pressure(2.0 * ref_pressure)        ! subroutine call
  end subroutine checks

  subroutine scale_pressure(p)
    real, intent(in) :: p   !< @unit{Pa}
    ref_pressure = p
  end subroutine scale_pressure
end module qa_mod
```

Open it in Neovim with DimFort configured; the LSP attaches
automatically. Give the first workspace check a moment, then walk the
sections below.

## Defaults (fresh config)

- [ ] No `[unit]` inlay ghost text anywhere — inlays are off by default.
- [ ] The **side panel opens automatically** on the right — it's on by
      default.
- [ ] `:DimFortStatus` prints **exactly** this (the `active client id`
      is whatever number this session assigned):

      ```
      DimFort status
        executable          : dimfort
        inlay hints         : off
        completion          : on
        code actions        : on
        go-to-definition    : on
        hover               : short
        cache               : read-write
        scale checking      : auto
        cache dir           : (default)
        max workset size    : 40
        external modules    : (none)
        active client id    : 1
      ```

## Diagnostics

Diagnostics render per your `vim.diagnostic` config (signs, underline,
and/or virtual text). Put the cursor on a line and run
`vim.diagnostic.open_float()` to read its code + message; to list them
all, `vim.diagnostic.setloclist()` then `:lopen` (a bare `:lopen` errors
with `E776` because diagnostics don't populate the location list on
their own). On a fresh open, confirm exactly these fire:

- [ ] **Line 17** — `t_celsius` (no annotation) → **U005 warning**.
- [ ] **Line 19** — `bogus = c_sound * t` → **H001 error** `kg ≠ m`.
- [ ] **Line 20** — `t_celsius = t - 273.15` → **H010 warning** on the
      `273.15` literal (suggests extracting it to a named PARAMETER).
- [ ] Lines 18 and 21 are **clean** — no diagnostic.

**Interactive — U002 (unparseable annotation):** change line 14's
`!< @unit{s}` to `!< @unit{??}` and save (`:w`). Confirm **two**
diagnostics on line 14, then undo (`u`):

- [ ] A **U002 error** spanning the `@unit{??}` token itself (not the
      start of the line).
- [ ] A **U005 warning** on `t` — an unparseable annotation makes `t`
      count as unannotated. (In the panel, `t` flips to 🔴.)

## Hover

Hover defaults to **`short`** (one cursor-following unit surface beside the
panel). `:DimFortCycleHover` cycles `disabled → short → detailed` (restarting
each time). Hover with `K` (`vim.lsp.buf.hover()`).

- [ ] **Short (default)** — `K` on `c_sound` → `c_sound : m/s`; on the
      product `c_sound * t` (line 18) → the single line `c_sound * t : m`.
- [ ] **Detailed** — `:DimFortCycleHover` once. `K` on `c_sound * t` now
      breaks down across lines (each operand with its unit); on the call
      `dynamic_pressure` (line 21) the formal-vs-actual pairing
      (`v : m/s ◂ 0.5 * c_sound : m/s`) gains a sub-tree under the computed
      argument (`0.5 : 1`, `c_sound : m/s`) — that's the difference from
      Short, which shows the pairing row only.
- [ ] **Subroutine call** — still in `detailed`, `K` on the call name
      `scale_pressure` (line 22): same formal-vs-actual layout as a
      function call, **but no return unit in the header** (subroutines
      don't return) — `p : Pa ◂ 2.0 * ref_pressure : Pa` with the argument
      sub-tree beneath.
- [ ] `:DimFortCycleHover` once more → back to `disabled`.

## Inlay hints

- [ ] `:DimFortToggleInlayHints` → `[m/s]`-style virtual text appears
      after variable uses; run it again → it disappears.

## Code actions

`vim.lsp.buf.code_action()` (Neovim 0.11 default mapping: `gra`) with the
cursor on the relevant line.

- [ ] On `t_celsius` (line 17) → **"add `@unit{}`"**. Applying inserts
      `!< @unit{}` and leaves the cursor **between the braces**.
- [ ] On the `273.15` (line 20) → **"extract literal to PARAMETER"**.
      Applying prompts for a name (`vim.ui.input`), then inserts a typed
      `real, parameter` declaration and replaces the `273.15`.

## Navigation & completion

- [ ] `vim.lsp.buf.definition()` on a `c_sound` use → jumps to its
      declaration on line 2.
- [ ] Type a new `!< @unit{` and trigger LSP completion (`<C-x><C-o>`, or
      your completion plugin) → unit names are offered.

## Side panel

Open by default; `:DimFortTogglePanel` closes/reopens it. The panel
follows the cursor (≈200 ms debounce) and dims (Comment highlight) while
it refreshes.

- [ ] **Assignment with a mismatch** — put the cursor on the **`=`** in
      line 19 (`bogus = c_sound * t`). The whole assignment renders, marked
      🔴 because `kg ≠ m`:

      ```
      Expression

      bogus = c_sound * t        🔴
      ├── bogus           : kg   🟢
      └── c_sound * t     : m    🟢 (R4.2)
          ├── c_sound     : m/s  🟢
          └── t           : s    🟢
      ```

- [ ] **Multiplication chain** — cursor on the **`=`** in line 10
      (`q = 0.5 * rho * v * v`). The product nests, each step tagged with
      its rule:

      ```
      q = 0.5 * rho * v * v              🟢
      ├── q                 : kg/(m×s²)  🟢
      └── 0.5 * rho * v * v : kg/(m×s²)  🟢 (R4.2)
          ├── 0.5 * rho * v : kg/(m²×s)  🟢 (R4.2)
          │   ├── 0.5 * rho : kg/m³      🟢 (R4.2)
          │   │   ├── 0.5   : 1          🟢
          │   │   └── rho   : kg/m³      🟢
          │   └── v         : m/s        🟢
          └── v             : m/s        🟢
      ```

- [ ] **Function call with arguments** — cursor on the call name
      `dynamic_pressure` in line 21. The computed argument breaks down
      beneath the call:

      ```
      dynamic_pressure(0.5 * c_sound) : kg/(m×s²)  🟢
      └── 0.5 * c_sound               : m/s        🟢 (R4.2)
          ├── 0.5                     : 1          🟢
          └── c_sound                 : m/s        🟢
      ```

- [ ] **Subroutine call** — cursor on the call name `scale_pressure` in
      line 22. A subroutine has no return unit, so the root carries none
      (🟡), but the computed argument still expands beneath it:

      ```
      call scale_pressure(2.0 * ref_pressure)              🟡
      └── 2.0 * ref_pressure                  : kg/(m×s²)  🟢 (R4.2)
          ├── 2.0                             : 1          🟢
          └── ref_pressure                    : kg/(m×s²)  🟢
      ```

- [ ] **Stacked scopes** — with the cursor in line 10 (inside the
      function), the Scope section stacks the module over the function,
      indented by nesting (no column header — rows are `line · name ·
      unit · mark`):

      ```
      Module: qa_mod

        2     c_sound       m/s  🟢
        3     ref_pressure  Pa   🟢

        Function: dynamic_pressure

          6     v     m/s    🟢
          7     q     Pa     🟢
          8     rho   kg/m^3 🟢
      ```

- [ ] **Markers** — in `checks` (e.g. cursor in line 19), `t_celsius`
      shows 🟡 (unannotated); a `@unit{??}` in scope shows 🔴.

- [ ] **Cursor-follow** — move between line 10 (function) and line 19
      (subroutine); the Scope section switches between `Function:
      dynamic_pressure` and `Subroutine: checks`.

### Panel — Diagnostics / Interactions / Actions (the `both` layout)

These three sections sit between Expression and Scope in the default
`both` layout. Each is always present, showing `(none)` when nothing
applies, so they don't pop in and out as the cursor moves.

- [ ] **Diagnostics** — cursor on line 19 (`bogus = c_sound * t`); the
      Diagnostics section shows **🔴 H001: …** (the cursor-line
      diagnostic). On line 17 (`t_celsius`) it shows **🟡 U005: …**. On a
      clean line (18) it shows `(none)`. Press `<CR>` on a diagnostic row
      → the cursor jumps to that span in the source.
- [ ] **Interactions** — cursor on a `c_sound` use (line 18). The
      Interactions section shows the symbol `c_sound`, then the
      **Declaration** group (line 2) and **Read** group (its use sites),
      each row `file:line   unit` with the source snippet beneath. Press
      `<CR>` on a site → jumps there (cross-file when the site is in
      another file). Because `c_sound` is read as `m/s` at lines 18/21 but
      as `kg/s` at line 19 (`bogus` is `kg`), a **🔴 X001** conflict row
      sits at the top.
- [ ] **Actions** — cursor on `t_celsius` (line 17) → the Actions section
      lists **• Add @unit{} to t_celsius**; `<CR>` on it inserts
      `!< @unit{}` in the source (cursor between the braces). Cursor
      anywhere on line 20 (the H010 line) → **• Extract literal '273.15'
      into a named PARAMETER (s)**; `<CR>` prompts for a name and applies
      the refactor.
- [ ] **Footer** — the panel's last line reads `File: 🔴 N   🟡 N` with
      the whole-file error / warning counts.

### Panel — Scope filter

- [ ] `:DimFortPanelFilter Pa` → the Scope section keeps only variables
      whose name or unit matches `Pa` (e.g. `ref_pressure`, `q`), and
      shows a `Filter: "Pa"` header. Scopes with no surviving variables
      are hidden. `:DimFortPanelFilter` with no argument clears it.

## Scale checking (S001 / S002)

Save this `scale_qa.f90` and open it (no `.dimfort.toml` needed — the
editor toggle drives it):

```fortran
module scale_qa
  real :: play   !< @unit{Pa}
  real :: phpa   !< @unit{hPa}
  real :: t_k    !< @unit{K}
  real :: t_c    !< @unit{degC}
contains
  subroutine s()
    phpa = play        ! S001: hPa vs Pa (×100 multiplicative scale)
    t_k  = t_c         ! S002: K vs degC (affine offset)
  end subroutine s
end module scale_qa
```

- [ ] **Auto (default)** — with `scale_mode = "auto"` and no
      `.dimfort.toml`, the file is **clean** (no S001/S002).
- [ ] **On** — `:DimFortCycleScale` until the notification says
      `scale checking → on` (the server restarts): **yellow** squiggles
      appear — `phpa = play` → **S001**, `t_k = t_c` → **S002** — and the
      panel circles match (🟡).
- [ ] **Off / Auto** — cycle again to `off` (forced clean even if a toml
      enabled it), once more to `auto` (back to deferring to the toml).
