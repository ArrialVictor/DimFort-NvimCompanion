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
      The hover reads:

      ```
      🟢 DimFort
      rho_brandes = … : -                          🟢
      ├── rho_brandes                : kg·m⁻³     🟢
      └── 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)
                                     : kg·m⁻³     🔵  (assumed: empirical-fit Brandes2007)
          ├── …                        (RHS sub-tree with 🟡 leaves
          └── …                         from the unresolved (-0.922))
      ```

      The 🔵 is a **per-row overlay** (NOT a severity tier — see
      DimFort design/markers.md §4.6) painted on the RHS row, the
      directive's syntactic subject. The RHS row's unit column shows
      the **asserted** unit `kg·m⁻³`, not the computed `?`. The
      assignment row stays **🟢** because the homogeneity check
      passes (LHS `kg·m⁻³` matches the asserted RHS `kg·m⁻³`); the
      hover header is `🟢 DimFort`. The 🔵 surfaces only in the
      body, where the assertion lives. The RHS sub-tree still shows
      its underlying algebra (with 🟡 on the `(-0.922)` unresolved
      leaf) for transparency, but doesn't propagate up to the
      assignment row.
      Common in physics: Tetens (saturation vapour pressure),
      Magnus, Buck, parameterised turbulence closures, etc.
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

      dynamic_pressure(m·s⁻¹) : kg·m⁻¹·s⁻²
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

      bogus = c_sound * t : -      🔴
      ├── bogus           : kg     🟢
      └── c_sound * t     : m      🟡  (expected kg)
          ├── c_sound     : m·s⁻¹  🟢
          └── t           : s      🟢
      ```

      The root row reads `: -` (structural-no-unit — an assignment has
      no own unit) and 🔴 because H001 owns it. The RHS row demotes
      🟢 → 🟡 with `(expected kg)` appended: the expression
      `c_sound * t` resolved cleanly to `m`, but its consumer (the LHS)
      demanded `kg`. (Rule IDs like `(R4.2)` are no longer rendered on
      tree rows.)

- [ ] **Multiplication chain** — cursor on the **`=`** in line 10
      (`q = 0.5 * rho * v * v`). The product nests, every step 🟢, the
      root resolving to `kg·m⁻¹·s⁻²`:

      ```
      q = 0.5 * rho * v * v : -            🟢
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
      line 39. A subroutine has no return unit, so the root shows `-`
      in the unit column and 🟢 (no diagnostic owns it). The computed
      argument still expands beneath it:

      ```
      call scale_pressure(2.0 * ref_pressure) : -           🟢
      └── 2.0 * ref_pressure                  : kg·m⁻¹·s⁻²  🟢
          ├── 2.0                             : 1           🟢
          └── ref_pressure                    : kg·m⁻¹·s⁻²  🟢
      ```

- [ ] **Call-arg expected on mismatch** — temporarily edit line 38 to
      `ref_pressure = dynamic_pressure(c_sound * t)`. The Expression
      tree's argument row now shows
      `c_sound * t : m 🟡 (expected m·s⁻¹)` — the 🟡 is the
      expected-override (the expression resolved cleanly, but the call
      disagrees with the formal); the 🔴 sits on the enclosing call
      via H004. Revert the edit when done.

- [ ] **Stacked scopes** — with the cursor in line 10 (inside the
      function), the Scope section stacks the module over the function,
      indented by nesting (no column header — rows are `line · name ·
      unit · mark`):

      ```
      Module: qa_mod

        2     c_sound                              m·s⁻¹       🟢
        3     ref_pressure                         Pa          🟢
        5     dynamic_pressure(m·s⁻¹)              kg·m⁻¹·s⁻²  🟢
       24     scale_pressure(kg·m⁻¹·s⁻²)           -           🟢

        Function: dynamic_pressure

          6     v    m·s⁻¹  🟢
          7     q    Pa     🟢
          8     rho  kg/m^3 🟢
      ```

      The two procedure rows under `Module: qa_mod` are the module's own
      defined functions/subroutines — visible from anywhere within the
      module (Fortran host association), mirroring how imported
      procedures show in the Imports section. Subroutines render `-` in
      the unit column (no return *by design*).

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
  real, parameter :: PA_PER_HPA = 100.   !< @unit{Pa/hPa}
  real :: play   !< @unit{Pa}
  real :: phpa   !< @unit{hPa}
  real :: t_k    !< @unit{K}
  real :: t_c    !< @unit{degC}
