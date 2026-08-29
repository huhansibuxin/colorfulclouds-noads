//
// 彩云天气 Pro 去广告 + 去小助手 Tweak
// Bundle: net.colorfulclouds.app.pro
// 目标：保留天气/降水图/我的，移除底部「小助手」tab；拦截所有会员推广弹窗广告
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

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

static void CYLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:CYLogFileURL().path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:CYLogFileURL().path contents:data attributes:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    }
    NSLog(@"[CaiYunRemoveAds] %@", msg);
}

#pragma mark - 文本关键词判断（用于识别广告/会员弹窗）

static NSSet<NSString *> *CYAdKeywords(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithObjects:
            @"会员", @"VIP", @"SVIP", @"vip", @"svip",
            @"限时特惠", @"限时优惠", @"限时",
            @"立即查看", @"开通会员", @"购买会员",
            @"会员购买成功", @"您的会员已经离开",
            @"会员优惠券", @"恢复订阅",
            @"彩云天气会员", @"彩云天气SVIP",
            nil];
    });
    return set;
}

static BOOL CYStringContainsAdKeyword(NSString *text) {
    if (!text.length) return NO;
    NSString *low = text.lowercaseString;
    for (NSString *kw in CYAdKeywords()) {
        if ([low containsString:kw.lowercaseString]) {
            return YES;
        }
    }
    return NO;
}

static BOOL CYViewControllerIsAssistantTab(id vc) {
    if (!vc) return NO;
    // 优先通过 tabBarItem.title 判断
    NSString *title = nil;
    if ([vc respondsToSelector:@selector(tabBarItem)]) {
        UITabBarItem *item = [vc tabBarItem];
        title = item.title;
    }
    if (!title.length && [vc respondsToSelector:@selector(title)]) {
        title = [vc title];
    }
    if (title.length) {
        if ([title containsString:@"小助手"] || [title containsString:@"助手"]) {
            CYLog(@"[Tab] filter by title: %@", title);
            return YES;
        }
    }
    // 通过类名判断
    NSString *cls = NSStringFromClass([vc class]);
    if ([cls containsString:@"Assistant"] || [cls containsString:@"assistant"]) {
        CYLog(@"[Tab] filter by class: %@", cls);
        return YES;
    }
    // 通过是否响应 assistantAction 判断（小助手功能入口常见命名）
    if ([vc respondsToSelector:NSSelectorFromString(@"assistantAction")]) {
        CYLog(@"[Tab] filter by assistantAction selector: %@", cls);
        return YES;
    }
    return NO;
}

static NSString *CYExtractTitleFromObject(id obj) {
    if (!obj) return nil;
    NSArray *getters = @[@"title", @"alertTitle", @"message", @"alertString", @"desc", @"text"];
    for (NSString *getter in getters) {
        SEL sel = NSSelectorFromString(getter);
        if ([obj respondsToSelector:sel]) {
            id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if ([val isKindOfClass:[NSString class]] && [val length]) {
                return val;
            }
        }
    }
    return nil;
}

static BOOL CYObjectIsAdPopup(id obj) {
    if (!obj) return NO;
    NSString *combined = @"";
    NSString *t = CYExtractTitleFromObject(obj);
    if (t.length) combined = [combined stringByAppendingString:t];
    if ([obj isKindOfClass:NSClassFromString(@"UIAlertController")]) {
        NSString *title = [(UIAlertController *)obj title] ?: @"";
        NSString *msg = [(UIAlertController *)obj message] ?: @"";
        combined = [combined stringByAppendingFormat:@" %@ %@", title, msg];
    }
    if (CYStringContainsAdKeyword(combined)) {
        CYLog(@"[AdPopup] block %@ text=%@", NSStringFromClass([obj class]), combined);
        return YES;
    }
    return NO;
}

#pragma mark - UITabBarController：过滤小助手 tab

%hook UITabBarController

- (void)setViewControllers:(NSArray *)viewControllers animated:(BOOL)animated {
    NSMutableArray *filtered = [NSMutableArray array];
    for (id vc in viewControllers) {
        if (CYViewControllerIsAssistantTab(vc)) {
            continue;
        }
        [filtered addObject:vc];
    }
    if (filtered.count != viewControllers.count) {
        CYLog(@"[UITabBarController] removed %lu assistant tab(s)", (unsigned long)(viewControllers.count - filtered.count));
    }
    %orig(filtered.copy, animated);
}

%end

#pragma mark - CYTabBarController：兜底过滤

%hook CYTabBarController

- (void)setViewControllers:(NSArray *)viewControllers animated:(BOOL)animated {
    NSMutableArray *filtered = [NSMutableArray array];
    for (id vc in viewControllers) {
        if (CYViewControllerIsAssistantTab(vc)) {
            continue;
        }
        [filtered addObject:vc];
    }
    if (filtered.count != viewControllers.count) {
        CYLog(@"[CYTabBarController] removed %lu assistant tab(s)", (unsigned long)(viewControllers.count - filtered.count));
    }
    %orig(filtered.copy, animated);
}

