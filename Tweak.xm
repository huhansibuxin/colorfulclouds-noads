//
//  彩云天气 Pro 去小助手 + 去广告 Tweak
//  Bundle: net.colorfulclouds.app.pro
//
//  实测有效的两条链路（其余猜测性 hook 已全部删除）：
//   1. 小助手 = CYTabBarController 自定义底栏 bottomBarView 里的 chatButton。
//      不是系统 tab，所以过滤 viewControllers 完全无效。
//      生效点：isShowChat 恒返回 NO + setIsShowChat: 强制 NO
//      → App 自己不创建小助手按钮，底栏剩 3 个按钮并自动三等分（实测 143px×3）。
//   2. 广告 = CYADLaunchViewController（开屏）与 CYADFactory（插屏/信息流）。
//      直接从"请求广告"这一步掐断，不让数据回来，弹窗自然不会出现。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>

// Logos 只生成 @class 前向声明，访问继承来的成员或自己的方法必须先声明。
// 属性一律走 KVC（valueForKey:）访问，避免和真实类型耦合。
@interface CYTabBarController : UITabBarController
- (void)refreshShowChat;
- (void)refreshBottomView;
- (void)refreshMyButton;
- (void)goChat;
@end

@interface CYADLaunchViewController : UIViewController
@end

@interface CYADFactory : NSObject
@end

#pragma mark - 日志工具

static NSURL *CYLogFileURL(void) {
    static NSURL *url = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = paths.firstObject ?: NSTemporaryDirectory();
        url = [NSURL fileURLWithPath:[doc stringByAppendingPathComponent:@"caiyun_remove_ads.log"]];
    });
    return url;
}

// 日志轮转上限：1.5MB（1兆500K）。超过就整文件重写，防止撑爆沙盒。
static const unsigned long long CYLogRotateBytes = 1572864ULL;

static void CYLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = CYLogFileURL().path;
    // 大小轮转：超过 1.5MB 直接删掉重写（旧日志丢弃，留最近一段）
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attrs && [attrs fileSize] > CYLogRotateBytes) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:data attributes:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    }
}

#pragma mark - 会员/广告文案关键词

static NSSet<NSString *> *CYAdKeywords(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithObjects:
            @"会员", @"VIP", @"SVIP", @"vip", @"svip",
            @"限时特惠", @"限时优惠", @"限时", @"特惠",
            @"开通会员", @"购买会员", @"升级会员", @"续费", @"到期",
            @"会员优惠券", @"恢复订阅", @"立即开通", @"立即购买",
            @"连续包月", @"连续包年", @"免费试用", @"试用",
            @"折扣", @"优惠", @"福利", @"抽奖", @"红包", @"签到",
            @"活动", @"推广", @"广告", @"领券", @"领取",
            nil];
    });
    return set;
}

static BOOL CYStringContainsAdKeyword(NSString *text) {
    if (!text.length) return NO;
    NSString *low = text.lowercaseString;
    for (NSString *kw in CYAdKeywords()) {
        if ([low containsString:kw.lowercaseString]) return YES;
    }
    return NO;
}

// 从任意对象身上尽量抠出可判定的文案（title / message / text）
static NSString *CYExtractTitleFromObject(id obj) {
    if (!obj) return @"";
    NSMutableString *s = [NSMutableString string];
    NSString *selNames[] = {@"title", @"message", @"text", @"content", @"desc"};
    for (int i = 0; i < 5; i++) {
        SEL sel = NSSelectorFromString(selNames[i]);
        if (![obj respondsToSelector:sel]) continue;
        id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        if ([v isKindOfClass:[NSString class]] && [v length]) {
            [s appendFormat:@" %@", v];
        }
    }
    return s;
}

// 兜底判定：present 出来的 VC 是否属于"业务推广弹窗"（会员/活动/广告/升级等）。
// 系统权限弹窗（定位/通知/相册等）一律放行，否则 App 无法正常工作。
static BOOL CYObjectIsAdPopup(id obj) {
    if (!obj) return NO;
    NSString *cls = NSStringFromClass([obj class]);
    // 类名层面的硬判定
    if ([cls containsString:@"PayLaunchView"] ||
        [cls containsString:@"MemberToastView"] ||
        [cls containsString:@"SvipToastView"] ||
        [cls containsString:@"SVIPBottomToastView"] ||
        [cls containsString:@"MemberBottomView"] ||
        [cls containsString:@"VipBottomView"] ||
        [cls containsString:@"ADLaunch"]) {
        CYLog(@"[AdPopup] block by class: %@", cls);
        return YES;
    }
    // 文案层面的判定（title / message）
    NSString *text = CYExtractTitleFromObject(obj);
    if (CYStringContainsAdKeyword(text)) {
        CYLog(@"[AdPopup] block by keyword: %@ text=%@", cls, text);
        return YES;
    }
    // 系统权限弹窗放行（定位/通知/相册/蓝牙/麦克风/粘贴等）
    if ([text containsString:@"位置"] || [text containsString:@"定位"] ||
        [text containsString:@"通知"] || [text containsString:@"相册"] ||
        [text containsString:@"麦克风"] || [text containsString:@"蓝牙"] ||
        [text containsString:@"粘贴"] || [text containsString:@"权限"] ||
        [text containsString:@"允许"]) {
        return NO;
    }
    return NO;
}

