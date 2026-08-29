//
// 彩云天气 Pro 去广告 + 去小助手 Tweak
// Bundle: net.colorfulclouds.app.pro
// 目标：保留天气/降水图/我的，移除底部「小助手」tab；拦截所有会员推广弹窗广告
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 前向声明目标类，否则 Logos 只生成 @class，编译器拿不到继承来的属性/方法
@interface CYTabBarController : UITabBarController
@end

@interface CYAlertView : UIView
@end

@interface CYAlertContentView : UIView
@end

@interface CYADLaunchViewController : UIViewController
@end

@interface CYADFactory : NSObject
@end

@interface CYMainADModel : NSObject
@end

@interface CYThemeAdView : UIView
@end

@interface CYToastViewController : UIViewController
@end

@interface CYToastView : UIView
@end

@interface CYMainController : UIViewController
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

// 扫描类及其所有父类（最多 6 层）的 ivar + 方法名，统计指纹命中数。
// 只扫 ivar 是不够的：Swift 存储属性在 ObjC runtime 里未必暴露成 ivar，
// 但 @objc 方法名一定在 method list 里，两者互补才稳。
static NSInteger CYClassAssistantScore(Class cls) {
    if (!cls) return 0;
    NSArray *prints = CYAssistantIvarFingerprints();
    NSInteger hits = 0;
    Class c = cls;
    int depth = 0;
    while (c && depth < 6) {
        // ivar
        unsigned int icount = 0;
        Ivar *ivars = class_copyIvarList(c, &icount);
        if (ivars) {
            for (unsigned int i = 0; i < icount; i++) {
                const char *nm = ivar_getName(ivars[i]);
                if (!nm) continue;
                NSString *low = [@(nm) lowercaseString];
                for (NSString *p in prints) {
                    if ([low containsString:p]) {
                        hits++;
                        break;
                    }
                }
            }
            free(ivars);
        }
        // method names
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(c, &mcount);
        if (methods) {
            for (unsigned int i = 0; i < mcount; i++) {
                SEL s = method_getName(methods[i]);
                if (!s) continue;
                NSString *low = [NSStringFromSelector(s) lowercaseString];
                for (NSString *p in prints) {
                    if ([low containsString:p]) {
                        hits++;
                        break;
                    }
                }
            }
            free(methods);
        }
        c = class_getSuperclass(c);
        depth++;
    }
    return hits;
}

static BOOL CYClassLooksLikeAssistant(Class cls) {
    return CYClassAssistantScore(cls) >= 2;
}

// 收集类的全部方法名（含父类，最多 6 层），用于远程诊断
static NSString *CYMethodNamesOfClass(Class cls, NSUInteger limit) {
    if (!cls) return @"";
    NSMutableArray *names = [NSMutableArray array];
    Class c = cls;
    int depth = 0;
    while (c && depth < 6) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        if (methods) {
            for (unsigned int i = 0; i < count && names.count < limit; i++) {
                SEL s = method_getName(methods[i]);
                if (s) [names addObject:NSStringFromSelector(s)];
            }
            free(methods);
        }
        c = class_getSuperclass(c);
        depth++;
    }
    return [names componentsJoinedByString:@" "];
}

// 诊断：把每个 tab 的类名 / 标题 / 指纹分 / 方法名全量打进日志
static void CYDumpTabDiagnostics(NSArray *vcs, NSString *where) {
    if (!vcs.count) {
        CYLog(@"[Diag][%@] viewControllers is empty", where);
        return;
    }
    CYLog(@"[Diag][%@] %lu tab(s):", where, (unsigned long)vcs.count);
    NSUInteger idx = 0;
    for (UIViewController *vc in vcs) {
        NSString *clsName = NSStringFromClass([vc class]);
        NSString *itemTitle = [vc respondsToSelector:@selector(tabBarItem)] ? ([vc tabBarItem].title ?: @"") : @"";
        NSString *vcTitle = [vc respondsToSelector:@selector(title)] ? ([vc title] ?: @"") : @"";
        UIViewController *root = CYUnwrapRootViewController(vc);
        NSString *rootCls = root ? NSStringFromClass([root class]) : @"";
        NSInteger score = root ? CYClassAssistantScore([root class]) : 0;
        CYLog(@"[Diag]  #%lu cls=%@ rootCls=%@ itemTitle='%@' vcTitle='%@' score=%ld",
              (unsigned long)idx, clsName, rootCls, itemTitle, vcTitle, (long)score);
        // 方法名全量输出，便于确认小助手的真实特征
        NSString *methods = CYMethodNamesOfClass([vc class], 60);
        CYLog(@"[Diag]     methods[%@]: %@", clsName, methods);
        if (root && root != vc) {
            NSString *rMethods = CYMethodNamesOfClass([root class], 60);
            CYLog(@"[Diag]     methods[%@](root): %@", rootCls, rMethods);
        }
        idx++;
    }
}

