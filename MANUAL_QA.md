# Manual QA — DimFort Neovim companion (display walk)

A short visual smoke walk run **before tagging a release**. It covers
only what an LSP client test can't reach: **how Neovim renders** the
server's payloads. Server-side correctness (diagnostic codes, hover /
panel / inlay / workspace / coverage / code-action / completion
payloads) is verified by the LSP integration suite at
`DimFort/tests/lsp_integration/` — this walk does **not** re-check
those.

> Items marked `*` are covered by an internal automated harness
> (not shipped). Spot-check on release rather than
> exhaustively re-walking.

Each step lists the **exact** visible result; anything that differs is
a regression to file. The same fixtures are reused across surfaces, so
save all six before starting.

## Fixtures

Save these into a fresh directory. The walks below reference them by
name + line number.

### `qa.f90` — main scene

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
    d         = c_sound * t            ! OK
    bogus     = c_sound * t            ! H001
    t_celsius = t - 273.15             ! H010
    combo     = c_sound**2 + d * d / (t * t) - c_sound * c_sound
    ln_p      = log(ref_pressure)
    rt_e2     = sqrt(c_sound * c_sound)
    abs_t     = abs(t)
    recovered   = exp(log(ref_pressure) + log(ref_pressure))
    rho_brandes = 1.e3 * 0.178 * (d * 2.0 * 1000.0)**(-0.922)   !< @unit_assume{kg/m^3 : empirical-fit Brandes2007}
    ref_pressure = dynamic_pressure(0.5 * c_sound)
    call scale_pressure(2.0 * ref_pressure)
  end subroutine checks

  subroutine scale_pressure(p)
    real, intent(in) :: p   !< @unit{Pa}
    ref_pressure = p
  end subroutine scale_pressure
end module qa_mod
```

### `scale_qa.f90` — scale-mode display

```fortran
module scale_qa
  real, parameter :: PA_PER_HPA = 100.   !< @unit{Pa/hPa}
  real :: play   !< @unit{Pa}
  real :: phpa   !< @unit{hPa}
  real :: t_k    !< @unit{K}
  real :: t_c    !< @unit{degC}
contains
  subroutine s()
    phpa = play
    phpa = play / PA_PER_HPA
    t_k  = t_c
  end subroutine s
end module scale_qa
```

### `unparsed_qa.f90` — P001 squiggle display

```fortran
subroutine unparsed_qa(press, vel)
  implicit none
  real, intent(in)  :: press   !< @unit{Pa}
  real, intent(out) :: vel     !< @unit{m/s}
  vel = press
  vel = * / +
  vel = 0.0
  vel = vel * 2.0
end subroutine unparsed_qa
```

### `imports_qa.f90` — imports panel + cross-file navigation

```fortran
module phys_base
  real :: g0   !< @unit{m/s^2}
end module phys_base

module phys_constants
  use phys_base
  real :: play     !< @unit{Pa}
  real :: grav     !< @unit{m/s^2}
  real :: density
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

### `delim_qa.f90` + companion `dimfort.toml` — delimiter display

```fortran
subroutine delim_demo
  implicit none
  real :: ws   ! @unit{m/s}
  real :: pa   ! atmospheric pressure [Pa] at the surface
  ! mass loading [kg]
  real :: kg
  real :: a, b, c   ! [m]
  real :: g   !< wind speed [m/s] @unit{kg}
  real :: t   !< @unit_assume{K: legacy fit}
  ws = 1.0   !< @unit{m/s}
  real :: diff   !< @unit{m2/s}
end subroutine
```

```toml
[parser.unit_comments]
unit = [
  { open = "@unit{", close = "}" },
  { open = "[",      close = "]" },
]
```

### `poly_qa.f90` — polymorphic `'a` display

```fortran
module poly_qa
contains
  subroutine avg_two(x, y, mean)
    real, intent(in)  :: x     !< @unit{'a}
    real, intent(in)  :: y     !< @unit{'a}
    real, intent(out) :: mean  !< @unit{'a}
    real :: half  !< @unit{1}
    half = 0.5
    mean = half * (x + y)
  end subroutine avg_two

  subroutine caller_clean(a_in, b_in, out_mean)
    real, intent(in)  :: a_in      !< @unit{m}
    real, intent(in)  :: b_in      !< @unit{m}
    real, intent(out) :: out_mean  !< @unit{m}
    call avg_two(a_in, b_in, out_mean)
  end subroutine caller_clean
end module poly_qa
```