#pragma mark - 小助手：隐藏底栏按钮（兜底）

// 主手段是 isShowChat 返回 NO；这里是保险——万一 App 绕开配置直接创建了按钮，
// 在底栏每次刷新后把它按下去。用 KVC 取属性，不依赖具体类型。
static void CYHideChatButton(id tbc, NSString *when) {
    if (!tbc) return;
    @try {
        id chatBtn = [tbc valueForKey:@"chatButton"];
        id chatBg  = [tbc valueForKey:@"chatBtnBgView"];
        BOOL changed = NO;
        if ([chatBtn isKindOfClass:[UIView class]] && !((UIView *)chatBtn).hidden) {
            ((UIView *)chatBtn).hidden = YES;
            changed = YES;
        }
        if ([chatBg isKindOfClass:[UIView class]] && !((UIView *)chatBg).hidden) {
            ((UIView *)chatBg).hidden = YES;
            changed = YES;
        }
        if (changed) {
            CYLog(@"[Chat] chatButton hidden via %@", when);
        }
    } @catch (NSException *e) {
        CYLog(@"[Chat] KVC chatButton failed @%@: %@", when, e.reason);
    }
}

#pragma mark - CYTabBarController：去小助手（实测命中的主链路）

%hook CYTabBarController

// ① 配置层：App 启动时用服务端下发的开关调 setIsShowChat:YES，这里强制改写成 NO，
//    App 自己就不会创建小助手按钮，底栏自动三等分——这是真正生效的一招。
- (BOOL)isShowChat {
    return NO;
}

- (void)setIsShowChat:(BOOL)show {
    %orig(NO);
}

// ② UI 层兜底：底栏每次重建/刷新后再压一次，防 App 绕开配置直接建按钮
- (void)refreshShowChat {
    %orig;
    CYHideChatButton(self, @"refreshShowChat");
}

- (void)refreshBottomView {
    %orig;
    CYHideChatButton(self, @"refreshBottomView");
}

- (void)refreshMyButton {
    %orig;
    CYHideChatButton(self, @"refreshMyButton");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    CYHideChatButton(self, @"viewDidAppear");
}

// ③ 防呆：deeplink / 推送 / 活动位可能直接调 goChat 进小助手
- (void)goChat {
    CYLog(@"[Chat] goChat blocked");
    return;
}

%end

#pragma mark - CYADLaunchViewController：开屏广告（含 SVIP 付费开屏）

%hook CYADLaunchViewController

// 只掐"请求 / 加载 / 预加载"这类无返回值的入口，绝不动带 completion 的方法：
// 不回调 completion 会让 App 卡在开屏流程上。
- (void)requestADInfoWithIsHot:(BOOL)isHot hotArray:(NSArray *)hotArray {
    CYLog(@"[ADLaunch] requestADInfoWithIsHot:%d blocked", isHot);
    return;
}

- (void)loadADwithDict:(id)dict isHot:(BOOL)isHot {
    CYLog(@"[ADLaunch] loadADwithDict blocked");
    return;
}

- (void)preloadArray:(id)array {
    CYLog(@"[ADLaunch] preloadArray blocked");
    return;
}

%end

#pragma mark - CYADFactory：插屏 / 信息流 / 通用广告位

%hook CYADFactory

- (void)requestInsertADWithModel:(id)model {
    CYLog(@"[ADFactory] requestInsertAD blocked");
    return;
}

- (void)requestInfoflowWithModel:(id)model {
    CYLog(@"[ADFactory] requestInfoflow blocked");
    return;
}

- (void)requestRewardVideoWithModel:(id)model {
    CYLog(@"[ADFactory] requestRewardVideo blocked");
    return;
}

- (void)requestADWithModel:(id)model bottomView:(id)bottomView backgroundImage:(id)image {
    CYLog(@"[ADFactory] requestAD blocked");
    return;
}

%end

#pragma mark - 浮层监控 + 广告兜底隐藏（事件驱动，不做轮询）

// 判断某个类名是否属于"会员/付费推广浮层"。
// 第一层：硬编码黑名单——静态分析已知的会员类，不管形态直接拉黑；
// 第二层：组合判断——"会员语义" + "浮层形态"都命中才拦。
// 只针对浮层视图，绝不碰 ViewController 的根 view，所以会员中心等正常业务页不会被误伤。
// 大小写不敏感子串搜索（避免依赖 strcasestr 声明，编译更稳）
static const char *CYStrCaseless(const char *hay, const char *needle) {
    if (!hay || !needle) return NULL;
    size_t hlen = strlen(hay), nlen = strlen(needle);
    if (nlen == 0 || hlen < nlen) return NULL;
    for (size_t i = 0; i <= hlen - nlen; i++) {
        size_t j = 0;
        for (; j < nlen; j++) {
            char a = hay[i+j]; if (a >= 'A' && a <= 'Z') a += 32;
            char b = needle[j]; if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
        }
        if (j == nlen) return hay + i;
    }
    return NULL;
}

