// CloudCord adapter only. RainTweak's binary and runtime hooks are not modified.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
#import "CloudCordRuntimeCache.h"
#import "CloudCordRuntimeUpdate.h"

// ==================== ChatAuto: floating button + real-keyboard typing ====================
// File IPC with the "Chat Auto" CloudCord userplugin. The plugin writes
// Documents/rain/chatauto-req.json {"id":N,"op":...}; this side answers in
// chatauto-res.json and publishes the button state in chatauto-state.json.
// Everything degrades silently: without the plugin the files never appear,
// and the button still toggles its persisted on/off state.

static NSURL *gChatAutoDir;

static NSDictionary *ChatAutoReadJSON(NSString *name) {
    NSString *path = [gChatAutoDir.path stringByAppendingPathComponent:name];
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static void ChatAutoWriteJSON(NSString *name, NSDictionary *obj) {
    if (!gChatAutoDir) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (d) [d writeToFile:[gChatAutoDir.path stringByAppendingPathComponent:name] atomically:YES];
}

// Overlay window that only accepts touches inside the floating button —
// everywhere else hitTest returns nil so touches fall through to Discord.
@interface ChatAutoWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end

@implementation ChatAutoWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *iv = self.interactiveView;
    if (!iv || iv.hidden || !iv.userInteractionEnabled) return nil;
    CGPoint p = [self convertPoint:point toView:iv];
    if (![iv pointInside:p withEvent:event]) return nil;
    UIView *hit = [iv hitTest:p withEvent:event];
    return hit ?: iv;
}
@end

@interface ChatAutoOverlay : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *secureCanvas;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, assign) BOOL enabled;
+ (instancetype)shared;
- (void)showIfNeeded;
- (void)setEnabled:(BOOL)en;
@end

@implementation ChatAutoOverlay

+ (instancetype)shared {
    static ChatAutoOverlay *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [ChatAutoOverlay new]; });
    return o;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        _enabled = [d objectForKey:@"chatautoEnabled"] ? [d boolForKey:@"chatautoEnabled"] : YES;
    }
    return self;
}

- (void)applyEnabled:(BOOL)en to:(UIButton *)b {
    b.backgroundColor = en
        ? [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1.0]
        : [UIColor colorWithWhite:0.55 alpha:1.0];
}

- (UIButton *)makeButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 54, 54);
    b.layer.cornerRadius = 27;
    b.clipsToBounds = YES;
    b.layer.borderWidth = 1;
    b.layer.borderColor = UIColor.whiteColor.CGColor;
    UIImage *icon = [UIImage systemImageNamed:@"bolt.fill"];
    if (icon) {
        icon = [icon imageWithConfiguration:[UIImageSymbolConfiguration
            configurationWithPointSize:22 weight:UIImageSymbolWeightBold]];
        [b setImage:icon forState:UIControlStateNormal];
        b.tintColor = UIColor.whiteColor;
        b.imageView.contentMode = UIViewContentModeCenter;
    } else {
        [b setTitle:@"A" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    }
    [self applyEnabled:_enabled to:b];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(panned:)];
    [b addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(tapped:)];
    [tap requireGestureRecognizerToFail:pan];
    [b addGestureRecognizer:tap];
    return b;
}

- (void)restorePosition {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    CGFloat x = [d doubleForKey:@"chatautoBtnX"], y = [d doubleForKey:@"chatautoBtnY"];
    if (x > 0 && y > 0) {
        self.button.center = CGPointMake(x, y);
    } else {
        self.button.center = CGPointMake(
            CGRectGetWidth(self.window.bounds) - 40,
            CGRectGetHeight(self.window.bounds) * 0.55);
    }
}

