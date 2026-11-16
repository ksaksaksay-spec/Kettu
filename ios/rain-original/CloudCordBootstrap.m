// CloudCord adapter only. RainTweak's binary and runtime hooks are not modified.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
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

// Full-window container owning the floating button and the settings panel.
// Only touches inside the button or the (visible) panel card are delivered;
// everything else falls through to Discord.
@interface ChatAutoBox : UIView
@property (nonatomic, weak) UIView *actionButton;
@property (nonatomic, weak) UIView *settingsPanel;
@end

@implementation ChatAutoBox
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.actionButton && CGRectContainsPoint(self.actionButton.frame, point)) return YES;
    if (self.settingsPanel && !self.settingsPanel.hidden &&
        CGRectContainsPoint(self.settingsPanel.frame, point)) return YES;
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.settingsPanel && !self.settingsPanel.hidden) {
        CGPoint pp = [self convertPoint:point toView:self.settingsPanel];
        if ([self.settingsPanel pointInside:pp withEvent:event]) {
            UIView *h = [self.settingsPanel hitTest:pp withEvent:event];
            if (h) return h;
        }
    }
    if (self.actionButton) {
        CGPoint bp = [self convertPoint:point toView:self.actionButton];
        if ([self.actionButton pointInside:bp withEvent:event]) {
            UIView *h = [self.actionButton hitTest:bp withEvent:event];
            if (h) return h;
        }
    }
    return nil;
}
@end

// ---------- Settings panel styling helpers ----------

static UIColor *CAMuted(void) { return [UIColor colorWithWhite:0.72 alpha:1.0]; }
static UIColor *CAFaint(void) { return [UIColor colorWithWhite:0.55 alpha:1.0]; }
static UIColor *CAAccent(void) {
    return [UIColor colorWithRed:88.0/255.0 green:101.0/255.0 blue:242.0/255.0 alpha:1.0];
}
static UIColor *CAGreen(void) {
    return [UIColor colorWithRed:35.0/255.0 green:165.0/255.0 blue:90.0/255.0 alpha:1.0];
}
static UIColor *CARowHi(void) { return [UIColor colorWithWhite:1.0 alpha:0.08]; }
static char kCAActionKey;
static char kCABgKey;
static char kCAValueKey;

// iPhone-style Arabic keyboard drawn inside the secure canvas. It is purely
// visual — keys flash in sync with real UITextInput events (or with the
// standalone "animate" pass) so typing always looks human.
@interface ChatAutoKeyboard : UIView
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *keyMap;
@property (nonatomic, copy) NSString *typed;
- (id)initWithWidth:(CGFloat)w;
- (void)reset;
- (void)appendCluster:(NSString *)s;
- (void)flashCluster:(NSString *)s;
@end

static NSString *CAKBNorm(NSString *s) {
    NSString *r = s;
    for (NSString *a in @[@"أ", @"إ", @"آ", @"ٱ"]) r = [r stringByReplacingOccurrencesOfString:a withString:@"ا"];
    r = [r stringByReplacingOccurrencesOfString:@"ى" withString:@"ي"];
    r = [r stringByReplacingOccurrencesOfString:@"ؤ" withString:@"و"];
    r = [r stringByReplacingOccurrencesOfString:@"ئ" withString:@"ي"];
    return r;
}

@implementation ChatAutoKeyboard

