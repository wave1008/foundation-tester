// 要素上限で木が切り詰められたときの**判定と逃げ道**。MCP と DSL の唯一の定義元。
//
// なぜ判定を共有するか(2026-08-15): 打ち切りの注記は3箇所に別々に書かれていて、
// **DSL だけが「対象に近づくようスクロールする」と勧めていた**。MCP は同じ事実に対して
// 「スクロールしても戻ってこない」と書いており、同じ画面で逆のことを言う状態になっていた
// (しかも MCP 側のコメントは「文言だけ揃えて複製する」と書いてあり、実際は揃っていなかった)。
//
// **落ちた要素はスクロールでは戻らない**: 打ち切りは配列そのものからの脱落であって描画の
// 省略ではない。スクロールで変わるのは「画面にどの要素があるか」であって、上限に当たった木の
// 中身が増えるわけではない。有効な手は2つだけ —— **上限を上げる**か、**画面を狭くする**
// (シートを閉じる・大きなリストを畳む・スコープを絞る)。
//
// **文言は呼び手ごとに持つ**(docs/design.md の規律): MCP は `ft_snapshot maxElements:` と
// 書き、DSL は `.webView >> ...` / `scrollFrame:` と書く。ここが決めるのは
// 「どちらの手が残っているか」だけ。

import Foundation

public enum SnapshotTruncation {

    /// 残っている手。**上限に余地があるかどうかで排他**
    public enum Remedy: Sendable, Equatable {
        /// まだ上限を上げられる(`to` まで上げれば落ちた分がちょうど入る)
        case raiseLimit(to: Int)
        /// すでに天井で読んでいる = 上限では解決しない。画面を狭くするしかない
        case narrowTheScreen
    }

    /// **予算を使った件数**(= `elements.count` から bulk 群を引いたもの)。
    ///
    /// **`elements.count` をそのまま上限と比べてはいけない**(2026-08-15 のレビューで発見):
    /// bulk 群(同一 id ×20 以上の非操作の葉)は**予算の外で送られる**ので
    /// (`BridgeAPI` の版 61。安全弁 `bulkExemptCeiling` は 400)、`elements.count` は
    /// 上限 + 最大 400 まで膨らむ。既定 120 で読んだ木に bulk が 280 件乗っただけで
    /// 「もう天井だ」と誤判定し、**上げれば取れる要素に「上げても無駄」と言う**。
    ///
    /// **bulk 群の件数は申告(`bulkExemptCount`)を信用せず、最終配列から数え直す**
    /// (2026-08-15 のレビューで発見。分類器は予算計算の唯一の定義元
    /// `BridgeSnapshotThinning.bulkExemptCount` を再適用するだけで、規則をここへ複製しない):
    /// 申告と配列がずれる生産者が2つある。①in-app の WebView-DOM マージ
    /// (`InAppBridge.mergeWebViewDOM`)はマージ後の集合で bulk 免除を**やり直す**のに、
    /// 返す `bulkExempt` はマージ前(native 単独)の値のまま —— マージで bulk 群が増えると
    /// 申告が実際より小さくなり、`budgetedCount` が**過大**になる(上げれば取れる要素に
    /// 「もう天井だ」と言う偽陽性)。②Safari のホスト側 DOM 注入
    /// (`BridgeClient.injectSafariDOMIfApplicable`)は webView 部分木を落として DOM 要素を
    /// 無制限に足すが `bulkExemptCount` を一切更新しない —— 落とした部分木に native の bulk 群が
    /// 含まれていると申告が配列より大きいまま残り、`elements.count - 申告` が負に振れる
    /// (**過少**方向。旧実装ではここで `max(0,)` の保険が実際に発動していた)。
    /// 最終配列そのものから数え直せば、どちらの生産者でも実配列と一致する
    ///
    /// **申告が nil(旧ブリッジ・Android)のときは数え直さない**: これらは bulk 免除の概念を
    /// 持たず、同一 id ×20 以上の群があっても**予算を消費して**送っている。分類器を当てると
    /// 「免除されている」扱いにしてしまい過少カウントになる。nil は「このブリッジは bulk を
    /// 免除しない」という申告として読み、従来どおり `elements.count` をそのまま使う
    ///
    /// `max(0,)` は残すが、**数え直した bulk 件数は必ず `elements.count` の部分集合**
    /// (`BridgeSnapshotThinning.bulkExemptCount` は同じ配列をフィルタするだけ)なので、
    /// この経路では数学的に到達しない。旧実装は「申告が正しい」という前提が崩れて
    /// 実際に到達していた(②)。到達しないので変異テストでは殺せない
    ///
    /// **表示も判定もこの `budgetedCount` と `bulkExemptPresentCount` の2つから組み立てる**
    /// (2026-08-15 のレビューで発見) —— 呼び手が切り詰めの文脈で `snapshot.elements.count` を
    /// 直接印字すると、bulk が乗った木では「truncated at 420 elements」のように、勧める上限
    /// (予算ぶんの120基準)より大きい数字を出して読み手に矛盾として映る
    public static func budgetedCount(_ snapshot: SnapshotResponse) -> Int {
        max(0, snapshot.elements.count - bulkExemptPresentCount(snapshot))
    }