- (void)showIfNeeded {
    if (self.window && !self.window.hidden) return;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] &&
            ((UIWindowScene *)sc).activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)sc;
            break;
        }
    }
    if (!scene) return;
    if (!self.window) {
        self.window = [[ChatAutoWindow alloc] initWithWindowScene:scene];
        self.window.frame = scene.coordinateSpace.bounds;
        self.window.windowLevel = UIWindowLevelAlert + 100;
        self.window.backgroundColor = UIColor.clearColor;
        self.window.opaque = NO;
        // Capture shielding: a secure text field owns a private "secure
        // canvas" subview whose layer is flagged secure — anything placed
        // inside it is excluded from screenshots, screen recording, AirPlay
        // and ReplayKit/screen-share capture on every iOS version.
        UITextField *shield = [[UITextField alloc] initWithFrame:self.window.bounds];
        shield.secureTextEntry = YES;
        shield.userInteractionEnabled = NO;
        shield.backgroundColor = UIColor.clearColor;
        [self.window addSubview:shield];
        UIView *canvas = shield.subviews.firstObject;
        if (canvas) {
            canvas.frame = self.window.bounds;
            canvas.userInteractionEnabled = YES;
            canvas.backgroundColor = UIColor.clearColor;
            [self.window addSubview:canvas];
            self.secureCanvas = canvas;
        }
    }
    if (!self.button) {
        self.button = [self makeButton];
        [self restorePosition];
        UIView *host = self.secureCanvas ?: self.window;
        [host addSubview:self.button];
        ((ChatAutoWindow *)self.window).interactiveView = self.button;
    }
    self.window.hidden = NO;
}

- (void)panned:(UIPanGestureRecognizer *)g {
    if (!self.window || !self.button) return;
    CGPoint t = [g translationInView:self.window];
    CGPoint c = self.button.center;
    c.x += t.x;
    c.y += t.y;
    CGFloat hw = self.button.bounds.size.width / 2.0;
    CGFloat hh = self.button.bounds.size.height / 2.0;
    c.x = MAX(hw + 4, MIN(CGRectGetWidth(self.window.bounds) - hw - 4, c.x));
    c.y = MAX(hh + 50, MIN(CGRectGetHeight(self.window.bounds) - hh - 16, c.y));
    self.button.center = c;
    [g setTranslation:CGPointZero inView:self.window];
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setDouble:c.x forKey:@"chatautoBtnX"];
        [NSUserDefaults.standardUserDefaults setDouble:c.y forKey:@"chatautoBtnY"];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
}

- (void)tapped:(UITapGestureRecognizer *)g {
    [self setEnabled:!self.enabled];
}

- (void)setEnabled:(BOOL)en {
    _enabled = en;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:en forKey:@"chatautoEnabled"];
    [d synchronize];
    if (self.button) [self applyEnabled:en to:self.button];
    ChatAutoWriteJSON(@"chatauto-state.json", @{
        @"enabled": @(en),
        @"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000))
    });
}

@end

// ---------- Composer discovery + real text-input typing ----------

static void ChatAutoCollectInputs(UIView *v, NSMutableArray *out) {
    if ([v isKindOfClass:[UITextView class]] || [v isKindOfClass:[UITextField class]]) {
        BOOL editable = YES;
        if ([v respondsToSelector:@selector(isEditable)]) {
            editable = [(id)v isEditable];
        } else if ([v respondsToSelector:@selector(isEnabled)]) {
            editable = [(id)v isEnabled];
        }
        if (editable && v.userInteractionEnabled && !v.hidden &&
            v.alpha > 0.05 && v.window) {
            CGRect f = [v convertRect:v.bounds toView:nil];
            if (f.size.width > 120) [out addObject:v];
        }
    }
    for (UIView *s in v.subviews) ChatAutoCollectInputs(s, out);
}

static UIView *ChatAutoFindComposer(void) {
    UIWindow *key = nil;
    UIWindow *overlayWin = [ChatAutoOverlay shared].window;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        key = ws.keyWindow;
        if (!key) {
            for (UIWindow *w in ws.windows) {
                if (!w.hidden && w != overlayWin) { key = w; break; }
            }
        }
        if (key) break;
    }
    if (!key) return nil;
    NSMutableArray *cands = [NSMutableArray array];
    ChatAutoCollectInputs(key, cands);
    if (!cands.count) return nil;
    for (UIView *v in cands) {
        if ([v isFirstResponder]) return v;
    }
    // Otherwise take the lowest (bottom-most) wide input: the composer.
    UIView *best = nil;
    CGFloat bestBottom = -1, bestWidth = -1;
    for (UIView *v in cands) {
        CGRect f = [v convertRect:v.bounds toView:nil];
        CGFloat bottom = CGRectGetMaxY(f);
        if (bottom > bestBottom || (bottom == bestBottom && f.size.width > bestWidth)) {
            best = v;
            bestBottom = bottom;
            bestWidth = f.size.width;
        }
    }
    return best;
}

