#!/usr/bin/env python
"""Scan a decrypted Mach-O for Swift class names in the ColorfulCloudsPro module.

Why: Swift classes that are NOT @objc-exposed never show up in __objc_classname,
so class-dump style tools miss them entirely. Their mangled names (`$s17ColorfulCloudsPro7XxxViewC`
or legacy `_TtC17ColorfulCloudsPro7XxxView`) are still plain ASCII in the binary.

Usage:
    python scan_swift_classes.py <binary> [keyword-filter]
"""
import re
import sys
import mmap

PAT = re.compile(rb'[\x20-\x7e]{6,160}')
SUB = re.compile(r'17ColorfulCloudsPro(\d+)([A-Za-z0-9_$]+)')


def scan(path, kw=None):
    names = set()
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        for m in PAT.finditer(mm):
            s = m.group().decode('ascii', 'ignore')
            if 'ColorfulCloudsPro' not in s:
                continue
            for m2 in SUB.finditer(s):
                n = int(m2.group(1))
                names.add(m2.group(2)[:n])
    out = sorted(names)
    if kw:
        out = [c for c in out if kw.lower() in c.lower()]
    return out


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    kw = sys.argv[2] if len(sys.argv) > 2 else None
    res = scan(sys.argv[1], kw)
    for c in res:
        print(c)
    print('TOTAL:', len(res))
