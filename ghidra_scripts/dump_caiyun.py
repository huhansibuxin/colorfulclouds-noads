# Ghidra headless post script: decompile CY classes of interest
# Output: /tmp/caiyun_analysis_output.txt
# Jython 2.7 compatible

import codecs
from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor

program = getCurrentProgram()
fm = program.getFunctionManager()
decomp = DecompInterface()
decomp.openProgram(program)

TARGETS = [
    'CYTabBarController',
    'CYMainController',
    'CYAlertView',
    'CYAlertContentView',
    'CYADLaunchViewController',
    'CYADFactory',
    'CYMainADModel',
    'CYToastViewController',
    'Popup',
]

out_path = '/tmp/caiyun_analysis_output.txt'
fh = codecs.open(out_path, 'w', encoding='utf-8')

def dump(limit):
    written = 0
    fn_iter = fm.getFunctions(True)
    for f in fn_iter:
        name = f.getName()
        hit = False
        for t in TARGETS:
            if t in name:
                hit = True
                break
        if not hit:
            continue
        try:
            res = decomp.decompileFunction(f, 60, ConsoleTaskMonitor())
        except Exception as e:
            fh.write(u'\n===== %s @ %s : DECOMP FAIL =====\n' % (name, f.getEntryPoint()))
            written += 1
            continue
        if res is not None and res.decompileCompleted():
            code = res.getDecompiledFunction().getC()
            fh.write(u'\n\n===== %s  @ %s =====\n' % (name, f.getEntryPoint()))
            fh.write(code if isinstance(code, unicode) else code.decode('utf-8', 'replace'))
            written += 1
            if written >= limit:
                break
    return written

total = dump(300)
fh.write(u'\n\n// total decompiled: %d\n' % total)

fh.write(u'\n\n########## SYMBOLS ##########\n')
st = program.getSymbolTable()
for sym in st.getAllSymbols(True):
    nm = sym.getName()
    if 'ssistant' in nm or 'CYTabBarController' in nm or 'Popup' in nm or 'CYAD' in nm:
        fh.write(u'%s  @ %s\n' % (nm, sym.getAddress()))

fh.close()
print('DONE: wrote %s (%d funcs)' % (out_path, total))
