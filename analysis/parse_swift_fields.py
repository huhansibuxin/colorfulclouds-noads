#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Parse Swift field descriptors from ColorfulCloudsPro binary (mmap-based).
Locates Swift classes whose stored properties belong to the AI "assistant" chat feature.

Handles Swift's indirect mangled-name references: a target of b'\x01' followed by
an int32 relative offset means "real string lives at (ptr+1) + offset".
"""
import struct
import mmap
import sys

BIN = sys.argv[1] if len(sys.argv) > 1 else 'ColorfulCloudsPro'


def main():
    with open(BIN, 'rb') as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

        magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<IIIIIIII', mm, 0)

        sections = {}
        off = 32
        for i in range(ncmds):
            cmd, cmdsize = struct.unpack_from('<II', mm, off)
            if cmd == 0x19:  # LC_SEGMENT_64
                nsects = struct.unpack_from('<I', mm, off + 64)[0]
                so = off + 72
                for j in range(nsects):
                    sname = mm[so:so+16].split(b'\x00')[0].decode()
                    saddr = struct.unpack_from('<Q', mm, so + 32)[0]
                    ssize = struct.unpack_from('<Q', mm, so + 40)[0]
                    soffset = struct.unpack_from('<I', mm, so + 48)[0]
                    sections[sname] = (saddr, ssize, soffset)
                    so += 80
            off += cmdsize

        def addr2off(a):
            for n, (x, s, o) in sections.items():
                if x <= a < x + s:
                    return a - x + o
            return None

        def raw_cstr(a):
            o = addr2off(a)
            if o is None or o < 0 or o >= len(mm):
                return None
            e = mm.find(b'\x00', o)
            return mm[o:e] if e != -1 else None

        def resolve(a):
            """Resolve a possibly-indirect Swift string reference."""
            b = raw_cstr(a)
            if b is None:
                return ''
            if len(b) >= 5 and b[0] == 0x01:
                rel = struct.unpack('<i', b[1:5])[0]
                b2 = raw_cstr((a + 1) + rel)
                if b2 is None:
                    return ''
                return b2.decode('utf-8', 'replace')
            return b.decode('utf-8', 'replace')

        def demangle(m):
            if not m:
                return m
            # Swift 5+: $s17ColorfulCloudsPro12CYPopupModelC
            if m.startswith('$s') or m.startswith('_$s'):
                r = m[2:] if m.startswith('$s') else m[3:]
                parts = []
                i = 0
                while i < len(r):
                    if not r[i].isdigit():
                        break
                    n = ''
                    while i < len(r) and r[i].isdigit():
                        n += r[i]
                        i += 1
                    ln = int(n)
                    parts.append(r[i:i+ln])
                    i += ln
                return parts[-1] if parts else m
            if m.startswith('_TtC'):
                r = m[4:]
                i = 0
                n = ''
                while i < len(r) and r[i].isdigit():
                    n += r[i]
                    i += 1
                if not n:
                    return m
                i += int(n)
                n = ''
                while i < len(r) and r[i].isdigit():
                    n += r[i]
                    i += 1
                if not n:
                    return m
                return r[i:i+int(n)]
            return m

        base, size, foff = sections['__swift5_fieldmd']

        rows = []
        pos = 0
        guard = 0
        while pos + 16 <= size and guard < 200000:
            guard += 1
            mrel = struct.unpack_from('<i', mm, foff + pos)[0]
            kind, fs = struct.unpack_from('<HH', mm, foff + pos + 8)
            nf = struct.unpack_from('<I', mm, foff + pos + 12)[0]
            mangled_addr = (base + pos) + mrel
            cls = demangle(resolve(mangled_addr))
            flds = []
            ro = pos + 16
            if fs > 0 and nf > 0:
                for k in range(nf):
                    if ro + fs > size:
                        break
                    if fs >= 12:
                        fr = struct.unpack_from('<i', mm, foff + ro + 8)[0]
                        flds.append(resolve((base + ro + 8) + fr))
                    ro += fs
            rows.append((cls, flds))
            pos = ro if ro > pos else pos + 16

        print('parsed field descriptors: %d' % len(rows))
        print('\n--- sanity check (first 8) ---')
        for c, fl in rows[:8]:
            print('  %-42s : %s' % (c, ', '.join(fl[:6])))

        KEY = ['chat', 'assistant', 'ailabel', 'helper', 'robot']
        print('\n=== Swift classes with chat/assistant-like fields ===')
        hits = 0
        for c, fl in rows:
            j = ' '.join(fl).lower()
            if any(k in j for k in KEY):
                hits += 1
                print('\n[%s]' % c)
                print('  fields: %s' % ', '.join(fl[:60]))
        print('\n# hits: %d' % hits)

        mm.close()


if __name__ == '__main__':
    main()
