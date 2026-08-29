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
    NSLog(@"[CaiYunRemoveAds] %@", msg);
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
            CYLog(@"[Chat] hid chatButton via %@ (btn=%@ bg=%@)", when,
                  chatBtn ? NSStringFromClass([chatBtn class]) : @"nil",
                  chatBg ? NSStringFromClass([chatBg class]) : @"nil");
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
    CYLog(@"[Chat] setIsShowChat:%d -> force NO", show);
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
static BOOL CYIsAdOverlayClassName(NSString *cls) {
    if (!cls.length) return NO;
    // ① 硬编码黑名单（来自静态 class-dump，改名后靠 [Overlay] 日志再补）
    static NSSet *hard = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hard = [NSSet setWithObjects:
            @"ColorfulCloudsPro.CYPayLaunchView",
            @"ColorfulCloudsPro.CYPayLaunchOtherView",
            @"ColorfulCloudsPro.CYMemberBottomView",
            @"ColorfulCloudsPro.CYVipBottomView",
            @"ColorfulCloudsPro.CYMemberToastView",
            @"ColorfulCloudsPro.CYGetSvipToastView",
            @"ColorfulCloudsPro.CYLightupSVIPBottomToastView",
            @"ColorfulCloudsPro.CYOneSVIPBottomToastView",
            @"ColorfulCloudsPro.CYChatPayToastView",
            @"ColorfulCloudsPro.CYMemberBackToastView",
            @"ColorfulCloudsPro.CYMemberPayButtonView",
            nil];
    });
    if ([hard containsObject:cls]) return YES;
    // ② 组合判断兜底
    NSString *lo = cls.lowercaseString;
    if ([cls hasSuffix:@"PayLaunchView"]) return YES;
    if ([cls hasSuffix:@"PayLaunchOtherView"]) return YES;
    BOOL memberish = [lo containsString:@"svip"] || [lo containsString:@"vip"] ||
                     [lo containsString:@"member"] || [lo containsString:@"pay"];
    BOOL overlay = [lo containsString:@"toast"] || [lo containsString:@"popup"] ||
                   [lo containsString:@"launch"] || [lo containsString:@"banner"] ||
                   [lo containsString:@"activity"] || [lo containsString:@"advert"];
    return memberish && overlay;
}

// 通用弹窗形态判定：直接挂 window 上的自定义浮层，若盖住屏幕中心、尺寸适中
// （面积约 4%~92% 屏幕），就是一个"卡片式弹窗"——不管它是什么业务，一律拦。
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

    NSString *cls = NSStringFromClass([self class]);
    BOOL onWindow = (self.superview == win);
    // 兜底 A：直接挂 window 的"居中卡片"浮层一律当弹窗干掉（不挑业务，全拦）
    if (onWindow && CYLooksLikePopupOverlay(self, win)) {
        CYLog(@"[Overlay] popup-like %@ -> hidden", cls);
        self.hidden = YES;
    }
    // 兜底 B：类名带会员/付费语义的浮层，直接隐藏
    if (CYIsAdOverlayClassName(cls)) {
        CYLog(@"[AdOverlay] hid %@", cls);
        self.hidden = YES;
        // 广告容器本身也一起摘掉，避免留下透明遮罩挡住点击
        if (self.superview && self.superview != win) {
            UIView *container = self.superview;
            if (container.subviews.count <= 2 &&
                container.frame.size.width >= win.bounds.size.width * 0.8) {
                container.hidden = YES;
                CYLog(@"[AdOverlay] hid container %@", NSStringFromClass([container class]));
            }
        }
    }
    // 漏网定位（零噪音）：非系统类、直接挂 window、宽度 ≥ 30% 屏幕的可疑浮层，
    // 同类只记一次。平时几乎不写；真弹窗出现时（无论拦没拦住）都会留下类名和尺寸，
    // 方便从日志反推是哪一层没兜住。
    if (onWindow && ![cls hasPrefix:@"UI"] && ![cls hasPrefix:@"_UI"]) {
        CGRect f = self.frame;
        if (f.size.width >= win.bounds.size.width * 0.30) {
            static NSMutableSet *seen = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
            if (![seen containsObject:cls]) {
                [seen addObject:cls];
                CYLog(@"[Overlay] %@ f=(%.0f,%.0f,%.0f,%.0f)",
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

%ctor {
    CYLog(@"[CaiYunRemoveAds] loaded for %@", [[NSBundle mainBundle] bundleIdentifier]);
}