- (id)initWithWidth:(CGFloat)W {
    self = [super initWithFrame:CGRectMake(0, 0, W, 252)];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.11 alpha:0.97];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.keyMap = [NSMutableDictionary dictionary];

    // Text strip on top — shows the answer accumulating like a real field.
    self.textLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 5, W - 20, 34)];
    self.textLabel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    self.textLabel.layer.cornerRadius = 8;
    self.textLabel.clipsToBounds = YES;
    self.textLabel.font = [UIFont systemFontOfSize:17];
    self.textLabel.textColor = UIColor.whiteColor;
    self.textLabel.textAlignment = NSTextAlignmentRight;
    self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.textLabel.userInteractionEnabled = NO;
    [self addSubview:self.textLabel];

    UIColor *keyBg = [UIColor colorWithWhite:1 alpha:0.13];
    NSArray *rows = @[
        @[@"ض", @"ص", @"ث", @"ق", @"ف", @"غ", @"ع", @"ه", @"خ", @"ح", @"ج", @"د"],
        @[@"ش", @"س", @"ي", @"ب", @"ل", @"ا", @"ت", @"ن", @"م", @"ك", @"ط"],
        @[@"ئ", @"ء", @"ؤ", @"ى", @"ة", @"و", @"ز", @"ظ", @"ذ"],
    ];
    CGFloat y = 46, gap = 5, pad = 4, rowH = 46;
    for (NSArray *row in rows) {
        NSInteger n = row.count;
        CGFloat kw = (W - pad * 2 - gap * (n - 1)) / n;
        for (NSInteger i = 0; i < n; i++) {
            NSString *ch = row[i];
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(pad + i * (kw + gap), y, kw, rowH);
            b.backgroundColor = keyBg;
            b.layer.cornerRadius = 6;
            [b setTitle:ch forState:UIControlStateNormal];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightRegular];
            b.userInteractionEnabled = NO;
            [self addSubview:b];
            self.keyMap[ch] = b;
        }
        y += rowH + gap;
    }
    // Bottom row: 123 | space | return — decorative, matches iPhone look.
    CGFloat bw = (W - pad * 2 - gap * 2) / 3;
    NSArray *bottom = @[@"123", @"", @"return"];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat w = (i == 1) ? bw * 3 + gap * 2 - 8 : bw;
        CGFloat x = pad;
        if (i == 1) x = pad + bw + gap;
        if (i == 2) x = pad + (bw + gap) * 2;
        b.frame = CGRectMake(x, y, w, rowH);
        b.backgroundColor = keyBg;
        b.layer.cornerRadius = 6;
        [b setTitle:bottom[i] forState:UIControlStateNormal];
        [b setTitleColor:CAMuted() forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        b.userInteractionEnabled = NO;
        [self addSubview:b];
        if (i == 1) self.keyMap[@" "] = b;
    }
    self.typed = @"";
    return self;
}

- (void)reset { self.typed = @""; self.textLabel.text = @""; }

- (void)appendCluster:(NSString *)s {
    if (!s.length) return;
    self.typed = [self.typed stringByAppendingString:s];
    self.textLabel.text = self.typed;
}

- (void)flashCluster:(NSString *)s {
    if (!s.length) return;
    UIView *k = nil;
    if ([s isEqualToString:@" "]) {
        k = self.keyMap[@" "];
    } else {
        k = self.keyMap[s];
        if (!k) {
            NSString *n = CAKBNorm(s);
            if (n.length == 1) k = self.keyMap[n];
        }
        if (!k && s.length == 1) {
            // composed cluster of one char already handled; try stripping marks
            NSString *n = CAKBNorm(s);
            if (n.length == 1) k = self.keyMap[n];
        }
    }
    if (!k) return;
    UIColor *hi = [UIColor colorWithWhite:1 alpha:0.38];
    k.backgroundColor = hi;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.11 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        k.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
    });
}

@end

@interface ChatAutoOverlay : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *secureCanvas;
@property (nonatomic, strong) ChatAutoBox *container;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *pageHost;
@property (nonatomic, strong) NSArray *panelGuilds;
@property (nonatomic, strong) NSDictionary *panelActive;
@property (nonatomic, strong) NSDictionary *panelSaved;
@property (nonatomic, copy) NSString *panelPage;
@property (nonatomic, copy) NSString *selGuildId;
@property (nonatomic, copy) NSString *selChannelId;
@property (nonatomic, copy) NSString *selBotId;
@property (nonatomic, copy) NSString *selSpeed;
@property (nonatomic, strong) NSTimer *panelTimer;
@property (nonatomic, strong) UITextField *botIDField;
@property (nonatomic, strong) UILabel *vGuild, *vChannel, *vBot, *vSpeed;
@property (nonatomic, strong) UISwitch *swEnabled;
@property (nonatomic, strong) ChatAutoKeyboard *kb;
@property (nonatomic, assign) CGFloat panelHomeY;
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
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(longPressed:)];
    lp.minimumPressDuration = 0.35;
    [b addGestureRecognizer:lp];
    [tap requireGestureRecognizerToFail:lp];
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
    UIView *host = self.secureCanvas ?: self.window;
    if (!self.container) {
        self.container = [[ChatAutoBox alloc] initWithFrame:self.window.bounds];
        self.container.backgroundColor = UIColor.clearColor;
        self.container.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:self.container];
    }
    if (!self.button) {
        self.button = [self makeButton];
        [self restorePosition];
        [self.container addSubview:self.button];
        [self ensurePanel];
    }
    self.container.actionButton = self.button;
    self.container.settingsPanel = self.panel;
    ((ChatAutoWindow *)self.window).interactiveView = self.container;
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

// ---------- Settings panel (native menu on long-press) ----------

- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self togglePanel];
}

- (void)togglePanel {
    if (self.panel && !self.panel.hidden) [self hidePanel];
    else [self showPanel];
}

