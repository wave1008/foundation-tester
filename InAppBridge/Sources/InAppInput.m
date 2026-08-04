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

// 2本指ぶんの HID デジタイザイベント(1つの hand イベントに finger を2つぶら下げる)。
// index/identity を分けないと UIKit が同一の指の移動と解釈して多点にならない。
static IOHIDEventRef ftMakeHIDEvent2(UIWindow *window, CGPoint p1, CGPoint p2, UITouchPhase phase) {
    UIScreen *scr = window.screen ?: UIScreen.mainScreen;
    CGSize screen = scr.bounds.size;
    uint64_t ts = mach_absolute_time();
    boolean_t touching = (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled);
    uint32_t mask = (phase == UITouchPhaseMoved) ? FT_HID_POSITION : (FT_HID_RANGE | FT_HID_TOUCH);
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts,
        FT_HID_TRANSDUCER_HAND, 0, 0, 0, 0, 0, 0, 0, 0, 0, touching, touching, 0);
    IOHIDEventSetIntegerValue(hand, FT_HID_FIELD_IS_DISPLAY_INTEGRATED, 1);
    CGPoint points[2] = {p1, p2};
    for (uint32_t i = 0; i < 2; i++) {
        CGPoint sp = [window convertPoint:points[i] toCoordinateSpace:scr.coordinateSpace];
        IOHIDFloat nx = screen.width > 0 ? sp.x / screen.width : 0;
        IOHIDFloat ny = screen.height > 0 ? sp.y / screen.height : 0;
        IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts,
            i + 1, i + 1, mask, nx, ny, 0, 0, 0, touching, touching, 0);
        IOHIDEventAppendEvent(hand, finger, 0);
        CFRelease(finger);
    }
    return hand;
}

// 2本指を同じ UITouchesEvent に載せて送る(片方ずつ送ると多点として解釈されない)
static void ftDispatch2(UIWindow *window, UITouch *t1, UITouch *t2,
                        CGPoint p1, CGPoint p2, UITouchPhase phase) {
    IOHIDEventRef hid = ftMakeHIDEvent2(window, p1, p2, phase);
    UIApplication *app = UIApplication.sharedApplication;
    UIEvent *ev = [app _touchesEvent];
    [ev _clearTouches];
    [ev _setHIDEvent:hid];
    [ev _addTouch:t1 forDelayedDelivery:NO];
    [ev _addTouch:t2 forDelayedDelivery:NO];
    [app sendEvent:ev];
    CFRelease(hid);
}

// 単発タップ(tapCount 指定つき)。ダブルタップの2打目は tapCount=2 にする(実機の UIKit と同じ形)
static void ftTapWithCount(UIWindow *window, CGPoint point, NSUInteger tapCount) {
    UIView *hit = [window hitTest:point withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t = ftMakeTouch(window, hit, point, ts);
    [t setTapCount:tapCount];
    ftDispatch(window, t, point, UITouchPhaseBegan);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    [t setPhase:UITouchPhaseEnded];
    [t _setLocationInWindow:point resetPrevious:NO];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    ftDispatch(window, t, point, UITouchPhaseEnded);
}

// ダブルタップ。**gapSeconds は「離してから次に押すまで」**で、ここが短すぎると
// Compose(iOS)が2打目を捨てる(doubleTapMinTimeMillis = 40ms 未満は無視。XCUITest の
// doubleTap はここが 0ms になるため Compose では単タップに落ちる。2026-08-04 実測)。
// 長すぎると今度は判定窓(約 300ms)を外れる。
void FTSynthDoubleTap(UIWindow *window, CGPoint point, double gapSeconds) {
    if (!(gapSeconds > 0) || gapSeconds > 0.25) gapSeconds = 0.08;
    ftTapWithCount(window, point, 1);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:gapSeconds]];
    ftTapWithCount(window, point, 2);
}

