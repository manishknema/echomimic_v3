#!/usr/bin/env python3
"""
scan_imports.py

Static import + symbol scan for research repos that have implicit dependencies.

Outputs:
  - imports.csv: file,line,kind,module,name
  - third_party.txt: unique top-level third-party modules
  - stdlib.txt: unique stdlib modules
  - local.txt: unique repo-local modules (best-effort)
  - name_errors.txt: best-effort undefined names referenced at module scope (heuristic)

Notes:
  - This is static analysis. It does not execute code.
  - "name_errors" is heuristic: it flags unknown Name nodes at module level,
    excluding known builtins and names defined in the module.
"""

from __future__ import annotations

import ast
import csv
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, List, Optional, Set, Tuple

# A conservative stdlib set is hard to ship without Python version tables.
# We use sys.stdlib_module_names when available (3.10+) and treat the rest as third-party/local.
STDLIB: Set[str] = set(getattr(sys, "stdlib_module_names", set()))
BUILTINS: Set[str] = set(dir(__builtins__))  # type: ignore[arg-type]

@dataclass(frozen=True)
class ImportRec:
    file: str
    line: int
    kind: str        # "import" or "from"
    module: str      # top-level module
    name: str        # full import target (best-effort)

def top_module(name: str) -> str:
    return name.split(".", 1)[0].strip()

def iter_py_files(root: Path) -> Iterator[Path]:
    for p in root.rglob("*.py"):
        # skip common junk dirs
        parts = set(p.parts)
        if any(x in parts for x in (".git", ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache")):
            continue
        yield p

def parse_file(p: Path) -> Optional[ast.Module]:
    try:
        txt = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        txt = p.read_text(encoding="utf-8", errors="replace")
    try:
        return ast.parse(txt, filename=str(p))
    except SyntaxError:
        return None

def collect_imports(mod: ast.Module, file_rel: str) -> List[ImportRec]:
    out: List[ImportRec] = []
    for node in ast.walk(mod):
        if isinstance(node, ast.Import):
            for alias in node.names:
                full = alias.name
                out.append(ImportRec(file_rel, getattr(node, "lineno", 0), "import", top_module(full), full))
        elif isinstance(node, ast.ImportFrom):
            if node.module is None:
                continue
            full_mod = node.module
            for alias in node.names:
                nm = f"{full_mod}:{alias.name}"
                out.append(ImportRec(file_rel, getattr(node, "lineno", 0), "from", top_module(full_mod), nm))
    return out

def is_probably_local(mod_top: str, root: Path) -> bool:
    # best-effort: if there is a package/dir or module file matching top module name.
    if (root / mod_top).is_dir() and (root / mod_top / "__init__.py").exists():
        return True
    if (root / f"{mod_top}.py").exists():
        return True
    return False

def module_scope_defined_names(mod: ast.Module) -> Set[str]:
    defined: Set[str] = set()
    for node in mod.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            defined.add(node.name)
        elif isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    defined.add(t.id)
        elif isinstance(node, ast.AnnAssign):
            if isinstance(node.target, ast.Name):
                defined.add(node.target.id)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                defined.add((alias.asname or alias.name).split(".", 1)[0])
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                defined.add(alias.asname or alias.name)
    return defined

def collect_module_scope_name_uses(mod: ast.Module) -> Set[str]:
    # Only look at module-level statements (not inside function bodies),
    # because import-time explosions usually occur there.
    used: Set[str] = set()

    class Visitor(ast.NodeVisitor):
        def visit_Name(self, node: ast.Name) -> None:
            used.add(node.id)

        # Don't descend into function/class bodies
        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            return

        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            return

        def visit_ClassDef(self, node: ast.ClassDef) -> None:
            return

    v = Visitor()
    for node in mod.body:
        v.visit(node)
    return used

def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: scan_imports.py <repo_root> <out_dir>", file=sys.stderr)
        return 2

    repo_root = Path(sys.argv[1]).resolve()
    out_dir = Path(sys.argv[2]).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    all_imports: List[ImportRec] = []
    third_party: Set[str] = set()
    stdlib: Set[str] = set()
    local: Set[str] = set()
    name_errors: List[Tuple[str, str]] = []

    for p in iter_py_files(repo_root):
        rel = str(p.relative_to(repo_root))
        mod = parse_file(p)
        if mod is None:
            continue

        recs = collect_imports(mod, rel)
        all_imports.extend(recs)

        defined = module_scope_defined_names(mod)
        used = collect_module_scope_name_uses(mod)

        # Heuristic undefined at module scope
        unknown = sorted(x for x in used if x not in defined and x not in BUILTINS)
        if unknown:
            for x in unknown[:50]:  # keep bounded
                name_errors.append((rel, x))

        for r in recs:
            m = r.module
            if not m:
                continue
            if is_probably_local(m, repo_root):
                local.add(m)
            elif m in STDLIB:
                stdlib.add(m)
            else:
                third_party.add(m)

    # Write imports.csv
    with (out_dir / "imports.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "line", "kind", "module", "name"])
        for r in sorted(all_imports, key=lambda x: (x.file, x.line, x.kind, x.name)):
            w.writerow([r.file, r.line, r.kind, r.module, r.name])

    def write_set(fname: str, s: Set[str]) -> None:
        (out_dir / fname).write_text("\n".join(sorted(s)) + "\n", encoding="utf-8")

    write_set("third_party.txt", third_party)
    write_set("stdlib.txt", stdlib)
    write_set("local.txt", local)

    # name_errors
    with (out_dir / "name_errors.txt").open("w", encoding="utf-8") as f:
        for file_rel, sym in sorted(set(name_errors)):
            f.write(f"{file_rel}: {sym}\n")

    print(f"OK: wrote reports to {out_dir}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