- (void)reloadOptions {
    NSDictionary *o = ChatAutoReadJSON(@"chatauto-options.json");
    self.panelGuilds = [o[@"guilds"] isKindOfClass:[NSArray class]] ? o[@"guilds"] : @[];
    self.panelActive = [o[@"active"] isKindOfClass:[NSDictionary class]] ? o[@"active"] : @{};
    self.panelSaved = [o[@"saved"] isKindOfClass:[NSDictionary class]] ? o[@"saved"] : @{};
}

- (void)ensurePanel {
    if (self.panel) return;
    CGFloat sw = CGRectGetWidth(self.window.bounds);
    CGFloat sh = CGRectGetHeight(self.window.bounds);
    CGFloat w = MIN(340, sw - 32);
    CGFloat h = MIN(430, sh * 0.72);
    CGFloat x = (sw - w) / 2.0;
    CGFloat y = sh * 0.14;
    self.panelHomeY = y;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, h)];
    self.panel.backgroundColor = [UIColor colorWithRed:0.09 green:0.095 blue:0.11 alpha:0.97];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.borderWidth = 0.5;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    self.panel.clipsToBounds = YES;
    self.panel.hidden = YES;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 72, 50)];
    title.text = @"Chat Auto";
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = UIColor.whiteColor;
    title.userInteractionEnabled = NO;
    [self.panel addSubview:title];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 50, 9, 36, 32);
    UIImage *xi = [UIImage systemImageNamed:@"xmark"];
    if (xi) {
        [close setImage:xi forState:UIControlStateNormal];
        close.tintColor = CAMuted();
        close.imageView.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:CAMuted() forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    }
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:close];
    UIView *hair = [[UIView alloc] initWithFrame:CGRectMake(0, 50, w, 0.5)];
    hair.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    hair.userInteractionEnabled = NO;
    [self.panel addSubview:hair];
    self.pageHost = [[UIView alloc] initWithFrame:CGRectMake(0, 51, w, h - 51)];
    self.pageHost.clipsToBounds = YES;
    [self.panel addSubview:self.pageHost];
    [self.container addSubview:self.panel];
}

- (void)showPanel {
    [self ensurePanel];
    [self reloadOptions];
    if (!self.selGuildId.length && self.panelActive[@"guildId"]) {
        self.selGuildId = [self.panelActive[@"guildId"] description];
        self.selChannelId = [self.panelActive[@"channelId"] description] ?: @"";
        self.selBotId = [self.panelActive[@"botId"] description] ?: @"";
        NSString *sp = [self.panelActive[@"speed"] description];
        self.selSpeed = sp.length ? sp : @"normal";
    }
    if (!self.selSpeed.length) self.selSpeed = @"normal";
    self.panelPage = @"main";
    [self showMainPage];
    self.panel.transform = CGAffineTransformMakeScale(0.94, 0.94);
    self.panel.hidden = NO;
    self.panel.alpha = 0;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.panel.alpha = 1.0;
        self.panel.transform = CGAffineTransformIdentity;
    } completion:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillShowPanel:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardDidHidePanel) name:UIKeyboardWillHideNotification object:nil];
    self.panelTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
        [self reloadOptions];
        if ([self.panelPage isEqualToString:@"main"]) [self refreshMainValues];
    }];
}

- (void)hidePanel {
    if (self.panelTimer) { [self.panelTimer invalidate]; self.panelTimer = nil; }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [self.botIDField resignFirstResponder];
    [UIView animateWithDuration:0.15 animations:^{
        self.panel.alpha = 0;
    } completion:^(BOOL finished) {
        self.panel.hidden = YES;
        CGRect f = self.panel.frame;
        f.origin.y = self.panelHomeY;
        self.panel.frame = f;
        self.panel.transform = CGAffineTransformIdentity;
    }];
}

- (void)keyboardWillShowPanel:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat screenH = CGRectGetHeight(self.window.bounds);
    CGFloat overlap = CGRectGetMaxY(self.panel.frame) - (screenH - kb.size.height);
    if (overlap > 0) {
        CGRect f = self.panel.frame;
        f.origin.y -= (overlap + 10);
        if (f.origin.y < 6) f.origin.y = 6;
        [UIView animateWithDuration:0.25 animations:^{ self.panel.frame = f; }];
    }
}

- (void)keyboardDidHidePanel {
    CGRect f = self.panel.frame;
    if (f.origin.y != self.panelHomeY) {
        f.origin.y = self.panelHomeY;
        [UIView animateWithDuration:0.2 animations:^{ self.panel.frame = f; }];
    }
}