static BOOL CYIsAdOverlayClassName(const char *cls) {
    if (!cls || !*cls) return NO;
    // ① 硬编码黑名单（来自静态 class-dump，改名后靠 [Overlay] 日志再补）。用 C 字符串比较，
    //    不走 NSString/NSArray，避免热路径上的对象分配。
    static const char *hard[] = {
        "ColorfulCloudsPro.CYPayLaunchView",
        "ColorfulCloudsPro.CYPayLaunchOtherView",
        "ColorfulCloudsPro.CYMemberBottomView",
        "ColorfulCloudsPro.CYVipBottomView",
        "ColorfulCloudsPro.CYMemberToastView",
        "ColorfulCloudsPro.CYGetSvipToastView",
        "ColorfulCloudsPro.CYLightupSVIPBottomToastView",
        "ColorfulCloudsPro.CYOneSVIPBottomToastView",
        "ColorfulCloudsPro.CYChatPayToastView",
        "ColorfulCloudsPro.CYMemberBackToastView",
        "ColorfulCloudsPro.CYMemberPayButtonView",
        // 静态分析确认存在（源码路径 ColorfulCloudsPro/CYNotificationPopupActivityView.swift）：
        // 通知弹窗式活动视图，属于首页营销弹窗队列的一类渲染结果，兜底一并拉黑。
        "ColorfulCloudsPro.CYNotificationPopupActivityView",
        NULL
    };
    for (int i = 0; hard[i]; i++) if (strcmp(cls, hard[i]) == 0) return YES;
    // ② 组合判断兜底（后缀 / 语义+形态）
    size_t len = strlen(cls);
    if (len >= 13 && strcmp(cls + len - 13, "PayLaunchView") == 0) return YES;
    if (len >= 17 && strcmp(cls + len - 17, "PayLaunchOtherView") == 0) return YES;
    BOOL memberish = CYStrCaseless(cls, "svip") || CYStrCaseless(cls, "vip") ||
                     CYStrCaseless(cls, "member") || CYStrCaseless(cls, "pay");
    BOOL overlay = CYStrCaseless(cls, "toast") || CYStrCaseless(cls, "popup") ||
                   CYStrCaseless(cls, "launch") || CYStrCaseless(cls, "banner") ||
                   CYStrCaseless(cls, "activity") || CYStrCaseless(cls, "advert");
    return memberish && overlay;
}

// 通用弹窗形态判定：直接挂 window 上的自定义浮层，若盖住屏幕中心、尺寸适中
// （面积约 4%~92% 屏幕），就是一个"卡片式弹窗"——不管它是什么业务，一律拦。
// ---- v2.0.1 强营销文案判定层 ----
// 上面所有兜底都有同一个致命前提：要求浮层"直接挂在 window 上"（self.superview == win）。
// 实测 8/30→9/28 整月零日志，正是因为这个弹窗挂在某个容器视图上 —— 既不命中类名黑名单，
// 也不满足 onWindow 分支，于是连"漏网记录"都没有，完全静默穿透。
// 这一层改成"与父视图无关、与类名无关"：只看两件事 —— ① 面积盖住半屏以上；
// ② 子树里出现运营文案（年卡/终身/立即开通/先不看…）。命中即收。
//
// 性能：didMoveToWindow 本身是事件驱动（无轮询）。每次进入仅做几次 isKindOfClass 与
// 面积除法；只有"面积 ≥ 50% 且不是页面根视图"这种极罕见情况才会扫子树，
// 且扫描限深 4 层、只看 UILabel/UIButton/UITextView 的 text，开销可忽略。
static NSSet<NSString *> *CYMarketingKeywords(void) {
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithObjects:
            @"立即开通", @"立即购买", @"马上开通", @"一键开通",
            @"连续包月", @"连续包年", @"连续包季",
            @"限时特惠", @"限时优惠", @"限时折扣", @"限时抢购",
            @"年卡", @"终身", @"永久会员", @"买一年",
            @"续费", @"优惠券", @"抽奖", @"免费试用", @"开通会员",
            @"先不看", @"去看看", @"已经是会员", @"升级会员",
            @"尊享", @"特惠", @"秒杀", @"红包", @"会员日",
            nil];
    });
    return set;
}

static BOOL CYTextHasMarketingKeyword(NSString *t) {
    if (![t isKindOfClass:[NSString class]] || t.length == 0) return NO;
    static NSSet *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = CYMarketingKeywords(); });
    for (NSString *k in keys) {
        if ([t containsString:k]) return YES;
    }
    return NO;
}

