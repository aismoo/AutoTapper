#!/usr/bin/env python3
"""Crude cross-file symbol check for the AutoTapper sources.

Not a compiler. It only catches the cheap mistakes:
  1. a YG*/kYG* C symbol that is *called* in a .m/.xm but is neither a
     macro nor declared/defined anywhere;
  2. a YG* ObjC class used as a type / receiver with no @interface;
  3. the same C function defined in two different translation units.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = sorted(list(ROOT.glob("*.m")) + list(ROOT.glob("*.xm")) + list(ROOT.glob("*.h")))


def strip_comments(text: str) -> str:
    # keep line structure so ^ anchors and line numbers stay comparable
    def repl(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    text = re.sub(r"/\*.*?\*/", repl, text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


files = {p.name: strip_comments(p.read_text(encoding="utf-8", errors="replace")) for p in SRC}

macros = set()
declared = set()
defined_in = {}     # C function name -> set(files)
objc_ifaces = set()

for name, txt in files.items():
    for m in re.finditer(r"^\s*#\s*define\s+([A-Za-z_]\w*)", txt, re.M):
        macros.add(m.group(1))
    for m in re.finditer(r"^\s*extern\s+[^;]*?\b([A-Za-z_]\w*)\s*[;\[]", txt, re.M):
        declared.add(m.group(1))
    for m in re.finditer(r"@interface\s+([A-Za-z_]\w*)", txt):
        objc_ifaces.add(m.group(1))
    # function-ish declarations:  <type> Name(args)  followed by ; or { on same line
    for m in re.finditer(
        r"^[ \t]*(?!return\b|if\b|for\b|while\b|switch\b|else\b|typedef\b)"
        r"(?:static\s+|inline\s+|const\s+|FOUNDATION_EXPORT\s+|extern\s+)*"
        r"[A-Za-z_][\w \t\*]*?\b([A-Za-z_]\w*)\s*\([^;{]*\)\s*([{;])",
        txt,
        re.M,
    ):
        nm, tail = m.group(1), m.group(2)
        declared.add(nm)
        if tail == "{":
            defined_in.setdefault(nm, set()).add(name)

problems = []

for name, txt in files.items():
    if name.endswith(".h"):
        continue
    # drop class extensions / implementations before scanning calls:
    #   '@interface YGInjector ()'  would otherwise look like a call.
    callsrc = re.sub(r"^\s*@(?:interface|implementation)\b[^\n]*", "", txt, flags=re.M)
    for u in sorted(set(re.findall(r"\b([A-Za-z_]\w*)\s*\(", callsrc))):
        if not u.startswith(("YG", "kYG")):
            continue
        if u in macros or u in declared:
            continue
        problems.append(f"{name}: called but never declared/defined -> {u}()")

    used_cls = set(re.findall(r"\[\s*([A-Z][A-Za-z0-9_]*)\s+[a-z_]", txt))
    used_cls |= set(re.findall(r"\b([A-Z][A-Za-z0-9_]*)\s*\*", txt))
    for u in sorted(used_cls):
        if not u.startswith("YG") or u in objc_ifaces or u in macros:
            continue
        # C typedef'd struct pointers (IOHIDEventRef) end with Ref, skip those
        if u.endswith(("Ref", "Time")):
            continue
        problems.append(f"{name}: ObjC class used with no @interface -> {u}")

for fn, where in sorted(defined_in.items()):
    if len(where) > 1:
        problems.append(f"duplicate C definition of {fn}() in {', '.join(sorted(where))}")

if problems:
    print("\n".join(sorted(set(problems))))
    print(f"\n{len(set(problems))} issue(s)")
    sys.exit(1)

print(f"clean: {len(files)} files | {len(declared)} declared symbols | "
      f"{len(macros)} macros | {len(objc_ifaces)} @interface | {len(defined_in)} C defs")
