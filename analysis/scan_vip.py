import mmap, re
path = r"D:\woekbude\caiyun-remove-ads\ipa_unzipped\Payload\ColorfulCloudsPro.app\ColorfulCloudsPro"
with open(path,'rb') as f:
    data = mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ)
strs = re.findall(rb'[\x20-\x7e]{4,200}\x00', data)
names = set()
for s in strs:
    try:
        t = s[:-1].decode('utf-8','ignore')
    except:
        continue
    if re.search(r'(Vip|VIP|Svip|SVIP|Pay|Member|BottomView|PayLaunch|PayWall|Manager)', t):
        names.add(t)
print("=== candidate class/method/string names (Vip/Pay/Member/BottomView/Manager) ===")
for n in sorted(names):
    print(n)
print("=== direct CYVipBottomView mentions ===")
seen=set()
for m in re.finditer(rb'CYVipBottomView[\x00\x20-\x7e]{0,48}', data):
    g=m.group(0)
    if g not in seen:
        seen.add(g); print(g[:60])