contains
  subroutine s()
    phpa = play                  ! S001: hPa vs Pa (×100 multiplicative scale)
    phpa = play / PA_PER_HPA     ! clean: the typed factor cancels the mismatch
    t_k  = t_c                   ! S002: K vs degC (affine offset)
  end subroutine s
end module scale_qa
```

- [ ] **Auto (default)** — with `scale_mode = "auto"` and no
      `.dimfort.toml`, the file is **clean** (no S001/S002).
- [ ] **On** — `:DimFortCycleScale` until the notification says
      `scale checking → on` (the server restarts): **yellow** squiggles
      appear — `phpa = play` → **S001**, `t_k = t_c` → **S002** — and the
      panel circles match (🟡).
- [ ] **Scale factor surfaces uniformly in scale mode** — with scale on,
      hover the `=` of `phpa = play` (or look at the Panel's Expression
      section). The LHS row reads `phpa : 100×kg·m⁻¹·s⁻²` 🟢 and the
      RHS row reads `play : kg·m⁻¹·s⁻²` 🟢 — the ×100 ratio matches the
      diagnostic's `×100`. The same factor appears wherever a unit is
      rendered (scope/imports normalized columns, etc.). With scale off,
      factors are hidden everywhere — both sides of the assignment
      render to the bare `kg·m⁻¹·s⁻²`. Single rule: displays match what
      the checker is reasoning about.
- [ ] **Typed conversion silences it** — the second assignment in `s()`,
      `phpa = play / PA_PER_HPA`, is **clean** (no S001). The typed
      `Pa/hPa` parameter carries the multiplicative factor explicitly,
      so the assignment's units balance and the scale check passes.
- [ ] **Off / Auto** — cycle again to `off` (forced clean even if a toml
      enabled it), once more to `auto` (back to deferring to the toml).

## Unparsed regions (P001)

`P001` marks lines tree-sitter couldn't parse — DimFort makes no unit
guarantee there. It's an **info** diagnostic, so it renders as a faint
**blue** squiggle, distinct from real (red) violations.

Save this `unparsed_qa.f90` and open it:

```fortran
subroutine unparsed_qa(press, vel)
  implicit none
  real, intent(in)  :: press   !< @unit{Pa}
  real, intent(out) :: vel     !< @unit{m/s}
  vel = press        ! H001 (red): m·s⁻¹ vs Pa
  vel = * / +        ! P001 (blue): unparseable line
  vel = 0.0          ! swallowed by line-6 error region — blue too
  vel = vel * 2.0    ! CLEAN — proves the blue stops here
