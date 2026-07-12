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

/// アクセシビリティを自動化用に活性化する(_AXSSetAutomationEnabled)。これをしないと
/// SwiftUI の AX ツリーが materialize されず、accessibilityFrame が zero・label が空になる
/// (XCUITest は起動時にこれを行っている)。起動時に1回呼ぶ。失敗は非致命。
void FTActivateAccessibility(void);

NS_ASSUME_NONNULL_END
