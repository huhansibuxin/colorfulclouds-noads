#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Demangle the ColorfulCloudsPro creator offsets captured in the VipCreator stack.
# Connects via SSH tunnel 127.0.0.1:27042 (run: ssh -f -N -L 27042:127.0.0.1:27042 root@<dev>).
import sys, time, frida

# offsets (decimal) from the [VipCreator:initWithFrame:] stack: "ColorfulCloudsPro + <offset>"
OFFSETS = [5646412, 5376464, 3825472, 3822528, 3822944, 1791924, 1790400, 7316648, 502560]

JS = r"""
'use strict';
function log(s){ send({kind:'log', msg:String(s)}); }

function objcMethodAt(addr) {
  // best = method whose IMP is the largest value <= addr (i.e. contains addr)
  var best = null;
  try {
    var classes = ObjC.classes;
    for (var name in classes) {
      try {
        var m = classes[name].methods;
        for (var sel in m) {
          try {
            var imp = m[sel].implementation;
            if (!imp) continue;
            if (imp.compareTo(addr) <= 0) {
              if (best === null || imp.compareTo(best.imp) > 0) {
                best = { imp: imp, cls: name, sel: sel };
              }
            }
          } catch (e) {}
        }
      } catch (e) {}
    }
  } catch (e) { log('objcMethodAt err: ' + e); }
  return best;
}

rpc.exports = {
  sym: function (offsets) {
    var mod;
    try { mod = Process.getModuleByName('ColorfulCloudsPro'); }
    catch (e) { log('no module: ' + e); return; }
    log('module base = ' + mod.base + '  size=' + mod.size);
    for (var i = 0; i < offsets.length; i++) {
      var off = offsets[i];
      var addr = mod.base.add(off);
      var ds = null;
      try { ds = DebugSymbol.fromAddress(addr); } catch (e) { ds = 'ERR ' + e; }
      var name = (ds && ds.name) ? ds.name : String(ds);
      log('--- offset +' + off + '  addr=' + addr);
      log('    DebugSymbol: ' + name);
      if (ds && ds.moduleName) log('    module=' + ds.moduleName + '  file=' + (ds.fileName||'') + ':' + (ds.lineNumber||''));
      var om = objcMethodAt(addr);
      if (om) log('    ObjC candidate: -[' + om.cls + ' ' + om.sel + ']  imp=' + om.imp);
      else log('    ObjC candidate: (none / pure Swift)');
    }
    return true;
  }
};
"""

def main():
    pid = int(sys.argv[1])
    dev = frida.get_device_manager().add_remote_device('127.0.0.1:27042')
    print('attaching to pid %d ...' % pid)
    session = dev.attach(pid)
    script = session.create_script(JS)
    def on_message(message, data):
        if message['type'] == 'send':
            p = message['payload']
            if isinstance(p, dict) and p.get('kind') == 'log':
                print(p['msg'])
            else:
                print(p)
        elif message['type'] == 'error':
            print('SCRIPT ERROR:')
            print(message.get('stack', message))
        else:
            print(message)
    script.on('message', on_message)
    script.load()
    print('--- symbolize ---')
    try:
        script.exports_sync.sym(OFFSETS)
    except Exception as e:
        print('rpc err: %s' % e)
    time.sleep(1)
    session.detach()
    print('done')

if __name__ == '__main__':
    main()