// 子树文案扫描（限深 4 层，只查文本型控件）。返回命中文案用于日志取证。
static NSString *CYSubtreeMarketingText(UIView *v, int depth) {
    if (!v || depth > 4) return nil;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t && CYTextHasMarketingKeyword(t)) return t;
    } else if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (!t) t = b.titleLabel.text;
        if (t && CYTextHasMarketingKeyword(t)) return t;
    } else if ([v isKindOfClass:[UITextView class]]) {
        NSString *t = ((UITextView *)v).text;
        if (t && CYTextHasMarketingKeyword(t)) return t;
    }
    for (UIView *s in v.subviews) {
        NSString *r = CYSubtreeMarketingText(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

// 面积占比：bounds 与 frame 取大者。autolayout 下刚上屏时 frame 常还是 0，
// 但 bounds 一般已被约束系统算好，只看 frame 会漏判。
static CGFloat CYViewAreaRatio(UIView *v, UIWindow *win) {
    CGSize ws = win.bounds.size;
    if (ws.width <= 0 || ws.height <= 0) return 0;
    CGFloat winArea = ws.width * ws.height;
    if (winArea <= 0) return 0;
    CGSize bs = v.bounds.size, fs = v.frame.size;
    CGFloat b = bs.width * bs.height, f = fs.width * fs.height;
    CGFloat best = (b > f) ? b : f;
    return best / winArea;
}

static BOOL CYLooksLikePopupOverlay(UIView *v, UIWindow *win) {
    CGRect f = v.frame;
    CGFloat ww = win.bounds.size.width, wh = win.bounds.size.height;
    if (ww <= 0 || wh <= 0) return NO;
    CGPoint center = CGPointMake(ww / 2, wh / 2);
    if (!CGRectContainsPoint(f, center)) return NO;      // 不盖住屏幕中心 → 不是弹窗
    CGFloat ratio = (f.size.width * f.size.height) / (ww * wh);
    if (ratio < 0.04 || ratio > 0.92) return NO;         // 太小的控件 / 全屏页 → 不是弹窗
    return YES;
}

%hook UIView

// 事件驱动：任何视图挂到 window 上时触发一次，不做定时轮询（避免额外 CPU/能耗）。
- (void)didMoveToWindow {
    %orig;
    UIWindow *win = self.window;
    if (!win) return;

    const char *cls = class_getName([self class]);
    BOOL onWindow = (self.superview == win);
    // 三条护栏，保证下面新增的"文案层"零误伤：
    //   ① 位于 rootViewController.view 层级之下的视图 = 正常页面（首页/设置页/会员中心…），
    //      永不判定。营销弹窗是"盖在页面之上"的窗口级浮层，不在其中 —— 这条把误伤压到零；
    //   ② 系统容器视图（UI* / _UI*，如 UITransitionView / UILayoutContainerView）= 页面骨架；
    //   ③ 面积不足半屏的直接跳过（绝大多数控件在这里就被排除，几乎不产生开销）。
    BOOL isVCRoot = [self.nextResponder isKindOfClass:[UIViewController class]];
    BOOL isSystemCls = (strncmp(cls, "UI", 2) == 0) || (strncmp(cls, "_UI", 3) == 0);
    // rootViewController.view 的层级判定放进下面 if 内部做惰性求值：只有"面积过半屏"的
    // 极小撮视图才需要走一次超级视图链，普通控件在面积那步就被短路掉了。

    // 兜底 C（v2.0.1 新增，最关键的一层）：不挑类名、不挑父视图 —— 任何"盖住半屏以上 +
    // 子树里出现运营文案"的视图一律收掉。之前所有兜底都要求"直接挂 window"，弹窗只要挂在
    // 某个容器上就整条链静默穿透，这正是 8/30→9/28 整月零日志的根因。
    if (!isSystemCls && CYViewAreaRatio(self, win) >= 0.50) {
        UIView *rootView = win.rootViewController.view;
        BOOL underRootVC = (rootView != NULL) && (self == rootView || [self isDescendantOfView:rootView]);
        NSString *txt = underRootVC ? nil : CYSubtreeMarketingText(self, 0);
        if (txt) {
            CYLog(@"[AdPopup] killed %s by copy: %@", cls, txt);
            self.hidden = YES;
            self.userInteractionEnabled = NO;
            UIView *sup = self.superview;
            if (sup && sup != win && CYViewAreaRatio(sup, win) >= 0.90 && sup.subviews.count <= 3) {
                // 父层是"纯遮罩容器"（几乎全屏 + 子视图极少）→ 一并收掉，
                // 否则留下的透明遮罩会继续挡住正常点击。
                sup.hidden = YES;
                CYLog(@"[AdPopup] killed container %s too", class_getName([sup class]));
            }
        }
    }
    // 兜底 A：直接挂 window 的"居中卡片"浮层一律当弹窗干掉（不挑业务，全拦）
    if (onWindow && CYLooksLikePopupOverlay(self, win)) {
        CYLog(@"[Overlay] popup-like %s -> hidden", cls);
        self.hidden = YES;
    }
    // 兜底 B：类名带会员/付费语义的浮层，直接隐藏
    if (CYIsAdOverlayClassName(cls)) {
        CYLog(@"[AdOverlay] hid %s", cls);
        self.hidden = YES;
        // 广告容器本身也一起摘掉，避免留下透明遮罩挡住点击
        if (self.superview && self.superview != win) {
            UIView *container = self.superview;
            if (container.subviews.count <= 2 &&
                container.frame.size.width >= win.bounds.size.width * 0.8) {
                container.hidden = YES;
                CYLog(@"[AdOverlay] hid container %s", class_getName([container class]));
            }
        }
    }
    // 漏网定位（零噪音）：非系统类、直接挂 window、宽度 ≥ 30% 屏幕的可疑浮层，
    // 同类只记一次。平时几乎不写；真弹窗出现时（无论拦没拦住）都会留下类名和尺寸，
    // 方便从日志反推是哪一层没兜住。
    if (!isVCRoot && strncmp(cls, "UI", 2) != 0 && strncmp(cls, "_UI", 3) != 0) {
        CGRect f = self.frame;
        if (f.size.width >= win.bounds.size.width * 0.30) {
            static NSMutableSet *seen = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
            NSString *key = [NSString stringWithUTF8String:cls];
            if (![seen containsObject:key]) {
                [seen addObject:key];
                CYLog(@"[Overlay] %s f=(%.0f,%.0f,%.0f,%.0f)",
                      cls, f.origin.x, f.origin.y, f.size.width, f.size.height);
            }
        }
    }
}

%end

#pragma mark - CYAlertView 系列：卡片弹窗直接掐掉

@interface CYAlertView : UIView
@end
@interface CYAlertContentView : UIView
@end
@interface CYThemeAdView : UIView
@end

%hook CYAlertView

- (void)show {
    CYLog(@"[CYAlertView] show blocked");
    return;
}

- (void)showAlert:(id)arg1 {
    CYLog(@"[CYAlertView] showAlert: blocked");
    return;
}

- (void)showAlert:(id)arg1 showClose:(BOOL)showClose {
    CYLog(@"[CYAlertView] showAlert:showClose: blocked");
    return;
}

%end

%hook CYAlertContentView

- (void)show {
    CYLog(@"[CYAlertContentView] show blocked");
    return;
}

%end

%hook CYThemeAdView

- (instancetype)init {
    CYLog(@"[CYThemeAdView] init blocked -> nil");
    return nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    CYLog(@"[CYThemeAdView] initWithFrame blocked -> nil");
    return nil;
}

%end

#pragma mark - UIAlertController：业务弹窗兜底

%hook UIAlertController

+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)preferredStyle {
    if (CYStringContainsAdKeyword(title) || CYStringContainsAdKeyword(message)) {
        CYLog(@"[UIAlertController] blocked title=%@ message=%@", title, message);
        return nil;
    }
    return %orig(title, message, preferredStyle);
}

%end

#pragma mark - present 兜底

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))completion {
    if (CYObjectIsAdPopup(vc)) {
        CYLog(@"[present] blocked ad popup: %@", NSStringFromClass([vc class]));
        if (completion) completion();
        return;
    }
    %orig(vc, flag, completion);
}

