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
    // 大小轮转：超过 1.5MB 直接删掉重写（旧日志丢弃，留最近一段）。
    // v2.0.3：原来每写一条都做一次 attributesOfItemAtPath:（背后是 stat 系统调用），
    // 属于纯浪费 —— 改成每 32 条查一次。计数竞争最坏只是多 stat 几次，无副作用。
    static int sinceSizeCheck = 0;
    if (sinceSizeCheck <= 0) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (attrs && [attrs fileSize] > CYLogRotateBytes) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
        sinceSizeCheck = 32;
    }
    sinceSizeCheck--;
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

// 关键词表统一存**小写**形态（v2.0.3）。原来表里混着 "VIP"/"vip"，比对时对每个
// 关键词现调 lowercaseString，等于每次判定都多分配 3x 个临时 NSString，
// 还保留了大小写重复项。现在表即小写、去重，比对侧零分配。
static NSSet<NSString *> *CYAdKeywords(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithObjects:
            @"会员", @"vip", @"svip",
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
    NSString *low = text.lowercaseString;   // 只转原文一次
    for (NSString *kw in CYAdKeywords()) {
        if ([low containsString:kw]) return YES;   // 关键词已是小写，不再转换
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

// ---- 类名归属判定（v2.0.5 新增）----
// 实机教训（v2.0.4「弹窗总闸彻底没装上」的根因）：这个 App **混用两种类名形态** ——
//   · Swift 类：运行时 class_getName 返回 "ColorfulCloudsPro.CYVipBottomView"（带模块前缀）
//   · ObjC  类：运行时 class_getName 返回 "CYMainActivityManager"（裸名，无前缀）
// 主二进制 __objc_classname 段里两类**都是裸名**（静态 dump 看不出差别），
// 模块前缀只在 Swift 类上由 Swift runtime 在注册时补上 —— 实测证据：
//   v2.0.2 日志 "[PopupGate] armed ... setHomePopupArray:=-CYMainActivityManager"（裸名）
//   同时期日志 "[VipSafe] blocked ColorfulCloudsPro.CYVipBottomView"（带前缀）
// v2.0.4 只认 "ColorfulCloudsPro." 前缀 → 四个 ObjC 宿主全部漏掉 → armed 0/4，拦截失效；
// 而 v2.0.2 能装上纯属侥幸（靠后来被我删掉的"全表兜底扫描"，那也正是闪退元凶）。
// 所以归属判定必须同时接受两种形态。
// 安全性：本函数只做字符串比较，**绝不调用 class_getInstanceMethod** —— 用它做前置过滤，
// 可保证后续的方法查询永不触达系统/第三方框架类（v2.0.3 崩溃的关键防线）。
static BOOL CYIsOwnAppClassName(const char *cn) {
    if (!cn || !cn[0]) return NO;
    if (strncmp(cn, "ColorfulCloudsPro.", 18) == 0) return YES;   // Swift 类（带模块前缀）
    if (cn[0] == 'C' && cn[1] == 'Y') return YES;                 // App 自研 ObjC 类（CY* 裸名）
    return NO;
}

// 统一到「裸名」口径再做等值比较，这样同一个类无论以哪种形态出现都能匹配
static const char *CYBareClassName(const char *cn) {
    if (cn && strncmp(cn, "ColorfulCloudsPro.", 18) == 0) return cn + 18;
    return cn;
}

static BOOL CYIsAdOverlayClassName(const char *cls) {
    if (!cls || !*cls) return NO;
    // v2.0.3 性能修复：本函数在**每个视图上屏时**都会走一次（全局 didMoveToWindow 热路径）。
    // 下面的硬编码黑名单与组合判断的目标类，全部位于 App 自己的命名空间
    // （Swift 模块名 ColorfulCloudsPro），所以先用一次 strncmp 把系统类/第三方类整体放行：
    // 省掉 12 次全名 strcmp，以及最多 10 次 CYStrCaseless —— 后者是 O(串长²) 的双层循环，
    // 是这里最贵的一项（每个 UIView/UILabel 上屏都要白做上千次字符比较）。
    // 万一以后出现命名空间外的广告浮层，兜底 A（居中卡片）与兜底 C（面积+文案）都不依赖
    // 类名，仍能拦住，且探针会写 [Overlay] leak? 留下类名。
    if (!CYIsOwnAppClassName(cls)) return NO;
    // ① 硬编码黑名单（来自静态 class-dump，改名后靠 [Overlay] 日志再补）。用 C 字符串比较，
    //    不走 NSString/NSArray，避免热路径上的对象分配。
    //    v2.0.5：比较改成「剥掉模块前缀后再比」—— 同一个类在 Swift/ObjC 两种形态下名字不同
    //    （"ColorfulCloudsPro.CYVipBottomView" vs "CYVipBottomView"），统一口径才不会漏。
    const char *bare = CYBareClassName(cls);
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
    for (int i = 0; hard[i]; i++) {
        if (strcmp(bare, CYBareClassName(hard[i])) == 0) return YES;
    }
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

// 居中卡片特征（不挑业务文案的通用兜底，v2.0.2 由"仅直接挂 window"放宽为"窗口级浮层"）：
//   ① 盖住屏幕中心；② 两侧留边（宽/高都不贴满屏，全屏页与遮罩在此被排除）；
//   ③ 面积落在合理区间 —— 上限 0.55 排除全屏/大半屏容器，下限 0.06 排除小控件。
// 老板实机观察：这个会员卡弹窗"居中显示、不大、最多四分之一屏"（约 0.25），
// 远在区间内。旧版要求 superview == window，弹窗只要挂在任意容器上就整条链穿透，
// 故 v2.0.2 改为与外层共享"不在 rootViewController.view 之下"这条更强且更准的护栏。
static BOOL CYLooksLikeCenteredCard(UIView *v, UIWindow *win, CGFloat ratio) {
    if (ratio < 0.06 || ratio > 0.55) return NO;
    CGFloat ww = win.bounds.size.width, wh = win.bounds.size.height;
    if (ww <= 0 || wh <= 0) return NO;
    CGRect f = v.frame;
    if (f.size.width <= 0 || f.size.height <= 0) return NO;
    if (f.size.width > ww * 0.95 || f.size.height > wh * 0.95) return NO;  // 贴边 = 页面或遮罩
    if (!CGRectContainsPoint(f, CGPointMake(ww / 2, wh / 2))) return NO;  // 不盖中心 = 不是弹窗
    return YES;
}

// 漏网定位（零噪音）。触发条件是"确实是窗口级浮层、但两级判定都没认出来"——
// 正常使用下几乎不写。原先的探针条件是"宽度 ≥ 30% 屏"，实测把首页几十个卡片视图
// 全刷进了日志（一次启动 40+ 行、累计 213 行），与"日志少写"的要求相悖，故收敛。
// 真弹窗无论拦没拦住都必有留痕：拦住了写 [AdPopup]，没拦住写 [Overlay] leak。
#define CY_PROBE_MAX 24
static void CYCoverlayProbe(const char *cls, UIView *v, CGFloat ratio) {
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    static int probeCount = 0;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    if (probeCount >= CY_PROBE_MAX) return;
    NSString *key = [NSString stringWithUTF8String:cls];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    probeCount++;
    CGRect f = v.frame;
    CYLog(@"[Overlay] leak? %s f=(%.0f,%.0f,%.0f,%.0f) r=%.2f",
          cls, f.origin.x, f.origin.y, f.size.width, f.size.height, ratio);
}

// 兜底 E（v2.0.5 新增）：页面层级内的「一次性文案探针」—— 只记录，绝不拦截。
// 背景：上面所有拦截层都有一道人为的安全护栏 —— "位于 rootViewController.view 层级之下的
// 视图一律跳过"。这条护栏是必需的（会员购买页本身就满屏"立即开通/年卡"，若照拦就会把
// 用户主动打开的页面打空白），但它留下一个盲区：万一营销弹窗是 addSubview 到当前页面
// 视图里、而不是盖在其上的窗口级浮层，就会**完全静默穿透** —— 连探针都不写一条。
// 这里补一条零误伤、零常态开销的观察通道：
//   · 零误伤 —— 只写日志，不碰任何视图状态；
//   · 零常态开销 —— ① 面积先预筛（只对"居中卡片"尺度的视图感兴趣）；② 同一类名只处理
//     一次；③ 全进程上限 CY_INPAGE_PROBE_MAX 条，写满即彻底静默。
// 于是常态下最多多出十几行一次性日志，之后再无开销；而"弹窗藏在页面层级"这种盲区
// 一旦发生，日志里一定会出现 `[Overlay] in-page?` + 类名 + 命中文案，可一轮精准收口。
#define CY_INPAGE_PROBE_MAX 12
static void CYCoverlayProbeInPage(const char *cls, UIView *v, CGFloat ratio) {
    if (!cls || !*cls || !v) return;
    // ① 面积预筛：只关心"居中卡片"尺度（6%~55% 屏）。调用方已保证 ratio >= 0.06。
    //    独占半屏以上的多半是页面容器/滚动视图，不是弹窗。
    if (ratio > 0.55) return;
    // ② 排除系统容器（UITransitionView / UILayoutContainerView…）—— 它们是页面骨架，
    //    且 App 里的 label/button/icon 全是 UI 前缀，这一条就滤掉了绝大多数视图。
    if (strncmp(cls, "UI", 2) == 0 || strncmp(cls, "_UI", 3) == 0) return;
    // ③ 排除 VC 的根视图 = 页面本身（会员页天然满屏"开通/会员"等词，否则必误报）
    if ([v.nextResponder isKindOfClass:[UIViewController class]]) return;

    // ④ 同类只处理一次。这里刻意用 C 字符串数组而不是 NSMutableSet —— 本函数位于
    //    didMoveToWindow 热路径上，一次首页加载会有几百个 App 自己的视图上屏，
    //    每个都做一次 NSString 分配 + 哈希查表是不必要的开销。
    //    直接存 class_getName 返回的指针即可：那是 runtime 持有的持久字符串，
    //    只要类还在就不会失效 —— 所以既不用 strdup、也不用管释放（真正零分配）。
    static const char *seen[CY_INPAGE_PROBE_MAX * 2];
    static int seenCount = 0, logged = 0;
    if (logged >= CY_INPAGE_PROBE_MAX) return;                 // ⑤ 全进程上限，写满即静默
    for (int i = 0; i < seenCount; i++) {
        if (strcmp(seen[i], cls) == 0) return;
    }
    if (seenCount < (int)(sizeof(seen) / sizeof(seen[0]))) seen[seenCount++] = cls;
    logged++;

    NSString *t = CYSubtreeMarketingText(v, 0);
    if (t) {
        CYLog(@"[Overlay] in-page? %s r=%.2f copy=%@", cls, ratio, t);
    }
}

// 兜底 D（布局延迟复核）。didMoveToWindow 触发时 autolayout 可能尚未布局，
// frame/bounds 都还是 0 —— 此时任何基于面积的判据都会漏判，弹窗正好在"上屏那一帧"
// 溜过 A/C 两层。这个可能性在 v2.0.1 的日志里无法证伪（那一轮没抓到弹窗），所以不赌。
// 处理方式：对"窗口级浮层候选"（不在 rootViewController.view 之下）排**一次**主队列
// 异步复核 —— 不做轮询、不装定时器；复核内部带尺寸/隐藏态短路，不会反复排队。
// 正常页面（在 rootVC 之下）在这里直接返回：零开销、一次都不排。
static void CYLateWindowCheck(UIView *v) {
    if (!v) return;
    UIWindow *w0 = v.window;
    if (!w0) return;
    UIView *rv0 = w0.rootViewController.view;
    if (rv0 && (v == rv0 || [v isDescendantOfView:rv0])) return;

    __weak UIView *weakV = v;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *sv = weakV;
        if (!sv || sv.hidden) return;
        UIWindow *w = sv.window;
        if (!w) return;
        CGFloat r = CYViewAreaRatio(sv, w);
        if (r < 0.06) return;
        UIView *rv = w.rootViewController.view;
        if (rv && (sv == rv || [sv isDescendantOfView:rv])) return;
        NSString *t = CYSubtreeMarketingText(sv, 0);
        if (t || CYLooksLikeCenteredCard(sv, w, r)) {
            CYLog(@"[AdPopup] killed late %s r=%.2f %@",
                  class_getName([sv class]), r, t ? t : @"");
            sv.hidden = YES;
            sv.userInteractionEnabled = NO;
        }
    });
}

%hook UIView

// 事件驱动：任何视图挂到 window 上时触发一次，不做定时轮询（避免额外 CPU/能耗）。
- (void)didMoveToWindow {
    %orig;
    UIWindow *win = self.window;
    if (!win) return;

    const char *cls = class_getName([self class]);

    // v2.0.3：系统容器视图（UI* / _UI*，如 UITransitionView / UILayoutContainerView）是页面
    // 骨架，先判先出。这一条命中率最高（首页绝大多数视图都是 UIView/UILabel/UIImageView 等
    // 系统类），放在最前面可以让后面那次类名黑名单比对整个跳过 —— 纯粹白捡的顺序优化。
    if ((strncmp(cls, "UI", 2) == 0) || (strncmp(cls, "_UI", 3) == 0)) return;

    // 兜底 B（便宜层）：类名带会员/付费/活动语义的浮层直接隐藏。纯 C 字符串黑名单，
    // 内部还有一次命名空间前缀预筛，零对象分配。
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
        return;
    }

    // 热路径短路：面积门槛先算，按钮/文字/图标等绝大多数控件在这里就被排除，
    // 下面"超级视图链 + 子树文案扫描"这两项相对昂贵的操作只在极少数够大的视图上执行。
    // 门槛取 0.06（约 1/16 屏）—— 老板实机观察这个会员卡弹窗"居中、不大、最多四分之一屏"
    // （约 0.25），旧版门槛是 0.50（半屏），根本够不着它，这是上一轮没拦住的直接原因。
    CGFloat ratio = CYViewAreaRatio(self, win);
    if (ratio < 0.06) {
        // 尺寸还没算出来（上屏那一帧 autolayout 尚未布局），也可能就是真的小控件。
        // v2.0.3 性能修复：这里绝不能对所有小视图排延迟复核 —— CYLateWindowCheck 第一步
        // 就是 isDescendantOfView: 沿 superview 链向上遍历，而一次首页加载会有上千个
        // 小控件（按钮/图标/分隔线/label）上屏，等于给每个控件都做一次链遍历。
        // 这正是"打开卡一下、反应变慢"的主要来源（上一版注释写"正常页面零开销"是错的）。
        // 收紧成 O(1) 判据：只有"父视图就是 window"这种明确的窗口级浮层才值得延迟复核；
        // 页面内的小视图（父视图是普通容器）在这里一次指针比较就出去了。
        if (self.superview == win) CYLateWindowCheck(self);
        return;
    }

    // 唯一的误伤护栏（比旧版"必须直接挂 window"更强也更准）：位于 rootViewController.view
    // 层级之下的就是正常页面内容（首页卡片、设置页、会员中心…），永不判定。营销弹窗是
    // "盖在页面之上"的窗口级浮层，天然不在其中 —— 正因为有这条，下面才敢把面积门槛
    // 压到 0.06 并使用不挑业务文案的通用形状判据。
    // 注：旧版要求 superview == window，弹窗只要挂在任意容器上就整条链静默穿透，
    // 这正是 8/30→9/28 整月零命中的根因。
    UIView *rootView = win.rootViewController.view;
    if (rootView != NULL && (self == rootView || [self isDescendantOfView:rootView])) {
        // 页面内容：跳过全部拦截判定（防误伤），但走一次"一次性文案探针"——
        // 只为了在"弹窗藏进页面层级"这一种盲区发生时留下证据（见 CYCoverlayProbeInPage）。
        // 该函数自带三层收敛（面积预筛 / 同类一次 / 全进程上限），常态开销可忽略。
        CYCoverlayProbeInPage(cls, self, ratio);
        return;
    }

    // 兜底 C（最强判据）：子树里出现强运营文案（年卡 / 终身 / 立即开通 / 先不看 / 去看看…）
    NSString *txt = CYSubtreeMarketingText(self, 0);
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
        return;
    }

    // 兜底 A：不依赖任何业务文案的通用形状判据（居中卡片）→ 一律收掉
    if (CYLooksLikeCenteredCard(self, win, ratio)) {
        CYLog(@"[AdPopup] hid centered card %s r=%.2f", cls, ratio);
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        return;
    }

    // 走到这里 = "确实是窗口级浮层、但两级判定都没认出来" → 留一条证，便于下次精准收口
    if (![self.nextResponder isKindOfClass:[UIViewController class]]) {
        CYCoverlayProbe(cls, self, ratio);
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
    // v2.0.5：原先只认 "ColorfulCloudsPro." 前缀 —— 对 ObjC 裸名类（CY* 无前缀）会整层失效。
    // 改用统一归属判定 + 裸名比较，两种形态都能拦。
    if (!CYIsOwnAppClassName(name)) return NO;
    const char *bare = CYBareClassName(name);
    static const char *black[] = {
        "CYVipBottomView", "CYMemberBottomView", "CYMemberAPayView",
        "CYMemberPayButtonView", "CYPayLaunchView", "CYPayLaunchOtherView",
        "CYLightupSVIPBottomToastView", "CYFlowerBottomView",
        "CYGuidePayView", "CYVipRightsView",
        "CYNotificationPopupActivityView", NULL
    };
    for (int i = 0; black[i]; i++) if (strstr(bare, black[i])) return YES;
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
// 命中日志按 selector 限流：一个进程内每档只记首条（实测 popupsArrWithDict: 单次启动
// 就会命中 5 次，逐条打印会把日志刷成流水账，与"日志少写"的要求相悖）。
#define CY_GATE_HIT_ONCE(ID)                    \
    static int logged_##ID = 0;                 \
    int doLog_##ID = (logged_##ID < 1);         \
    if (doLog_##ID) logged_##ID++;

#define CY_GATE_VOID_OBJARG(ID, SELNAME)                                            \
    static void (*orig_##ID)(id, SEL, id) = NULL;                                   \
    static void imp_##ID(id self, SEL _cmd, id arg) {                               \
        CY_GATE_HIT_ONCE(ID)                                                        \
        if (doLog_##ID) {                                                           \
            NSArray *a = [arg isKindOfClass:[NSArray class]] ? (NSArray *)arg : nil; \
            CYLog(@"[PopupGate] hit " SELNAME " on %s n=%lu",                       \
                  class_getName([self class]), (unsigned long)a.count);             \
        }                                                                           \
        if (orig_##ID) orig_##ID(self, _cmd, @[]);                                  \
    }

#define CY_GATE_VOID_NOARG(ID, SELNAME)                                             \
    static void (*orig_##ID)(id, SEL) = NULL;                                       \
    static void imp_##ID(id self, SEL _cmd) {                                       \
        (void)orig_##ID;                                                            \
        CY_GATE_HIT_ONCE(ID)                                                        \
        if (doLog_##ID) {                                                           \
            CYLog(@"[PopupGate] hit " SELNAME " (swallowed) on %s",                 \
                  class_getName([self class]));                                     \
        }                                                                           \
    }

#define CY_GATE_OBJRET_OBJARG(ID, SELNAME)                                          \
    static id (*orig_##ID)(id, SEL, id) = NULL;                                     \
    static id imp_##ID(id self, SEL _cmd, id arg) {                                 \
        (void)orig_##ID;                                                            \
        CY_GATE_HIT_ONCE(ID)                                                        \
        if (doLog_##ID) {                                                           \
            CYLog(@"[PopupGate] hit " SELNAME " (starved) on %s",                   \
                  class_getName([self class]));                                     \
        }                                                                           \
        return @[];                                                                 \
    }

CY_GATE_VOID_OBJARG(setHomePopupArray,   "setHomePopupArray:")
CY_GATE_VOID_OBJARG(handlePopupArray,    "handlePopupArray:")
CY_GATE_VOID_NOARG(handleNextPopup,      "handleNextPopup")
CY_GATE_OBJRET_OBJARG(popupsArrWithDict, "popupsArrWithDict:")

static NSMutableSet *gPopupGateArmed = nil;
// 自愈跳过状态：一旦判定"上一轮装弹崩了"，本进程内（含 1.2s 补装轮）不再尝试装弹。
// 否则补装轮会再撞一次同一个崩溃点，等于白崩。
static BOOL gPopupGateSkipped = NO;

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

// 总闸的行为说明：
// · setHomePopupArray: / handlePopupArray: → 一律传 @[]（而不是 nil）。该属性是 copy
//   语义，空数组是合法值，下游按 count 做的边界判断天然安全 —— 这个队列本来就要支持
//   "今天没有弹窗"的情况，所以清空不会让 App 进入异常状态（实测启动/首页/设置/会员页均正常）。
// · handleNextPopup（无参无返回）→ 吞掉不转发，队列不再往下推进。
// · popupsArrWithDict: → 返回 @[]，从**解析入口**就断供，这是效果最干净的一层：
//   实测它每次启动被调 5 次、每次都被 starving，下游 setHomePopupArray: 因此从未被调用过。
// 队列内容取证已合并进 CY_GATE_VOID_OBJARG 宏的 n= 字段。

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

// ⚠️⚠️ v2.0.4 关键安全修复：**只扫 App 自己的命名空间，永不扫全表**。
//
// 实机崩溃铁证（ColorfulCloudsPro-2026-09-28-230637.ips，bug_type 309 / EXC_BREAKPOINT /
// SIGTRAP，两次崩溃形态完全一致）：
//     class_getInstanceMethod          ← 我们在后台队列调它
//   → lookUpImpOrForward / initializeAndMaybeRelock / CALLING_SOME_+initialize_METHOD
//   → WebKitInitialize                 ← WebKit 的 +initialize 被触发
//   → +[WebView enableWebThread] → StartWebThread()
//   → WTFCrashWithInfo                 ← WebKit 断言"必须主线程"，非主线程直接 trap
//
// 两个教训叠加才导致这次闪退：
//   ① `class_getInstanceMethod` **会给目标类做 realize（跑它的 +initialize）**，不是只读查表；
//   ② 上一版的「第二轮全量兜底扫描」把**全表所有类**都喂进了它 —— 系统前缀黑名单里写了 "WK"
//      却没有 "WebView"/"WebCore"，于是 WebKit 的类被扫到，它的 +initialize 在后台线程炸。
// 结论：任何形式的"全表扫描 + method lookup"都是不可接受的 —— 它会替 App 提前初始化任意框架。
// 宿主必然是 App 自己的类，所以把范围锁死在 App 命名空间内既安全又够用。
// 万一命名空间前缀将来不匹配，日志会明确写 NOHOST（失败必留痕），不会静默白等。
// （上面的教训直接决定了下方 CYGateHosts 的扫描范围：只扫 App 自己的命名空间。）

// 类表缓存（v2.0.3 性能修复）。objc_copyClassList 每次调用都要进 objc 运行时取锁，
// 并**把整张类表 malloc 拷贝一份**（本机 3000+ 类，几十 KB + 全表遍历）。
// 之前 4 个 selector 各调一次 = 白扫四遍全表；装弹又跑两轮（%ctor 一次 + 1.2s 补装一次）
// → 最坏 8 次全表拷贝，全部发生在 App 启动的关键路径上。这是"打开变慢"的第一元凶。
// 现在只拷一份全局复用；只有延时补装那一轮强制刷新（Swift 类可能注册得比本 dylib 晚）。
static Class *gClassList = NULL;
static unsigned int gClassCount = 0;

static void CYRefreshClassList(BOOL force) {
    if (gClassList && !force) return;
    if (gClassList) {
        free(gClassList);
        gClassList = NULL;
        gClassCount = 0;
    }
    gClassList = objc_copyClassList(&gClassCount);
}

static unsigned int CYGateHosts(SEL sel, CYGateHost *out, unsigned int maxOut) {
    if (!gClassList) return 0;
    const unsigned int count = gClassCount;
    unsigned int found = 0;

    // 唯一的一轮：只扫 App 自己的类名（绝不扫全表的理由见上方注释）。
    // v2.0.5 关键修正：过滤条件从「只认 ColorfulCloudsPro. 前缀」改成统一归属判定，
    // 因为本 App 的 ObjC 类运行时是**裸名**（无前缀）—— 旧条件会让四个宿主全部漏掉。
    // 本行仍是纯字符串比较，不触达任何方法查询，所以安全性不变。
    for (unsigned int i = 0; i < count && found < maxOut; i++) {
        Class c = gClassList[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        if (!CYIsOwnAppClassName(cn)) continue;

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

    return found;
}

// ---- 已知宿主「快路径」（v2.0.4 引入，v2.0.5 修正）----
// 类名是 v2.0.2 实机日志里**直接打印出来的**（不是猜的）：
//   CYMainActivityManager ← setHomePopupArray: / handlePopupArray: / handleNextPopup（实例方法）
//   CYUtility             ← popupsArrWithDict:（**类方法**，日志里的 "+" 号）
// v2.0.4 写成带模块前缀的 "ColorfulCloudsPro.CYMainActivityManager" 是错的 —— 这两个是
// ObjC 类，运行时是**裸名**，objc_getClass 拿不到 → 快路径全落空 → armed 0/4。
// 现在两种形态都列上，谁在就取谁。
// 用 objc_getClass 直取是 O(1) 的：不拷类表、不做全表遍历、不碰无关类（也就不会触发
// 无关类的 realize）。正常路径下**完全不需要 objc_copyClassList**，这是最快也最安全的做法。
// 类名哪天变了（App 升级 / 改包）→ 返回 0 → 自动回落到归属过滤扫描兜底，所以不会失效。
static const char *kCYGateKnownHosts[] = {
    "CYMainActivityManager",                    // 实机日志确认的形态（ObjC 裸名）
    "ColorfulCloudsPro.CYMainActivityManager",  // 兼容 Swift 命名空间形态
    "CYUtility",
    "ColorfulCloudsPro.CYUtility",
    NULL
};

static unsigned int CYGateHostsFast(SEL sel, CYGateHost *out, unsigned int maxOut) {
    unsigned int found = 0;
    for (int i = 0; kCYGateKnownHosts[i] && found < maxOut; i++) {
        Class c = objc_getClass(kCYGateKnownHosts[i]);
        if (!c) continue;
        // 去重：同一个类会被"裸名 + 带前缀名"两种写法各命中一次。若不去重就会对同一
        // selector swizzle 两遍 —— 第二次会把第一次的 hook 当成 original 再包一层，
        // 调用链翻倍且原实现从此不可达。
        BOOL dup = NO;
        for (unsigned int k = 0; k < found; k++) {
            if (out[k].owner == c) { dup = YES; break; }
        }
        if (dup) continue;

        // 与慢路径同一套判据：只认"真正实现该 selector"的类，跳过仅从父类继承的
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
        // 类方法（v2.0.5 补）：popupsArrWithDict: 是 +CYUtility 类方法，原本快路径只查
        // 实例方法 → 必然落空 → 白白退回全类表扫描（把风险路径当常规路径，正是隐患所在）。
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

// ---- 装弹自愈（v2.0.4）----
// 万一"装弹过程本身"导致崩溃，App 不能永远打不开。装弹前落一个标记文件、成功后删除；
// 下次启动若发现标记还在 → 说明上一轮装弹崩了 → 本轮跳过装弹（并留日志）。
// 代价只有一轮：下一次启动会重新尝试装弹。这条与"探针必留痕"同一原则 ——
// 出问题要让 App 能活、且留下可查的证据，而不是崩到用户没法用。
static NSString *CYGateCrumbPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *doc = docs.firstObject ?: NSTemporaryDirectory();
        p = [doc stringByAppendingPathComponent:@"caiyun_gate_pending"];
    });
    return p;
}

// 返回 YES = 本轮四个总闸全部装上（调用方据此决定是否还需要排"补装轮"）
static BOOL CYInstallPopupGate(BOOL refreshClasses, BOOL allowScan, BOOL verbose) {
    double t0 = [NSDate timeIntervalSinceReferenceDate];
    // 扩展进程（.appex：widget / 通知扩展…）里没有首页弹窗，跳过 —— 省掉一次类表扫描，
    // 也避免同一份日志被两个进程各写一遍（实测日志里出现过两批相隔 10s 的装弹记录）。
    // 结果缓存进 static：hasSuffix: 不必每次唤醒都做一遍字符串比较。
    static int isExtension = -1;
    if (isExtension < 0) {
        isExtension = [[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"] ? 1 : 0;
    }
    if (isExtension) return YES;

    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPopupGateArmed = [NSMutableSet set]; });

    // 自愈优先：本进程已决定跳过装弹（上一轮崩过）→ 直接返回，
    // 补装轮也不会再尝试，避免在同一处崩第二次。
    if (gPopupGateSkipped) return YES;

    // 崩溃分界：只在首轮写（补装轮不再重复写）。有 begin 无 armed = 崩在本次装弹内部；
    // 连 begin 都没有 = 崩在更早（%ctor 或 App 自己的启动流程）。
    if (verbose) {
        CYLog(@"[Gate] begin (thread=%@)", [NSThread isMainThread] ? @"main" : @"bg");
    }

    // 自愈：先看上一轮的标记是否残留
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *crumb = CYGateCrumbPath();
    if ([fm fileExistsAtPath:crumb]) {
        [fm removeItemAtPath:crumb error:nil];
        gPopupGateSkipped = YES;
        CYLog(@"[Gate] skipped -- last install attempt crashed; retry on next launch");
        return YES;
    }
    [fm createFileAtPath:crumb
                contents:[@"pending" dataUsingEncoding:NSUTF8StringEncoding]
              attributes:nil];

    NSMutableArray *summary = [NSMutableArray array];
    int total = 0, armedTotal = 0;
    int missedFastPath = 0;          // 快路径落空的 selector 数（正常应恒为 0）
    BOOL usedScan = NO;              // 本轮是否真做过类表扫描兜底

    for (const CYGateTarget *t = kCYGateTargets; t->sel; t++) {
        total++;
        NSString *key = [NSString stringWithUTF8String:t->sel];
        if ([gPopupGateArmed containsObject:key]) { armedTotal++; continue; }

        SEL sel = NSSelectorFromString(key);
        CYGateHost hosts[8];
        // 先走已知宿主快路径（objc_getClass 直取，O(1)、零类表拷贝、不碰无关类）。
        // 只有它落空（App 升级改了类名 / 冷启时类尚未注册）才做归属过滤扫描兜底。
        unsigned int n = CYGateHostsFast(sel, hosts, 8);
        if (n == 0) {
            missedFastPath++;
            // 「扫描 + 方法查询」是整个装弹里唯一有风险的步骤（class_getInstanceMethod 会触达
            // 标的类的 +initialize）。所以分两档：
            //   首轮（allowScan=NO，启动早期）：一律不扫，累积计数，由调用方决定是否排补装轮；
            //   补装轮（allowScan=YES，1.2s 后 App 已起来）：才允许在归属过滤内扫描兜底。
            if (!allowScan) continue;
            CYRefreshClassList(refreshClasses);
            usedScan = YES;
            n = CYGateHosts(sel, hosts, 8);
        }
        if (n == 0) {
            CYLog(@"[PopupGate] NOHOST %@ -- no own-app class implements it", key);
            continue;
        }

        BOOL armedAny = NO;
        const char *lastEnc = NULL;
        for (unsigned int i = 0; i < n; i++) {
            Class target = hosts[i].hookTarget;
            const char *enc = CYHostTypeEncoding(target, sel);
            char norm[64];
            CYNormalizeTypeEncoding(enc, norm, sizeof(norm));
            lastEnc = enc;
            // 签名不符：静默跳过（正常现象，同级同名方法很多），只有"全败"才上报
            if (strcmp(norm, t->enc) != 0) continue;
            MSHookMessageEx(target, sel, t->imp, t->origSlot);
            armedAny = YES;
            [summary addObject:[NSString stringWithFormat:@"%@=%s%s", key,
                                hosts[i].isClassMethod ? "+" : "-",
                                class_getName(hosts[i].owner)]];
        }
        if (armedAny) {
            armedTotal++;
            [gPopupGateArmed addObject:key];
        } else {
            // 失败必须留痕：上一版就是"失败什么都不打"导致白等一整轮
            CYLog(@"[PopupGate] UNARMED %@ want=%s got=%s hosts=%u",
                  key, t->enc, lastEnc ? lastEnc : "?", n);
        }
    }

    // 成功路径压缩成一行（老板要求"日志少写"），异常才逐条展开。
    // 额外带两个字段：装弹耗时（量化"有没有拖启动"/"有没有拖主线程"）+ 走的是
    // fastpath（已知宿主直取）还是 scan（归属过滤兜底），都不增加日志行数。
    double cost = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;
    BOOL complete = (armedTotal >= total);
    if (summary.count > 0) {
        CYLog(@"[PopupGate] armed %d/%d %.1fms %@ %@", armedTotal, total, cost,
              usedScan ? @"scan" : @"fastpath",
              [summary componentsJoinedByString:@" "]);
    } else if (verbose && !complete) {
        // 首轮一行都不打会让人误判成"没装上"（v2.0.0 静默失败白等一整轮的教训）。
        // 已装齐时不再重复写，日志保持干净。
        CYLog(@"[PopupGate] armed %d/%d %.1fms %@ (fastpath miss=%d)",
              armedTotal, total, cost, usedScan ? @"scan" : @"fastpath", missedFastPath);
    }

    // 整段跑完 → 清掉崩溃标记（下次启动可正常装弹）
    [fm removeItemAtPath:crumb error:nil];
    return complete;
}

#pragma mark - 后台解码闸（YYKit 的 WebP 动画帧解码）
//
// 【现象】退到后台后本进程 CPU 冲到 94~99%，持续约 70 秒（spindump 实测 10s 窗口内
//   CPU Time 9.905s）。老板**关掉全部插件**后现象不变 —— 与本插件及任何插件无关，
//   是彩云天气自己的行为。
//
// 【归因】spindump 逐线程归因：单轮 9.402s 里 9.120s（97%）压在同一行
//     -[_YYAnimatedImageViewFetchOperation main]        ← App 内嵌 YYKit 的私有类
//       → YYImageDecoder frameAtIndex: / _newBlendedImageWithFrame:
//         → _WebPDecode → _DecodeInto → _VP8Decode → _FinishRow → _EmitFancyRGB
//           → _UpsampleBgraLinePair / _ApplyAlphaMultiply / _DispatchAlpha
//   即**持续把 WebP 动画图的每一帧解成位图**（帧内多线程并行，所以单核打满）。
//   运行时类名（__objc_classname 段明文）确认为 `_YYAnimatedImageViewFetchOperation`。
//
// 【它凭什么能在后台一直跑】Info.plist 的 UIBackgroundModes 带了 `audio`
//   （主二进制里有 AVAudioPlayer×12 / AVAudioSessionCategoryPlayback / AVAudioEngine），
//   靠 audio 会话拿后台存活权。本版已把**整个 UIBackgroundModes**（audio +
//   remote-notification）从 Info.plist 摘掉 —— 它连"被静默推送唤醒"的通道也没有了。
//   下面这层是**双保险**：即便它还能活着，也别再解码。
//
//   ⚠️ 去掉 remote-notification **不影响通知推送的显示**（横幅/声音/角标由 APNs 直接
//   投递给系统，不经过 App），只影响"后台被静默唤醒执行代码"。小组件
//   （ProWidgetExtensionExtension.appex）是独立进程、自带 NSURLSession 直连
//   wrapper.cyapi.cn，本就不依赖主 App 后台存活，刷新不受影响。
//
// 【为什么纯浪费】后台时 App 的 layer 根本不渲染，解出来的帧没有任何人看，
//   循环还在替下一帧继续解码（预取链自续）。
//
// 【策略】**只在「App 不在前台」时禁解码，前台动效零影响**（不改变任何 UI 行为）：
//   L1 硬闸 —— hook -[_YYAnimatedImageViewFetchOperation main]，非前台直接返回。
//              连预取链一起断：下一环是在 main 内/完成时新建 op，返回后不再产生新 op。
//   L2 冻结 —— 进后台把已注册实例的 autoPlayAnimatedImage 置 NO，回前台恢复原值
//              （只恢复"被我们改过"的，用 associated object 记账）+ setNeedsDisplay
//              重新点火，防止 L1 断链后回前台动画僵住。
//   L3 注册 —— hook -[YYAnimatedImageView didMoveToWindow] 收实例（弱表，零强引用，
//              视图销毁自动出表）。
//
// 【线程安全】gCYForeground 是由通知维护、在主线程写的原子量；硬闸跑在
//   NSOperationQueue 的工作线程上，只做一次原子读 —— 不在工作线程上碰
//   UIApplication.applicationState（跨线程读 UI 状态不安全，也不值得）。
//   初值 = 前台：进程启动阶段必然可见，随后通知会逐次修正。
//
// 【Android 式"保活"的代价】这段解码是纯粹的耗电：实测两段尖峰合计约 70 秒满载。
//   前台时 gCYForeground=1，一切照旧，天气动效完全不受影响。

// YYKit 的私有类/类只做声明，不用 %hook —— 走手工 MSHookMessageEx，理由同 CYVipSafe：
// ABI 明确（均为 @objc 方法），且能拿到"装没装上"的真实返回值，便于日志判定与重试。
@interface _YYAnimatedImageViewFetchOperation : NSOperation
@end

@interface YYAnimatedImageView : UIImageView
@property (nonatomic) BOOL autoPlayAnimatedImage;   // 实测存在的公开属性，默认 YES
@end

static NSHashTable *gCYAnimatedViews = nil;      // 弱表：只登记，不持有
static volatile int32_t gCYForeground = 1;       // 1 = 前台（允许解码），0 = 后台（拦）
static unsigned long long gCYFetchSkipped = 0;   // 后台被拦下的解码操作数（原子累加）
static unsigned long long gCYFrozenViews = 0;    // 被我们冻结过的实例数（累计）
static void (*origFetchOpMain)(id, SEL) = NULL;
static void (*origYYViewDidMoveToWindow)(id, SEL) = NULL;
static const void *kCYFrozenKey = &kCYFrozenKey;

// L1：硬闸。后台时连 %orig 都不调 —— 不解码、不建后续 op（op 会立刻被判定完成）。
static void CYFetchOpMain(id self, SEL _cmd) {
    if (gCYForeground == 0) {
        __atomic_fetch_add(&gCYFetchSkipped, 1, __ATOMIC_RELAXED);
        return;
    }
    if (origFetchOpMain) origFetchOpMain(self, _cmd);
}

// L2 冻结：只动"本来在自动播"的实例，并用 associated object 记账，
// 保证回前台只恢复被我们改过的，不去覆盖 App 自己的选择。
// 返回 YES 表示"这次真的冻了" —— 日志计数靠返回值，不靠事后猜状态
// （否则 autoPlay 本来就是 NO 的静态图会被误计成"我们冻的"，日志就撒谎了）。
static BOOL CYFreezeAnimatedView(id v) {
    if (!v) return NO;
    YYAnimatedImageView *iv = (YYAnimatedImageView *)v;
    if (![iv respondsToSelector:@selector(autoPlayAnimatedImage)]) return NO;
    if (![iv respondsToSelector:@selector(setAutoPlayAnimatedImage:)]) return NO;
    if (!iv.autoPlayAnimatedImage) return NO;                 // 本来就不自动播 → 不碰
    objc_setAssociatedObject(iv, kCYFrozenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    iv.autoPlayAnimatedImage = NO;
    __atomic_fetch_add(&gCYFrozenViews, 1, __ATOMIC_RELAXED);
    return YES;
}

static BOOL CYRestoreAnimatedView(id v) {
    if (!v) return NO;
    YYAnimatedImageView *iv = (YYAnimatedImageView *)v;
    if (!objc_getAssociatedObject(iv, kCYFrozenKey)) return NO; // 不是我们冻的 → 不管
    objc_setAssociatedObject(iv, kCYFrozenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    iv.autoPlayAnimatedImage = YES;
    [iv setNeedsDisplay];     // 重新点火：L1 断过链，需要一个触发点把动效接回来
    return YES;
}

// L3：登记实例。didMoveToWindow 是所有视图上屏/离屏的必经点，插弱表几乎零成本。
static void CYAnimatedViewDidMoveToWindow(id self, SEL _cmd) {
    if (gCYAnimatedViews) [gCYAnimatedViews addObject:self];
    if (gCYForeground == 0) CYFreezeAnimatedView(self);   // 后台新建的视图：出生就冻住
    if (origYYViewDidMoveToWindow) origYYViewDidMoveToWindow(self, _cmd);
}

static void CYDecodeGateEnterBackground(void) {
    gCYForeground = 0;                       // 先关闸，再冻结（顺序不能反）
    unsigned int frozen = 0;
    for (id v in gCYAnimatedViews.allObjects) {
        if (CYFreezeAnimatedView(v)) frozen++;   // 计"真冻了的"，不靠事后猜状态
    }
    // "少写"：没有动画实例就不写，有才写（这一行同时是"通知链路活着"的证据）。
    if (frozen > 0) CYLog(@"[DecodeGate] bg → frozen %u views", frozen);
}

static void CYDecodeGateEnterForeground(void) {
    // 先开闸再恢复：否则 restore 的 setNeedsDisplay 触发的解码会被自己拦掉。
    gCYForeground = 1;
    unsigned int restored = 0;
    for (id v in gCYAnimatedViews.allObjects) {
        if (CYRestoreAnimatedView(v)) restored++;
    }
    unsigned long long skipped = __atomic_exchange_n(&gCYFetchSkipped, 0, __ATOMIC_RELAXED);
    // 只在真的拦到过东西时写一行 —— 后台空转（没有动画图）时保持零日志。
    if (skipped > 0 || restored > 0) {
        CYLog(@"[DecodeGate] fg → gate open, restored %u views, blocked %llu bg decodes",
              restored, skipped);
    }
}

// 只在"类自己实现了"该方法时才 hook。
// 必须的守卫：substrate 的 MSHookMessageEx 走的是 class_getInstanceMethod +
// method_setImplementation —— 若 sel 是**继承**来的，被改掉的会是父类的实现。
// 例如 YYAnimatedImageView 若没重写 didMoveToWindow，这一钩就会落到 UIView 上，
// 等于给全 App 每个视图都挂上我们的钩子（灾难级副作用）。
// 用"自己的 IMP != 父类的 IMP"判定，零歧义。
static BOOL CYClassOverridesSelector(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method own = class_getInstanceMethod(cls, sel);
    if (!own) return NO;
    Class sup = class_getSuperclass(cls);
    if (!sup) return YES;
    Method parent = class_getInstanceMethod(sup, sel);
    if (!parent) return YES;                        // 父类没有 → 必定是自己的
    return method_getImplementation(own) != method_getImplementation(parent);
}

static void CYInstallDecodeGate(void) {
    // 两个 hook 用 MSHookMessageEx 直接挂，失败可重试（App 升级换类名时日志会说话）。
    static BOOL fetchHooked = NO, viewHooked = NO;
    if (!fetchHooked) {
        Class opCls = objc_getClass("_YYAnimatedImageViewFetchOperation");
        if (opCls && CYClassOverridesSelector(opCls, @selector(main))) {
            MSHookMessageEx(opCls, @selector(main),
                            (IMP)CYFetchOpMain, (IMP *)&origFetchOpMain);
            fetchHooked = YES;
        }
    }
    if (!viewHooked) {
        Class viewCls = objc_getClass("YYAnimatedImageView");
        if (viewCls && CYClassOverridesSelector(viewCls, @selector(didMoveToWindow))) {
            MSHookMessageEx(viewCls, @selector(didMoveToWindow),
                            (IMP)CYAnimatedViewDidMoveToWindow,
                            (IMP *)&origYYViewDidMoveToWindow);
            viewHooked = YES;
        }
    }
    if (!gCYAnimatedViews) gCYAnimatedViews = [NSHashTable weakObjectsHashTable];

    // 通知订阅只做一次。三条都要：willEnterForeground 备帧、didBecomeActive 兜底，
    // 而 willResignActive（下拉通知中心/来电）**故意不订阅** —— 那时 App 仍可见，不该关闸。
    static BOOL observersInstalled = NO;
    if (!observersInstalled) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue *main = [NSOperationQueue mainQueue];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:main
                    usingBlock:^(NSNotification *note) { CYDecodeGateEnterBackground(); }];
        [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:main
                    usingBlock:^(NSNotification *note) { CYDecodeGateEnterForeground(); }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:main
                    usingBlock:^(NSNotification *note) {
                        if (gCYForeground == 0) CYDecodeGateEnterForeground();
                    }];
        observersInstalled = YES;
    }

    // 一行结果，含两侧装弹状态（0/1）。装齐只打一次（补装轮会再调一次本函数，必须幂等）；
    // 没装齐则每次都写 —— 那说明 App 换类名了，这种"失败日志"值得刷屏提醒。
    static BOOL loggedArmed = NO;
    if (!loggedArmed) {
        if (fetchHooked && viewHooked) {
            CYLog(@"[DecodeGate] armed (fetchOp.main=1 viewDidMoveToWindow=1)");
            loggedArmed = YES;
        } else {
            CYLog(@"[DecodeGate] PARTIAL (fetchOp.main=%d viewDidMoveToWindow=%d) will retry",
                  fetchHooked ? 1 : 0, viewHooked ? 1 : 0);
        }
    }
}

%ctor {
    double t0 = [NSDate timeIntervalSinceReferenceDate];
    CYInstallDidAddSubviewGuard();   // 零闪烁主拦截：任意父视图一加会员/付费子视图就移除
    CYInstallVipSafe();              // 兜底：CYVipBottomView 出生即隐藏（@objc init 中和）
    // 上面两层都是 O(1) 的 MSHookMessageEx（无任何扫描），留在这里没问题。
    double ctorCost = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;

    CYLog(@"[CaiYunRemoveAds] loaded (ctor %.2fms) for %@",
          ctorCost, [[NSBundle mainBundle] bundleIdentifier]);

    // 总闸装弹：v2.0.4 修正 —— **必须回主线程**。
    // v2.0.3 为了不拖启动把它丢进了后台队列，结果启动即闪退（实机三次启动只有 loaded、
    // 一行 armed 都没有）。根因是启动早期在非主线程做 runtime 操作：class_getInstanceMethod
    // 会触发类的 realize（跑 +initialize），swizzle 还要与正在启动的主线程抢 runtime 锁 ——
    // 这是经典崩法，不能赌。
    // 现在改成「主队列异步」：依然不在 %ctor 帧（dyld 加载帧）内执行，所以不占启动关键路径；
    // 但落在启动后第一个 runloop 周期的主线程上，与 v2.0.2 已验证安全的环境一致。
    // 再配合新增的已知宿主快路径，正常路径下连 objc_copyClassList 都不会被调用。
    // 首轮：只走已知宿主快路径（零类表拷贝、零无关类触达）。
    // v2.0.5：补装轮改成「按需」—— 只有首轮真出现落空（App 升级改了类名 / 类尚未注册）才排。
    // 正常路径（快路径 4/4 命中）完全不需要第二次装弹，省掉一个定时器和一轮循环，
    // 日志也少写两行。
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL complete = CYInstallPopupGate(NO, NO, YES);
        // v2.2.0 后台解码闸：装 D-YYKit 这一层。放在这里而不是 %ctor 帧里，理由同上
        // （不在 dyld 加载帧做 runtime 操作）。App 内嵌 YYKit 且启动时已加载，
        // 首轮必然拿得到类；万一落空，下面补装轮还会再调一次（函数幂等）。
        CYInstallDecodeGate();
        if (!complete) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // refreshClasses=NO：复用类表缓存（首轮不扫描，所以这里其实是首次拷贝，
                // 已经包含 1.2s 后才注册的类）。原先是 YES，会 free + 重拷全表 ——
                // 若四个 selector 都落空，就要白拷 4 次全表（每次都要 runtime 锁 + malloc）。
                CYInstallPopupGate(NO, YES, NO);
                CYInstallDecodeGate();   // 幂等；只为"首轮 YYKit 尚未注册"这种情况兜一次
            });
        }
    });
}
