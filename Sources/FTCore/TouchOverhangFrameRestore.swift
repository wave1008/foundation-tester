// テキストの可視性検証の切り抜きに使う枠を、Compose が兄弟のタッチ範囲で削った分だけ戻す(純粋関数)。
//
// Compose はアクセシビリティの枠を「後から描かれる兄弟のタッチ範囲に覆われていない部分」にする
// (compose-multiplatform-core v1.12.1 `SemanticsOwner.kt` の getAllUncoveredSemanticsNodesToIntObjectMap →
// iOS は `Accessibility.ios.kt` の traverseChildren が adjustedBounds を枠にする)。一覧の上端で半分隠れた行の
// タッチ範囲は**一覧の上端を越えて**申告されるので、一覧の上に置いたテキストの下側が、画面では何も覆っていないのに
// 枠から削られる(E2EX-CMP の無限スクロール: 一覧の上端 214 に対し row_i_49 が 190〜216.7、結果のテキスト 182〜206 が
// 182〜190 の 8pt になり、文字の上半分だけの切り抜きを FM が別の文字と読んで誤反転した)。
// **木の枠そのものは変えない**(タップ・幾何の判定は従来どおり)。戻すのは切り抜きの範囲だけで、上限はその行の
// スクロール容器の上端 = 一覧はそこで中身を切るので、その上に一覧の中身は描かれない。

public enum TouchOverhangFrameRestore {
    /// 端の一致の許容(pt)。木の座標は 3x の画素(1/3pt)刻みで、別々に丸められた2つの値は最大 1/3pt ずれる
    static let edgeTolerancePt: Double = 0.5

    /// 削られた形なら戻した枠、そうでなければ nil。条件は全部:
    /// ①対象の下端に、横に重なる要素の上端が(許容内で)接している ②対象の下端はその要素のスクロール容器の上端より上
    /// (= 対象は容器の上に居て、①と合わせてその要素は容器の上端より上へはみ出している)。
    /// 観測したのは上端の形だけ(下端・横は未観測なので扱わない)
    public static func restoredFrame(for target: ElementInfo, in elements: [ElementInfo]) -> FTRect? {
        let t = target.frame
        let bottom = t.y + t.height
        for other in elements where other.ref != target.ref {
            let o = other.frame
            guard abs(o.y - bottom) <= edgeTolerancePt,
                  o.x < t.x + t.width, o.x + o.width > t.x,
                  let container = ContainerGeometry.clippingContainer(of: other, in: elements),
                  bottom < container.y - edgeTolerancePt,
                  t.y < container.y
            else { continue }
            return FTRect(x: t.x, y: t.y, width: t.width, height: container.y - t.y)
        }
        return nil
    }
}
