#import "InAppInput.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>

// UITouch/UIApplication/UITouchesEvent の合成 private セレクタ(実在確認済み: Xcode 27 beta 3)。
// これらが消えたら合成が黙って効かなくなるので、壊れたら InAppInput の再調査が必要。
@interface UITouch (FTPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)reset;
- (void)setPhase:(UITouchPhase)phase;
- (void)setTapCount:(NSUInteger)count;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)_setIsFirstTouchForView:(BOOL)first;
@end

// IOHIDEvent デジタイザ合成(IOKit)。gesture 認識器ベースのコントロール(SwiftUI Button・
// スクロール等)は、UITouch に HID の裏付けが無いと touch を受理しない。UITextField の
// フォーカスは HID 無しでも view.touchesBegan/Ended 経由で効くが、gesture は要 HID。
// 決め手は親(hand)イベントの kIOHIDEventFieldDigitizerIsDisplayIntegrated=1
// (これが無いと UIKit がタッチスクリーン由来と見なさず gesture へ配送しない。KIF/WDA と同じ)。
typedef double IOHIDFloat;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t type, uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    boolean_t range, boolean_t touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    boolean_t range, boolean_t touch, uint32_t options);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, CFIndex value);

// IOHIDEventTypes.h の ABI 固定値。kIOHIDEventTypeDigitizer=11、field base=type<<16。
#define FT_HID_RANGE    0x00000001u
#define FT_HID_TOUCH    0x00000002u
#define FT_HID_POSITION 0x00000004u
#define FT_HID_TRANSDUCER_HAND 3u
#define FT_HID_FIELD_IS_DISPLAY_INTEGRATED 0x000B0019u  // (11<<16)|0x19

@interface UIApplication (FTPrivate)
- (UIEvent *)_touchesEvent;
- (void)_enqueueHIDEvent:(IOHIDEventRef)event;
@end

@interface UIEvent (FTPrivate)  // 実体は UITouchesEvent
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(IOHIDEventRef)event;
@end

static UITouch *ftMakeTouch(UIWindow *window, UIView *view, CGPoint p, NSTimeInterval ts) {
    UITouch *t = [[UITouch alloc] init];
    [t setWindow:window];
    [t setView:view];
    [t _setLocationInWindow:p resetPrevious:YES];
    [t setPhase:UITouchPhaseBegan];
    [t setTapCount:1];
    [t setTimestamp:ts];
    [t _setIsFirstTouchForView:YES];
    return t;
}

// HID デジタイザの座標は「画面」正規化(0..1)。point は window 座標で来るため、window の
// スクリーン座標へ変換してから screen サイズで割る(window が全画面でない場合=iPad Split View 等の
// ずれ防止。UIScreen.main は非推奨なので window.screen を使う)。
static IOHIDEventRef ftMakeHIDEvent(UIWindow *window, CGPoint point, UITouchPhase phase) {
    UIScreen *scr = window.screen ?: UIScreen.mainScreen;
    CGPoint sp = [window convertPoint:point toCoordinateSpace:scr.coordinateSpace];
    CGSize screen = scr.bounds.size;
    IOHIDFloat nx = screen.width > 0 ? sp.x / screen.width : 0;
    IOHIDFloat ny = screen.height > 0 ? sp.y / screen.height : 0;
    uint64_t ts = mach_absolute_time();
    boolean_t touching = (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled);
    uint32_t mask = (phase == UITouchPhaseMoved) ? FT_HID_POSITION : (FT_HID_RANGE | FT_HID_TOUCH);
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts,
        FT_HID_TRANSDUCER_HAND, 0, 0, 0, 0, 0, 0, 0, 0, 0, touching, touching, 0);
    IOHIDEventSetIntegerValue(hand, FT_HID_FIELD_IS_DISPLAY_INTEGRATED, 1);
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts,
        1, 1, mask, nx, ny, 0, 0, 0, touching, touching, 0);
    IOHIDEventAppendEvent(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

// UITouch(ヒットテスト・first responder 用)と HID イベント(gesture 認識用)を同じ
// UITouchesEvent に載せて送る。
static void ftDispatch(UIWindow *window, UITouch *t, CGPoint point, UITouchPhase phase) {
    IOHIDEventRef hid = ftMakeHIDEvent(window, point, phase);
    UIApplication *app = UIApplication.sharedApplication;
    UIEvent *ev = [app _touchesEvent];
    [ev _clearTouches];
    [ev _setHIDEvent:hid];
    [ev _addTouch:t forDelayedDelivery:NO];
    [app sendEvent:ev];
    CFRelease(hid);
}

void FTSynthTap(UIWindow *window, CGPoint point) {
    UIView *hit = [window hitTest:point withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, point, ts);
    ftDispatch(window, t, point, UITouchPhaseBegan);
    // タップジェスチャ認識器が began を処理する猶予(同一ランループで ended まで送ると遷移不能)
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    [t setPhase:UITouchPhaseEnded];
    [t _setLocationInWindow:point resetPrevious:NO];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    ftDispatch(window, t, point, UITouchPhaseEnded);
}

void FTSynthSwipe(UIWindow *window, CGPoint from, CGPoint to, int steps) {
    if (steps < 1) steps = 10;
    UIView *hit = [window hitTest:from withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, from, ts);
    ftDispatch(window, t, from, UITouchPhaseBegan);
    for (int i = 1; i <= steps; i++) {
        CGFloat f = (CGFloat)i / (CGFloat)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * f, from.y + (to.y - from.y) * f);
        ts += 0.01;
        [t _setLocationInWindow:p resetPrevious:NO];
        [t setPhase:UITouchPhaseMoved];
        [t setTimestamp:ts];
        ftDispatch(window, t, p, UITouchPhaseMoved);
    }
    ts += 0.01;
    [t setPhase:UITouchPhaseEnded];
    [t setTimestamp:ts];
    ftDispatch(window, t, to, UITouchPhaseEnded);
}

