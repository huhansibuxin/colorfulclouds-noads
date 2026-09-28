# -*- coding: utf-8 -*-
"""Dump every Swift type name (ColorfulCloudsPro module) and ObjC CY* name
found as plain ASCII inside the main binary.

Usage:
    python dump_all_names.py <binary> > all_names.txt
"""
import re
import sys
import mmap

SUB = re.compile(r'17ColorfulCloudsPro(\d+)([A-Za-z0-9_$]+)')
CY = re.compile(r'CY[A-Za-z][A-Za-z0-9_]{2,60}')


def main(path):
    swift = set()
    cy = set()
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        for m in re.finditer(rb'[\x20-\x7e]{4,200}', mm):
            t = m.group().decode('ascii', 'ignore')
            for m2 in SUB.finditer(t):
                n = int(m2.group(1))
                swift.add(m2.group(2)[:n])
            for m2 in CY.finditer(t):
                cy.add(m2.group(0))
    print('### SWIFT ###')
    for s in sorted(swift):
        print(s)
    print('### OBJC_CY ###')
    for s in sorted(cy):
        print(s)
    print('### COUNTS ### swift=%d cy=%d' % (len(swift), len(cy)))


if __name__ == '__main__':
    main(sys.argv[1])
