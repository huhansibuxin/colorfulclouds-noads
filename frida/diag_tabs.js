'use strict';

// 诊断彩云天气底部 tab 结构：类名 / title / 聊天功能指纹命中
if (!ObjC.available) {
    console.log('ObjC not available');
} else {
    var prints = ['chatinputview', 'chatarray', 'chattableview', 'chatinputbar',
                  'promptarray', 'historystatus', 'isrequesthistroy',
                  'ailabel', 'chatmodel', 'chatimgview', 'chatimages',
                  'assistant', 'chattextview'];

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
            console.log('=== ' + label + ' tabs=' + n);
            for (var i = 0; i < n; i++) {
                var vc = vcs.objectAtIndex_(i);
                var clsName = vc.$className;
                var itemTitle = '';
                try { var it = vc.tabBarItem(); if (it) { var t = it.title(); if (t) itemTitle = t.toString(); } } catch (e) {}
                var vcTitle = '';
                try { var vt = vc.title(); if (vt) vcTitle = vt.toString(); } catch (e) {}
                console.log('  #' + i + ' cls=' + clsName);
                console.log('      itemTitle=' + JSON.stringify(itemTitle) + '  vcTitle=' + JSON.stringify(vcTitle));
                // 如果是 nav 包装，也看根 VC
                try {
                    if (clsName.indexOf('NavigationController') >= 0) {
                        var roots = vc.viewControllers();
                        if (roots && roots.count() > 0) {
                            var rv = roots.objectAtIndex_(0);
                            console.log('      -> rootCls=' + rv.$className);
                            var rh = scoreForClass(rv.$className);
                            console.log('      -> rootHits(' + rh.length + ')=' + rh.slice(0, 12).join(', '));
                        }
                    }
                } catch (e) {}
                var hits = scoreForClass(clsName);
                console.log('      hits(' + hits.length + ')=' + hits.slice(0, 12).join(', '));
            }
        } catch (e) {
            console.log('dumpTabBar err: ' + e);
        }
    }

    var count = 0;
    if (ObjC.classes.CYTabBarController) {
        ObjC.choose(ObjC.classes.CYTabBarController, {
            onMatch: function (inst) {
                count++;
                dumpTabBar(inst, 'CYTabBarController#' + count);
            },
            onComplete: function () {
                console.log('CYTabBarController instances: ' + count);
            }
        });
    } else {
        console.log('CYTabBarController class NOT found');
    }

    // 兜底：从 keyWindow 的 rootViewController 找任意 UITabBarController
    try {
        var app = ObjC.classes.UIApplication.sharedApplication();
        var windows = app.windows();
        var foundTBC = false;
        for (var w = 0; w < windows.count(); w++) {
            var win = windows.objectAtIndex_(w);
            var rvc = win.rootViewController();
            if (!rvc) continue;
            console.log('window#' + w + ' rootVC=' + rvc.$className);
            if (String(rvc.$className).indexOf('TabBar') >= 0) {
                dumpTabBar(rvc, 'rootTabBar');
                foundTBC = true;
            }
            // child 里找
            try {
                var kids = rvc.childViewControllers();
                for (var k = 0; k < kids.count(); k++) {
                    var kd = kids.objectAtIndex_(k);
                    if (String(kd.$className).indexOf('TabBar') >= 0) {
                        dumpTabBar(kd, 'childTabBar');
                        foundTBC = true;
                    }
                }
            } catch (e) {}
        }
        if (!foundTBC) console.log('no TabBarController found from windows');
    } catch (e) {
        console.log('window err: ' + e);
    }
}