%end

#pragma mark - CYVipBottomView 兜底中和（@objc init 安全 swizzle，主拦截的补充层）

// 安全"按死"源头（ABI 安全版）：在 CYVipBottomView 的 @objc 初始化方法里，调用原始 init
// 拿到真实实例，立即隐藏+禁交互。CYVipBottomView 是 UIView 子类，initWithFrame:/initWithCoder:
// 均为 @objc，ABI 与 (id,SEL,...) 一致，用 MSHookMessageEx swizzle 完全安全——不会出现之前
// MSHookFunction 改"私有 Swift 创建函数"（无 _cmd、返回可能是 Optional 结构体）导致的 ABI 错乱
// 与设置页强解包崩溃。浮层在"出生"时即被中和，App 即便反复从 nib 重建，每次都被立刻隐藏，
// 无闪烁、无崩溃；下方 didMoveToWindow 仍兜底（最后一道拦截）。
static id (*origCYVipInitWithFrame)(id, SEL, CGRect);
static id (*origCYVipInitWithCoder)(id, SEL, NSCoder *);

static id CYVipInitWithFrameSafe(id self, SEL _cmd, CGRect frame) {
    id v = origCYVipInitWithFrame(self, _cmd, frame);
    if (v) { [v setHidden:YES]; [v setUserInteractionEnabled:NO]; }
    return v;
}
static id CYVipInitWithCoderSafe(id self, SEL _cmd, NSCoder *coder) {
    id v = origCYVipInitWithCoder(self, _cmd, coder);
    if (v) { [v setHidden:YES]; [v setUserInteractionEnabled:NO]; }
    return v;
}