void FTSynthPress(UIWindow *window, CGPoint point, double duration) {
    UIView *hit = [window hitTest:point withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, point, ts);
    ftDispatch(window, t, point, UITouchPhaseBegan);
    // 長押しの認識にはタイマ発火が要るため、押下を保持したままランループを回す
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:duration]];
    [t setPhase:UITouchPhaseEnded];
    [t _setLocationInWindow:point resetPrevious:NO];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    ftDispatch(window, t, point, UITouchPhaseEnded);
}

// first responder 探索: nil ターゲットの sendAction は first responder に届く(公開APIの定番手法)
static __weak UIResponder *ftCapturedFirstResponder = nil;

@interface UIResponder (FTFind)
@end
@implementation UIResponder (FTFind)
- (void)ft_captureFirstResponder:(id)sender { ftCapturedFirstResponder = self; }
@end

// sendAction(to:nil)で捕まらない埋め込みレスポンダ(Compose 等の可能性)向けの
// ビュー木からの isFirstResponder 探索フォールバック
static UIView * _Nullable ftFindFirstResponderView(UIView *root) {
    if (root.isFirstResponder) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = ftFindFirstResponderView(sub);
        if (found) return found;
    }
    return nil;
}

static UIResponder * _Nullable ftCurrentFirstResponder(void) {
    ftCapturedFirstResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(ft_captureFirstResponder:)
                                             to:nil from:nil forEvent:nil];
    if (ftCapturedFirstResponder) return ftCapturedFirstResponder;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        UIView *found = ftFindFirstResponderView(w);
        if (found) return found;
    }
    return nil;
}

// 前方宣言(定義は診断セクション)
static NSArray<UIView *> *ftTextReceivers(void);

BOOL FTInsertTextIntoFirstResponder(NSString *text) {
    // 罠: first responder が複数ウィンドウに存在しうる(Compose はフォーカスアンカーの
    // OverlayInputView と、実際のキーボード受け口 IntermediateTextInputUIView が別ビュー。
    // 2026-07-21 実測)。「insertText: に応答し、かつ isFirstResponder」のビューを最優先する
    for (UIView *v in ftTextReceivers()) {
        if (!v.isFirstResponder) continue;  // 非フォーカス受け口への誤入力防止
        if ([v conformsToProtocol:@protocol(UIKeyInput)]) {
            [(id<UIKeyInput>)v insertText:text];
        } else {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(v, @selector(insertText:), text);
        }
        return YES;
    }
    // 従来経路: sendAction で捕まえた first responder(UITextField 等)
    UIResponder *fr = ftCurrentFirstResponder();
    if (!fr) return NO;
    if ([fr conformsToProtocol:@protocol(UIKeyInput)]) {
        [(id<UIKeyInput>)fr insertText:text];
        return YES;
    }
    if ([fr respondsToSelector:@selector(insertText:)]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(fr, @selector(insertText:), text);
        return YES;
    }
    return NO;
}

// ウィンドウ木から insertText: に応答するビューを収集(Compose 等は first responder と
// 実際の入力受け口が別オブジェクトのため)
static void ftCollectTextReceivers(UIView *root, NSMutableArray<UIView *> *out) {
    if ([root respondsToSelector:@selector(insertText:)]) [out addObject:root];
    for (UIView *sub in root.subviews) ftCollectTextReceivers(sub, out);
}

static NSArray<UIView *> *ftTextReceivers(void) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        ftCollectTextReceivers(w, out);
    }
    return out;
}

/// type 失敗(409)時の診断: first responder と「insertText: に応答するビュー」の一覧
NSString *FTFirstResponderDiagnostics(void) {
    UIResponder *fr = ftCurrentFirstResponder();
    NSMutableArray<NSString *> *receivers = [NSMutableArray array];
    for (UIView *v in ftTextReceivers()) {
        [receivers addObject:[NSString stringWithFormat:@"%@(fr=%d,keyInput=%d)",
                              NSStringFromClass(v.class), v.isFirstResponder,
                              [v conformsToProtocol:@protocol(UIKeyInput)]]];
    }
    return [NSString stringWithFormat:@"firstResponder=%@ textReceivers=[%@]",
            fr ? NSStringFromClass(fr.class) : @"nil",
            [receivers componentsJoinedByString:@", "]];
}

void FTActivateAccessibility(void) {
    void (*setAutomationEnabled)(BOOL) = dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled");
    if (!setAutomationEnabled) {
        void *h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        if (h) setAutomationEnabled = dlsym(h, "_AXSSetAutomationEnabled");
    }
    if (setAutomationEnabled) setAutomationEnabled(YES);
}

NSString *FTAccessibilityIdentifier(id node) {
    SEL s = @selector(accessibilityIdentifier);
    if (![node respondsToSelector:s]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(node, s);
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}
