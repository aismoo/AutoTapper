#!/usr/bin/env python3
"""Rough structural sanity check for ObjC/Logos sources.

Strips comments, string and char literals, then reports bracket balance and
@interface/@implementation/@end counts. Not a compiler -- just a fast tripwire
for truncated files or a dropped brace after edits.
"""
import os
import re
import sys

BLOCK = re.compile(r"/\*.*?\*/", re.S)
LINE = re.compile(r"//[^\n]*")
STR = re.compile(r'"(?:\\.|[^"\\])*"')
CHR = re.compile(r"'(?:\\.|[^'\\])*'")

EXT = (".m", ".xm", ".h", ".mm")


def scan(path):
    src = open(path, encoding="utf-8").read()
    t = BLOCK.sub("", src)
    t = LINE.sub("", t)
    t = STR.sub('""', t)
    t = CHR.sub("''", t)
    b = {c: t.count(c) for c in "{}()[]"}
    iface = len(re.findall(r"@interface\b", t))
    impl = len(re.findall(r"@implementation\b", t))
    end = len(re.findall(r"@end\b", t))
    return b, iface, impl, end


def main(root):
    bad = 0
    for name in sorted(os.listdir(root)):
        if not name.endswith(EXT):
            continue
        b, iface, impl, end = scan(os.path.join(root, name))
        ok = (
            b["{"] == b["}"]
            and b["("] == b[")"]
            and b["["] == b["]"]
            and end >= iface + impl
        )
        flag = "ok  " if ok else "FAIL"
        if not ok:
            bad += 1
        print(
            f"{flag} {name:26s} {{}}={b['{']}/{b['}']}  ()={b['(']}/{b[')']}  "
            f"[]={b['[']}/{b[']']}  @interface={iface} @implementation={impl} @end={end}"
        )
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
