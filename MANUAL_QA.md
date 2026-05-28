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
    real :: combo      !< @unit{m^2/s^2}
    real :: ln_p       !< @unit{LOG(Pa)}
    real :: rt_e2      !< @unit{m/s}
    real :: abs_t      !< @unit{s}
    real :: recovered  !< @unit{Pa^2}
    real :: rho_brandes !< @unit{kg/m^3}
    real :: t_celsius                  ! no annotation -> U005
    d         = c_sound * t            ! OK:   m = (m·s⁻¹)*s
    bogus     = c_sound * t            ! H001: kg = m  (mismatch)
    t_celsius = t - 273.15             ! H010: bare 273.15 literal
    combo     = c_sound**2 + d * d / (t * t) - c_sound * c_sound
                                           !       (exercises +, -, *, /, **; all m²/s²)
    ln_p      = log(ref_pressure)            ! intrinsic: LOG-wrap (Pa → LOG(Pa))
    rt_e2     = sqrt(c_sound * c_sound)      ! intrinsic: sqrt halves (m²/s² → m/s)
    abs_t     = abs(t)                       ! intrinsic: preserves (s → s)
    recovered   = exp(log(ref_pressure) + log(ref_pressure))
                                             ! LOG/EXP algebra: homomorphism + cancellation
                                             !   exp(LOG(Pa) + LOG(Pa)) → exp(LOG(Pa²)) → Pa²
    rho_brandes = 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)   !< @unit_assume{kg/m^3 : empirical-fit Brandes2007}
                                             ! Non-rational power on a length — not algebraically derivable;
                                             ! @unit_assume asserts the result and fires U020 INFO.
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

- [ ] **Line 23** — `t_celsius` (no annotation) → **U005 warning**.
- [ ] **Line 25** — `bogus = c_sound * t` → **H001 error** `kg ≠ m`.
- [ ] **Line 26** — `t_celsius = t - 273.15` → **H010 warning** on the
      `273.15` literal (suggests extracting it to a named PARAMETER).
- [ ] Lines 24, 27, 29, 30, 31, 32, and 38 are **clean**; line 35 fires a **U020 INFO** acknowledging the `@unit_assume` (informational, not a problem) — no diagnostic.

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

- [ ] **Short (default)** — `K` on `c_sound` → single row
      `c_sound : m·s⁻¹`; on the product `c_sound * t` (line 24) → the
      tree shape used by every short hover: root `c_sound * t : m  🟢` +
      immediate operand rows `├── c_sound : m·s⁻¹  🟢` and
      `└── t : s  🟢`.
- [ ] **Binary operators** — on **line 27** (the `combo = …` assignment),
      `K` on each of `+`, `-`, `*`, `/`, `**` in turn. Each renders the
      same tree shape (root sub-expression + immediate operand rows);
      every row is 🟢; the topmost `**` shows `c_sound**2 : m²·s⁻²` over
      its operand rows. One fixture exercises every binary operator.
- [ ] **Detailed** — `:DimFortCycleHover` once. For bare-identifier
      operands like `c_sound * t` the layout is unchanged from short
      (nothing to expand). For the call `dynamic_pressure` (line 38)
      the call hover renders the same tree shape as the side panel:
      root `dynamic_pressure(0.5 * c_sound) : kg·m⁻¹·s⁻² 🟢` + child
      row `0.5 * c_sound : m·s⁻¹ 🟢` + sub-tree (`0.5 : 1`,
      `c_sound : m·s⁻¹`). Short shows root + the argument row only.
- [ ] **Subroutine call** — still in `detailed`, `K` on the call name
      `scale_pressure` (line 39): same tree layout as a function call,
      **but the root carries `-`** (structural-no-unit — subroutines
      have no return unit *by design*) and a clean call paints 🟢:
      `call scale_pressure(…) : -  🟢`. Argument row
      `2.0 * ref_pressure : kg·m⁻¹·s⁻² 🟢` with the sub-tree beneath.
