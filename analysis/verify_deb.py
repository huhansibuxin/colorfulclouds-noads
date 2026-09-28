# -*- coding: utf-8 -*-
"""Verify that the built .deb actually contains the v2.0.0 popup-gate code.

Usage:
    python verify_deb.py <path-to.deb>
"""
import gzip
import io
import lzma
import sys
import tarfile


def iter_ar(path):
    with open(path, 'rb') as f:
        if f.read(8) != b'!<arch>\n':
            raise SystemExit('not an ar archive')
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            name = hdr[0:16].decode('ascii', 'ignore').strip().rstrip('/')
            try:
                size = int(hdr[48:58].decode('ascii', 'ignore').strip())
            except ValueError:
                break
            data = f.read(size)
            if size % 2:
                f.read(1)
            yield name, data


def main(deb):
    payload = None
    for name, data in iter_ar(deb):
        print('[member] %-22s %d bytes' % (name, len(data)))
        if name.startswith('data.tar'):
            if name.endswith('.xz'):
                payload = lzma.decompress(data)
            elif name.endswith('.gz'):
                payload = gzip.decompress(data)
            else:
                payload = data
    if payload is None:
        raise SystemExit('no data.tar member')

    tf = tarfile.open(fileobj=io.BytesIO(payload))
    needles = [
        b'PopupGate',
        b'setHomePopupArray:',
        b'handlePopupArray:',
        b'CYNotificationPopupActivityView',
        b'activated on',
        b'loaded for',
    ]
    for m in tf.getmembers():
        if not m.isfile():
            continue
        print('[file] %s (%d bytes)' % (m.name, m.size))
        if not m.name.endswith('.dylib'):
            continue
        blob = tf.extractfile(m).read()
        for nd in needles:
            print('   %-32s %s' % (nd.decode(), 'FOUND' if nd in blob else 'MISSING'))
    for m in tf.getmembers():
        if m.name.endswith('/control'):
            txt = tf.extractfile(m).read().decode('utf-8', 'ignore')
            for line in txt.splitlines():
                if line.startswith(('Version', 'Package', 'Name')):
                    print('[control] ' + line)


if __name__ == '__main__':
    main(sys.argv[1])
