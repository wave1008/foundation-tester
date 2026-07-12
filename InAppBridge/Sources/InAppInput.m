#import "InAppInput.h"

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

@interface UIApplication (FTPrivate)
- (UIEvent *)_touchesEvent;
@end

@interface UIEvent (FTPrivate)  // 実体は UITouchesEvent
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
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

static void ftSend(UITouch *t) {
    UIApplication *app = UIApplication.sharedApplication;
    UIEvent *ev = [app _touchesEvent];
    [ev _clearTouches];
    [ev _addTouch:t forDelayedDelivery:NO];
    [app sendEvent:ev];
}

void FTSynthTap(UIWindow *window, CGPoint point) {
    UIView *hit = [window hitTest:point withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, point, ts);
    ftSend(t);
    [t setPhase:UITouchPhaseEnded];
    [t _setLocationInWindow:point resetPrevious:NO];
    [t setTimestamp:ts + 0.02];
    ftSend(t);
}

void FTSynthSwipe(UIWindow *window, CGPoint from, CGPoint to, int steps) {
    if (steps < 1) steps = 10;
    UIView *hit = [window hitTest:from withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, from, ts);
    ftSend(t);
    for (int i = 1; i <= steps; i++) {
        CGFloat f = (CGFloat)i / (CGFloat)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * f, from.y + (to.y - from.y) * f);
        ts += 0.01;
        [t _setLocationInWindow:p resetPrevious:NO];
        [t setPhase:UITouchPhaseMoved];
        [t setTimestamp:ts];
        ftSend(t);
    }
    ts += 0.01;
    [t setPhase:UITouchPhaseEnded];
    [t setTimestamp:ts];
    ftSend(t);
}

void FTSynthPress(UIWindow *window, CGPoint point, double duration) {
    UIView *hit = [window hitTest:point withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, point, ts);
    ftSend(t);
    // 長押しの認識にはタイマ発火が要るため、押下を保持したままランループを回す
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:duration]];
    [t setPhase:UITouchPhaseEnded];
    [t _setLocationInWindow:point resetPrevious:NO];
    [t setTimestamp:ts + duration + 0.02];
    ftSend(t);
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