// ---------- Panel rows ----------

- (UIControl *)baseRow:(CGRect)frame {
    UIControl *row = [[UIControl alloc] initWithFrame:frame];
    row.backgroundColor = UIColor.clearColor;
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [row addTarget:self action:@selector(rowTouchDown:) forControlEvents:UIControlEventTouchDown];
    [row addTarget:self action:@selector(rowTouchUp:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return row;
}

- (void)rowTapped:(UIControl *)row {
    void (^b)(void) = objc_getAssociatedObject(row, &kCAActionKey);
    if (b) b();
}

- (void)rowTouchDown:(UIControl *)row { row.backgroundColor = CARowHi(); }

- (void)rowTouchUp:(UIControl *)row {
    row.backgroundColor = objc_getAssociatedObject(row, &kCABgKey) ?: UIColor.clearColor;
}

- (UIControl *)actionRow:(CGRect)frame title:(NSString *)title value:(NSString *)value
                chevron:(BOOL)chev action:(void (^)(void))block {
    UIControl *row = [self baseRow:frame];
    objc_setAssociatedObject(row, &kCABgKey, UIColor.clearColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat w = frame.size.width;
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w * 0.44, frame.size.height)];
    tl.text = title;
    tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    tl.textColor = UIColor.whiteColor;
    tl.userInteractionEnabled = NO;
    [row addSubview:tl];
    CGFloat vx = w * 0.44;
    CGFloat vw = w - vx - (chev ? 30 : 18);
    UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(vx, 0, vw, frame.size.height)];
    vl.text = value.length ? value : @"Not set";
    vl.font = [UIFont systemFontOfSize:14];
    vl.textColor = value.length ? CAMuted() : CAFaint();
    vl.textAlignment = NSTextAlignmentRight;
    vl.lineBreakMode = NSLineBreakByTruncatingTail;
    vl.adjustsFontSizeToFitWidth = YES;
    vl.minimumScaleFactor = 0.65;
    vl.userInteractionEnabled = NO;
    [row addSubview:vl];
    objc_setAssociatedObject(row, &kCAValueKey, vl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (chev) {
        UILabel *ch = [[UILabel alloc] initWithFrame:CGRectMake(w - 24, 0, 18, frame.size.height)];
        ch.text = @"›";
        ch.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
        ch.textColor = CAFaint();
        ch.userInteractionEnabled = NO;
        [row addSubview:ch];
    }
    objc_setAssociatedObject(row, &kCAActionKey, [block copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    return row;
}

- (UIControl *)enabledRow:(CGRect)frame {
    UIControl *row = [self baseRow:frame];
    objc_setAssociatedObject(row, &kCABgKey, UIColor.clearColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat w = frame.size.width;
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 96, frame.size.height)];
    tl.text = @"Enabled";
    tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    tl.textColor = UIColor.whiteColor;
    tl.userInteractionEnabled = NO;
    [row addSubview:tl];
    self.swEnabled = [[UISwitch alloc] initWithFrame:
        CGRectMake(w - 70, (frame.size.height - 31) / 2.0, 51, 31)];
    self.swEnabled.on = self.enabled;
    self.swEnabled.onTintColor = CAGreen();
    self.swEnabled.userInteractionEnabled = NO;
    [row addSubview:self.swEnabled];
    objc_setAssociatedObject(row, &kCAActionKey, ^{ [self toggleEnabledFromRow]; },
                            OBJC_ASSOCIATION_COPY_NONATOMIC);
    return row;
}

- (void)toggleEnabledFromRow {
    [self setEnabled:!self.enabled];
    if (self.swEnabled) self.swEnabled.on = self.enabled;
    [self persistChoice];
}

- (UIControl *)optionRow:(CGRect)frame title:(NSString *)title selected:(BOOL)sel
                  action:(void (^)(void))block {
    UIControl *row = [self baseRow:frame];
    UIColor *bg = sel
        ? [UIColor colorWithRed:88.0/255.0 green:101.0/255.0 blue:242.0/255.0 alpha:0.22]
        : [UIColor colorWithWhite:1 alpha:0.05];
    row.backgroundColor = bg;
    row.layer.cornerRadius = 8;
    row.clipsToBounds = YES;
    objc_setAssociatedObject(row, &kCABgKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat w = frame.size.width;
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, w - 44, frame.size.height)];
    tl.text = title;
    tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    tl.textColor = sel ? CAAccent() : UIColor.whiteColor;
    tl.lineBreakMode = NSLineBreakByTruncatingTail;
    tl.userInteractionEnabled = NO;
    [row addSubview:tl];
    if (sel) {
        UILabel *ck = [[UILabel alloc] initWithFrame:CGRectMake(w - 34, 0, 24, frame.size.height)];
        ck.text = @"✓";
        ck.font = [UIFont boldSystemFontOfSize:16];
        ck.textColor = CAAccent();
        ck.textAlignment = NSTextAlignmentRight;
        ck.userInteractionEnabled = NO;
        [row addSubview:ck];
    }
    objc_setAssociatedObject(row, &kCAActionKey, [block copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    return row;
}

// ---------- Panel pages ----------

- (void)clearPage {
    for (UIView *v in [self.pageHost.subviews copy]) [v removeFromSuperview];
}

- (void)backToMain {
    [self.botIDField resignFirstResponder];
    [self showMainPage];
}

- (NSDictionary *)guildEntry:(NSString *)gid {
    if (!gid.length) return nil;
    for (NSDictionary *g in self.panelGuilds) {
        if ([g isKindOfClass:[NSDictionary class]] && [g[@"id"] isEqualToString:gid]) return g;
    }
    return nil;
}

- (NSString *)guildNameForId:(NSString *)gid {
    NSDictionary *g = [self guildEntry:gid];
    if (g && [g[@"name"] length]) return g[@"name"];
    if (self.panelActive && [self.panelActive[@"guildId"] isEqualToString:gid] &&
        [self.panelActive[@"guildName"] length]) return self.panelActive[@"guildName"];
    return gid.length ? gid : @"Not set";
}

- (NSString *)channelNameForId:(NSString *)cid {
    if (!cid.length) return @"Not set";
    NSDictionary *g = [self guildEntry:self.selGuildId];
    id chs = g ? g[@"channels"] : nil;
    if ([chs isKindOfClass:[NSArray class]]) {
        for (NSDictionary *c in chs) {
            if ([c isKindOfClass:[NSDictionary class]] && [c[@"id"] isEqualToString:cid] && [c[@"name"] length])
                return [NSString stringWithFormat:@"#%@", c[@"name"]];
        }
    }
    if (self.panelActive && [self.panelActive[@"guildId"] isEqualToString:self.selGuildId] &&
        [self.panelActive[@"channelId"] isEqualToString:cid] &&
        [self.panelActive[@"channelName"] length])
        return [NSString stringWithFormat:@"#%@", self.panelActive[@"channelName"]];
    return cid;
}

- (NSString *)botNameForId:(NSString *)bid {
    if (!bid.length) return @"Not set";
    NSDictionary *g = [self guildEntry:self.selGuildId];
    id bots = g ? g[@"bots"] : nil;
    if ([bots isKindOfClass:[NSArray class]]) {
        for (NSDictionary *b in bots) {
            if ([b isKindOfClass:[NSDictionary class]] && [b[@"id"] isEqualToString:bid]) {
                NSString *n = [b[@"name"] description];
                return n.length ? [NSString stringWithFormat:@"@%@", n] : bid;
            }
        }
    }
    if (self.panelActive && [self.panelActive[@"guildId"] isEqualToString:self.selGuildId] &&
        [self.panelActive[@"botId"] isEqualToString:bid] &&
        [self.panelActive[@"botName"] length])
        return [NSString stringWithFormat:@"@%@", self.panelActive[@"botName"]];
    return bid;
}

- (NSString *)displayGuildName {
    return self.selGuildId.length ? [self guildNameForId:self.selGuildId] : @"Not set";
}
- (NSString *)displayChannelName {
    return self.selChannelId.length ? [self channelNameForId:self.selChannelId] : @"Not set";
}
- (NSString *)displayBotName {
    return self.selBotId.length ? [self botNameForId:self.selBotId] : @"Not set";
}
- (NSString *)displaySpeedName {
    return [self.selSpeed isEqualToString:@"insane"] ? @"Insane" : @"Normal";
}

- (void)refreshMainValues {
    if (self.vGuild) self.vGuild.text = [self displayGuildName];
    if (self.vChannel) self.vChannel.text = [self displayChannelName];
    if (self.vBot) self.vBot.text = [self displayBotName];
    if (self.vSpeed) self.vSpeed.text = [self displaySpeedName];
    if (self.swEnabled) self.swEnabled.on = self.enabled;
}

- (void)showMainPage {
    [self clearPage];
    self.panelPage = @"main";
    CGFloat w = self.pageHost.bounds.size.width;
    CGFloat H = self.pageHost.bounds.size.height;
    __weak typeof(self) ws = self;
    CGFloat y = 8, rh = 46;
    UIControl *r;
    r = [self actionRow:CGRectMake(0, y, w, rh) title:@"Server" value:[self displayGuildName]
               chevron:YES action:^{ [ws showGuildPage]; }];
    self.vGuild = objc_getAssociatedObject(r, &kCAValueKey);
    [self.pageHost addSubview:r]; y += rh + 2;
    r = [self actionRow:CGRectMake(0, y, w, rh) title:@"Channel" value:[self displayChannelName]
               chevron:YES action:^{ [ws showChannelPage]; }];
    self.vChannel = objc_getAssociatedObject(r, &kCAValueKey);
    [self.pageHost addSubview:r]; y += rh + 2;
    r = [self actionRow:CGRectMake(0, y, w, rh) title:@"Bot" value:[self displayBotName]
               chevron:YES action:^{ [ws showBotPage]; }];
    self.vBot = objc_getAssociatedObject(r, &kCAValueKey);
    [self.pageHost addSubview:r]; y += rh + 2;
    r = [self actionRow:CGRectMake(0, y, w, rh) title:@"Speed" value:[self displaySpeedName]
               chevron:YES action:^{ [ws showSpeedPage]; }];
    self.vSpeed = objc_getAssociatedObject(r, &kCAValueKey);
    [self.pageHost addSubview:r]; y += rh + 12;
    [self.pageHost addSubview:[self enabledRow:CGRectMake(0, y, w, rh)]];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, H - 36, w - 32, 30)];
    hint.text = @"Tap = on/off   •   Hold = this menu";
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = CAFaint();
    hint.textAlignment = NSTextAlignmentCenter;
    hint.userInteractionEnabled = NO;
    [self.pageHost addSubview:hint];
    [self refreshMainValues];
}

- (NSString *)emptyTextForKind:(NSString *)kind {
    if ([kind isEqualToString:@"guild"]) return @"No servers found — join a server first.";
    if ([kind isEqualToString:@"channel"]) return @"No channels — open the server in Discord first.";
    if ([kind isEqualToString:@"bot"]) return @"No bots found — paste the Bot ID below.";
    return @"Nothing here.";
}

- (void)showPickPage:(NSString *)kind title:(NSString *)title
               items:(NSArray *)items selected:(NSString *)sel
          allowBotID:(BOOL)allowBotID {
    [self clearPage];
    self.panelPage = kind;
    CGFloat w = self.pageHost.bounds.size.width;
    CGFloat H = self.pageHost.bounds.size.height;
    __weak typeof(self) ws = self;
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.frame = CGRectMake(6, 4, 96, 32);
    [back setTitle:@"‹ Back" forState:UIControlStateNormal];
    [back setTitleColor:CAAccent() forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [back addTarget:self action:@selector(backToMain) forControlEvents:UIControlEventTouchUpInside];
    [self.pageHost addSubview:back];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 34, w - 28, 24)];
    t.text = title;
    t.font = [UIFont boldSystemFontOfSize:16];
    t.textColor = UIColor.whiteColor;
    t.userInteractionEnabled = NO;
    [self.pageHost addSubview:t];
    CGFloat listH = H - 68 - (allowBotID ? 74 : 0);
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 62, w, listH)];
    sv.alwaysBounceVertical = YES;
    sv.showsVerticalScrollIndicator = YES;
    if (items.count) {
        CGFloat iy = 4;
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            NSString *iid = [it[@"id"] description];
            NSString *iname = [it[@"title"] description] ?: iid;
            if (!iid.length) continue;
            UIControl *row = [self optionRow:CGRectMake(10, iy, w - 20, 42)
                                       title:iname selected:[iid isEqualToString:sel]
                                      action:^{ [ws pickOption:kind withId:iid]; }];
            [sv addSubview:row];
            iy += 44;
        }
        sv.contentSize = CGSizeMake(w, iy + 8);
    } else {
        UILabel *emp = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, w - 32, 60)];
        emp.text = [self emptyTextForKind:kind];
        emp.font = [UIFont systemFontOfSize:13];
        emp.textColor = CAFaint();
        emp.numberOfLines = 3;
        emp.textAlignment = NSTextAlignmentCenter;
        emp.userInteractionEnabled = NO;
        [sv addSubview:emp];
        sv.contentSize = CGSizeMake(w, listH);
    }
    [self.pageHost addSubview:sv];
    if (allowBotID) {
        CGFloat by = H - 70;
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, by, w, 70)];
        bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
        self.botIDField = [[UITextField alloc] initWithFrame:CGRectMake(12, 8, w - 118, 36)];
        self.botIDField.placeholder = @"Or paste Bot ID";
        self.botIDField.font = [UIFont systemFontOfSize:14];
        self.botIDField.textColor = UIColor.whiteColor;
        self.botIDField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.botIDField.layer.cornerRadius = 8;
        self.botIDField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 36)];
        self.botIDField.leftViewMode = UITextFieldViewModeAlways;
        self.botIDField.keyboardType = UIKeyboardTypeNumberPad;
        self.botIDField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.botIDField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        UIToolbar *kb = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
        kb.barStyle = UIBarStyleDefault;
        kb.translucent = YES;
        UIBarButtonItem *flex = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"Done"
            style:UIBarButtonItemStyleDone target:self action:@selector(dismissKeyboard)];
        [done setTitleTextAttributes:@{NSForegroundColorAttributeName: CAAccent()}
                           forState:UIControlStateNormal];
        kb.items = @[flex, done];
        self.botIDField.inputAccessoryView = kb;
        [bar addSubview:self.botIDField];
        UIButton *setB = [UIButton buttonWithType:UIButtonTypeSystem];
        setB.frame = CGRectMake(w - 102, 8, 90, 36);
        [setB setTitle:@"Set" forState:UIControlStateNormal];
        [setB setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        setB.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        setB.backgroundColor = CAAccent();
        setB.layer.cornerRadius = 8;
        [setB addTarget:self action:@selector(botIDSet:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:setB];
        [self.pageHost addSubview:bar];
    }
}