- [ ] **Intrinsics — same tree as user calls.** Still in `detailed`:
      - `K` on `log` (line 29): root row `log(ref_pressure) : LOG(Pa)`
        + child row `ref_pressure : Pa 🟢`. The intrinsic call hover
        now uses the same tree renderer as user calls — no more
        bare-identifier-fallback one-liner.
      - `K` on `sqrt` (line 30): root row `sqrt(c_sound * c_sound) :
        m·s⁻¹` + computed-arg row (with its operand sub-tree in
        Detailed). Sqrt halves the unit (m²/s² → m/s).
      - `K` on `abs` (line 31): root row `abs(t) : s` + `t : s` child
        row. Abs preserves the operand's unit.
      Intrinsics have no `(expected …)` annotation on args — we don't
      track formal-arg units for them — but the structural tree is
      identical.
- [ ] **LOG / EXP computational tricks** — the idiom physicists use
      to do multiplicative work in log space:
      `recovered = exp(log(p) + log(p))`. One line exercises BOTH
      rules:
      - **Homomorphism** (inside): `log(p) + log(p) → LOG(p²)`.
      - **Cancellation** (outside): `exp(log(q)) → q`.

      On **line 32**, `K` on the outermost `exp` (Detailed): root row
      `exp(log(ref_pressure) + log(ref_pressure)) : Pa²  🟢` over
      the child `log(ref_pressure) + log(ref_pressure) : LOG(Pa²) 🟢`,
      and the sub-tree under that shows two `log(ref_pressure) :
      LOG(Pa) 🟢` rows. DimFort follows the algebra symbolically —
      no opacity, no approximation — so the round-trip `exp ∘ (sum
      of logs)` recovers the product unit cleanly. Strong showcase
      for atmospheric-science audiences.
- [ ] **`@unit_assume` escape hatch** — empirical fits with
      non-derivable units. On **line 35**, `K` on the assignment
      (`rho_brandes = 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)`):
      the line carries `!< @unit_assume{kg/m^3 : empirical-fit
      Brandes2007}`. Because the RHS contains a length raised to a
      non-rational power, the unit isn't derivable from first
      principles — DimFort would normally emit `D1.4`. The
      `@unit_assume` directive asserts the result's unit and
      suppresses `D1.4`; in its place a **U020 INFO** appears,
      acknowledging the assumption (informational, not a problem).
      The hover root reads `rho_brandes = … : -  🟢` (assignment
      statement, structural-no-unit `-`); the RHS row carries the
      assumed unit `kg·m⁻³` with no `(expected …)` mismatch.
      Common in physics: Tetens (saturation vapour pressure),
      Magnus, Buck, parameterised turbulence closures, etc. The
      assumed-unit registry lives in
      `Homogeneity/UNIT_ASSUME_REGISTRY.md`.
- [ ] **Assignment-mismatch `(expected …)` annotation.** On line 25
      (`bogus = c_sound * t`), `K` on the `=`. The root row paints 🔴
      from `H001` owning the assignment; the RHS child row reads
      `c_sound * t : m  🟡  (expected kg)`. The 🟡 is the
      🟡-on-`expected` override — the RHS expression resolved cleanly
      to `m`, but its consumer (the LHS) demanded `kg`. The
      annotation surfaces the same information the `(expected …)` tag
      gives on call-arg mismatches.
- [ ] **Pure-signature hover** (cursor on a function/subroutine
      *definition* header — no call site). `K` on `dynamic_pressure`
      in **line 5** (the function definition itself). The hover
      collapses to a single line:

      ```
      🟢 DimFort

      dynamic_pressure: (m·s⁻¹) → kg·m⁻¹·s⁻²
      ```

      Just the dimensional signature. No per-arg row table — the
      header alone carries the formal interface. Unannotated formal
      slots and unannotated returns render as `?` and flip the
      header marker to 🟡.
- [ ] `:DimFortCycleHover` once more → back to `disabled`.

## Inlay hints

- [ ] `:DimFortToggleInlayHints` → `[m·s⁻¹]`-style virtual text appears
      after variable uses; run it again → it disappears.

## Code actions

`vim.lsp.buf.code_action()` (Neovim 0.11 default mapping: `gra`) with the
cursor on the relevant line.

- [ ] On `t_celsius` (line 23) → **"add `@unit{}`"**. Applying inserts
      `!< @unit{}` and leaves the cursor **between the braces**.
