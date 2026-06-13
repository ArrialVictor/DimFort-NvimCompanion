---
name: Bug report
about: A wrong unit verdict, a crash, a panel/hover glitch, or unexpected behaviour
title: ""
labels: bug
---

<!-- The Nvim companion is a thin LSP client; many bugs are actually in
     the DimFort server. The version block below helps route the report. -->

**DimFort server version**: <!-- `dimfort --version` -->
**Nvim companion version**: <!-- git rev: `git -C <plugin-dir> rev-parse --short HEAD` (no version file yet) -->
**Neovim version**: <!-- `nvim --version | head -1` -->
**OS**: <!-- macOS 14 / Ubuntu 24.04 / … -->

**What happened**
<!-- What you saw versus what you expected — a wrong diagnostic, a hover
     popup that's wrong/missing, a panel section glitch, a crash. -->

**Minimal reproducer**
<!-- The smallest Fortran snippet (with the relevant @unit annotations)
     that shows it. A few lines is ideal. -->

```fortran

```

**LSP trace** (very helpful)
<!-- `:LspLog` opens the Neovim LSP log file; paste the last ~30–50 lines
     around the failure. Also useful: `:checkhealth dimfort` if defined,
     or `:messages` for transient errors. -->

```

```

**Additional context**
<!-- Did this work in a previous version? Project layout / dimfort.toml
     contents if relevant. -->