static void CYInstallVipSafe(void) {
    Class cls = objc_getClass("ColorfulCloudsPro.CYVipBottomView");
    if (!cls) return;
    MSHookMessageEx(cls, @selector(initWithFrame:), (IMP)CYVipInitWithFrameSafe, (IMP *)&origCYVipInitWithFrame);
    MSHookMessageEx(cls, @selector(initWithCoder:), (IMP)CYVipInitWithCoderSafe, (IMP *)&origCYVipInitWithCoder);
}

// 零闪烁打磨（主拦截）：无论哪个父视图把会员/付费类子视图加进来，都立刻 removeFromSuperview，
// 视图从未进入 window 渲染 -> 零闪烁；同时也让下方 didMoveToWindow 不再需要反复 hide。
// 实测只 hook CYConfigureHeadView didAddSubview: 命中 0 次 —— 因为 CYVipBottomView 实际被加在
// CYConfigureHeadView 的*子视图*（如 contentView）上，而非直接加在 CYConfigureHeadView 本身，
// 故父视图的 didAddSubview: 收不到它。改为 hook UIView 全局 didAddSubview: 才能稳定兜住。
// UIView 是 ObjC，didAddSubview: 为 @objc，ABI 与 (id,SEL,UIView*) 一致，MSHookMessageEx swizzle
// 完全安全（不会像私有 Swift 创建函数那样崩）。这是"主拦截"，下方 CYVipBottomView 的 @objc init
// 中和作为兜底。
static void (*origUIViewDidAddSubview)(id, SEL, UIView *) = NULL;

// 会员/付费底部浮层判定（C 字符串 + 前缀预筛，热路径零对象分配）。
// 关键优化：彩云私有类都在 "ColorfulCloudsPro.CY" 命名空间，正常视图（UILabel/UIView/
// 系统 _UI* 等）首字符不匹配 -> 直接跳过，不进黑名单比较，开销可忽略。
static BOOL CYIsMemberPayBottomView(UIView *v) {
    if (!v) return NO;
    const char *name = class_getName([v class]);
    if (strncmp(name, "ColorfulCloudsPro.CY", 18) != 0) return NO;
    static const char *black[] = {
        "CYVipBottomView", "CYMemberBottomView", "CYMemberAPayView",
        "CYMemberPayButtonView", "CYPayLaunchView", "CYPayLaunchOtherView",
        "CYLightupSVIPBottomToastView", "CYFlowerBottomView",
        "CYGuidePayView", "CYVipRightsView",
        "CYNotificationPopupActivityView", NULL
    };
    for (int i = 0; black[i]; i++) if (strstr(name, black[i])) return YES;
    return NO;
}

static void CYUIViewDidAddSubview(id self, SEL _cmd, UIView *subview) {
    if (origUIViewDidAddSubview) origUIViewDidAddSubview(self, _cmd, subview);
    if (CYIsMemberPayBottomView(subview)) {
        [subview removeFromSuperview];
        [subview setHidden:YES];
        [subview setUserInteractionEnabled:NO];
        CYLog(@"[VipSafe] blocked %s", class_getName([subview class]));
    }
}

static void CYInstallDidAddSubviewGuard(void) {
    MSHookMessageEx([UIView class], @selector(didAddSubview:), (IMP)CYUIViewDidAddSubview, (IMP *)&origUIViewDidAddSubview);
}

#pragma mark - 营销弹窗总闸：运行时定位调度中心 + 清空首页弹窗队列（根治层）

// 静态分析（IPA 主二进制，类名段未加密）确认：App 的营销弹窗不是"各自随机弹"，
// 而是"队列式顺序派发"：
//   服务端下发字典 → popupsArrWithDict: → setHomePopupArray:（存入首页弹窗队列）
//   → handlePopupArray: → handleNextPopup（按 currenPopupIndex 逐个弹）
//   → 按 popupId / popupStyles 渲染成具体 View。
// 埋点事件名直接泄露了完整业务面：
//   activity_discount_popup_show/close、member_retain_popup、exit_popup_return_gift、
//   feature_promotion_popup_show、lightup_spring_promotion_popup、coupon_pay_popup、
//   before_expiration_popup、generic_payment_popup、referral_card_popup …
// 中文文案交叉验证命中：
//   「先不看 / 去看看 / 已经是会员啦 / 已经购买过优惠，暂时无法购买」+
//   「弹窗活动后不展示开屏 / 一日卡第一次弹出时间：%@」
//   —— 即用户看到的会员卡（年卡）营销弹窗。
//
// v1.x 的所有做法都是"等弹窗 View 创建之后再隐藏"，属于补丁，必然猫鼠：新增一类
// 弹窗就要补一次黑名单。这里改在**队列入队口直接把队列置空** —— 弹窗从未进入渲染
// 流程：零闪烁、零创建开销，且完全不依赖具体类名/弹窗类型，服务端换新活动弹窗、
// App 升级版本都一并失效。
//
// 宿主类名不做硬编码：运行时在 ColorfulCloudsPro 命名空间里找"真正实现
// setHomePopupArray: 的类"再 swizzle（行为定位，而非名字定位），改包/换版本通吃。

