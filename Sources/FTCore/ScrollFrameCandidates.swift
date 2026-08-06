// ScrollFrameCandidates.swift
// 画面上の「`scrollFrame:` に指定できる領域」を列挙する純ロジック。
// **デバイスを必要としない**ので境界は単体テストで固定する(ScrollGeometry と同じ規律)。
//
// 判定に使えるのは **`scrollable == true` を見つけたときだけ**。申告できないエンジン
// (Compose/Flutter の in-app)では全要素が nil になるので、そこで「候補なし」と言うと嘘になる。
// StepExecutor.scrollFrameNote と同じ規律 —— **1つも true が無い画面では黙る**。

import Foundation

public enum ScrollFrameCandidates {

    /// スクロール容器1つ。`selector` が nil = **名指しできない**(id もラベルも無い)ので
    /// `scrollFrame:` には書けない。呼び出し側はその事実を出す(黙って別の書き方を勧めない)
    public struct Candidate: Sendable {
        public let ref: Int
        /// 画面と交差させた後の矩形(表示されている範囲)
        public let visible: FTRect
        public let selector: String?

        public init(ref: Int, visible: FTRect, selector: String?) {
            self.ref = ref
            self.visible = visible
            self.selector = selector
        }
    }

    /// ラベルをセレクタに使う上限。**切り詰めたら別のセレクタになる**ので、長いラベルは
    /// 名指しできない扱いに倒す(表示用の truncate と混同しないこと)
    static let maxLabelLength = 40

    /// この画面のスクロール容器。**申告が1つも無ければ空**(= 候補なしではなく「分からない」)。
    /// 木の順(pre-order)を保つので、先に出たものほど外側の容器
    public static func candidates(in snapshot: SnapshotResponse) -> [Candidate] {
        var result: [Candidate] = []
        var seenFrames = Set<String>()
        for element in snapshot.elements where element.scrollable == true {
            guard let visible = ScrollGeometry.intersection(element.frame, snapshot.screen) else {
                continue
            }
            // 同じ矩形の入れ子(Android は容器と中身の両方が isScrollable を立てることがある)は
            // 1つに畳む。**名指しできる方を残す** —— 先に出た方が外側だが、id を持つのは中身側
            let key = frameKey(visible)
            if seenFrames.contains(key) {
                if let index = result.firstIndex(where: { frameKey($0.visible) == key }),
                   result[index].selector == nil, let selector = selector(for: element) {
                    result[index] = Candidate(ref: element.ref, visible: visible, selector: selector)
                }
                continue
            }
            seenFrames.insert(key)
            result.append(Candidate(ref: element.ref, visible: visible,
                                    selector: selector(for: element)))
        }
        return result
    }

    /// `ft_snapshot` の先頭に出す注記。**2つ以上あるときだけ**返す(1つしか無い画面で
    /// `scrollFrame:` を勧めると、iOS in-app では XCUITest フォールバックを払うだけになる)。
    /// 申告できないエンジンでは候補が空になり、ここも nil = 黙る
    public static func note(_ snapshot: SnapshotResponse) -> String? {
        let found = candidates(in: snapshot)
        guard found.count >= 2 else { return nil }
        let listed = found.prefix(4).map(describe).joined(separator: " / ")
        let more = found.count > 4 ? " (+\(found.count - 4) more)" : ""
        return "note: \(found.count) scroll areas on screen: \(listed)\(more)."
            + " Pass scrollFrame: to ft_scroll_to to search inside one of them.\n"
    }

    /// 矩形から**書けるセレクタ**を引く(飛び越しの注記で「どれを指定すればよいか」を名指しする)。
    /// 名指しできる候補が無い / どれとも十分に重ならなければ nil = 呼び出し側は総称の文言のまま。
    /// **重なりは IoU** —— 包含で採ると画面いっぱいの外側容器がいつでも当たってしまう
    public static func selector(matching rect: FTRect, in snapshot: SnapshotResponse,
                                minOverlap: Double = 0.5) -> String? {
        var best: (selector: String, score: Double)?
        for candidate in candidates(in: snapshot) {
            guard let selector = candidate.selector else { continue }
            let score = intersectionOverUnion(candidate.visible, rect)
            guard score >= minOverlap else { continue }
            if best == nil || score > best!.score { best = (selector, score) }
        }
        return best?.selector
    }

    static func describe(_ candidate: Candidate) -> String {
        if let selector = candidate.selector { return selector }
        let f = candidate.visible
        return "(\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)) — no id)"
    }

    /// `scrollFrame:` にそのまま貼れる形。id が最優先(ラベルは容器では珍しく、
    /// 長いものは切り詰めると別物になるので採らない)
    static func selector(for element: ElementInfo) -> String? {
        if let id = element.identifier, !id.isEmpty { return "#\(id)" }
        if let label = element.label, !label.isEmpty, label.count <= maxLabelLength,
           !label.contains("\"") {
            return "\"\(label)\""
        }
        return nil
    }

    static func frameKey(_ rect: FTRect) -> String {
        "\(Int(rect.x)),\(Int(rect.y)),\(Int(rect.width)),\(Int(rect.height))"
    }

    static func intersectionOverUnion(_ a: FTRect, _ b: FTRect) -> Double {
        guard let overlap = ScrollGeometry.intersection(a, b) else { return 0 }
        let intersection = overlap.width * overlap.height
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
