#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Attach to ColorfulClouds Pro via frida (through an SSH tunnel on 127.0.0.1:27042)
and dump the tab bar structure.

Prereq: ssh -f -N -L 27042:127.0.0.1:27042 root@<device>
"""
import sys
import time
import frida

JS = r"""
'use strict';
var prints = ['chatinputview','chatarray','chattableview','chatinputbar',
              'promptarray','historystatus','isrequesthistroy',
              'ailabel','chatmodel','chatimgview','chatimages',
              'assistant','chattextview'];

function log(s) { send({ kind: 'log', msg: String(s) }); }

function scoreForClass(clsName) {
    var hits = [];
    try {
        var c = ObjC.classes[clsName];
        var depth = 0;
        while (c && depth < 6) {
            try {
                var ivs = c.$ivars;
                for (var i = 0; i < ivs.length; i++) {
                    var low = String(ivs[i]).toLowerCase();
                    for (var p = 0; p < prints.length; p++) {
                        if (low.indexOf(prints[p]) >= 0) { hits.push('ivar:' + ivs[i]); break; }
                    }
                }
            } catch (e) {}
            try {
                var ms = c.$ownMethods;
                for (var j = 0; j < ms.length; j++) {
                    var low2 = String(ms[j]).toLowerCase();
                    for (var q = 0; q < prints.length; q++) {
                        if (low2.indexOf(prints[q]) >= 0) { hits.push('m:' + ms[j]); break; }
                    }
                }
            } catch (e) {}
            c = c.$superClass;
            depth++;
        }
    } catch (e) {}
    return hits;
}

function dumpTabBar(tbc, label) {
    try {
        var vcs = tbc.viewControllers();
        var n = vcs.count();
        log('=== ' + label + ' tabs=' + n);
        for (var i = 0; i < n; i++) {
            var vc = vcs.objectAtIndex_(i);
            var clsName = vc.$className;
            var itemTitle = '';
            try { var it = vc.tabBarItem(); if (it) { var t = it.title(); if (t) itemTitle = t.toString(); } } catch (e) {}
            var vcTitle = '';
            try { var vt = vc.title(); if (vt) vcTitle = vt.toString(); } catch (e) {}
            log('  #' + i + ' cls=' + clsName);
            log('      itemTitle=' + JSON.stringify(itemTitle) + '  vcTitle=' + JSON.stringify(vcTitle));
            try {
                if (clsName.indexOf('NavigationController') >= 0) {
                    var roots = vc.viewControllers();
                    if (roots && roots.count() > 0) {
                        var rv = roots.objectAtIndex_(0);
                        log('      -> rootCls=' + rv.$className);
                        var rh = scoreForClass(rv.$className);
                        log('      -> rootHits(' + rh.length + ')=' + rh.slice(0, 12).join(', '));
                    }
                }
            } catch (e) {}
            var hits = scoreForClass(clsName);
            log('      hits(' + hits.length + ')=' + hits.slice(0, 12).join(', '));
        }
    } catch (e) { log('dumpTabBar err: ' + e); }
}

rpc.exports = {
    diag: function () {
        var out = 0;
        if (ObjC.classes.CYTabBarController) {
            ObjC.choose(ObjC.classes.CYTabBarController, {
                onMatch: function (inst) { out++; dumpTabBar(inst, 'CYTabBarController#' + out); },
                onComplete: function () { log('CYTabBarController instances: ' + out); }
            });
        } else {
            log('CYTabBarController class NOT found');
        }
        try {
            var app = ObjC.classes.UIApplication.sharedApplication();
            var windows = app.windows();
            for (var w = 0; w < windows.count(); w++) {
                var win = windows.objectAtIndex_(w);
                var rvc = win.rootViewController();
                if (!rvc) continue;
                log('window#' + w + ' rootVC=' + rvc.$className);
                try {
                    var kids = rvc.childViewControllers();
                    for (var k = 0; k < kids.count(); k++) {
                        var kd = kids.objectAtIndex_(k);
                        log('   child#' + k + ' ' + kd.$className);
                    }
                } catch (e) {}
            }
        } catch (e) { log('window err: ' + e); }
        return true;
    }
};
"""


def main():
    pid = int(sys.argv[1])
    mgr = frida.get_device_manager()
    dev = mgr.add_remote_device('127.0.0.1:27042')
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
    print('--- diag ---')
    try:
        script.exports_sync.diag()
    except Exception as e:
        print('rpc err: %s' % e)
    time.sleep(2)
    session.detach()
    print('done')


if __name__ == '__main__':
    main()