// ---- 签名适配 hook 模板：一种模板严格对应一种 typeEncoding ----
// 装机前逐条比对（先剥掉帧偏移数字再比），完全匹配才 hook。
// 只有"签名完全一致"才敢动手 —— 这是 v1.7.x 拿返回值类型不匹配换来崩设置页的教训。
#define CY_GATE_VOID_OBJARG(ID, SELNAME)                                            \
    static void (*orig_##ID)(id, SEL, id) = NULL;                                   \
    static void imp_##ID(id self, SEL _cmd, id arg) {                               \
        NSArray *a = [arg isKindOfClass:[NSArray class]] ? (NSArray *)arg : nil;    \
        CYLog(@"[PopupGate] hit " SELNAME " on %s n=%lu",                           \
              class_getName([self class]), (unsigned long)a.count);                 \
        if (orig_##ID) orig_##ID(self, _cmd, @[]);                                  \
    }

#define CY_GATE_VOID_NOARG(ID, SELNAME)                                             \
    static void (*orig_##ID)(id, SEL) = NULL;                                       \
    static void imp_##ID(id self, SEL _cmd) {                                       \
        (void)orig_##ID;                                                            \
        CYLog(@"[PopupGate] hit " SELNAME " (swallowed) on %s",                     \
              class_getName([self class]));                                         \
    }

#define CY_GATE_OBJRET_OBJARG(ID, SELNAME)                                          \
    static id (*orig_##ID)(id, SEL, id) = NULL;                                     \
    static id imp_##ID(id self, SEL _cmd, id arg) {                                 \
        (void)orig_##ID;                                                            \
        CYLog(@"[PopupGate] hit " SELNAME " (starved) on %s",                       \
              class_getName([self class]));                                         \
        return @[];                                                                 \
    }

CY_GATE_VOID_OBJARG(setHomePopupArray,   "setHomePopupArray:")
CY_GATE_VOID_OBJARG(handlePopupArray,    "handlePopupArray:")
CY_GATE_VOID_NOARG(handleNextPopup,      "handleNextPopup")
CY_GATE_OBJRET_OBJARG(popupsArrWithDict, "popupsArrWithDict:")

static NSMutableSet *gPopupGateArmed = nil;
static int gPopupGateLogCount = 0;

// typeEncoding 常带帧偏移数字（如 v24@0:8@16），比对前先剥掉数字
static void CYNormalizeTypeEncoding(const char *enc, char *out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = 0;
    if (!enc) return;
    size_t j = 0;
    for (const char *p = enc; *p && j + 1 < cap; p++) {
        if (*p >= '0' && *p <= '9') continue;
        out[j++] = *p;
    }
    out[j] = 0;
}

typedef struct {
    const char *sel;
    const char *enc;
    IMP imp;
    IMP *origSlot;
} CYGateTarget;

static const CYGateTarget kCYGateTargets[] = {
    { "setHomePopupArray:", "v@:@", (IMP)imp_setHomePopupArray, (IMP *)&orig_setHomePopupArray },
    { "handlePopupArray:",  "v@:@", (IMP)imp_handlePopupArray,  (IMP *)&orig_handlePopupArray  },
    { "handleNextPopup",    "v@:",  (IMP)imp_handleNextPopup,   (IMP *)&orig_handleNextPopup   },
    { "popupsArrWithDict:", "@@:@", (IMP)imp_popupsArrWithDict, (IMP *)&orig_popupsArrWithDict },
    { NULL, NULL, NULL, NULL }
};

// 取证：把"本来要弹什么"写进日志（队列元素的类名）。命中才记 + 条数上限，避免刷屏。
static void __attribute__((unused)) CYPopupGateRecord(const char *tag, id self, NSArray *arr) {
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return;
    if (gPopupGateLogCount >= 40) return;
    gPopupGateLogCount++;
    NSMutableArray *names = [NSMutableArray array];
    NSUInteger n = arr.count < 8 ? arr.count : 8;
    for (NSUInteger i = 0; i < n; i++) {
        id e = arr[i];
        [names addObject:NSStringFromClass([e class])];
    }
    CYLog(@"[PopupGate] %s on %s n=%lu {%@}", tag, class_getName([self class]),
          (unsigned long)arr.count, [names componentsJoinedByString:@" "]);
}

// 总闸：入队口清空队列。
// 传 @[] 而不是 nil —— 该属性是 copy 语义，空数组是合法值，下游按 count 做的
// 边界判断天然安全（这个队列本来就要支持"今天没有弹窗"的情况）。
// （队列内容取证已合并进 CY_GATE_VOID_OBJARG 宏的 n= 字段）

// 观测层（不改变行为）：确认清空队列后调度链是否仍被走到、参数是什么。
// 保留原参数原样转发，只为取证，不参与拦截，避免影响 App 正常流程。
// （观测层已由 kCYGateTargets 统一驱动，不再单独实现）

// 在彩云命名空间内找"真正实现"某 selector 的类（跳过只继承的子类，避免重复 swizzle）
// 宿主查找同时覆盖实例方法与类方法，并返回"真正实现"该 selector 的所有类
// （跳过只从父类继承的子类，避免把 swizzle 挂到一堆子类上）。
// 命名空间只用来排序（ColorfulCloudsPro 优先），不再用来过滤 —— 上一版正是
// 死在前缀过滤把宿主筛没了，而且失败时静默不报，白等一整轮。
typedef struct {
    Class hookTarget;
    Class owner;
    BOOL  isClassMethod;
} CYGateHost;

static unsigned int CYGateHosts(SEL sel, CYGateHost *out, unsigned int maxOut) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return 0;
    unsigned int found = 0;

    for (int pass = 0; pass < 2 && found < maxOut; pass++) {
        for (unsigned int i = 0; i < count && found < maxOut; i++) {
            Class c = classes[i];
            const char *cn = class_getName(c);
            if (!cn) continue;
            BOOL isNS = (strncmp(cn, "ColorfulCloudsPro.", 18) == 0);
            if (pass == 0 && !isNS) continue;
            if (pass == 1 && isNS) continue;

            Method m = class_getInstanceMethod(c, sel);
            if (m) {
                Class sup = class_getSuperclass(c);
                Method sm = sup ? class_getInstanceMethod(sup, sel) : NULL;
                if (!(sm && method_getImplementation(sm) == method_getImplementation(m))) {
                    out[found].hookTarget = c;
                    out[found].owner = c;
                    out[found].isClassMethod = NO;
                    found++;
                    continue;
                }
            }

            Method cm = class_getClassMethod(c, sel);
            if (cm) {
                Class sup = class_getSuperclass(c);
                Method sm = sup ? class_getClassMethod(sup, sel) : NULL;
                if (!(sm && method_getImplementation(sm) == method_getImplementation(cm))) {
                    out[found].hookTarget = object_getClass(c);
                    out[found].owner = c;
                    out[found].isClassMethod = YES;
                    found++;
                }
            }
        }
    }

    free(classes);
    return found;
}

