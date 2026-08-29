#!/usr/bin/env python
"""Dump the method list of a specific ObjC class from a decrypted Mach-O.

Why: parse_macho.py `methods <kw>` searches the whole __objc_methname section and
cannot tell you WHICH class a selector belongs to. When you need to know what a
single class (e.g. CYTabBarController) actually implements, you must walk
__objc_classlist -> class_t -> class_ro_t -> baseMethodList.

Usage:
    python dump_objc_class.py <binary> <ClassName> [--super]
"""
import struct
import sys


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]


def load(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'), 'not mach-o'
    magic = data[:4]
    is64 = magic == b'\xcf\xfa\xed\xfe'
    ncmds = u32(data, 16)
    off = 32 if is64 else 28
    segs = {}
    for _ in range(ncmds):
        cmd = u32(data, off)
        cmdsize = u32(data, off + 4)
        if cmd in (0x19, 0x1):  # SEGMENT_64 / SEGMENT
            name = data[off + 8:off + 16].rstrip(b'\0').decode()
            vmaddr = u64(data, off + 24) if is64 else u32(data, off + 24)
            vmsize = u64(data, off + 32) if is64 else u32(data, off + 32)
            fileoff = u64(data, off + 40) if is64 else u32(data, off + 40)
            segs[name] = (vmaddr, vmsize, fileoff)
        off += cmdsize
    return data, segs, is64


def sections(data, segs, segname, secname):
    """Return (vmaddr, fileoff, size) of __segname,__secname."""
    with open(_path, 'rb') as f:
        raw = f.read()
    # walk sections directly
    is64 = data[:4] == b'\xcf\xfa\xed\xfe'
    ncmds = u32(raw, 16)
    off = 32 if is64 else 28
    for _ in range(ncmds):
        cmd = u32(raw, off)
        cmdsize = u32(raw, off + 4)
        if cmd in (0x19, 0x1):
            sname = raw[off + 8:off + 16].rstrip(b'\0').decode()
            nsects = u32(raw, off + 64) if is64 else u32(raw, off + 56)
            soff = off + (72 if is64 else 56)
            ssize = 80 if is64 else 68
            for i in range(nsects):
                o = soff + i * ssize
                sec = raw[o:o + 16].rstrip(b'\0').decode()
                seg = raw[o + 16:o + 32].rstrip(b'\0').decode()
                addr = u64(raw, o + 32) if is64 else u32(raw, o + 32)
                size = u64(raw, o + 40) if is64 else u32(raw, o + 40)
                foff = u32(raw, o + 48)
                if seg == segname and sec == secname:
                    return addr, foff, size
        off += cmdsize
    return None


def vm_to_file(segs, vmaddr):
    for name, (vm, size, foff) in segs.items():
        if vm <= vmaddr < vm + size:
            return foff + (vmaddr - vm)
    return None


def read_cstr(data, off):
    end = data.index(b'\0', off)
    return data[off:end].decode('utf-8', 'replace')


def main():
    global _path
    _path = sys.argv[1]
    target = sys.argv[2]
    want_super = '--super' in sys.argv

    data, segs, is64 = load(_path)
    cls_sec = sections(data, segs, '__DATA', '__objc_classlist')
    if not cls_sec:
        cls_sec = sections(data, segs, '__DATA_CONST', '__objc_classlist')
    if not cls_sec:
        print('no __objc_classlist')
        return

    addr, foff, size = cls_sec
    n = size // 8
    classes = []
    for i in range(n):
        p = u64(data, foff + i * 8)
        classes.append(p)

    # resolve superclass chain by scanning: build class_ro -> name map lazily
    def class_name_ro(cls_ptr):
        """returns (name, ro_ptr_fileoff, superclass_ptr)"""
        fo = vm_to_file(segs, cls_ptr)
        if fo is None:
            return None
        # class_t: isa(8) superclass(8) cache(16) vtable(16) data(8) -> data at +40? use +32 for ARM64 modern
        data_ptr = u64(data, fo + 32)
        # data ptr has low bits flags in some versions
        ro_ptr = data_ptr & 0x7fffffffffff if data_ptr >> 47 else data_ptr
        ro_fo = vm_to_file(segs, ro_ptr)
        if ro_fo is None:
            return None
        # class_ro_t: flags(u32) instanceStart(u32) instanceSize(u32) reserved(u32)
        #             ivarLayout(ptr) name(ptr) baseMethodList(ptr) ...
        name_ptr = u64(data, ro_fo + 24)
        ml_ptr = u64(data, ro_fo + 32)
        name_fo = vm_to_file(segs, name_ptr & 0x7fffffffffff)
        if name_fo is None:
            return None
        name = read_cstr(data, name_fo)
        return name, ro_fo, ml_ptr, u64(data, fo + 8)

    def methods_of(ml_ptr):
        if not ml_ptr:
            return []
        fo = vm_to_file(segs, ml_ptr & 0x7fffffffffff)
        if fo is None:
            return []
        # method_list_t entsize: u32 at +0 (flags), count u32 at +4 (ARM64: entsize u32 + count u32)
        entsize = u32(data, fo)
        count = u32(data, fo + 4)
        out = []
        base = fo + 8
        # entsizeAndFlags: lower 16 bits size, upper flags; mask
        esz = entsize & 0xFFFF
        if esz == 0 or esz > 64:
            esz = 24
        for i in range(min(count, 2000)):
            o = base + i * esz
            # method_t: name(ptr) types(ptr) imp(ptr)
            sel_ptr = u64(data, o)
            sfo = vm_to_file(segs, sel_ptr & 0x7fffffffffff)
            if sfo is not None:
                try:
                    out.append(read_cstr(data, sfo))
                except Exception:
                    pass
        return out

    for cp in classes:
        r = class_name_ro(cp)
        if not r:
            continue
        name, ro_fo, ml_ptr, sup = r
        if name != target:
            continue
        print('=== %s ===' % name)
        ms = methods_of(ml_ptr)
        print('methods (%d):' % len(ms))
        for m in ms:
            print('   ', m)
        if want_super and sup:
            sr = class_name_ro(sup)
            if sr:
                print('superclass:', sr[0])
        return
    print('class not found:', target)


if __name__ == '__main__':
    main()
