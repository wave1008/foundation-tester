// スナップショットに同じ物が2度並ぶのを落とす規則。
//
// iOS の AX ツリーはラッパと実体を両方出すことがある(2026-08-06 に Simulator 上で実測):
//   - UIKit の Switch が `id=sw_notify 61x28` と `(id 無し) 63x28` の2ノード
//   - UIAlertController の `#btn_dialog_ok` / `#btn_dialog_cancel` が同一 frame で各2つ
//   - キーボードの `#dictation` が2つ
// **Android のブリッジは同じ画面を1つで返す**ので、これは iOS 側だけの見え方の差だった。
//
// 実害は2つ: `.button[n]` の序数が実際の見え方とずれる / 同じ id が複数候補になる。
//
// 判定を FTCore に置くのは**単体テストで固めるため**(Runner は SPM のターゲットではなく、
// BridgeContractTests の指紋しか掛からない)。呼び出し側は
// Runner/FTesterRunnerUITests/BridgeRouter.swift の collect。

public enum SnapshotDedupe {

    /// 同じ位置とみなす許容(pt)。**2**: UIKit の Switch はラッパと実体で幅が 2pt ずれる(実測)。
    /// これ以上広げると、隣接する小さなアイコンどうしが同一視され始める
    public static let frameTolerance: Double = 2.0

    /// `candidate` は、既に採った要素のどれかと**同じ物**か。
    ///
    /// 落としてよい条件は3つとも成り立つときだけ:
    ///   1. 型が同じ(容器と中身 = Other と Button は今までどおり両方残す)
    ///   2. 位置がほぼ同じ
    ///   3. **情報を足していない**(id・ラベル・value を新しく持たない)
    ///
    /// 3 が要る: 外側が無名で内側が名前を持つ形があり、そこで内側を落とすと**指せなくなる**。
    /// 逆に「外側が名前を持ち内側が無名」は内側を落としてよい(同じ物の別表現)。
    ///
    /// ラベルが違えば別物として残す —— スクロールで同じ矩形へクランプされた行
    /// (`行 09`〜`行 40` が全部 `行 01` の位置に畳まれる形)を**畳んで消さない**ため。
    /// あれは「重複」ではなく「描かれていない残骸」で、扱いは MCP の stackedRefs 側の警告。
    public static func isRedundant(_ candidate: ElementInfo,
                                   alreadyEmitted: [ElementInfo]) -> Bool {
        alreadyEmitted.contains { earlier in
            guard earlier.type == candidate.type,
                  candidate.identifier == nil || candidate.identifier == earlier.identifier,
                  candidate.label == nil || candidate.label == earlier.label,
                  candidate.value == nil || candidate.value == earlier.value
            else { return false }
            return nearlyEqual(earlier.frame, candidate.frame)
        }
    }

    static func nearlyEqual(_ a: FTRect, _ b: FTRect) -> Bool {
        abs(a.x - b.x) <= frameTolerance && abs(a.y - b.y) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance
            && abs(a.height - b.height) <= frameTolerance
    }
}