// 取一个 tab VC 实际呈现在 tabBar 上的 item（兼容 UINavigationController 包装）
static UITabBarItem *CYEffectiveTabBarItem(id vc) {
    if (![vc respondsToSelector:@selector(tabBarItem)]) return nil;
    UITabBarItem *item = [vc tabBarItem];
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *root = [(UINavigationController *)vc viewControllers].firstObject;
        if (root && root.tabBarItem) {
            item = root.tabBarItem;
        }
    }
    return item;
}

static BOOL CYViewControllerIsAssistantTab(id vc) {
    if (!vc) return NO;

    // 1) tabBarItem.title / 类名明确写着「小助手」
    // 注意：title 通常设置在 UINavigationController 的 rootViewController 上，
    // 直接读 [vc tabBarItem].title 会得到空字符串。
    UITabBarItem *item = CYEffectiveTabBarItem(vc);
    NSString *title = item.title ?: @"";
    if (!title.length && [vc respondsToSelector:@selector(title)]) {
        title = [vc title] ?: @"";
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

    // 3) 已知白名单：天气/降水图/我的 都不删，避免误杀
    static NSSet *whitelist = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        whitelist = [NSSet setWithObjects:
            @"CYMainController",
            @"CYMapController", @"CYGaodeMapController", @"CYIOSMapController",
            @"CYConfigureViewController",
            @"UINavigationController",
            nil];
    });
    UIViewController *root = CYUnwrapRootViewController(vc);
    NSString *rootCls = root ? NSStringFromClass([root class]) : @"";
    if ([whitelist containsObject:clsName] || [whitelist containsObject:rootCls]) {
        return NO;
    }

    // 4) 兜底：ivar/method 聊天指纹（只删高度疑似且不在白名单里的）
    if (root && CYClassLooksLikeAssistant([root class])) {
        CYLog(@"[Tab] filter by ivar/method fingerprint: %@ (wrapped: %@)",
              rootCls, clsName);
        return YES;
    }

    // 5) 响应 assistantAction（小助手入口常见命名）
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

// 递归 dump 视图层级，用于找出自定义 tabbar 里的小助手按钮
static void CYDumpViewHierarchy(UIView *view, int depth, int maxDepth) {
    if (!view || depth > maxDepth) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSString *cls = NSStringFromClass([view class]);
    CGRect f = view.frame;
    NSString *acc = view.accessibilityIdentifier ?: @"";
    CYLog(@"[Tree]%@%@ frame=(%.0f,%.0f,%.0f,%.0f) hidden=%d acc='%@'",
          indent, cls, f.origin.x, f.origin.y, f.size.width, f.size.height,
          view.hidden, acc);
    // UIButton 额外打标题
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)view currentTitle] ?: @"";
        CYLog(@"[Tree]%@  -> button title='%@'", indent, t);
    }
    for (UIView *sub in view.subviews) {
        CYDumpViewHierarchy(sub, depth + 1, maxDepth);
    }
}

// 只打印位于屏幕底部区域的视图（tabbar 就在那儿），避免整棵树刷屏
static void CYDumpBottomViews(UIView *view, CGFloat bottomY, int depth) {
    if (!view || depth > 12) return;
    CGRect f = view.frame;
    // 视图本身或其子视图区域落在底部 → 打印
    BOOL inBottom = (f.origin.y >= bottomY) || (f.origin.y + f.size.height >= bottomY);
    if (inBottom) {
        NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
        NSString *cls = NSStringFromClass([view class]);
        CYLog(@"[Bottom]%@%@ frame=(%.0f,%.0f,%.0f,%.0f) hidden=%d tag=%ld acc='%@'",
              indent, cls, f.origin.x, f.origin.y, f.size.width, f.size.height,
              view.hidden, (long)view.tag, view.accessibilityIdentifier ?: @"");
        if ([view isKindOfClass:[UIButton class]]) {
            CYLog(@"[Bottom]%@  -> title='%@'", indent, [(UIButton *)view currentTitle] ?: @"");
        }
        if ([view isKindOfClass:[UILabel class]]) {
            CYLog(@"[Bottom]%@  -> label='%@'", indent, [(UILabel *)view text] ?: @"");
        }
    }
    for (UIView *sub in view.subviews) {
        CYDumpBottomViews(sub, bottomY, depth + 1);
    }
}

