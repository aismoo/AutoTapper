#!/usr/bin/env python3
"""Cross-check message sends against declared/implemented methods.

Parses `- (type)name:(type)arg name2:(type)arg2` and `- (type)name` from .h/.m/.xm,
then reports `[SomeClass someSelector]` / dot-with-colon sends whose selector is
not found anywhere in the project and whose receiver class is a project class.
Heuristic: it only flags receives whose class name starts with YG, so UIKit/private
API noise is skipped.
"""
import os
import re
import sys

EXT = (".m", ".xm", ".h")
DECL = re.compile(r"^[ \t]*[-+]\s*\([^)]*\)\s*([A-Za-z_][\w:]*(?:\s*[\w:]+\s*)?)", re.M)

# NSObject / UIKit 继承来的方法，项目里不需要自己声明；不在此列的才会被当成漏写。
INHERITED = {
    "new", "alloc", "init", "copy", "mutableCopy", "class", "self", "description",
    "dealloc", "load", "initialize", "superclass", "hash", "isEqual:", "debugDescription",
    "retain", "release", "autorelease", "retainCount", "zone",
    "isKindOfClass:", "isMemberOfClass:", "respondsToSelector:", "conformsToProtocol:",
    "performSelector:", "performSelector:withObject:", "performSelector:withObject:withObject:",
    "valueForKey:", "setValue:forKey:", "valueForKeyPath:", "setValue:forKeyPath:",
    "addObserver:forKeyPath:options:context:", "removeObserver:forKeyPath:",
    "observeValueForKeyPath:ofObject:change:context:",
    "methodSignatureForSelector:", "forwardInvocation:",
    "isProxy", "classForCoder", "awakeAfterUsingCoder:",
}


def collect(root):
    files = [os.path.join(root, n) for n in sorted(os.listdir(root)) if n.endswith(EXT)]
    src = {f: open(f, encoding="utf-8").read() for f in files}
    # selector -> files
    sels = {}
    for f, s in src.items():
        for m in re.finditer(r"^[ \t]*[-+]\s*\([^)]*\)\s*([^;{\n]+)", s, re.M):
            sig = m.group(1)
            # split into selector pieces: name: arg name: arg -> foo:bar:
            pieces = re.findall(r"([A-Za-z_]\w*)\s*:", sig)
            if pieces:
                sel = "".join(p + ":" for p in pieces)
            else:
                sel = sig.strip().split()[0] if sig.strip() else ""
            if sel:
                sels.setdefault(sel, set()).add(os.path.basename(f))
    # property getters: @property (...) Type name;
    props = {}
    for f, s in src.items():
        for m in re.finditer(r"@property\s*\([^)]*\)\s*[^;\n]*?\b([A-Za-z_]\w*)\s*;", s):
            props.setdefault(m.group(1), set()).add(os.path.basename(f))
    # calls
    missing = []
    for f, s in src.items():
        t = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
        t = re.sub(r"//[^\n]*", "", t)
        for m in re.finditer(r"\[\s*(?:\[?\s*)?(YG\w+)(?:\s+[^\]]*?)?\s+([A-Za-z_]\w*(?::[^\]\s]*)*)\s*\]", t):
            cls, sel = m.group(1), m.group(2)
            if sel in INHERITED or (sel + ":") in INHERITED:
                continue
            if sel.endswith(":"):
                base = sel
            else:
                base = sel + ":" if (sel + ":") in sels else sel
            if base in sels or base in props or base.rstrip(":") in props:
                continue
            missing.append((os.path.basename(f), f"line~{t[:m.start()].count(chr(10)) + 1}", cls, sel))
    return missing


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    miss = collect(root)
    if not miss:
        print("no unresolved YG* selector sends")
    for f, loc, cls, sel in miss:
        print(f"{f} {loc}  [{cls} {sel}]")
    sys.exit(1 if miss else 0)
