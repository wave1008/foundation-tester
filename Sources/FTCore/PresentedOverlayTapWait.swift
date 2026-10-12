// 本物の指と同じ経路(XCUITest)で、表示の切り替え(RN の Modal の fade)の最中に届いた tap は UIKit に捨てられて飲まれる
// (in-app は合成タッチを窓へ直接送るので起きない)。出てきたばかりのダイアログ・シートの中の要素を押す前だけ、
// 切り替えが終わる長さを待つ。**打ち直さない**(画面を変えないのが正しいボタンで二重に押した = 実験の「交互にダイアログ」)・
// **画素を撮らない**(負荷)。実測と範囲の根拠は docs/framework-differences.md §2.1
public enum PresentedOverlayTapWait {

    /// 切り替えの長さ(秒)。実測: React Native 0.86 の Modal(fade = `UIModalTransitionStyleCrossDissolve`。RN は長さを
    /// 指定せず UIKit の既定)を開く描画が iOS 27 Simulator で 516〜517ms(描画プローブ・5 回)。約 30ms の余裕を足した。
    /// 尽きた(待っても飲まれた)ときは、続く確認の失敗文言の「飲まれた tap」の注記がそう言う
    public static let transitionSeconds = 0.55

    /// 木が画面の一部しか覆っていない(ダイアログ・シートが前面)とみなす空きの割合(`TreeCoverage.unrepresentedScreenFraction`)。
    /// 固定コーパス(Tests/Fixtures の 62 枚): ダイアログ 0.41(and-dialog_confirm)・RN の Modal 0.46・普通の画面は最大 0.17。
    /// 疎な画面とキーボードの画面(0.36〜0.38)も当たるが、払うのは下の条件をすべて満たした tap の待ちだけ
    public static let overlayUncoveredFraction = 0.3

    /// 押す前に待つか。**React Native だけ**(ユーザー決定。他のフレームワークは飲まれる witness が無い)。
    /// `previousTapTree` は直前の tap が解決に使った木(撃つ前)。無ければ「出てきたばかり」と言えないので待たない
    public static func shouldWait(framework: AppUIFramework?, tapsWithSystemTouch: Bool, target: ElementInfo,
                                  previousTapTree: [ElementInfo]?, current: SnapshotResponse) -> Bool {
        guard tapsWithSystemTouch, framework == .reactNative, let previousTapTree else { return false }
        guard !previousTapTree.contains(where: { sameElement($0, target) }) else { return false }
        return TreeCoverage.unrepresentedScreenFraction(current) >= overlayUncoveredFraction
    }

    /// 同じ要素か: identifier があればそれ、無ければ型とラベル(ref は木ごとに振り直される・枠は切り替えで動く)
    static func sameElement(_ a: ElementInfo, _ b: ElementInfo) -> Bool {
        if let id = b.identifier, !id.isEmpty { return a.identifier == id }
        return (a.identifier ?? "").isEmpty && a.type == b.type && a.label == b.label
    }
}