// 2本指ピンチ。center を挟んで対角(45度)に startSpan → endSpan まで開閉する。
// **合成タッチの move がジェスチャ認識器に受理されるかはフレームワーク依存**(UIKit/SwiftUI と
// Compose は受理しない = swipe/press が in-app で 501 な理由と同じ)。受理判定はできないので
// 呼び出し側が事後に検証する。
void FTSynthPinch(UIWindow *window, CGPoint center, double startSpan, double endSpan,
                  double duration, int steps) {
    if (steps < 1) steps = 20;
    if (!(duration > 0)) duration = 0.5;
    const double axis = 0.70710678;   // cos45: 各軸への射影
    CGPoint p1 = CGPointMake(center.x - startSpan / 2 * axis, center.y - startSpan / 2 * axis);
    CGPoint p2 = CGPointMake(center.x + startSpan / 2 * axis, center.y + startSpan / 2 * axis);
    UIView *hit = [window hitTest:center withEvent:nil] ?: window;
    NSTimeInterval ts = NSProcessInfo.processInfo.systemUptime;
    UITouch *t1 = ftMakeTouch(window, hit, p1, ts);
    UITouch *t2 = ftMakeTouch(window, hit, p2, ts);
    [t2 _setIsFirstTouchForView:NO];
    ftDispatch2(window, t1, t2, p1, p2, UITouchPhaseBegan);
    double stepDelay = duration / steps;
    for (int i = 1; i <= steps; i++) {
        double f = (double)i / (double)steps;
        double span = startSpan + (endSpan - startSpan) * f;
        p1 = CGPointMake(center.x - span / 2 * axis, center.y - span / 2 * axis);
        p2 = CGPointMake(center.x + span / 2 * axis, center.y + span / 2 * axis);
        ts = NSProcessInfo.processInfo.systemUptime;
        [t1 _setLocationInWindow:p1 resetPrevious:NO];
        [t2 _setLocationInWindow:p2 resetPrevious:NO];
        [t1 setPhase:UITouchPhaseMoved];
        [t2 setPhase:UITouchPhaseMoved];
        [t1 setTimestamp:ts];
        [t2 setTimestamp:ts];
        ftDispatch2(window, t1, t2, p1, p2, UITouchPhaseMoved);
        // 実時間を進める(タイムスタンプだけ進めても速度計算が追随しない)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:stepDelay]];
    }
    ts = NSProcessInfo.processInfo.systemUptime;
    [t1 setPhase:UITouchPhaseEnded];
    [t2 setPhase:UITouchPhaseEnded];
    [t1 setTimestamp:ts];
    [t2 setTimestamp:ts];
    ftDispatch2(window, t1, t2, p1, p2, UITouchPhaseEnded);
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

// アプリが Flutter か。**clear の可否はこの粒度で判定する**(受け口のクラス名は secure 欄など
// 構成で変わり取りこぼすため。2026-07-30 実測)
static BOOL ftIsFlutterApp(void) {
    return NSClassFromString(@"FlutterViewController") != nil;
}

// Flutter の入力受け口か。**engine 配送(pressEnter)は受け口そのものを特定する必要がある**ため
// こちらはクラス名で見る。secure 欄はサブクラスで別名なので prefix 一致では足りない
static BOOL ftIsFlutterTextInput(id responder) {
    NSString *name = NSStringFromClass([responder class]);
    return [name hasPrefix:@"Flutter"] && [name containsString:@"TextInput"];
}

// 受け口に残っているテキストの長さ。**「空に見えること」を成功の根拠にしてよい受け口だけ**
// 長さを返し、状態を別レイヤに持つ実装(Flutter = Dart 側)は NSNotFound = 判定不能を返す
// (view のローカル状態は空でも実体に値が残る = 嘘の成功になるため。2026-07-30 実測)。
// 呼び出し側は `== 0` で判定するので、NSNotFound は自動的に「空とは言えない」側へ倒れる
static NSUInteger ftRemainingTextLength(id responder) {
    if ([responder isKindOfClass:[UITextField class]]) return ((UITextField *)responder).text.length;
    if ([responder isKindOfClass:[UITextView class]]) return ((UITextView *)responder).text.length;
    // Flutter は Dart 側が真の状態を持つ = ここでは読めない(層2 の要点。判定粒度の理由は
    // ftIsFlutterApp 参照)
    if (ftIsFlutterApp()) return NSNotFound;
    if ([responder conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> ti = (id<UITextInput>)responder;
        UITextPosition *begin = ti.beginningOfDocument;
        UITextPosition *end = ti.endOfDocument;
        UITextRange *range = (begin && end) ? [ti textRangeFromPosition:begin toPosition:end] : nil;
        if (range) return [ti textInRange:range].length;
    }
    if ([responder conformsToProtocol:@protocol(UIKeyInput)]) {
        return ((id<UIKeyInput>)responder).hasText ? 1 : 0;
    }
    return NSNotFound;
}

// FTInsertTextIntoFirstResponder と同じ探索順(isFirstResponder な insertText: 受け口を優先、
// 無ければ sendAction 捕捉/ビュー木探索の first responder)で対象を1つ選ぶ
static id _Nullable ftClearTarget(void) {
    for (UIView *v in ftTextReceivers()) {
        if (v.isFirstResponder) return v;
    }
    return ftCurrentFirstResponder();
}

BOOL FTClearTextInFirstResponder(void) {
    id responder = ftClearTarget();
    if (!responder) return NO;
    // **Flutter アプリでは in-app では消せない**(docs/design.md に不採用の記録)。
    // 判定はアプリ粒度: 受け口の実クラスでは判定しきれない(secure 欄は別クラスで、名前は
    // 版・構成で変わる。2026-07-30 実測で取りこぼした)。Flutter はテキスト状態を Dart 側が
    // 持つというアプリ単位の性質なのでこの粒度が正しい。NO = 409 → xcuitest フォールバック
    // (**実測で機能する**。ref 有/無とも確認済み)
    if (ftIsFlutterApp()) return NO;

    if ([responder isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)responder;
        field.text = @"";
        // .text 代入は UIControlEventEditingChanged/通知を自動発火しない(insertText: と違い
        // 内部キー入力経路を通らないため)。SwiftUI/UIKit の変更監視経路を明示的に補う
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification
                                                           object:field];
        return YES;
    }
    if ([responder isKindOfClass:[UITextView class]]) {
        UITextView *view = (UITextView *)responder;
        view.text = @"";
        [NSNotificationCenter.defaultCenter postNotificationName:UITextViewTextDidChangeNotification
                                                           object:view];
        if ([view.delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [view.delegate textViewDidChange:view];
        }
        return YES;
    }
    // UITextField/UITextView 以外の UITextInput 準拠(Compose の IntermediateTextInputUIView 等)。
    // insertText: だけでは追記になるため、全文書レンジを取って replaceRange:withText:@"" する。
    // **replaceRange が通っても消えたとは限らない**(状態を別レイヤに持つ実装)。必ず読み返して
    // 確認し、残っていたら下の deleteBackward 経路(キー入力経路)へ落とす
    if ([responder conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> ti = (id<UITextInput>)responder;
        UITextPosition *begin = ti.beginningOfDocument;
        UITextPosition *end = ti.endOfDocument;
        UITextRange *range = (begin && end) ? [ti textRangeFromPosition:begin toPosition:end] : nil;
        if (range) {
            [ti replaceRange:range withText:@""];
            if (ftRemainingTextLength(responder) == 0) return YES;
        }
    }
    // UITextInput の replaceRange が効かない/レンジが取れない実装向け(UIKeyInput 専用)。
    // カーソルが先頭にあると deleteBackward が減らないため上限を設け、残ったら NO
    // (= 呼び出し側が 409 で xcuitest を案内する既知の縮退。嘘の成功を返さないことが要点)
    if ([responder conformsToProtocol:@protocol(UIKeyInput)]) {
        id<UIKeyInput> ki = (id<UIKeyInput>)responder;
        NSInteger attempts = 0;
        NSUInteger remaining = ftRemainingTextLength(responder);
        // NSNotFound(長さを読めない実装)は「空でない」とも言えないので即 NO
        // (空打ちの deleteBackward を 10000 回撃たない)
        while (remaining != NSNotFound && remaining > 0 && attempts < 10000) {
            [ki deleteBackward];
            attempts++;
            remaining = ftRemainingTextLength(responder);
        }
        return remaining == 0;
    }
    return NO;
}

// FTClearTextInFirstResponder と同じ対象解決(ftClearTarget)を使う。**冪等**: 対象が無い/
// resignFirstResponder に応答しない場合も YES(呼び出し側 handleHideKeyboard は 409 分岐を持たない
// ―― 「閉じるべきキーボードが無い」は既に望む状態であり失敗ではない)
/// Flutter の入力受け口へ IME アクションを配送する。**engine の私有 API を叩く**ので、
/// 各段で存在確認し1つでも欠けたら NO を返す(= 呼び出し側が 409 で「xcuitest を使え」と案内する
/// 既知の縮退へ落ちる。Flutter 更新で黙って誤動作させないため、推測で続行しない)。
/// insertText:@"\n" が使えないのは engine が改行を握り潰すため(文字も入らずアクションも出ない)。
/// アクション値は view が保持する returnKeyType(UIKit の公開 enum)から復元する
/// ―― engine 側が Dart の textInputAction から returnKeyType を作っているので逆写像になる。
static BOOL ftFlutterPerformInputAction(UIView *v) {
    if (![v respondsToSelector:@selector(textInputDelegate)]) return NO;
    if (![v respondsToSelector:@selector(textInputClient)]) return NO;
    if (![v respondsToSelector:@selector(returnKeyType)]) return NO;
    id delegate = ((id (*)(id, SEL))objc_msgSend)(v, @selector(textInputDelegate));
    SEL perform = @selector(flutterTextInputView:performAction:withClient:);
    if (!delegate || ![delegate respondsToSelector:perform]) return NO;

    // FlutterTextInputAction(engine の enum)。未知の returnKeyType は写像せず NO を返す
    UIReturnKeyType returnKey = ((UIReturnKeyType (*)(id, SEL))objc_msgSend)(v, @selector(returnKeyType));
    NSInteger action;
    switch (returnKey) {
        case UIReturnKeyDone: action = 1; break;
        case UIReturnKeyGo: action = 2; break;
        case UIReturnKeySend: action = 3; break;
        case UIReturnKeySearch: action = 4; break;
        case UIReturnKeyNext: action = 5; break;
        case UIReturnKeyContinue: action = 6; break;
        case UIReturnKeyJoin: action = 7; break;
        case UIReturnKeyRoute: action = 8; break;
        case UIReturnKeyEmergencyCall: action = 9; break;
        default: return NO;
    }
    int client = ((int (*)(id, SEL))objc_msgSend)(v, @selector(textInputClient));
    ((void (*)(id, SEL, id, NSInteger, int))objc_msgSend)(delegate, perform, v, action, client);
    return YES;
}

BOOL FTPressEnterOnComposeFirstResponder(void) {
    for (UIView *v in ftTextReceivers()) {
        if (!v.isFirstResponder) continue;
        if ([v isKindOfClass:[UITextField class]]) {
            // UITextField への insertText:@"\n" は改行が文字として入るだけで return を発火しない。
            // xcuitest への 409 フォールバックも使えない(フォーカスを立てたのは in-app の合成タッチで、
            // XCUITest からは keyboard focus を持つ要素として見えず typeText が無言 no-op になる)。
            // そこで UIKit が Return で行うこと自体を再現する: delegate の textFieldShouldReturn: と
            // EditingDidEndOnExit(SwiftUI の onSubmit もこの経路)
            UITextField *field = (UITextField *)v;
            id<UITextFieldDelegate> delegate = field.delegate;
            if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                [delegate textFieldShouldReturn:field];
            }
            [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
            return YES;
        }
        // secure 欄はサブクラス(別名)なので prefix 一致では取りこぼす(ftIsFlutterTextInput 参照)
        if (ftIsFlutterTextInput(v)) {
            return ftFlutterPerformInputAction(v);
        }
        if ([v conformsToProtocol:@protocol(UIKeyInput)]) {
            [(id<UIKeyInput>)v insertText:@"\n"];
        } else {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(v, @selector(insertText:), @"\n");
        }
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

void FTEnsureFlutterSemantics(void) {
    Class flutterVCClass = NSClassFromString(@"FlutterViewController");
    if (!flutterVCClass) return;  // Flutter アプリではない
    // rootViewController から VC ツリーを浅く辿って FlutterViewController を探す
    // (presented / child まで。Flutter アプリは通常 root がそのまま FlutterViewController)
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.rootViewController) [queue addObject:w.rootViewController];
    }
    while (queue.count > 0) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([vc isKindOfClass:flutterVCClass] && [vc respondsToSelector:@selector(engine)]) {
            id engine = ((id (*)(id, SEL))objc_msgSend)(vc, @selector(engine));
            if ([engine respondsToSelector:@selector(ensureSemanticsEnabled)]) {
                ((void (*)(id, SEL))objc_msgSend)(engine, @selector(ensureSemanticsEnabled));
            }
            return;
        }
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
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
