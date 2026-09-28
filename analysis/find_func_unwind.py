import struct
PATH=r"D:\woekbude\caiyun-remove-ads\ipa_unzipped\Payload\ColorfulCloudsPro.app\ColorfulCloudsPro"
TARGET_OFF=5646412
d=open(PATH,'rb').read()
def u32(b,o): return struct.unpack_from("<I",b,o)[0]
def u64(b,o): return struct.unpack_from("<Q",b,o)[0]
magic=u32(d,0); ncmds=u32(d,16); off=32 if magic==0xfeedfacf else 28
ui_off=ui_size=None; text_vm=0
for i in range(ncmds):
    cmd=u32(d,off); cs=u32(d,off+4)
    if cmd==0x19:
        seg=d[off+8:off+24].split(b"\x00")[0].decode("latin1","ignore")
        if seg=="__TEXT": text_vm=u64(d,off+24)
    if cmd==0x32:  # LC_UNWIND_INFO
        ui_off=u32(d,off+8); ui_size=u32(d,off+12)
    off+=cs
print("__TEXT vm=0x%X  unwind dataoff=0x%X size=%d"%(text_vm,ui_off,ui_size))
# header
p=ui_off
ver=u32(d,p); commonCnt=u32(d,p+4); commonOff=u32(d,p+8)
persCnt=u32(d,p+12); persOff=u32(d,p+16)
idxCnt=u32(d,p+20); idxOff=u32(d,p+24)
funcCnt=u32(d,p+28); funcOff=u32(d,p+32)
print("ver=%d idxCnt=%d idxOff=0x%X"%(ver,idxCnt,idxOff))
# index section entries
starts=[]
for i in range(idxCnt):
    eo=p+idxOff+i*12
    funcOff0=u32(d,eo); secondOff=u32(d,eo+4); lsdaOff=u32(d,eo+8)
    # second-level compressed page
    so=p+secondOff
    magic2=u32(d,so)
    if magic2==0xFFFFFAFE:
        # compressed second level page
        KernOff=u32(d,so+4); KernCount=u32(d,so+8)
        encOff=u32(d,so+12); encCount=u32(d,so+16)
        entryBase=so+20
        for j in range(KernCount):
            fo=u32(d,entryBase+j*8); enc=u32(d,entryBase+j*8+4)
            starts.append(fo)
    else:
        # regular second level page: array of (funcOffset, funcLen, funcOffset+lsda?)
        # layout: uint32_t funcOffset; uint32_t funcLen; ... (regular page)
        cnt=(magic2)  # for regular, first field is count
        eo2=so+4
        for j in range(cnt):
            fo=u32(d,eo2+j*12); fl=u32(d,eo2+j*12+4)
            starts.append(fo)
starts=sorted(set(starts))
print("total function starts from unwind: %d"%(len(starts)))
entry=None; nxt=None
for s in starts:
    if s<=TARGET_OFF: entry=s
    elif nxt is None: nxt=s
    if nxt is not None: break
print("TARGET_OFF=%d (0x%X)"%(TARGET_OFF,TARGET_OFF))
print("CREATOR_ENTRY_OFFSET=%d (0x%X)"%(entry,entry))
print("next function start after entry=%d (0x%X)"%(nxt,nxt))
print("function size ~ %d bytes"%((nxt-entry) if nxt else -1))
# neighbors
i=starts.index(entry)
print("neighbors:",[(x,hex(x)) for x in starts[max(0,i-2):i+3]])