- (void)dismissKeyboard { [self.botIDField resignFirstResponder]; }

- (void)botIDSet:(id)sender {
    NSString *v = [self.botIDField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (v.length) {
        self.selBotId = v;
        [self persistChoice];
        [self.botIDField resignFirstResponder];
        [self showMainPage];
    }
}

- (void)showGuildPage {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *g in self.panelGuilds) {
        if (![g isKindOfClass:[NSDictionary class]]) continue;
        NSString *gid = [g[@"id"] description];
        if (!gid.length) continue;
        [items addObject:@{@"id": gid, @"title": [g[@"name"] description] ?: @"Server"}];
    }
    [self showPickPage:@"guild" title:@"Select Server" items:items
              selected:self.selGuildId allowBotID:NO];
}

- (void)showChannelPage {
    NSMutableArray *items = [NSMutableArray array];
    NSDictionary *g = [self guildEntry:self.selGuildId];
    id chs = g ? g[@"channels"] : nil;
    if ([chs isKindOfClass:[NSArray class]]) {
        for (NSDictionary *c in chs) {
            if (![c isKindOfClass:[NSDictionary class]]) continue;
            NSString *cid = [c[@"id"] description];
            if (!cid.length) continue;
            NSString *cn = [c[@"name"] description] ?: cid;
            [items addObject:@{@"id": cid, @"title": [NSString stringWithFormat:@"#%@", cn]}];
        }
    }
    [self showPickPage:@"channel" title:@"Select Channel" items:items
              selected:self.selChannelId allowBotID:NO];
}