## Setup

Open `qa.f90` in Neovim with DimFort configured; the LSP attaches
automatically. Give the first workspace check a moment to finish,
then walk the surfaces below.

---

## Surface 1 — Diagnostic rendering (`vim.diagnostic`)

Diagnostics render per the user's `vim.diagnostic` config (signs,
underline, virtual text). Confirm the three severities are visibly
distinct on the qa fixtures:

- [ ] * **Error** — on `qa.f90:25` (`bogus = c_sound * t`): the
      configured error rendering applies (default config: `E` sign in
      the sign column + red underline + red virtual text suffix).
- [ ] * **Warning** — on `qa.f90:23` (`real :: t_celsius`): warning
      rendering applies (default: `W` sign + orange underline + orange
      virtual text).
- [ ] * **Info (P001)** — on `unparsed_qa.f90:6` (`vel = * / +`): info
      rendering applies (default: no sign + faint blue underline /
      squiggle). Visibly distinct from real errors above the line.
- [ ] * **Info (U020)** — on `qa.f90:35` (the `@unit_assume` line):
      surfaces only as the panel's 🔵 row, no inline styling, no
      sign in the sign column (informational acknowledgement, not
      a problem).
- [ ] **P001 squiggle localised** — the blue underline on
      `unparsed_qa.f90` covers exactly lines 6 and 7 (the bad line and
      the swallowed `vel = 0.0`). Line 8 (`vel = vel * 2.0`) is
      **not** blue.
- [ ] **`vim.diagnostic.open_float()`** on a diagnostic line shows
      the code + message in a floating window. `:lopen` errors with
      `E776` because diagnostics don't populate the loclist on their
      own — `vim.diagnostic.setloclist()` first, then `:lopen` shows
      the entries.

## Surface 2 — Hover display (`K` / `vim.lsp.buf.hover()`)

Hover defaults to **`short`**. `K` opens a floating window with the
unit surface.

- [ ] * **Single-symbol hover** — `K` on `c_sound` (`qa.f90:2`): the
      floating window shows the single row `c_sound : m·s⁻¹` (the
      unit is rendered with **middle dot** `·` and **superscript
      minus** `⁻¹`, not ASCII `m/s`).
- [ ] **Tree rendering** — `K` on the product `c_sound * t`
      (`qa.f90:24`). The floating window renders the tree with
      **box-drawing connectors** (`├──`, `└──`), **column-aligned**
      unit and marker columns, and **emoji glyphs** (🟢 / 🟡 / 🔴 / 🔵)
      in the rightmost column:

      ```
      🟢 DimFort
      c_sound * t  :  m       🟢
      ├── c_sound  :  m·s⁻¹   🟢
      └── t        :  s       🟢
      ```

      Subsequent steps assume the same alignment pattern.
- [ ] * **Cycle hover mode** — `:DimFortCycleHover` cycles
      `disabled → short → detailed`; each tick echoes
      `DimFort: hover → <mode>` and **restarts the server**
      (verifiable via `:DimFortStatus` — the `active client id`
      changes). Hover content changes shape on the next invocation;
      disabled silences hover.
- [ ] **Pure-signature hover** — in `detailed`, `K` on the
      function-def header `dynamic_pressure` (`qa.f90:5`). Floating
      window collapses to a single signature line, no per-arg row
      table.
- [ ] **`(expected …)` trailer style** — in `detailed`, `K` on the
      `=` of `qa.f90:25` (`bogus = c_sound * t`). The RHS row's
      trailer `(expected kg)` renders distinctly from the row's
      primary text; the row's marker is 🟡 not 🟢.
- [ ] **`@unit_assume` 🔵 overlay** — in `detailed`, `K` on
      `qa.f90:35` (`rho_brandes`). The 🔵 glyph sits on the **RHS
      row only**, not the assignment header. Trailer reads
      `(assumed: empirical-fit Brandes2007)` in the same trailer
      style as `(expected …)`.

## Surface 3 — Side panel rendering

The panel opens automatically when DimFort attaches. `:DimFortTogglePanel`
closes / reopens it.

### Layout

- [ ] * **Sections divider** — a horizontal separator line spans the
      panel width between Cursor / Scope, Scope / Imports, and
      Imports / footer. Visible dividers always sit between two
      visible neighbours.
