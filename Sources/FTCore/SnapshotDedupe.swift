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
// Runner/FleetestRunnerUITests/BridgeRouter.swift の collect。

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
                  candidate.value == nil || candidate.value == earlier.value,
                  // scrollable を足す candidate は、earlier が id 持ち(= wrapperScrollMerge が
                  // 後で統合する RN のラッパー形)のときだけ残す。匿名どうしの同枠 scroll 双子は
                  // 従来どおり畳む(広く残すと既存 SUT の序数と間引き枠がずれる)
                  !(candidate.scrollable == true && earlier.scrollable != true
                        && earlier.identifier != nil)
            else { return false }
            return nearlyEqual(earlier.frame, candidate.frame)
        }
    }

    static func nearlyEqual(_ a: FTRect, _ b: FTRect) -> Bool {
        abs(a.x - b.x) <= frameTolerance && abs(a.y - b.y) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance
            && abs(a.height - b.height) <= frameTolerance
    }

    /// RN の ScrollView/FlatList は testID がラッパー(RCTScrollView)に付き、実際にスクロールする
    /// 内側ノードは別要素として出る(2026-08-08 実測、iOS xcuitest/in-app 双方)。
    /// id 付き非スクロール要素(A)と、**直後に続く**同じ frame の匿名スクロール要素(B)を1つに畳む。
    /// 隣接(pre-order で B が A の次)を条件にするのは、離れた位置の同枠一致
    /// (全画面 ScrollView に同寸の id 付きオーバーレイが重なる等)を誤結合しないため。
    /// RN のラッパー分離は常にこの隣接形で出る(実測)。
    public static func wrapperScrollMerge(_ elements: [ElementInfo]) -> [ElementInfo] {
        var result = elements
        var indicesToRemove = Set<Int>()
        for aIndex in result.indices.dropLast() {
            let a = result[aIndex]
            guard a.identifier != nil, a.scrollable != true else { continue }
            let bIndex = result.index(after: aIndex)
            guard !indicesToRemove.contains(bIndex) else { continue }
            let b = result[bIndex]
            guard b.identifier == nil, b.label == nil, b.value == nil,
                  b.scrollable == true, nearlyEqual(a.frame, b.frame) else { continue }
            result[aIndex].scrollable = true
            if result[aIndex].type == "other" && b.type != "other" {
                result[aIndex].type = b.type
            }
            indicesToRemove.insert(bIndex)
        }
        return result.enumerated().compactMap { indicesToRemove.contains($0.offset) ? nil : $0.element }
    }

    /// RN(Android)の Pressable は accessible でも子の Text が別ノードで出て、button と同ラベルの
    /// staticText が並ぶ(2026-08-08 実測。ブリッジは a11y 非重要ビューも採るためアプリ側では隠せない)。
    /// 素のラベルセレクタが曖昧になり `.staticText[n]` の序数も水増しされるので、
    /// **直前の button に frame ごと内包される同ラベル・無 id の staticText** を落とす。
    /// View/XML の Button はテキスト内蔵(子ノード無し)・Compose は単一ノードなので既存 SUT では発火しない。
    public static func dropLabelTwinsInsideButtons(_ elements: [ElementInfo]) -> [ElementInfo] {
        var buttons: [ElementInfo] = []
        return elements.filter { element in
            if element.type == "button" || element.type == "Button" {
                buttons.append(element)
                return true
            }
            guard element.type == "staticText" || element.type == "StaticText",
                  element.identifier == nil, let label = element.label
            else { return true }
            let twin = buttons.contains { b in
                b.label == label && contains(b.frame, element.frame)
            }
            return !twin
        }
    }

    private static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        inner.x >= outer.x - frameTolerance && inner.y >= outer.y - frameTolerance
            && inner.x + inner.width <= outer.x + outer.width + frameTolerance
            && inner.y + inner.height <= outer.y + outer.height + frameTolerance
    }
}