- (void)showBotPage {
    NSMutableArray *items = [NSMutableArray array];
    NSDictionary *g = [self guildEntry:self.selGuildId];
    id bots = g ? g[@"bots"] : nil;
    if ([bots isKindOfClass:[NSArray class]]) {
        for (NSDictionary *b in bots) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = [b[@"id"] description];
            if (!bid.length) continue;
            NSString *bn = [b[@"name"] description] ?: bid;
            [items addObject:@{@"id": bid, @"title": [NSString stringWithFormat:@"@%@", bn]}];
        }
    }
    [self showPickPage:@"bot" title:@"Select Games Bot" items:items
              selected:self.selBotId allowBotID:YES];
}

- (void)showSpeedPage {
    NSArray *items = @[
        @{@"id": @"normal", @"title": @"Normal — verified answers"},
        @{@"id": @"insane", @"title": @"Insane — fastest reply"},
    ];
    [self showPickPage:@"speed" title:@"Answer Speed" items:items
              selected:self.selSpeed allowBotID:NO];
}

- (void)pickOption:(NSString *)kind withId:(NSString *)oid {
    if (!oid.length) return;
    if ([kind isEqualToString:@"guild"]) {
        self.selGuildId = oid;
        NSDictionary *sv = [self.panelSaved isKindOfClass:[NSDictionary class]] ? self.panelSaved[oid] : nil;
        if (![sv isKindOfClass:[NSDictionary class]]) sv = nil;
        NSString *sc = [sv[@"channelId"] description];
        NSString *sb = [sv[@"botId"] description];
        NSString *ss = [sv[@"speed"] description];
        if (self.panelActive && [self.panelActive[@"guildId"] isEqualToString:oid]) {
            if (!sc.length) sc = [self.panelActive[@"channelId"] description];
            if (!sb.length) sb = [self.panelActive[@"botId"] description];
            if (!ss.length) ss = [self.panelActive[@"speed"] description];
        }
        self.selChannelId = sc.length ? sc : @"";
        self.selBotId = sb.length ? sb : @"";
        self.selSpeed = ss.length ? ss : @"normal";
        [self persistChoice];
        [self showMainPage];
    } else if ([kind isEqualToString:@"channel"]) {
        self.selChannelId = oid;
        [self persistChoice];
        [self showMainPage];
    } else if ([kind isEqualToString:@"bot"]) {
        self.selBotId = oid;
        [self persistChoice];
        [self showMainPage];
    } else if ([kind isEqualToString:@"speed"]) {
        self.selSpeed = oid;
        [self persistChoice];
        [self showMainPage];
    }
}

