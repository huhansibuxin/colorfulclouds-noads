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

// 小助手（AI 聊天）功能的 ivar 指纹。
// 这些名字来自二进制 __swift5_reflstr 中 Swift 类的存储属性名，
// 是小助手聊天界面/ViewModel 独有的，天气与降水图页面不会命中。
static NSArray<NSString *> *CYAssistantIvarFingerprints(void) {
    static NSArray *arr = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        arr = @[@"chatinputview", @"chatarray", @"chattableview", @"chatinputbar",
                @"promptarray", @"historyStatus", @"isrequesthistroy",
                @"ailabel", @"chatmodel", @"chatimgview", @"chatimages",
                @"assistant", @"chattextview"];
    });
    return arr;
}

// 扫描类及其所有父类（最多 6 层）的 ivar 列表，命中 >=2 个指纹即判定为小助手
static BOOL CYClassLooksLikeAssistant(Class cls) {
    if (!cls) return NO;
    NSArray *prints = CYAssistantIvarFingerprints();
    NSInteger hits = 0;
    Class c = cls;
    int depth = 0;
    while (c && depth < 6) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        if (ivars) {
            for (unsigned int i = 0; i < count; i++) {
                const char *nm = ivar_getName(ivars[i]);
                if (!nm) continue;
                NSString *low = [@(nm) lowercaseString];
                for (NSString *p in prints) {
                    if ([low containsString:p]) {
                        hits++;
                        break; // 同一个 ivar 只计一次
                    }
                }
            }
            free(ivars);
        }
        if (hits >= 2) {
            return YES;
        }
        c = class_getSuperclass(c);
        depth++;
    }
    return NO;
}

// 解开可能存在的 UINavigationController 包装，取真正的根 VC
static UIViewController *CYUnwrapRootViewController(UIViewController *vc) {
    UIViewController *cur = vc;
    int guard = 0;
    while (cur && guard < 5) {
        if ([cur isKindOfClass:[UINavigationController class]]) {
            cur = [(UINavigationController *)cur viewControllers].firstObject;
            guard++;
            continue;
        }
        break;
    }
    return cur;
}

static BOOL CYViewControllerIsAssistantTab(id vc) {
    if (!vc) return NO;

    // 1) tabBarItem.title 明确写着「小助手」
    NSString *title = nil;
    if ([vc respondsToSelector:@selector(tabBarItem)]) {
        title = [vc tabBarItem].title;
    }
    if (!title.length && [vc respondsToSelector:@selector(title)]) {
        title = [vc title];
    }
    if (title.length && ([title containsString:@"小助手"] || [title containsString:@"助手"])) {
        CYLog(@"[Tab] filter by title: %@", title);
        return YES;
    }

    // 2) 类名含 Assistant/assistant
    NSString *clsName = NSStringFromClass([vc class]);
    if ([clsName containsString:@"Assistant"] || [clsName containsString:@"assistant"]) {
        CYLog(@"[Tab] filter by class: %@", clsName);
        return YES;
    }

    // 3) ivar 指纹扫描（解开 nav 包装后判断，Swift 类名未知也能命中）
    UIViewController *root = CYUnwrapRootViewController(vc);
    if (root && CYClassLooksLikeAssistant([root class])) {
        CYLog(@"[Tab] filter by ivar fingerprint: %@ (wrapped: %@)",
              NSStringFromClass([root class]), clsName);
        return YES;
    }

    // 4) 响应 assistantAction（小助手入口常见命名）
    if ([vc respondsToSelector:NSSelectorFromString(@"assistantAction")]) {
        CYLog(@"[Tab] filter by assistantAction selector: %@", clsName);
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

// 兜底：如果 tab 不是走 setter 初始化的（例如直接赋值 ivar），在界面出现后再清一次
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    NSArray *vcs = self.viewControllers;
    if (!vcs.count) return;
    NSMutableArray *filtered = [NSMutableArray array];
    for (id vc in vcs) {
        if (CYViewControllerIsAssistantTab(vc)) {
            continue;
        }
        [filtered addObject:vc];
    }
    if (filtered.count != vcs.count) {
        CYLog(@"[CYTabBarController] viewDidAppear cleanup: removed %lu assistant tab(s)",
              (unsigned long)(vcs.count - filtered.count));
        [self setViewControllers:filtered.copy animated:NO];
    }
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