%end

#pragma mark - CYPopupModel：首页弹窗/活动弹窗

%hook _TtC17ColorfulCloudsPro12CYPopupModel

- (void)handlePopupArray:(id)array {
    CYLog(@"[CYPopupModel] handlePopupArray blocked");
    return;
}

- (void)handlePopupModel:(id)model {
    CYLog(@"[CYPopupModel] handlePopupModel blocked");
    return;
}

- (void)handleWithPopupId:(id)popupId pageId:(id)pageId completion:(id)completion {
    CYLog(@"[CYPopupModel] handleWithPopupId:pageId:completion: blocked");
    if (completion) {
        // 尽量安全调用 completion，避免业务逻辑卡死
        // block 签名未知，用 NSInvocation 太麻烦；对于弹窗 completion 通常可空过
    }
    return;
}

- (void)handleWithPopupId:(id)popupId pageId:(id)pageId isHotLaunch:(BOOL)isHotLaunch completion:(id)completion {
    CYLog(@"[CYPopupModel] handleWithPopupId:pageId:isHotLaunch:completion: blocked");
    return;
}

- (void)handleNextPopup {
    CYLog(@"[CYPopupModel] handleNextPopup blocked");
    return;
}

%end

#pragma mark - CYADLaunchViewController：启动广告

%hook CYADLaunchViewController

- (instancetype)init {
    CYLog(@"[CYADLaunchViewController] init blocked -> nil");
    return nil;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    CYLog(@"[CYADLaunchViewController] initWithNibName blocked -> nil");
    return nil;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    CYLog(@"[CYADLaunchViewController] initWithCoder blocked -> nil");
    return nil;
}

%end

#pragma mark - CYADFactory / CYMainADModel：广告数据加载（兜底）

%hook CYADFactory

- (id)createAdvertisingRequestURL:(id)arg1 type:(id)arg2 {
    CYLog(@"[CYADFactory] createAdvertisingRequestURL blocked");
    return nil;
}

%end

%hook CYMainADModel

- (id)init {
    CYLog(@"[CYMainADModel] init blocked -> nil");
    return nil;
}

%end

#pragma mark - CYAlertView / CYAlertContentView：弹窗展示

%hook CYAlertView

- (void)show {
    if (CYObjectIsAdPopup(self)) {
        CYLog(@"[CYAlertView] show blocked");
        return;
    }
    %orig;
}

- (void)showAlert:(id)arg1 {
    if (CYObjectIsAdPopup(self) || CYObjectIsAdPopup(arg1)) {
        CYLog(@"[CYAlertView] showAlert: blocked");
        return;
    }
    %orig(arg1);
}

- (void)showAlert:(id)arg1 showClose:(BOOL)showClose {
    if (CYObjectIsAdPopup(self) || CYObjectIsAdPopup(arg1)) {
        CYLog(@"[CYAlertView] showAlert:showClose: blocked");
        return;
    }
    %orig(arg1, showClose);
}

%end

%hook CYAlertContentView

- (void)show {
    if (CYObjectIsAdPopup(self)) {
        CYLog(@"[CYAlertContentView] show blocked");
        return;
    }
    %orig;
}

%end

#pragma mark - CYThemeAdView：主题广告位

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

#pragma mark - CYToastViewController / CYToastView：会员提示 Toast

%hook CYToastViewController

- (void)showMemberText:(id)arg1 {
    CYLog(@"[CYToastViewController] showMemberText: blocked");
    return;
}

%end

%hook CYToastView

- (void)showMemberText:(id)arg1 {
    CYLog(@"[CYToastView] showMemberText: blocked");
    return;
}

%end

#pragma mark - UIAlertController：会员弹窗兜底

%hook UIAlertController

+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)preferredStyle {
    if (CYStringContainsAdKeyword(title) || CYStringContainsAdKeyword(message)) {
        CYLog(@"[UIAlertController] blocked title=%@ message=%@", title, message);
        return nil;
    }
    return %orig(title, message, preferredStyle);
}

%end

#pragma mark - UIViewController present 兜底

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (CYObjectIsAdPopup(viewControllerToPresent)) {
        CYLog(@"[presentViewController] blocked ad popup: %@", NSStringFromClass([viewControllerToPresent class]));
        if (completion) completion();
        return;
    }
    %orig(viewControllerToPresent, flag, completion);
}

%end

#pragma mark - _ctor

%ctor {
    CYLog(@"[CaiYunRemoveAds] loaded for %@", [[NSBundle mainBundle] bundleIdentifier]);
}