- (void)persistChoice {
    ChatAutoWriteJSON(@"chatauto-choice.json", @{
        @"guildId": self.selGuildId ?: @"",
        @"channelId": self.selChannelId ?: @"",
        @"botId": self.selBotId ?: @"",
        @"speed": self.selSpeed.length ? self.selSpeed : @"normal",
        @"enabled": @(self.enabled),
        @"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000))
    });
}

// ---------- On-screen keyboard (visual typing feedback) ----------

- (void)buildKeyboard {
    if (self.kb) return;
    CGFloat w = CGRectGetWidth(self.container.bounds);
    self.kb = [[ChatAutoKeyboard alloc] initWithWidth:w];
    self.kb.frame = CGRectMake(0, CGRectGetHeight(self.container.bounds) - self.kb.bounds.size.height, w, self.kb.bounds.size.height);
    self.kb.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    self.kb.hidden = YES;
    self.kb.alpha = 0;
    [self.container addSubview:self.kb];
}

- (void)showKeyboard {
    [self buildKeyboard];
    if (self.kb.superview != self.container) [self.container addSubview:self.kb];
    [self.kb reset];
    self.kb.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ self.kb.alpha = 1; }];
}

- (void)hideKeyboardSoon {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self hideKeyboard]; });
}

- (void)hideKeyboard {
    if (!self.kb || self.kb.hidden) return;
    [UIView animateWithDuration:0.2 animations:^{ self.kb.alpha = 0; }
                     completion:^(BOOL f) { self.kb.hidden = YES; }];
}