// 从 keyWindow 根视图开始，把底部 tabbar 整条路径挖出来
static void CYDumpTabBarArea(void) {
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in [(UIWindowScene *)scene windows]) {
                    if (w.isKeyWindow) { win = w; break; }
                }
            }
        }
    }
    if (!win) win = UIApplication.sharedApplication.keyWindow;
    if (!win) { CYLog(@"[Bottom] no keyWindow"); return; }

    CGFloat h = win.bounds.size.height;
    CGFloat bottomY = h - 160.0;
    CYLog(@"[Bottom] === keyWindow=%@ h=%.0f bottomY=%.0f ===",
          NSStringFromClass([win class]), h, bottomY);
    CYDumpBottomViews(win, bottomY, 0);
    CYLog(@"[Bottom] === end ===");
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

// 同上：无 animated 的 setter 也要 hook
- (void)setViewControllers:(NSArray *)viewControllers {
    NSMutableArray *filtered = [NSMutableArray array];
    for (id vc in viewControllers) {
        if (CYViewControllerIsAssistantTab(vc)) {
            continue;
        }
        [filtered addObject:vc];
    }
    if (filtered.count != viewControllers.count) {
        CYLog(@"[UITabBarController] removed %lu assistant tab(s) [no-animated]", (unsigned long)(viewControllers.count - filtered.count));
    }
    %orig(filtered.copy);
}

%end

#pragma mark - CYTabBarController：兜底过滤

%hook CYTabBarController

// 注意：setViewControllers: 与 setViewControllers:animated: 是**两个不同的 selector**，
// UIKit 内部不保证前者转发后者，两个都必须 hook，否则会整个漏掉。
- (void)setViewControllers:(NSArray *)viewControllers animated:(BOOL)animated {
    CYLog(@"[CYTabBarController] setViewControllers:animated: called (%lu)", (unsigned long)viewControllers.count);
    CYDumpTabDiagnostics(viewControllers, @"setViewControllers:animated:");
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

- (void)setViewControllers:(NSArray *)viewControllers {
    CYLog(@"[CYTabBarController] setViewControllers: (no animated) called (%lu)", (unsigned long)viewControllers.count);
    CYDumpTabDiagnostics(viewControllers, @"setViewControllers:");
    NSMutableArray *filtered = [NSMutableArray array];
    for (id vc in viewControllers) {
        if (CYViewControllerIsAssistantTab(vc)) {
            continue;
        }
        [filtered addObject:vc];
    }
    if (filtered.count != viewControllers.count) {
        CYLog(@"[CYTabBarController] removed %lu assistant tab(s) [no-animated]", (unsigned long)(viewControllers.count - filtered.count));
    }
    %orig(filtered.copy);
}

// 兜底：如果 tab 不是走 setter 初始化的（例如直接赋值 ivar），在界面出现后再清一次
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    NSArray *vcs = self.viewControllers;
    if (!vcs.count) return;
    CYDumpTabDiagnostics(vcs, @"viewDidAppear");
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

#pragma mark - CYMainController：dump 视图层级找自定义 tabbar

%hook CYMainController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    // 只在每次进程内首次出现时 dump，避免刷屏
    static BOOL dumped = NO;
    if (dumped) return;
    dumped = YES;

    CYLog(@"[Tree] === CYMainController view hierarchy ===");
    CYLog(@"[Tree] self=%@ view=%@", NSStringFromClass([self class]),
          NSStringFromClass([self.view class]));

    // 子/弹出控制器
    NSArray *children = self.childViewControllers ?: @[];
    CYLog(@"[Tree] childViewControllers=%lu", (unsigned long)children.count);
    for (UIViewController *c in children) {
        CYLog(@"[Tree]   child: %@", NSStringFromClass([c class]));
    }
    if (self.presentedViewController) {
        CYLog(@"[Tree]   presented: %@", NSStringFromClass([self.presentedViewController class]));
    }

    // 只记结构，不再整树 dump（太冗长且 tabbar 不在这一层）
    CYLog(@"[Tree] view=%@ subviews=%lu",
          NSStringFromClass([self.view class]), (unsigned long)self.view.subviews.count);
    CYLog(@"[Tree] === end ===");
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
