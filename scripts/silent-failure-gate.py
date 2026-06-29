#!/usr/bin/env python3
"""Silent-failure regression gate (Lua).

Companion of DimFort's server-side gate, adapted to Lua. The Nvim
companion doesn't have a "true silent-failure" anti-pattern in the
shape of Python's bare ``except:`` or TypeScript's ``catch {}`` —
``pcall`` is Lua's explicit "I know this might fail" construct,
and it's the only practical place silent failures hide. So this
gate is **diff-aware only**: hard bans don't apply.

Diff-aware annotation requirement
---------------------------------
A new line containing ``pcall(`` must either:

  1. carry an ``audited(0.2.X)`` annotation within ±5 lines
     (documenting why the result is intentionally discarded), OR
  2. capture the result in an ``ok``-prefixed local — patterns
     like ``local ok, val = pcall(...)`` or ``local ok_panel = ...``
     are considered self-documenting.

This catches `pcall(fn)` statements that drop the boolean ok
result without explanation.

Exit codes
----------
0  Gate passes.
1  One or more findings; details printed to stderr.

Usage
-----
::

    BASE_REF=origin/main python scripts/silent-failure-gate.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANNOTATION = re.compile(r"audited\(0\.2\.\d+\)")
WINDOW = 5  # lines of context to search for the annotation

# New pcall to flag.
PCALL = re.compile(r"\bpcall\s*\(")

# Capture-form pcall: any `ok`-prefixed identifier near `= pcall(`.
CAPTURE_OK = re.compile(r"\bok\w*\s*,.*=\s*pcall\b|local\s+ok\w*\s*=\s*pcall\b")


def annotation_findings_in_diff(base_ref: str) -> list[tuple[Path, int, str, str]]:
    cmd = [
        "git",
        "diff",
        "--unified=0",
        "--no-color",
        f"{base_ref}...HEAD",
        "--",
        "lua/**/*.lua",
        "plugin/**/*.lua",
    ]
    try:
        diff = subprocess.check_output(cmd, cwd=ROOT, text=True)
    except subprocess.CalledProcessError as exc:
        print(f"silent-failure-gate: git diff failed ({exc})", file=sys.stderr)
        sys.exit(2)

    findings: list[tuple[Path, int, str, str]] = []
    current_path: Path | None = None
    current_line = 0
    for raw in diff.splitlines():
        if raw.startswith("+++ b/"):
            current_path = ROOT / raw[6:]
        elif raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
            if m:
                current_line = int(m.group(1)) - 1
        elif raw.startswith("+") and not raw.startswith("+++"):
            current_line += 1
            line = raw[1:]
            if PCALL.search(line) and not CAPTURE_OK.search(line):
                if current_path is None or not current_path.exists():
                    continue
                text = current_path.read_text(encoding="utf-8")
                lines = text.splitlines()
                lo = max(0, current_line - 1 - WINDOW)
                hi = min(len(lines), current_line + WINDOW)
                window = "\n".join(lines[lo:hi])
                if not ANNOTATION.search(window):
                    findings.append(
                        (
                            current_path,
                            current_line,
                            "new bare `pcall(...)` without an "
                            "`audited(0.2.X)` annotation or an `ok` "
                            "capture",
                            line.strip(),
                        )
                    )
        elif raw.startswith(" "):
            current_line += 1

    return findings


def main() -> int:
    base_ref = os.environ.get("BASE_REF")
    if not base_ref:
        # No base ref — push-to-main or local invocation without
        # diff context. Gate has nothing to check (no hard bans for
        # Lua); exit clean.
        print("silent-failure-gate: OK (no BASE_REF; diff-aware only)")
        return 0

    failures = annotation_findings_in_diff(base_ref)
    if not failures:
        print("silent-failure-gate: OK")
        return 0

    print(
        "silent-failure-gate: FAILED — the following patterns regress the "
        "0.2.7 silent-failure audit:",
        file=sys.stderr,
    )
    for path, lineno, desc, content in failures:
        rel = path.relative_to(ROOT)
        truncated = content if len(content) <= 100 else content[:97] + "..."
        print(f"  {rel}:{lineno}  [{desc}]", file=sys.stderr)
        print(f"    {truncated}", file=sys.stderr)
    print(
        "\nFix: either (a) capture the result — `local ok, val = "
        "pcall(...)` — and branch on `ok`, or (b) document why the "
        "failure is silent-OK with `audited(0.2.X): silent-OK — "
        "<reason>` in a Lua comment near the call.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