- [ ] On the `273.15` (line 26) → **"extract literal to PARAMETER"**.
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
      line 25 (`bogus = c_sound * t`). The whole assignment renders, marked
      🔴 because `kg ≠ m`:

      ```
      Expression

      bogus = c_sound * t      🔴
      ├── bogus       : kg     🟢
      └── c_sound * t : m      🟢
          ├── c_sound : m·s⁻¹  🟢
          └── t       : s      🟢
      ```

      (Rule IDs like `(R4.2)` are no longer rendered on tree rows.)

- [ ] **Multiplication chain** — cursor on the **`=`** in line 10
      (`q = 0.5 * rho * v * v`). The product nests, every step 🟢, the
      root resolving to `kg·m⁻¹·s⁻²`:

      ```
      q = 0.5 * rho * v * v               🟢
      ├── q                 : kg·m⁻¹·s⁻²  🟢
      └── 0.5 * rho * v * v : kg·m⁻¹·s⁻²  🟢
          ├── 0.5 * rho * v : kg·m⁻²·s⁻¹  🟢
          │   ├── 0.5 * rho : kg·m⁻³      🟢
          │   │   ├── 0.5   : 1           🟢
          │   │   └── rho   : kg·m⁻³      🟢
          │   └── v         : m·s⁻¹       🟢
          └── v             : m·s⁻¹       🟢
      ```

- [ ] **Function call with arguments** — cursor on the call name
      `dynamic_pressure` in line 38. The computed argument breaks down
      beneath the call:

      ```
      dynamic_pressure(0.5 * c_sound) : kg·m⁻¹·s⁻²  🟢
      └── 0.5 * c_sound               : m·s⁻¹       🟢
          ├── 0.5                     : 1           🟢
          └── c_sound                 : m·s⁻¹       🟢
      ```

- [ ] **Subroutine call** — cursor on the call name `scale_pressure` in
      line 39. A subroutine has no return unit, so the root carries none
      (🟡), but the computed argument still expands beneath it:

      ```
      call scale_pressure(2.0 * ref_pressure)              🟡
      └── 2.0 * ref_pressure                  : kg·m⁻¹·s⁻²  🟢
          ├── 2.0                             : 1           🟢
          └── ref_pressure                    : kg·m⁻¹·s⁻²  🟢
      ```

- [ ] **Call-arg expected on mismatch** — temporarily edit line 38 to
      `ref_pressure = dynamic_pressure(c_sound * t)`. The Expression
      tree's argument row now shows
      `c_sound * t : m 🔴 (expected m·s⁻¹)`, surfacing the formal unit the
      call-site demanded. Revert the edit when done.

- [ ] **Stacked scopes** — with the cursor in line 10 (inside the
      function), the Scope section stacks the module over the function,
      indented by nesting (no column header — rows are `line · name ·
      unit · mark`):

      ```
      Module: qa_mod

        2     c_sound       m·s⁻¹ 🟢
        3     ref_pressure  Pa    🟢

        Function: dynamic_pressure

          6     v    m·s⁻¹  🟢
          7     q    Pa     🟢
          8     rho  kg/m^3 🟢
      ```

- [ ] **Markers** — in `checks` (e.g. cursor in line 25), `t_celsius`
      shows 🟡 (unannotated); a `@unit{??}` in scope shows 🔴.

- [ ] **Cursor-follow** — move between line 10 (function) and line 25
      (subroutine); the Scope section switches between `Function:
      dynamic_pressure` and `Subroutine: checks`.

### Panel — Diagnostics / Interactions / Actions (the `both` layout)

These three sections sit between Expression and Scope in the default
`both` layout. Each is always present, showing `(none)` when nothing
applies, so they don't pop in and out as the cursor moves.

- [ ] **Diagnostics** — cursor on line 25 (`bogus = c_sound * t`); the
      Diagnostics section shows **🔴 H001: …** (the cursor-line
      diagnostic). On line 23 (`t_celsius`) it shows **🟡 U005: …**. On a
      clean line (18) it shows `(none)`. Press `<CR>` on a diagnostic row
      → the cursor jumps to that span in the source.
- [ ] **Interactions** — cursor on a `c_sound` use (line 24). The
      Interactions section shows the symbol `c_sound`, then the
      **Declaration** group (line 2) and **Read** group (its use sites),
      each row `file:line   unit` with the source snippet beneath. Press
      `<CR>` on a site → jumps there (cross-file when the site is in
      another file). Because `c_sound` is read as `m·s⁻¹` at lines 18/21 but
      as `kg/s` at line 25 (`bogus` is `kg`), a **🔴 X001** conflict row
      sits at the top.