// 只对返回 void 的方法挂 hook：彻底规避"返回值类型不匹配"这一类 ABI 坑
// （v1.7.x 按死私有 Swift 函数崩溃的教训：签名不对就会把调用方带崩）。
// 取宿主上该 sel 的原始 typeEncoding（实例方法优先，其次类方法）
static const char *CYHostTypeEncoding(Class hookTarget, SEL sel) {
    Method m = class_getInstanceMethod(hookTarget, sel);
    if (!m) m = class_getClassMethod(hookTarget, sel);
    return m ? method_getTypeEncoding(m) : NULL;
}

static void CYInstallPopupGate(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPopupGateArmed = [NSMutableSet set]; });

    for (const CYGateTarget *t = kCYGateTargets; t->sel; t++) {
        NSString *key = [NSString stringWithUTF8String:t->sel];
        if ([gPopupGateArmed containsObject:key]) continue;

        SEL sel = NSSelectorFromString(key);
        CYGateHost hosts[8];
        unsigned int n = CYGateHosts(sel, hosts, 8);
        if (n == 0) {
            CYLog(@"[PopupGate] NOHOST %@ -- no class in runtime implements it", key);
            continue;
        }

        BOOL armedAny = NO;
        for (unsigned int i = 0; i < n; i++) {
            Class target = hosts[i].hookTarget;
            const char *enc = CYHostTypeEncoding(target, sel);
            char norm[64];
            CYNormalizeTypeEncoding(enc, norm, sizeof(norm));
            if (strcmp(norm, t->enc) != 0) {
                CYLog(@"[PopupGate] SKIP %@ on %s%s enc=%s (want %s)",
                      key, hosts[i].isClassMethod ? "+" : "-",
                      class_getName(hosts[i].owner), enc ? enc : "?", t->enc);
                continue;
            }
            MSHookMessageEx(target, sel, t->imp, t->origSlot);
            armedAny = YES;
            CYLog(@"[PopupGate] ARMED %@ on %s%s enc=%s",
                  key, hosts[i].isClassMethod ? "+" : "-",
                  class_getName(hosts[i].owner), norm);
        }
        if (armedAny) {
            [gPopupGateArmed addObject:key];
        } else {
            CYLog(@"[PopupGate] UNARMED %@ -- signature mismatch on all %u host(s)", key, n);
        }
    }
}

%ctor {
    CYInstallDidAddSubviewGuard();   // 零闪烁主拦截：任意父视图一加会员/付费子视图就移除
    CYInstallVipSafe();              // 兜底：CYVipBottomView 出生即隐藏（@objc init 中和）
    CYInstallPopupGate();            // 根治层：清空首页营销弹窗队列（队列空 = 一个都不弹）
    // Swift 侧类注册可能晚于本 dylib 的 %ctor，延时补装一次（已装过则自动跳过）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CYInstallPopupGate();
    });
    CYLog(@"[CaiYunRemoveAds] loaded for %@", [[NSBundle mainBundle] bundleIdentifier]);
}