    /// bulk 免除群の実数(申告 nil なら0)。`budgetedCount` が使う分類器の数え直しを
    /// 呼び手からも直接引けるようにする口 —— **表示に bulk の内訳を添えるときはここを呼ぶ**
    /// (budgetedCount 側で二重に分類器を呼ばないよう、budgetedCount はこれを経由する)
    public static func bulkExemptPresentCount(_ snapshot: SnapshotResponse) -> Int {
        guard snapshot.bulkExemptCount != nil else { return 0 }
        let candidates = snapshot.elements.map { BridgeSnapshotThinning.Candidate(info: $0) }
        return BridgeSnapshotThinning.bulkExemptCount(candidates)
    }

    /// この木は天井で読まれたか。**上限で切り詰められた木の予算ぶんの件数は上限そのもの**なので、
    /// 予算ぶんが天井以上なら `max=天井` で読んだ回だと判る
    public static func isAtCeiling(_ snapshot: SnapshotResponse) -> Bool {
        budgetedCount(snapshot) >= BridgeAPI.maxSnapshotElementsCeiling
    }

    /// 打ち切られた木に勧める要素上限。**落ちた分がちょうど入る値**を出し、刻みの良い値へ
    /// 切り上げる(次の1回で足りずにもう一度払うのを避けるため)。天井で頭打ち。
    /// **必要量も予算ぶんで数える** —— bulk を混ぜると、次の読みでも予算の外へ出る分を
    /// 予算として要求することになり、必要より大きな値を勧める
    public static func suggestedLimit(_ snapshot: SnapshotResponse) -> Int {
        let needed = budgetedCount(snapshot) + snapshot.truncatedCount
        let rounded = (needed + 49) / 50 * 50
        return min(max(rounded, BridgeAPI.maxSnapshotElements), BridgeAPI.maxSnapshotElementsCeiling)
    }

    /// 切り詰められていなければ nil。**呼び手はこれを文言へ写すだけ**にする。
    ///
    /// 分岐は `isAtCeiling` だけ。「勧める値が現在の件数を超えない」を追加条件にしたくなるが、
    /// **その形は天井に達しているときにしか起きない**(勧める値は必ず件数+落ちた分以上へ
    /// 切り上がる)ので、`isAtCeiling` に吸収される —— 到達しない分岐はテストできないので置かない
    public static func remedy(for snapshot: SnapshotResponse) -> Remedy? {
        guard snapshot.truncatedCount > 0 else { return nil }
        // **天井で読んでいるなら上限では解決しない**。言われたとおり上げても同じ木が返るのが最悪
        if isAtCeiling(snapshot) { return .narrowTheScreen }
        return .raiseLimit(to: suggestedLimit(snapshot))
    }
}
