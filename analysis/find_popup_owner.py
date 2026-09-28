# -*- coding: utf-8 -*-
"""Find the popup/activity plumbing: source file paths, popup-related
selectors and the Chinese copy around the 'no thanks' button.

Usage:
    python find_popup_owner.py <binary>
"""
import re
import sys
import mmap

SRC = re.compile(rb'/Users/[^\x00\n]{6,200}?\.swift')
POPUP_IDENT = re.compile(rb'[A-Za-z_]{0,28}[Pp]opup[A-Za-z_]{0,70}')
KEY_ZH = ['先不看', '弹窗活动', '不去看看', '每日一次']


def main(path):
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        print('=== SWIFT SOURCE PATHS (filtered) ===')
        files = set()
        for m in SRC.finditer(mm):
            p = m.group().decode('utf-8', 'ignore')
            files.add(p)
        filt = {'Activity', 'Popup', 'Ad', 'Vip', 'Pay', 'Alert', 'Main', 'Guide', 'Card'}
        for p in sorted(files):
            name = p.rsplit('/', 1)[-1]
            if any(k.lower() in name.lower() for k in filt):
                print('  ' + p)
        print('  (total swift files=%d)' % len(files))

        print('=== POPUP IDENTIFIERS ===')
        idents = set()
        for m in POPUP_IDENT.finditer(mm):
            idents.add(m.group().decode('ascii', 'ignore'))
        for i in sorted(idents):
            print('  ' + i)
        print('  (count=%d)' % len(idents))

        print('=== CHINESE CONTEXT ===')
        for z in KEY_ZH:
            b = z.encode('utf-16-le')
            print('  --- %s ---' % z)
            cnt = 0
            for m in re.finditer(re.escape(b), mm):
                cnt += 1
                if cnt > 2:
                    break
                s = max(0, m.start() - 2)
                e = min(len(mm), m.end() + 160)
                try:
                    txt = mm[s:e].decode('utf-16-le', 'ignore')
                except Exception:
                    continue
                txt = ''.join(ch if ch.isprintable() else '.' for ch in txt)
                print('     ctx> ' + txt)
            if cnt == 0:
                print('     (none)')


if __name__ == '__main__':
    main(sys.argv[1])
