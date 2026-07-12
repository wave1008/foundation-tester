#import "InAppInput.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>

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

// point(window≒screen 座標)を正規化した display-integrated な HID デジタイザイベントを作る。
static IOHIDEventRef ftMakeHIDEvent(CGPoint point, UITouchPhase phase) {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    IOHIDFloat nx = screen.width > 0 ? point.x / screen.width : 0;
    IOHIDFloat ny = screen.height > 0 ? point.y / screen.height : 0;
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
static void ftDispatch(UITouch *t, CGPoint point, UITouchPhase phase) {
    IOHIDEventRef hid = ftMakeHIDEvent(point, phase);
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
    ftDispatch(t, point, UITouchPhaseBegan);
    // タップジェスチャ認識器が began を処理する猶予(同一ランループで ended まで送ると遷移不能)
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    [t setPhase:UITouchPhaseEnded];
    [t _setLocationInWindow:point resetPrevious:NO];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    ftDispatch(t, point, UITouchPhaseEnded);
}

void FTSynthSwipe(UIWindow *window, CGPoint from, CGPoint to, int steps) {
    if (steps < 1) steps = 10;
    UIView *hit = [window hitTest:from withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, from, ts);
    ftDispatch(t, from, UITouchPhaseBegan);
    for (int i = 1; i <= steps; i++) {
        CGFloat f = (CGFloat)i / (CGFloat)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * f, from.y + (to.y - from.y) * f);
        ts += 0.01;
        [t _setLocationInWindow:p resetPrevious:NO];
        [t setPhase:UITouchPhaseMoved];
        [t setTimestamp:ts];
        ftDispatch(t, p, UITouchPhaseMoved);
    }
    ts += 0.01;
    [t setPhase:UITouchPhaseEnded];
    [t setTimestamp:ts];
    ftDispatch(t, to, UITouchPhaseEnded);
}

void FTSynthPress(UIWindow *window, CGPoint point, double duration) {
    UIView *hit = [window hitTest:point withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, point, ts);
    ftDispatch(t, point, UITouchPhaseBegan);
    // 長押しの認識にはタイマ発火が要るため、押下を保持したままランループを回す
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:duration]];
    [t setPhase:UITouchPhaseEnded];
    [t _setLocationInWindow:point resetPrevious:NO];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    ftDispatch(t, point, UITouchPhaseEnded);
}

// first responder 探索: nil ターゲットの sendAction は first responder に届く(公開APIの定番手法)
static __weak UIResponder *ftCapturedFirstResponder = nil;

@interface UIResponder (FTFind)
@end
@implementation UIResponder (FTFind)
- (void)ft_captureFirstResponder:(id)sender { ftCapturedFirstResponder = self; }
@end

BOOL FTInsertTextIntoFirstResponder(NSString *text) {
    ftCapturedFirstResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(ft_captureFirstResponder:)
                                             to:nil from:nil forEvent:nil];
    UIResponder *fr = ftCapturedFirstResponder;
    if ([fr conformsToProtocol:@protocol(UIKeyInput)]) {
        [(id<UIKeyInput>)fr insertText:text];
        return YES;
    }
    return NO;
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