- [ ] **Column alignment** — in the Expression tree (panel for any
      qa.f90 line), the unit column and marker column are aligned
      across rows regardless of identifier length.
- [ ] * **Footer always present** — `:DimFortToggleCursor`,
      `:DimFortToggleScope`, `:DimFortToggleImports` all three off:
      the panel still shows the `File: …   Project: …` footer row.
- [ ] **Dividers adapt** — toggle Cursor off; the divider that sat
      between Cursor and Scope disappears (no stranded separator).
      Same on toggling Scope.

### Behavior

- [ ] **Cursor-follow debounce** — move cursor rapidly between
      `qa.f90:10` (function body) and `qa.f90:25` (subroutine body).
      The panel dims briefly during refresh (~200 ms debounce, via
      `Comment` highlight group), then re-renders with the
      appropriate scope.

### Workspace check display

- [ ] **`Project: –` before first check** — footer's Project segment
      reads `Project: –` dimmed.
- [ ] **Braille spinner** — run `:DimFortCheckWorkspace`. The
      Project segment becomes a spinner cycling through
      `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` for the duration of the check.
- [ ] **Settles on completion** — when
      `dimfort/workspaceCheckCompleted` arrives, the segment settles
      to `Project: <pct>% (🟡 N 🔴 M)`. A
      `DimFort workspace check complete: …` line fires through
      `vim.notify` (check `:messages`).
- [ ] **Stale dim** — after a successful check, edit any Fortran
      buffer. The Project segment dims. The File segment continues
      to update live on each edit.
- [ ] **Restart resets** — `:DimFortRestart` reverts the footer to
      `File: –   Project: –` dimmed. Next workspace check
      re-populates.

## Surface 4 — Progress widget (`[N/5]` workspace-check phase counter)

Requires a `workDoneProgress` widget — `fidget.nvim` or equivalent.
Without one this surface is a **no-op** (Neovim's default doesn't
render `workDoneProgress`).

Best verified on a real-world ~2400-file Fortran codebase (`qa.f90`
alone completes too fast to read every phase).

- [ ] **All five phases observed** — run `:DimFortCheckWorkspace`
      on the large workspace. The fidget notification cycles through:

      ```
      [1/5] loading <i>/<N> <file>
      [2/5] indexing modules <i>/<N> <file>
      [3/5] checking <i>/<N> <file>
      [4/5] published <N>/<N>
      [5/5] projecting coverage…
      ```

- [ ] **`[5/5]` persistence** — the `[5/5] projecting coverage…`
      message stays visible for the ~5 s post-publish projection
      window. Clears only when `dimfort/workspaceCheckCompleted`
      arrives and the panel footer's Project column populates.

## Surface 5 — `:DimFortStatus` + `vim.notify`

- [ ] * **`:DimFortStatus`** prints **exactly** these 13 lines (the
      `active client id` is whatever number this session assigned —
      the value 1 is typical for a fresh session):

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

- [ ] * **Cycle commands echo new mode** — each of the following
      cycle commands reports the new value via `vim.notify` (and the
      echo area) on every tick:
      - `:DimFortCycleHover` → `DimFort: hover → {disabled,short,detailed}`
      - `:DimFortCycleScale` → `DimFort: scale checking → {on,off,auto}`
      - `:DimFortCycleCache` → `DimFort: cache → {off,read-only,read-write}`
      - `:DimFortCycleSortMode` → `DimFort: sort mode → {line,alphabetic,status}`
      - `:DimFortCycleUnitDisplay` → `DimFort: unit display → {input,canonical,both}`
      - `:DimFortCycleCoverage` → `DimFort: coverage {gutter,background,disabled}`

- [ ] **Duplicate workspace trigger** — invoke
      `:DimFortCheckWorkspace` twice while a check is in flight. The
      second emits a `vim.notify` line
      `DimFort: workspace check already in progress` (no second
      worker). Confirm with `:messages`.
- [ ] **Restart notify** — `:DimFortRestart` emits a reset
      confirmation via `vim.notify`; footer reverts to dim
      (Surface 3 cross-check).

## Surface 6 — Inlay hints display

- [ ] * **Toggle visibility** — `:DimFortToggleInlayHints` →
      `[m·s⁻¹]`-style virtual text appears after variable use sites
      (qa.f90 makes this easy to scan). Toggle again → virtual text
      disappears.