static NSString *ChatAutoInputText(UIView *v) {
    if ([v isKindOfClass:[UITextView class]]) return ((UITextView *)v).text ?: @"";
    if ([v isKindOfClass:[UITextField class]]) return ((UITextField *)v).text ?: @"";
    return @"";
}

static void ChatAutoTypeStep(UIView *tv, NSArray *clusters, NSUInteger i,
                             double base, double jit, id resId) {
    if (i >= clusters.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ChatAutoWriteJSON(@"chatauto-res.json",
                @{@"id": resId, @"ok": @YES, @"chars": @(clusters.count)});
        });
        return;
    }
    @try { [(id<UITextInput>)tv insertText:clusters[i]]; } @catch (NSException *e) {}
    double delay = base + (arc4random() % 1000) / 1000.0 * jit;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChatAutoTypeStep(tv, clusters, i + 1, base, jit, resId);
    });
}

static void ChatAutoHandleType(NSDictionary *req) {
    id resId = req[@"id"];
    NSString *text = [req[@"text"] isKindOfClass:[NSString class]] ? req[@"text"] : @"";
    if (!text.length || text.length > 2000) {
        ChatAutoWriteJSON(@"chatauto-res.json",
            @{@"id": resId, @"ok": @NO, @"reason": @"bad-text"});
        return;
    }
    UIView *tv = ChatAutoFindComposer();
    if (!tv) {
        ChatAutoWriteJSON(@"chatauto-res.json",
            @{@"id": resId, @"ok": @NO, @"reason": @"no-composer"});
        return;
    }
    // Never clobber a draft the user is typing — fall back to direct send.
    NSString *cur = ChatAutoInputText(tv);
    if (cur.length && [cur stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
        ChatAutoWriteJSON(@"chatauto-res.json",
            @{@"id": resId, @"ok": @NO, @"reason": @"draft"});
        return;
    }
    if (![tv isFirstResponder] && ![tv becomeFirstResponder]) {
        ChatAutoWriteJSON(@"chatauto-res.json",
            @{@"id": resId, @"ok": @NO, @"reason": @"not-editable"});
        return;
    }
    NSMutableArray *clusters = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                            options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) {
        if (s.length) [clusters addObject:s];
    }];
    if (!clusters.count) {
        ChatAutoWriteJSON(@"chatauto-res.json",
            @{@"id": resId, @"ok": @NO, @"reason": @"empty"});
        return;
    }
    BOOL insane = [[req[@"speed"] description] isEqualToString:@"insane"];
    double base = insane ? 0.005 : 0.030;
    double jit = insane ? 0.012 : 0.050;
    // Let the keyboard start rising, then type through real input events.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChatAutoTypeStep(tv, clusters, 0, base, jit, resId);
    });
}

static void ChatAutoHandleClear(void) {
    UIView *tv = ChatAutoFindComposer();
    if (tv) {
        NSString *cur = ChatAutoInputText(tv);
        if (cur.length) {
            id<UITextInput> ti = (id<UITextInput>)tv;
            UITextPosition *b = ti.beginningOfDocument;
            UITextPosition *e = ti.endOfDocument;
            if (b && e) {
                UITextRange *all = [ti textRangeFromPosition:b toPosition:e];
                if (all) ti.selectedTextRange = all;
            }
            @try { [ti deleteBackward]; } @catch (NSException *ex) {}
            // RN fallback: if the text survived, force-clear and notify.
            NSString *after = ChatAutoInputText(tv);
            if (after.length && [tv isKindOfClass:[UITextView class]]) {
                UITextView *t = (UITextView *)tv;
                t.text = @"";
                id<UITextViewDelegate> d = t.delegate;
                if ([d respondsToSelector:@selector(textViewDidChange:)]) {
                    [d textViewDidChange:t];
                }
            }
        }
    }
}