- (void)kbAppend:(NSString *)s { [self.kb appendCluster:s]; }
- (void)kbFlash:(NSString *)s { [self.kb flashCluster:s]; }

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
                             double base, double jit, id resId, BOOL doType) {
    ChatAutoOverlay *ov = [ChatAutoOverlay shared];
    if (i >= clusters.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ChatAutoWriteJSON(@"chatauto-res.json",
                @{@"id": resId, @"ok": @YES, @"chars": @(clusters.count)});
            [ov hideKeyboardSoon];
        });
        return;
    }
    NSString *cl = clusters[i];
    [ov kbFlash:cl];
    [ov kbAppend:cl];
    if (doType && tv) {
        @try { [(id<UITextInput>)tv insertText:cl]; } @catch (NSException *e) {}
    }
    double delay = base + (arc4random() % 1000) / 1000.0 * jit;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChatAutoTypeStep(tv, clusters, i + 1, base, jit, resId, doType);
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
    ChatAutoOverlay *ov = [ChatAutoOverlay shared];
    [ov showKeyboard];
    // Let the keyboard start rising, then type through real input events.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChatAutoTypeStep(tv, clusters, 0, base, jit, resId, YES);
    });
}

// "animate": no composer target — just play the on-screen keyboard typing
// the text so the user still sees letter-by-letter input, then reply ok.
static void ChatAutoHandleAnimate(NSDictionary *req) {
    id resId = req[@"id"];
    NSString *text = [req[@"text"] description] ?: @"";
    if (!text.length || text.length > 2000) {
        ChatAutoWriteJSON(@"chatauto-res.json",
            @{@"id": resId, @"ok": @NO, @"reason": @"bad-text"});
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
    ChatAutoOverlay *ov = [ChatAutoOverlay shared];
    [ov showKeyboard];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChatAutoTypeStep(nil, clusters, 0, base, jit, resId, NO);
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
    } else if ([op isEqualToString:@"animate"]) {
        ChatAutoHandleAnimate(req);
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