- [ ] **Polymorphic vars full-weight** — open `poly_qa.f90`, toggle
      on, cursor in `avg_two`'s body. Virtual text on `x`, `y`,
      `mean` reads `['a]` at the same visual weight as a concrete
      `[m]`-style virtual text (no `Comment` highlight — polymorphism
      is a real annotation, not unknown).
- [ ] **Concrete vars** — in `caller_clean`, the virtual text on
      `a_in`, `b_in` reads `[m]`. Same visual weight as the
      polymorphic case.

## Surface 7 — Code actions UI

`vim.lsp.buf.code_action()` (Neovim 0.11 default mapping: `gra`)
with the cursor on the relevant fixture line.

- [ ] * **Add `@unit{}`** — cursor on `t_celsius` (`qa.f90:23`). The
      code-action picker surfaces **"add `@unit{}`"**. Applying
      inserts `!< @unit{}` and **leaves the cursor between the
      braces** (the `$0` snippet placeholder target works under
      Neovim's snippet apply path).
- [ ] * **Extract literal** — cursor on `273.15` (`qa.f90:26`). Picker
      surfaces **"extract literal to PARAMETER"**. Applying prompts
      via `vim.ui.input` for a name, then inserts a typed
      `real, parameter` declaration and replaces the literal with the
      new name.
- [ ] **U002 preferred fix** — cursor on `@unit{m2/s}`
      (`delim_qa.f90:18`). Picker surfaces **"DimFort: Replace with
      'm^2/s'"** as the **preferred** action (annotated as such by
      the LSP server; surfaced by Neovim's picker accordingly).
      Applying edits `m2/s` → `m^2/s` and clears the diagnostic.

## Surface 8 — Navigation & completion

- [ ] * **`vim.lsp.buf.definition()` lands at decl** — on a `c_sound`
      use, `vim.lsp.buf.definition()` (default mapping `gd`) lands
      the cursor on `qa.f90:2` (the declaration line).
- [ ] **Cross-file `<CR>` in panel** — open `imports_qa.f90`, panel
      visible, cursor in `step`. In the Imports section, `<CR>` on
      `play` navigates to its declaration (same file). Drop the
      `, only: …` filter on `solver`'s `use phys_constants` to expose
      the transitive `g0` row; `<CR>` on it **jumps cross-file** to
      `phys_base`'s declaration line. Same-buffer or cross-buffer
      depending on the row.
- [ ] * **LSP completion in `@unit{`** — type a new `!< @unit{` and
      trigger LSP completion (`<C-x><C-o>`, or your completion
      plugin's trigger); unit names are offered in the candidates
      popup.

## Surface 9 — Filter commands

- [ ] * **Scope filter** — `:DimFortScopeFilter Pa` narrows the Scope
      section to vars whose name or unit matches `Pa`. Panel header
      reads `Filter: "Pa"`. Scopes with no surviving variables are
      hidden. `:DimFortScopeFilter` with no argument clears it.
- [ ] **Imports filter** — `:DimFortImportsFilter gravity` narrows
      the Imports section to `gravity_at(m)`. **Does not** affect
      Scope (independent of the Scope filter).

## Surface 10 — Coverage visualization

- [ ] * **Three-mode cycle** — `:DimFortCycleCoverage` cycles
      `gutter → background → disabled`. `vim.notify` reports each
      tick. Visual states:
      - **gutter**: green dots in the sign column on annotated /
        clean lines; out-of-scope lines (module / contains / blank /
        comment) carry **no** sign. **On yellow / red lines the
        standard `vim.diagnostic` `W` / `E` sign occupies the column
        — the coverage layer steps aside to avoid competing for the
        slot.** With U005 propagation, every line referencing an
        unannotated identifier paints with the `W` sign too. To
        force the coverage layer to paint yellow / red dots itself
        (e.g. if you've turned `vim.diagnostic` signs off), set
        `require("dimfort.coverage").config.gutter_tiers = {
        "green", "yellow", "red", "blue" }` after `setup()`.
      - **background**: low-alpha tint on each in-scope line in the
        matching tier colour; sign-column dots **gone**. The two
        modes are **mutually exclusive**.
      - **disabled**: all coverage decorations clear.
- [ ] * **No LSP restart on mode flip** — note the `active client id`
      via `:DimFortStatus`. Cycle the coverage mode three times. Run
      `:DimFortStatus` again — the **same** `active client id`
      (no restart). Contrast with `:DimFortCycleHover` which **does**
      restart the server (active client id changes) — the
      restart-or-not difference is the verification.
- [ ] **Highlight customisation repaints** —
      `:hi DimFortCoverGreen guifg=#00ff00` (gutter mode) → green
      dots repaint on the next refresh.
      `:hi DimFortCoverBgGreen guibg=#003300` (background mode) →
      tint refreshes on next edit.

## Surface 11 — `:DimFortCoverageReport` floating window

- [ ] * **Cold-open populates** — fresh session, open `qa.f90`,
      immediately run `:DimFortCoverageReport`. A floating window
      opens with a File / Project table. File row populates with the
      current buffer's coverage stats (cold-open works without
      edits).
- [ ] **Project row dim until checked** — before
      `:DimFortCheckWorkspace`, the Project row reads
      `Run :DimFortCheckWorkspace to compute.`. After a check
      completes, the Project row updates in-place asynchronously
      (driven by `dimfort/workspaceCheckCompleted`; no flicker; the
      window stays open).
- [ ] **Stale marker on edits** — after a workspace check, edit any
      buffer. The Project row reads
      `Run :DimFortCheckWorkspace to update.` to signal the snapshot
      is stale.

## Surface 12 — Panel sort & unit-display modes (0.2.6)

- [ ] * **Sort cycle** — `:DimFortCycleSortMode` cycles
      `line → alphabetic → status`. Both Scope and Imports re-sort
      in the **same panel repaint** (no LSP round-trip — panel
      repaints from cached payload).
- [ ] **Sort persistence** — in-session toggles do not persist to
      disk. To start a session with a non-default sort, set
      `panel_sort_mode = "alphabetic"` in your
      `require('dimfort').setup{...}` call.
- [ ] * **Unit-display cycle** — `:DimFortCycleUnitDisplay` cycles
      `canonical → input → both`. Column layout changes per mode in
      **both** Scope and Imports together:
      - `canonical` (default): one column, base-SI form (`m·s⁻¹`).
      - `input`: one column, annotation as written (`m/s`).
      - `both`: two columns side-by-side — `input` then `canonical`,
        no arrow / separator glyph between (column spacing conveys
        the relationship; matches the VSCode panel's `<td>`
        convention).
- [ ] **Unit-display persistence** — same setup-time pattern as
      sort: `panel_unit_display_mode = "both"` in `setup{}`.

## Surface 13 — Config-file commands

These need a **fresh workspace folder** with no `dimfort.toml` and
no `units.toml`. `cd` into an empty directory before each
subsection.

### `dimfort.toml`

- [ ] * **Empty cold-create** — `:DimFortOpenConfig` → pick
      `Project configuration file (dimfort.toml)`. A `vim.ui.select`
      sub-pick shows `Empty file` and
      `Reference template (all sections commented out)`. Pick
      `Empty file`. A new `dimfort.toml` appears at the cwd, opens
      in the current buffer, contains just the minimal header.
      `vim.notify`: `DimFort: created <path>/dimfort.toml`.
- [ ] * **Reference cold-create** — same, pick `Reference template …`.
      The file's `[units]` / `[parser]` / `[diagnostics]` /
      `[scale]` / `[project]` section headers are all present but
      each line is prefixed with `# `.
- [ ] * **Warm-open** — run again, pick
      `Project configuration file …`. Opens existing file with **no
      sub-pick** and **no modification**. No "created" notify.

### `units.toml`

- [ ] * **Empty cold-create** — `:DimFortOpenConfig` → pick
      `Project units file (units.toml)`. Sub-pick shows
      `Empty file` and `Reference template …`. Pick `Empty file`. A
      new `units.toml` appears alongside an empty stub. A new
      `dimfort.toml` is auto-created with
      `[units]\nfile = "units.toml"`. Notify:
      `DimFort: created units.toml + wired into dimfort.toml`.
- [ ] **Reference cold-create** — pick `Reference template …`. The
      `[base]` / `[prefixes]` / `[derived]` sections are all present
      with `# `-prefixed lines.
- [ ] **Auto-wire appends to existing toml** — pre-create a
      `dimfort.toml` with only `[diagnostics]\nH001 = "off"\n`. Run
      command, pick units file. Existing `dimfort.toml` is
      **appended with** `[units]\nfile = "units.toml"`; original
      sections preserved.
- [ ] * **Existing `[units]` declines** — pre-create a `dimfort.toml`
      containing `[units]\nother_key = "value"\n`. Run command, pick
      units file. WARN-level notify:
      `DimFort: created units.toml. Your dimfort.toml already has
      a [units] section — add 'file = "units.toml"' under it to
      enable the new file.`. The `dimfort.toml` is **not**
      modified.

## Surface 14 — Server-restart behaviour on cycle commands

- [ ] * **Restarting cycles** — `:DimFortCycleHover`,
      `:DimFortCycleScale`, `:DimFortCycleCache` each **restart the
      server** on every tick. Verify via `:DimFortStatus` — the
      `active client id` changes after each tick. The new mode
      persists across the restart.
- [ ] * **Non-restarting cycles** — `:DimFortCycleCoverage`,
      `:DimFortCycleSortMode`, `:DimFortCycleUnitDisplay` each do
      **not** restart the server (client-side rendering modes only;
      `active client id` is stable).
- [ ] **`:DimFortClearCache`** — deletes `.dimfort-cache/` under
      the workspace root and restarts the server. Notify:
      `DimFort: cache cleared (…)`. When the cache directory does
      not exist, notify:
      `DimFort: cache directory does not exist (already clean).`.

## Surface 15 — Command-name parity

- [ ] * **`:DimFortTogglePanel`** is the canonical name (renamed from
      `:DimFortPanelToggle` in 0.2.6 for cross-companion consistency).
      `:DimFortPanelToggle` is **not** offered as a command (the old
      name is gone, beta-period rename per release-cycle convention).

## Surface 16 — Polymorphic `'a` rendering

(Open `poly_qa.f90`.)

- [ ] * **Scope rows** — cursor in `avg_two`'s body. Scope lists `x`,
      `y`, `mean` each with unit cell `'a` and `half` with `1`. The
      `'a` cells render at **full weight** (no `Comment` highlight)
      — same visual weight as concrete units like `m` in
      `caller_clean`'s Scope (also cursor inside it to compare).
- [ ] **Inlay full weight** — covered under Surface 6 (cross-check
      that polymorphic virtual text matches concrete virtual-text
      weight).
- [ ] **`Comment` highlight scope** — confirm the `Comment` highlight
      group fires only on bare `?` / bare `-` / trailing `= ?`. A
      plain `'a` is **never** dimmed.

## Surface 17 — Delimiter-config display

(Open `delim_qa.f90` with the companion `dimfort.toml` saved next
to it.)

- [ ] * **Bracket-pattern hover** — `K` on `pa`, `a`/`b`/`c`, or `kg`
      shows the bracket-captured unit in the hover floating window
      (the toml configures `[…]` as a unit delimiter pattern
      alongside `@unit{…}`).
- [ ] * **Plain `!` eligibility** — `K` on `ws` (line 4) shows `m/s`;
      the `! @unit{m/s}` form has no Doxygen marker but still
      surfaces the unit.
- [ ] **U002 quick-fix** — `vim.lsp.buf.code_action()` on the
      `@unit{m2/s}` line surfaces **DimFort: Replace with 'm^2/s'**;
      applying clears the diagnostic. (Same UX as Surface 7's U002
      step — verified here against the delimiter scene.)
- [ ] **Cache invalidation on pattern change** — comment out
      `{ open = "@unit{", close = "}" }` in the toml, save, then
      `:DimFortRestart`. `K` on `ws` should now show no unit
      (canonical form no longer configured). Uncomment to restore.

---

Notes on out-of-scope checks: every step that asked for a specific
diagnostic code / line / message / payload shape in the previous
manual-QA shape has been removed in favour of the LSP integration
suite, which now exercises:

- diagnostics firing on the qa fixture
  (`tests/lsp_integration/test_diagnostics.py`)
- hover payload structure (`test_hover.py`)
- inlay & panel payload (`test_inlay_and_panel.py`)
- workspace check + `workspaceCheckCompleted` notification
  (`test_workspace.py`)
- coverage `lineStatus` tier classifications + U005 propagation
  (`test_coverage.py`)
- code-action data + completion candidates
  (`test_actions_completion.py`)
- lifecycle / `initialize` / cancellation (`test_lifecycle.py`)

If a regression suggests the wire payload changed shape, **start
there**; if everything in this walk passes but the suite fails,
suspect a server-side change.
