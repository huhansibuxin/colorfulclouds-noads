# -*- coding: utf-8 -*-
"""Locate the owner of an activity/popup by extracting full mangled symbols
around candidate Swift type names, plus the surrounding Chinese copy
(UTF-16LE in __TEXT,__ustring and UTF-8 in __cstring).

Usage:
    python find_activity_owner.py <binary>
"""
import re
import sys
import mmap

KEYS = [b'MainActivity', b'NotificationPopup', b'ActivityTask', b'PopupModel', b'AlertCardView']
ZH = ['年卡', '终身', '抽奖', '免费领', '限时']


def ascii_tokens(buf):
    out = []
    for t in re.findall(rb'[\x20-\x7e]{5,}', buf):
        out.append(t.decode('ascii', 'ignore'))
    return out


def main(path):
    with open(path, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        for k in KEYS:
            print('=== %s ===' % k.decode())
            seen = set()
            n = 0
            for m in re.finditer(re.escape(k), mm):
                s = max(0, m.start() - 160)
                e = min(len(mm), m.end() + 160)
                for d in ascii_tokens(mm[s:e]):
                    if k.decode() not in d:
                        continue
                    if d in seen:
                        continue
                    seen.add(d)
                    print('  ' + d)
                    n += 1
                    if n > 40:
                        break
                if n > 40:
                    break
            print('  (unique=%d)' % len(seen))

        print('=== CHINESE COPY (utf-16le) ===')
        for z in ZH:
            b = z.encode('utf-16-le')
            cnt = 0
            samples = set()
            for m in re.finditer(re.escape(b), mm):
                cnt += 1
                if cnt > 3:
                    break
                s = max(0, m.start() - 2)
                e = min(len(mm), m.end() + 120)
                ctx = mm[s:e]
                try:
                    txt = ctx.decode('utf-16-le', 'ignore')
                except Exception:
                    continue
                txt = ''.join(ch if ch.isprintable() else '.' for ch in txt)
                samples.add(txt)
            print('  %s : hits=%d' % (z, cnt))
            for s in list(samples)[:3]:
                print('     ctx> ' + s)


if __name__ == '__main__':
    main(sys.argv[1])
