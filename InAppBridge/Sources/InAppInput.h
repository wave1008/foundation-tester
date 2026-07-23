// プロセス内タッチ合成・テキスト入力の C 関数(Swift から bridging header 経由で呼ぶ)。
// UITouch/UITouchesEvent の合成に private セレクタを使う(Xcode 27 beta 3 で実在確認済み)。
// EarlGrey/KIF がシミュレータで長年使う経路。実機では別経路(XCUITest ランナー)を使う。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// point(window 座標)に単発タップを合成する(down→up)。hitTest でヒットした view へ届く。
void FTSynthTap(UIWindow *window, CGPoint point);

/// from→to(window 座標)へスワイプを合成する(down→moved×steps→up)。steps<1 は既定 10。
void FTSynthSwipe(UIWindow *window, CGPoint from, CGPoint to, int steps);

/// point で down 後、duration 秒ランループを回して(長押しタイマ発火のため)up する。
void FTSynthPress(UIWindow *window, CGPoint point, double duration);

/// 現在の first responder が UIKeyInput なら text を挿入する。挿入できたら YES。
BOOL FTInsertTextIntoFirstResponder(NSString *text);

/// type 失敗(409)時の診断: first responder の実クラスと入力プロトコル対応状況
NSString *FTFirstResponderDiagnostics(void);

/// アクセシビリティを自動化用に活性化する(_AXSSetAutomationEnabled)。これをしないと
/// SwiftUI の AX ツリーが materialize されず、accessibilityFrame が zero・label が空になる
/// (XCUITest は起動時にこれを行っている)。起動時に1回呼ぶ。失敗は非致命。
void FTActivateAccessibility(void);

/// Flutter アプリで platform 側の a11y ブリッジ(SemanticsObject 群)を強制生成する。
/// _AXSSetAutomationEnabled は Flutter engine には効かず、これを呼ばないと
/// FlutterView.accessibilityElements が空のまま = snapshot が 0 要素になる。
/// FlutterEngine.ensureSemanticsEnabled(公開 API)を動的に呼ぶ。非 Flutter アプリでは no-op。
/// 冪等。メインスレッドから呼ぶこと。
void FTEnsureFlutterSemantics(void);

/// node の accessibilityIdentifier を返す(セレクタ応答時のみ)。SwiftUI の AccessibilityNode /
/// UIKitTextField は UIAccessibilityIdentification 準拠を宣言しないため Swift の as? では取れず、
/// セレクタ直接呼び出しが要る。空文字は nil を返す。
NSString * _Nullable FTAccessibilityIdentifier(id node);

NS_ASSUME_NONNULL_END
