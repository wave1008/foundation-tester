// SimilarLabels.swift
// 「セレクタが外れたときに近いラベル/id を挙げる」候補選定。MCP(similarLabelsHint)と
// DSL(StepExecutor+Resolve.candidateHint)が共有する唯一の定義元(2026-08-15、MCP から降ろした)。
//
// **文言はここでは組み立てない**: MCP の応答文言("note: similar labels on screen: …")は
// 既存の MCP テスト・NoteBudgetTests のバイト数ゲート対象で1文字も変えられない。
// ここは候補(要素・一致した経路・強さ・操作可能か)を返すところまでにし、
// 表示文字列の組み立ては呼び手(MCPServer / StepExecutor)がそれぞれ行う。

import Foundation

public enum SimilarLabels {

    /// 「近い」の強さ。**部分文字列関係(どちらかがどちらかを含む・大文字小文字無視)が強、
    /// 編集距離だけの一致(短い語同士・6文字以下・距離2以下)が弱**。
    public enum Strength { case strong, weak }

    public static func similarityStrength(_ a: String, _ b: String) -> Strength? {
        let la = a.lowercased(), lb = b.lowercased()
        guard la != lb else { return nil }
        if la.contains(lb) || lb.contains(la) { return .strong }
        guard la.count <= 6, lb.count <= 6 else { return nil }
        return Self.editDistance(la, lb) <= 2 ? .weak : nil
    }

    /// 「近い」の判定: ①どちらかがどちらかを部分文字列として含む(大文字小文字無視)
    /// ②短い文字列同士(6文字以下)なら編集距離2以下。②が無いと「経路」/「計画」のような
    /// 部分文字列関係の無い短い語の書き間違いを拾えない
    public static func isSimilarText(_ a: String, _ b: String) -> Bool {
        Self.similarityStrength(a, b) != nil
    }

    /// 素朴な編集距離(挿入・削除・置換を1コストずつ)。短い文字列(≤6)にしか使わない前提の
    /// O(n*m) 実装で十分 — 長い文字列にまで広げるならもっと速いものへ替える
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i]
            for j in 1...y.count {
                current.append(x[i - 1] == y[j - 1] ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1]))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    /// どちらの経路(ラベル/id)で一致したか。表示文字列の組み立ては呼び手が決める
    /// (MCP は `"label"` / `#id`、DSL は `type #id "label"` の複合名指しに使う)
    public enum Field { case label, id }

    public struct Candidate {
        public let element: ElementInfo
        public let field: Field
        /// 一致した表示用文字列。field=label ならゼロ幅を落とした表示テキスト、id ならそのまま
        public let matchedText: String
        public let strength: Strength
        public let operable: Bool
        /// 文書順(ties-break にのみ使う。呼び手には公開しない)
        let order: Int
    }

    private static func isBetter(_ a: Candidate, _ b: Candidate) -> Bool {
        if (a.strength == .strong) != (b.strength == .strong) { return a.strength == .strong }
        if a.operable != b.operable { return a.operable }
        return a.order < b.order
    }

    /// `labelTarget`/`idTarget` に近い要素を最大 `limit` 件、
    /// 「強い一致 > 操作可能 > 文書順」で返す(似ているというだけで断定はしない)。
    ///
    /// **装飾葉(bulk fold と同じ `SnapshotRenderer.isDecorativeLeaf` 判定)は候補プールから除く**
    /// —— 実測(2026-08-10、Apple マップ): 除かないと地図 POI のような装飾要素が短い CJK 語の
    /// 緩い編集距離一致で枠を埋め、実在した操作ボタンを1件も出せない(「南口」「北口」「1」が出て
    /// 「計画」が出ない)。
    ///
    /// **表示テキスト単位で重複を潰す**(同じラベル/id を複数要素が共有する画面で、同じ文字列を
    /// 何度も挙げない。同キーで複数要素が競合したら isBetter で勝った方だけ残す)。
    ///
    /// `labelTarget`/`idTarget` はそれぞれ独立(nil ならその経路は見ない)—— 呼び手が同じ文字列を
    /// 両方に渡せば MCP の「1つのターゲットを label/id 両方の経路で見る」形になり、
    /// 別々の文字列を渡せば DSL の「id ターゲットは id 欄だけ、label ターゲットは label 欄だけ」
    /// という狭い形になる。2つ目の判定は作らない —— 呼び手が引数で選ぶ
    public static func candidates(labelTarget: String?, idTarget: String?,
                                  in snapshot: SnapshotResponse, limit: Int = 3) -> [Candidate] {
        var best: [String: Candidate] = [:]
        func consider(_ candidate: Candidate, key: String) {
            if let existing = best[key], !isBetter(candidate, existing) { return }
            best[key] = candidate
        }
        for (order, element) in snapshot.elements.enumerated() {
            guard !SnapshotRenderer.isDecorativeLeaf(element, in: snapshot.elements) else { continue }
            let operable = BridgeSnapshotThinning.operableTypes.contains(element.type)
                || SnapshotRenderer.textInputTypes.contains(element.type)
            if let labelTarget, let label = element.label {
                let text = SnapshotRenderer.displayText(label)
                if !text.isEmpty, let strength = Self.similarityStrength(labelTarget, text) {
                    consider(Candidate(element: element, field: .label, matchedText: text,
                                       strength: strength, operable: operable, order: order), key: text)
                }
            }
            if let idTarget, let id = element.identifier, !id.isEmpty,
               let strength = Self.similarityStrength(idTarget, id) {
                consider(Candidate(element: element, field: .id, matchedText: id,
                                   strength: strength, operable: operable, order: order), key: "#" + id)
            }
        }
        return Array(best.values.sorted(by: isBetter).prefix(limit))
    }
}