- [ ] **Actions** — cursor on `t_celsius` (line 23) → the Actions section
      lists **• Add @unit{} to t_celsius**; `<CR>` on it inserts
      `!< @unit{}` in the source (cursor between the braces). Cursor
      anywhere on line 26 (the H010 line) → **• Extract literal '273.15'
      into a named PARAMETER (s)**; `<CR>` prompts for a name and applies
      the refactor.
- [ ] **Footer** — the panel's last line reads `File: 🔴 N   🟡 N` with
      the whole-file error / warning counts.

### Panel — Scope filter

- [ ] `:DimFortScopeFilter Pa` → the Scope section keeps only variables
      whose name or unit matches `Pa` (e.g. `ref_pressure`, `q`), and
      shows a `Filter: "Pa"` header. Scopes with no surviving variables
      are hidden. `:DimFortScopeFilter` with no argument clears it.

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

## Imports section

Save this `imports_qa.f90` and open it (one file, two modules — the
second `use`s the first):

```fortran
! `phys_base` exists to test TRANSITIVE re-export: phys_constants
! `use`s it, and `solver` uses phys_constants — see whether `g0`
! surfaces in solver's Imports section.
module phys_base
  real :: g0   !< @unit{m/s^2}
end module phys_base

module phys_constants
  use phys_base                          ! transitive: re-exports g0 by default
  real :: play     !< @unit{Pa}
  real :: grav     !< @unit{m/s^2}
  real :: density                        ! NO annotation → unannotated 🟡
contains
  function gravity_at(h) result(g)
    real, intent(in) :: h   !< @unit{m}
    real             :: g   !< @unit{m/s^2}
    g = grav
  end function gravity_at
  subroutine set_play(p)
    real, intent(in) :: p   !< @unit{Pa}
    play = p
  end subroutine set_play
end module phys_constants

module solver
  use phys_constants, only: play, gravity_at, set_play, density
  real :: local_p   !< @unit{Pa}
contains
  subroutine step()
    local_p = play
    call set_play(local_p)
  end subroutine step
end module solver
```

- [ ] **Lists vars + procedures + subroutines + unannotated** — cursor
      on `local_p = play` (inside `step`): the **Imports** section
      shows a `from phys_constants` header with four indented rows:
      - `play         kg·m⁻¹·s⁻²  🟢` (annotated variable)
      - `gravity_at(m)  m·s⁻²     🟢` (callable, arg unit in parens,
        return unit in the column)
      - `set_play(Pa)  -          🟢` (subroutine — structural-no-unit
        glyph, dimmed via `Comment`; distinct from `(none)`)
      - `density       ?          🟡` (unannotated variable — the `?`
        glyph appears dimmed, distinguishing it from a real unit)
- [ ] **Cross-file navigation** — `<CR>` on `play` jumps to its
      declaration; `<CR>` on `gravity_at(m)` jumps to the function;
      `<CR>` on `set_play(Pa)` jumps to the subroutine. Same file here;
      another file in a real project.
- [ ] **Scoped + shadowed** — `grav` is **not** listed (the `only:`
      list excludes it). Add `real :: play !< @unit{Pa}` as a local in
      `step` and `play` drops from Imports (the local shadows it; it
      shows under Scope instead).
- [ ] **Transitive imports — record actual behavior.** `phys_constants`
      itself `use`s `phys_base`, which declares `g0`. Default Fortran
      semantics re-export `g0` through `phys_constants`. Cursor inside
      `step` and confirm whether `g0` appears in solver's Imports:
      - **If yes** — DimFort follows transitive `use`. Note the unit
        in the row (`m·s⁻²` 🟢).
      - **If no** — DimFort treats `use` as non-transitive (only
        symbols declared directly in `phys_constants` surface). File
        a finding or document the intentional gap.
- [ ] **Imports filter** — `:DimFortImportsFilter gravity` narrows the
      Imports section to `gravity_at(m)`; `:DimFortImportsFilter play`
      narrows to `play` + `set_play(Pa)`; no-arg clears it. Independent
      of `:DimFortScopeFilter` — neither affects the other.
- [ ] **Empty case** — cursor in `phys_base` (which imports nothing):
      the Imports section shows `(none)`.
