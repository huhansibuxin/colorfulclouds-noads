import struct, sys

PATH = r"D:\woekbude\caiyun-remove-ads\ipa_unzipped\Payload\ColorfulCloudsPro.app\ColorfulCloudsPro"
TARGET_OFF = 5646412  # retAddr - image_base (frame 2 of VipCreator stack)

with open(PATH, "rb") as f:
    d = f.read()

def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]

magic = u32(d, 0)
assert magic in (0xfeedfacf, 0xcffaedfe), "not a Mach-O (magic=0x%X)" % magic
is64 = magic == 0xfeedfacf
ncmds = u32(d, 16)
off = 32 if is64 else 28

text_vmaddr = None
fs_dataoff = fs_datasize = None

for i in range(ncmds):
    cmd = u32(d, off)
    cmdsize = u32(d, off + 4)
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = d[off+8:off+24].split(b"\x00")[0].decode("latin1", "ignore")
        vmaddr = u64(d, off+24)
        if segname == "__TEXT":
            text_vmaddr = vmaddr
    elif cmd == 0x1a:  # LC_FUNCTION_STARTS
        fs_dataoff = u32(d, off+8)
        fs_datasize = u32(d, off+12)
    off += cmdsize

print("__TEXT vmaddr = 0x%X" % (text_vmaddr or 0))
print("LC_FUNCTION_STARTS dataoff=0x%X datasize=%d" % (fs_dataoff, fs_datasize))

# decode ULEB128 deltas -> cumulative function-start offsets (from __TEXT start)
def uleb(b, o):
    result = 0; shift = 0
    while True:
        byte = b[o]; o += 1
        result |= (byte & 0x7f) << shift
        if not (byte & 0x80): break
        shift += 7
    return result, o

starts = []
o = fs_dataoff
end = fs_dataoff + fs_datasize
cum = 0
while o < end:
    v, o = uleb(d, o)
    cum += v
    starts.append(cum)

starts.sort()
print("total function starts: %d" % len(starts))
# find largest start <= TARGET_OFF
entry = None
for s in starts:
    if s <= TARGET_OFF:
        entry = s
    else:
        break
print("TARGET_OFF = %d (0x%X)" % (TARGET_OFF, TARGET_OFF))
print("CREATOR_ENTRY_OFFSET (largest fn start <= target) = %d (0x%X)" % (entry, entry))
# show a few around it
idx = starts.index(entry) if entry in starts else -1
print("neighbors:", [(s, hex(s)) for s in starts[max(0,idx-2):idx+3]])