static id gChatAutoLastReqId;
static void ChatAutoPollReq(void) {
    if (!gChatAutoDir) return;
    NSDictionary *req = ChatAutoReadJSON(@"chatauto-req.json");
    if (!req) return;
    id rid = req[@"id"];
    if (![rid isKindOfClass:[NSNumber class]] && ![rid isKindOfClass:[NSString class]]) return;
    if (rid && [rid isEqual:gChatAutoLastReqId]) return;
    gChatAutoLastReqId = rid;
    [[NSFileManager defaultManager]
        removeItemAtPath:[gChatAutoDir.path stringByAppendingPathComponent:@"chatauto-req.json"]
        error:nil];
    NSString *op = [req[@"op"] description];
    if ([op isEqualToString:@"type"]) {
        ChatAutoHandleType(req);
    } else if ([op isEqualToString:@"clear"]) {
        ChatAutoHandleClear();
        ChatAutoWriteJSON(@"chatauto-res.json", @{@"id": rid, @"ok": @YES});
    } else if ([op isEqualToString:@"setEnabled"]) {
        [[ChatAutoOverlay shared] setEnabled:[req[@"enabled"] boolValue]];
        ChatAutoWriteJSON(@"chatauto-res.json", @{@"id": rid, @"ok": @YES});
    } else if ([op isEqualToString:@"hello"]) {
        ChatAutoWriteJSON(@"chatauto-res.json", @{@"id": rid, @"ok": @YES, @"v": @1});
    } else {
        ChatAutoWriteJSON(@"chatauto-res.json",
            @{@"id": rid, @"ok": @NO, @"reason": @"bad-op"});
    }
}

static void ChatAutoStart(NSURL *rainDir) {
    gChatAutoDir = rainDir;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES
                                      block:^(NSTimer *t) { ChatAutoPollReq(); }];
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
                                      block:^(NSTimer *t) {
            [[ChatAutoOverlay shared] showIfNeeded];
        }];
        [[ChatAutoOverlay shared] showIfNeeded];
    });
}

__attribute__((constructor)) static void connectCloudCordToRain(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
        NSURL *rain = [documents URLByAppendingPathComponent:@"rain"];
        [fm createDirectoryAtURL:rain withIntermediateDirectories:YES attributes:nil error:nil];
        // Inspect the actual installed host after the user's signer has processed it.
        // No certificate, account, receipt or authentication data is collected.
        BOOL sharedContainerAvailable = NO;
        @try {
            sharedContainerAvailable = [fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.hammerandchisel.discord"] != nil;
        } @catch (NSException *exception) {
            sharedContainerAvailable = NO;
        }
        NSURL *broadcast = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"PlugIns/BroadcastUpload.appex"];
        NSDictionary *broadcastInfo = [NSDictionary dictionaryWithContentsOfURL:[broadcast URLByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *broadcastCheck = @{
            @"hostSharedContainerAvailable": @(sharedContainerAvailable),
            @"broadcastExtensionPresent": @([fm fileExistsAtPath:broadcast.path]),
            @"broadcastUploadPointValid": @([broadcastInfo[@"NSExtension"][@"NSExtensionPointIdentifier"] isEqualToString:@"com.apple.broadcast-services-upload"])
        };
        NSData *broadcastJSON = [NSJSONSerialization dataWithJSONObject:broadcastCheck options:0 error:nil];
        [broadcastJSON writeToURL:[rain URLByAppendingPathComponent:@"cloudcord-broadcast-check.json"] atomically:YES];
        NSURL *runtime = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"BunnyResources.bundle/runtime.js"];
        NSData *data = [NSData dataWithContentsOfURL:runtime];
        if (!data.length) {
            NSLog(@"[CloudCord] No packaged runtime; leaving Discord unmodified");
            return;
        }
        // Install the packaged runtime once per build; retain later explicit updates.
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *hash = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
        if (!CloudCordEnsureRuntimeCache(fm, rain, data, hash)) {
            NSLog(@"[CloudCord] Could not prepare runtime cache; leaving Discord unmodified");
            return;
        }
        NSDictionary *config = @{@"customLoadUrl": @{
            @"enabled": @YES, @"url": @"https://getcloudcord.com/api/proxy/raw/dist/cc.js"
        }};
        NSData *json = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
        if (![json writeToURL:[rain URLByAppendingPathComponent:@"loader.json"] atomically:YES]) return;
        CloudCordRefreshRuntime(rain);
        // Load Rain only after its files are ready, including before its font ctor.
        NSString *library = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/RainTweak.dylib"];
        if (!dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL))
            NSLog(@"[CloudCord] RainTweak could not load: %s", dlerror());
        ChatAutoStart(rain);
    }
}
