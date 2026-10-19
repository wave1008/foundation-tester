// KeyboardDismissPoint.swift
// iOS の hideKeyboard が叩く「何も起きない点」の候補(純粋関数。呼び手は StepExecutor.executeIOSHideKeyboard)。
// iOS にはキーボードを閉じる共通の手段が無い(Escape・resignFirstResponder・nil ターゲットの sendAction は Compose で
// 不発 = docs/shirates-parity.md)ので、人と同じく「入力欄の外を叩く」。閉じるかはアプリ次第で、閉じなければ呼び手が失敗にする。
//
// 探す範囲は**表示されているキーボードの上側の領域を下から上へ**(ユーザー決定。焦点のある欄を起点にする案は、
// Compose・Flutter が焦点を木に出さないので使えなかった)。行を下から上へ、各行は左から右へ見る。
// 「空き」= どの要素にも重ならない点か、**画面幅いっぱいの・操作できない入れ物だけ**に重なる点(葉 = 文字・画像には乗らない)。
// 幅で絞るのは、トーストやカードのような重なった入れ物の余白を「空き」と読まないため(叩くとトーストが消える・操作が起きる)。
// 木に出ない重ねウィンドウ(`overlays` = スナップショットの overlayWindowFrames)の上も除く。
// 候補は入れ物ごとに代表1点(最も下の点。同じ入れ物の背景は当たり判定でも同じ答えになる)。
// 木に載らないステータスバー・別のウィンドウ(トースト等)は、呼び手が叩く前にブリッジの当たり判定(`AppDriver.tapProbe`)で
// 確かめる。**木に載らない透明な押せる仕掛けは避けられない**(既知の限界。叩いた後に画面が変わったら呼び手が注記に出す)。

import Foundation

public enum KeyboardDismissPoint {
    public struct Choice: Sendable {
        public let x: Double
        public let y: Double
    }

    /// 叩くと何かが起きうる型。ブリッジの操作可能な型・入力欄・タップを受け止める型に加え、中身が木に出ない面(WebView・地図)
    static let unsafeTypes: Set<String> = BridgeSnapshotThinning.operableTypes
        .union(TapTargetGeometry.interactiveTypes)
        .union(["secureTextField", "searchField", "textView", "radioButton", "segmentedControl", "stepper",
                "picker", "pickerWheel", "toggle", "webView", "map", "keyboard", "key"])

    /// 走査の格子の目の数(画面の横幅の何分の1か)。画面の大きさに比例させる(固定の pt を置かない)
    static let gridColumns = 24

    public static func candidates(elements: [ElementInfo], screen: FTRect, keyboard: FTRect,
                                  overlays: [FTRect]) -> [Choice] {
        let top = screen.y
        let bottom = min(keyboard.y, screen.y + screen.height)
        guard bottom > top, screen.width > 0 else { return [] }
        let step = screen.width / Double(gridColumns)
        let xs = samples(from: screen.x, length: screen.width, step: step)
        var result: [Choice] = []
        var seenContainers: Set<Int> = []  // 入れ物の ref(どの要素にも重ならない点は -1)
        var y = bottom - step / 2
        while y > top {
            for x in xs {
                guard !overlays.contains(where: { contains($0, x: x, y: y) }),
                      let container = emptySpotContainer(x: x, y: y, elements: elements, screen: screen),
                      seenContainers.insert(container).inserted else { continue }
                result.append(Choice(x: x, y: y))
            }
            y -= step
        }
        return result
    }

    /// 区間の中の点。区間が刻みより狭ければ中央の1点
    static func samples(from start: Double, length: Double, step: Double) -> [Double] {
        guard length > step else { return [start + length / 2] }
        return Array(stride(from: start + step / 2, to: start + length, by: step))
    }

    /// その点が「空き」なら、点を含む最も深い入れ物の ref(代表を入れ物ごとに1点にする鍵。どの要素にも重ならない点 = -1)。
    /// **要素が1つも重ならない点も空き**(in-app の木は画面全体を覆う入れ物を持たないことが多い。叩く前に当たり判定で確かめる)
    static func emptySpotContainer(x: Double, y: Double, elements: [ElementInfo], screen: FTRect) -> Int? {
        let containing = elements.filter { contains($0.frame, x: x, y: y) }
        guard !containing.contains(where: { unsafeTypes.contains($0.type) || isLeaf($0, in: elements)
                  || !isScreenWide($0, screen: screen) }) else { return nil }
        return containing.max(by: { $0.depth < $1.depth })?.ref ?? -1
    }

    static func isScreenWide(_ element: ElementInfo, screen: FTRect) -> Bool {
        element.frame.x <= screen.x + 1 && element.frame.x + element.frame.width >= screen.x + screen.width - 1
    }

    /// 木の preorder + depth で、直後の要素が自分より深ければ子を持つ
    static func isLeaf(_ element: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return true }
        let next = elements.index(after: index)
        return next >= elements.endIndex || elements[next].depth <= element.depth
    }

    private static func contains(_ rect: FTRect, x: Double, y: Double) -> Bool {
        x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height
    }
}