end subroutine unparsed_qa
```

> Why two trailing statements: `vel = 0.0` gets swallowed by tree-sitter's
> error recovery on line 6 (its assignment_statement is consumed into the
> ERROR region, so the Expression panel is degraded there). `vel = vel * 2.0`
> is the first fully-clean statement after the bad line — present to
> demonstrate that the P001 squiggle *stops* at line 7 and does NOT bleed
> further. A trailing valid statement is also required for tree-sitter to
> find the subroutine boundary; without one, the **whole** routine wraps in
> an error region and the Scope panel blanks (known panel-robustness gap).

- [ ] **Blue squiggle** — `vel = * / +` gets a **blue (info)** underline;
      `K` on it (or `:lua vim.diagnostic.open_float()`) shows
      **`P001` … "could not parse this region — DimFort makes no unit
      guarantee here"** at *Information* severity. With the cursor on
      that line, the panel's **Diagnostics** section lists the P001
      with a **🔵** glyph (matching 🔴 error / 🟡 warning).
- [ ] **Distinct from a real error** — `vel = press` carries a **red**
      `H001` on the line above, so blue (FYI) and red (violation) are
      visibly different.
- [ ] **Localized, not the whole routine** — the blue squiggle covers
      **exactly two lines**: `vel = * / +` (the bad line) and the
      immediately-following `vel = 0.0` (whose assignment_statement
      tree-sitter swallows into the error recovery region). The next
      line `vel = vel * 2.0` is **not blue** — proving the squiggle stops
      at the right boundary. The Expression panel is correctly empty on
      lines 6-7 (no trustworthy tree there) and populates normally on
      line 8 (clean autocast → `m·s⁻¹`).
- [ ] **Doesn't mask real checks** — the `H001` still fires; P001 only marks
      what it *couldn't* read, it doesn't suppress checking elsewhere.
- [ ] **Suppressible** — add a workspace `.dimfort.toml` with
      `[diagnostics]` `P001 = "off"`, save; the blue squiggle disappears
      (no manual restart), the red `H001` stays.

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
- [ ] **Transitive imports** — drop the `, only: …` filter on `solver`'s
      `use phys_constants` line so it becomes plain `use phys_constants`.
      `phys_constants` itself `use`s `phys_base`, which declares `g0`.
      Default Fortran semantics re-export `g0` through `phys_constants`.
      Cursor inside `step`: a **second** group header appears, `from
      phys_base` (tagged `via phys_constants`), with a single row:
      - `g0` → `m·s⁻²` 🟢 — `<CR>` on it **jumps cross-file** to
        `phys_base`'s declaration site (`imports_qa.f90:2`).
      The existing `from phys_constants` group still lists `play`,
      `grav`, `density`, `gravity_at`, `set_play` — transitive
      re-export only adds the `phys_base` group, never removes a row.
- [ ] **Imports filter** — `:DimFortImportsFilter gravity` narrows the
      Imports section to `gravity_at(m)`; `:DimFortImportsFilter play`
      narrows to `play` + `set_play(Pa)`; no-arg clears it. Independent
      of `:DimFortScopeFilter` — neither affects the other.
- [ ] **Empty case** — cursor in `phys_base` (which imports nothing):
      the Imports section shows `(none)`.

## Configurable comment delimiters (0.2.2)

Save this `delim_qa.f90` in a fresh folder alongside the toml
just below it:

```fortran
subroutine delim_demo
  implicit none

  ! §10 — bare ! @unit{} is now eligible at a decl. Hover → m/s.
  real :: ws   ! @unit{m/s}

  ! §2 — bracket pattern (configured below). Hover → Pa.
  real :: pa   ! atmospheric pressure [Pa] at the surface

  ! §3.2 — standalone above a decl, plain `!`. Hover → kg.
  ! mass loading [kg]
  real :: kg

  ! §6 — any pattern on a multi-var attaches to all names.
  real :: a, b, c   ! [m]

  ! §8.2 — two patterns disagree → U021. First-listed (`@unit{}`)
  ! wins, so hover `g` → kg.
  real :: g   !< wind speed [m/s] @unit{kg}

  ! §8.3 — @unit_assume on a declaration → U023.
  real :: t   !< @unit_assume{K: legacy fit}

  ! §8.3 — @unit{} on an assignment → U023.
  ws = 1.0   !< @unit{m/s}

  ! §12 — unparseable unit → U002 with suggested rewrite.
  real :: diff   !< @unit{m2/s}
end subroutine
```

Save this `.dimfort.toml` next to it:

```toml
[parser]
unit_comment_delimiters = [
  { open = "@unit{", close = "}" },
  { open = "[",      close = "]" },
]
```

- [ ] **Bracket pattern recognised** — `K` over `pa`, `a`/`b`/`c`,
      or `kg` (above) shows the bracket-captured unit in
      `vim.lsp.buf.hover()` output.
- [ ] **Plain `!` eligibility (§10)** — `ws` on line 4 has the
      `! @unit{m/s}` form (no Doxygen marker). Hover shows `m/s`.
- [ ] **U021 fires** — line with `[m/s] @unit{kg}` shows a warning
      sign in the signcolumn; the message names both captures;
      hover `g` shows `kg` (the first-listed pattern's capture).
- [ ] **U023 fires** — `@unit_assume{K: legacy fit}` on the
      `real :: t` decl shows a warning; message says "did you
      mean @unit?". Same for `@unit{m/s}` on `ws = 1.0` — the
      message suggests `@unit_assume` or
      `@unit_affine_conversion`.
- [ ] **U002 quick-fix** — `@unit{m2/s}` shows an error sign;
      message includes "did you mean 'm^2/s'?".
      `vim.lsp.buf.code_action()` offers **DimFort: Replace with
      'm^2/s'** as the preferred fix; accepting it edits
      `m2/s` → `m^2/s` and clears the diagnostic.
- [ ] **Pattern config invalidates cache** — comment out
      `{ open = "@unit{", close = "}" }` in the toml, save, then
      `:DimFortRestart`. The `@unit{m/s}` hover on `ws` should
      now show no unit (the canonical form is no longer
      configured in this project). Uncomment to restore.

## Polymorphism (0.2.3)

Save this as `poly_qa.f90` in a fresh folder (no `.dimfort.toml`
needed — defaults are fine). The scene covers four cases: clean
polymorphic body, dishonest body, caller mismatch, clean caller.

```fortran
module poly_qa
contains

  ! Case A — cleanly polymorphic body. No fires expected.
  subroutine avg_two(x, y, mean)
    real, intent(in)  :: x     !< @unit{'a}
    real, intent(in)  :: y     !< @unit{'a}
    real, intent(out) :: mean  !< @unit{'a}
    real :: half  !< @unit{1}
    half = 0.5
    mean = half * (x + y)
  end subroutine avg_two

  ! Case B — dishonest body: signature claims 'a but body adds {kg}.
  subroutine biased_avg(x, y, mean)
    real, intent(in)  :: x        !< @unit{'a}
    real, intent(in)  :: y        !< @unit{'a}
    real, intent(out) :: mean     !< @unit{'a}
    real, parameter   :: bias_kg = 1.0  !< @unit{kg}
    real :: half  !< @unit{1}
    half = 0.5
    mean = half * (x + y) + bias_kg
  end subroutine biased_avg

  ! Case C — caller passes kg into one 'a slot and m into another.
  subroutine caller_mismatch(m_in, l_in, out_mean)
    real, intent(in)  :: m_in      !< @unit{kg}
    real, intent(in)  :: l_in      !< @unit{m}
    real, intent(out) :: out_mean  !< @unit{kg}
    call avg_two(m_in, l_in, out_mean)
  end subroutine caller_mismatch

  ! Case D — caller passes consistent {m} to both slots.
  subroutine caller_clean(a_in, b_in, out_mean)
    real, intent(in)  :: a_in      !< @unit{m}
    real, intent(in)  :: b_in      !< @unit{m}
    real, intent(out) :: out_mean  !< @unit{m}
    call avg_two(a_in, b_in, out_mean)
  end subroutine caller_clean

  ! ------------------------------------------------------------------
  ! Function variants — same shape as Cases A-D but on a polymorphic
  ! FUNCTION. The call lives in an assignment RHS (call_expression
  ! node), and the function returns 'a too — exercises the return-
  ! side rendering, distinct from the subroutine_call path above.
  ! ------------------------------------------------------------------

  ! Case E — polymorphic function (clean body, no fires).
  function avg_two_f(x, y) result(out)
    real, intent(in) :: x    !< @unit{'a}
    real, intent(in) :: y    !< @unit{'a}
    real             :: out  !< @unit{'a}
    out = 0.5 * (x + y)
  end function avg_two_f

  ! Case F — clean caller of the function. No fires expected; mirrors
  ! Case D for the function path.
  subroutine caller_func_clean(a_in, b_in, r)
    real, intent(in)  :: a_in   !< @unit{m}
    real, intent(in)  :: b_in   !< @unit{m}
    real, intent(out) :: r      !< @unit{m}
    r = avg_two_f(a_in, b_in)
  end subroutine caller_func_clean

  ! Case G — H020 caller of the function. arg 1 (kg) and arg 2 (m)
  ! force 'a to inconsistent units; mirrors Case C for the function
  ! path.
  subroutine caller_func_mismatch(m_in, l_in, r)
    real, intent(in)  :: m_in   !< @unit{kg}
    real, intent(in)  :: l_in   !< @unit{m}
    real, intent(out) :: r      !< @unit{kg}
    r = avg_two_f(m_in, l_in)
  end subroutine caller_func_mismatch

end module poly_qa
```

### Diagnostics

On a fresh open, confirm exactly the following signs in the
`:lopen` / `:Trouble` list. Anything else (extra fire, missing fire,
wrong line, wrong code) is a regression.

- [ ] **Case A — no signs anywhere** on lines 5–12.
- [ ] **Case B — H023 error** on the assignment expression line
      `mean = half * (x + y) + bias_kg` (line 23). Message names
      the offending term (`bias_kg : kg`) and explains the body
      would force `'a = kg`.
- [ ] **Case C — H020 error** on the call site `call avg_two(m_in,
      l_in, out_mean)` (line 31). Message includes the **symmetric
      `(collides with arg N (name))` trailer** — both arg 1 and arg
      2 are named (no "first arg wins" asymmetry). The unit each
      slot implied (`kg` and `m`) is rendered.
- [ ] **Case D — no signs** on lines 36–41.
- [ ] **Case E — no signs anywhere** in the `avg_two_f` function
      body. Mirrors Case A's clean polymorphism, this time on a
      `function`.
- [ ] **Case F — no signs** in `caller_func_clean`. The
      `r = avg_two_f(a_in, b_in)` assignment is clean — function
      return `'a` binds to `m`, RHS unit = LHS unit (`m`). Mirrors
      Case D for the function path.
- [ ] **Case G — H020 error** on the call_expression inside the
      assignment `r = avg_two_f(m_in, l_in)`. Same shape as Case C
      (symmetric `collides with` trailer, two-way conflict between
      arg 1 = kg and arg 2 = m), just on a `call_expression` node
      instead of `subroutine_call`. There should be NO additional
      H001 / H004 / S001 on the assignment row — H020 alone owns
      the failure.
- [ ] **Diagnostic list** (`:lopen` or `:Trouble`) shows exactly
      **three** entries (H023 + H020 + H020), nothing else.

### Hover

Hover with `K` (or `vim.lsp.buf.hover()`).

- [ ] **Hover on a tyvar in a signature** — cursor on the `'a` in
      `@unit{'a}` on line 7 (Case A's `x`). Hover shows the
      polymorphic marker — exact rendering TBD per the spec; should
      indicate `'a` is a free type variable, not a concrete unit.
- [ ] **Hover on a clean call site (Case D)** — cursor on
      `call avg_two(...)` on line 41. Hover renders the
      **σ-binding panel**: `'a = m` (the unifier's solution at this
      call). Every slot row is 🟢.
- [ ] **Hover on the failed call site (Case C)** — cursor on
      `call avg_two(...)` on line 31. Hover surfaces the conflicting
      contributions per slot (`x → kg`, `y → m`, `mean → kg`); no
      single `σ` panel because unification failed.
- [ ] **Hover on `mean` in Case B body** — cursor on `mean` on
      line 23. The expression tree shows `'a` for `mean`, `kg` for
      `bias_kg`, the conflict row marked 🔴.
- [ ] **Hover on Case F's call assignment** — cursor on
      `r = avg_two_f(a_in, b_in)`. Tree root is the assignment;
      RHS row is the call_expression. Arg rows render bare `m` 🟢
      (no `(expected 'a)` trailer, no demote — same as Case D's
      subroutine_call path). RHS row's unit is `m` (the bound
      return), matching LHS `r : m` cleanly.
- [ ] **Hover on Case G's call assignment** — cursor on
      `r = avg_two_f(m_in, l_in)`. Arg rows render the spec form:
      `m_in : 'a = kg 🔴 (collides with arg 2)` and
      `l_in : 'a = m 🔴 (collides with arg 1)`. The call_expression
      RHS row shows 🔴 from the H020 propagation. Assignment row
      inherits 🔴. No spurious `(expected ...)` trailers on any arg
      row.

### Side panel

Cursor in each routine's body in turn (open the panel with
`:DimFortPanel` if not already visible). The Scope section should
list the routine's locals + formals; the polymorphic ones render
with `'a` in the unit column.

- [ ] **Case A — `avg_two`** — Scope lists `x`, `y`, `mean` each
      with unit `'a`, and `half` with unit `1`. All rows 🟢.
- [ ] **Case B — `biased_avg`** — Scope lists `x`, `y`, `mean` with
      `'a`, `bias_kg` with `kg`, `half` with `1`. The dishonest body
      assignment shows a 🔴 on `mean` (or a flag/marker that the
      body conflicts with the signature — exact UX TBD).
- [ ] **Case C — `caller_mismatch`** — Scope lists `m_in : kg`,
      `l_in : m`, `out_mean : kg`. Side panel surfaces the call-site
      σ failure somewhere (a dedicated row, marker, or callout —
      exact rendering to verify).
- [ ] **Case D — `caller_clean`** — Scope lists three rows in `m`.
      No σ markers; the call site is uneventful.
- [ ] **Case E — `avg_two_f`** — Scope lists `x`, `y`, `out` each
      with unit `'a`. All rows 🟢 (clean function body).
- [ ] **Case F — `caller_func_clean`** — Scope lists `a_in : m`,
      `b_in : m`, `r : m`. All 🟢. The Expression section (with
      cursor in the assignment) shows the call_expression RHS
      resolving to `m` cleanly.
- [ ] **Case G — `caller_func_mismatch`** — Scope lists `m_in : kg`,
      `l_in : m`, `r : kg`. The Expression section surfaces the
      H020 conflict on the call_expression child of the assignment
      (same UX as Case C's subroutine_call).

### Interactive — H021 / H022 probes

- [ ] **H021 (tyvar in forbidden position)** — add a module-level
      declaration at the top of `poly_qa`:
      `real :: bad_global !< @unit{'a}`. Save. Expect an **H021
      error** on that line: type variables aren't allowed in module-
      level scope (only in routine arg lists / locals). Undo with `u`.
- [ ] **H022 probe (tyvar exponent must be rational)** — change
      Case A's `mean` annotation to `!< @unit{'a^kappa}`. Save.
      Expect an **H022 error** stating the tyvar's exponent must be
      a literal rational (the symbolic `kappa` isn't supported in
      the polymorphism path). Undo with `u`.

### Known gaps in this annex

- **Quick-fix coverage** — there's no Polymorphism-specific code
  action today. The existing U002 / U023 / "Add @unit{}" actions
  still apply normally on this file; re-run those steps from the
  main Configurable-delimiters section if needed.
- **Inlay hints** — `vim.lsp.inlay_hint` is off by default;
  polymorphic vars under inlays render as `'a`. Toggle on and walk
  Case D to confirm if you care about that surface today.
- **Cross-file polymorphism** — this scene is single-file. Add a
  separate `caller.f90` + `lib.f90` pair if cross-file lookup of a
  polymorphic signature needs verifying.
