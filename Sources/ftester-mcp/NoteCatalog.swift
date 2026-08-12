// 木だけから決まる注記の目録。**ここが唯一の定義元**で、snapshotBody / scrollTo は並べるだけ。
//
// なぜ目録が要るか(2026-08-12):
// - **発火を数えられるようにする** —— どの注記がどの画面で出るかを NoteCoverageTests が
//   固定コーパスの全数で数える。目録に載っていない注記は測れないので、「地図でだけ効く注記」と
//   「どのアプリでも効く注記」が同じ棚に並んだまま増える(実際そうなっていた)
// - **鍵ごとに黙らせて A/B できるようにする** —— `FT_MCP_NOTES_OFF=<鍵,…|all>`。
//   Scripts/mcp-bench.sh がこれで「その注記があるとエージェントの手数が減るか」を測る。
//   **減らない注記を消す根拠はこれ以外に作れない**(注記は足す力しか働かず、単調に増える)
//
// **注記を足すときは必ずここへ足す**(応答の組み立て側へ直に書かない ——
// NoteCoverageTests.testSnapshotBodyEmitsOnlyCatalogNotes がソース走査で検出する)。
//
// 載せる範囲は**木だけから決まる注記**に限る: 画面のすり替わり・背面判定・待ちの経過など
// driver やセッション状態が要るものは、コーパスの静的な木では再現できないので対象外。
// 応答の量を決めているのは前者(毎回すべての木に対して評価される)なので、測る価値もそこにある。

import Foundation
import FTCore

enum NoteCatalog {

    /// 注記が載る応答の種類。**同じ目録を文脈で絞る**ことで、ft_snapshot と ft_scroll_to で
    /// 出る注記が違うという事実を目録の上で見えるようにする(以前は2箇所の並びを読み比べる
    /// しかなかった)
    enum Context {
        case snapshot
        case scrollTo
    }

    /// 注記1本を作るのに要る材料。`cache` は応答1回ぶんの共有キャッシュ
    /// (SnapshotAnnotationCache の宣言参照。snapshot を跨いで渡さない)
    struct Input {
        let snapshot: SnapshotResponse
        let collapsingBulk: Bool
        let cache: MCPServer.SnapshotAnnotationCache

        init(snapshot: SnapshotResponse, collapsingBulk: Bool = true,
             cache: MCPServer.SnapshotAnnotationCache? = nil) {
            self.snapshot = snapshot
            self.collapsingBulk = collapsingBulk
            self.cache = cache ?? MCPServer.SnapshotAnnotationCache()
        }
    }

    struct Entry {
        /// 安定した鍵。**`once`/`onceNonEmpty` の鍵と同じ名前空間**(短縮の状態を共有する)なので、
        /// 既存の鍵を持つ注記は同じ文字列を使うこと(変えると短縮の履歴が切れる)
        let key: String
        /// この注記が載る応答
        let contexts: Set<Context>
        /// 初回だけ満額・2回目以降は短縮(`onceNonEmpty` を通す)か、毎回同じ文か
        let abbreviates: Bool
        /// 本体。`abbreviated` は短縮形を出すかどうか
        let render: (Input, _ abbreviated: Bool) -> String
    }

    /// **並び順がそのまま応答の並び順**。入れ替えると読み手の目に入る順番が変わるので、
    /// 位置に意味があるものはここにコメントを残すこと
    static let snapshotNotes: [Entry] = [
        // 遮蔽・ghost は「下の一覧をそのまま信じてよいか」なので最初に置く
        Entry(key: "ghostNote", contexts: [.snapshot, .scrollTo], abbreviates: false) { input, _ in
            MCPServer.ghostNote(input.snapshot, collapsingBulk: input.collapsingBulk,
                                cache: input.cache)
        },
        // scrollFrame 候補は ft_scroll_to では別に組み立てる(渡された引数で文面が変わるため)
        Entry(key: "scrollFrameCandidates", contexts: [.snapshot], abbreviates: false) { input, _ in
            ScrollFrameCandidates.note(input.snapshot) ?? ""
        },
        Entry(key: "truncationNote", contexts: [.snapshot, .scrollTo], abbreviates: false) { input, _ in
            MCPServer.truncationNote(input.snapshot)
        },
        Entry(key: "bulkExemptNote", contexts: [.snapshot], abbreviates: true) { input, abbreviated in
            MCPServer.bulkExemptNote(input.snapshot, abbreviated: abbreviated)
        },
        // 「この一覧は画面の全部か」を問う注記なので、遮蔽・打ち切りの隣(上流)に置く
        Entry(key: "webViewGapNote", contexts: [.snapshot, .scrollTo], abbreviates: false) { input, _ in
            MCPServer.webViewGapNote(input.snapshot)
        },
        Entry(key: "unlabeledClickablesNote", contexts: [.snapshot], abbreviates: true) { input, abbreviated in
            MCPServer.unlabeledClickablesNote(input.snapshot, abbreviated: abbreviated)
        },
        Entry(key: "urlishLabelsNote", contexts: [.snapshot], abbreviates: true) { input, abbreviated in
            MCPServer.urlishLabelsNote(input.snapshot, abbreviated: abbreviated)
        },
        Entry(key: "ambiguousLabelsNote", contexts: [.snapshot], abbreviates: true) { input, abbreviated in
            MCPServer.ambiguousLabelsNote(input.snapshot, abbreviated: abbreviated, cache: input.cache)
        },
        // ラベル版の直後に置く(読み手はどちらも「一意に指せるか」を見に来る)
        Entry(key: "duplicateIDsNote", contexts: [.snapshot], abbreviates: true) { input, abbreviated in
            MCPServer.duplicateIDsNote(input.snapshot, abbreviated: abbreviated, cache: input.cache)
        },
        Entry(key: "keyboardCoverageNote", contexts: [.snapshot, .scrollTo], abbreviates: false) { input, _ in
            MCPServer.keyboardCoverageNote(input.snapshot)
        },
        Entry(key: "sliverNote", contexts: [.snapshot, .scrollTo], abbreviates: false) { input, _ in
            MCPServer.sliverNote(input.snapshot)
        },
        Entry(key: "truncatedLabelNote", contexts: [.snapshot, .scrollTo], abbreviates: true) { input, abbreviated in
            abbreviated
                ? "note: long labels are shown cut off with \"…\" — match with"
                    + " \"*prefix*\" (see the first snapshot's note).\n"
                : SnapshotRenderer.truncatedLabelNote(input.snapshot) ?? ""
        },
    ]

    static func entries(for context: Context) -> [Entry] {
        snapshotNotes.filter { $0.contexts.contains(context) }
    }

    // MARK: - 黙らせる指定(A/B 用)

    /// `FT_MCP_NOTES_OFF` の解釈。カンマ/空白区切りの鍵、または `all`。
    /// **純関数**(env は下の `disabled` が1回だけ読む) —— 指定の形はテストで固定する
    static func disabledKeys(from raw: String?) -> Set<String> {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let tokens = raw.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if tokens.contains("all") { return Set(snapshotNotes.map(\.key)) }
        return Set(tokens)
    }

    /// プロセスの寿命で固定(途中で変わると同じセッションの応答が不揃いになる)
    static let disabled = disabledKeys(from: ProcessInfo.processInfo.environment["FT_MCP_NOTES_OFF"])

    /// 目録に無い鍵を指定された分。**黙って無視しない** —— 綴りを間違えたまま A/B を回すと
    /// 「その注記は効かなかった」という誤った結論が出る(実際には落ちていない)
    static func unknownDisabledKeys(_ keys: Set<String> = disabled) -> [String] {
        keys.subtracting(snapshotNotes.map(\.key)).sorted()
    }
}

extension MCPServer {

    /// 目録の注記を文脈ぶんだけ順に並べる。**snapshotBody と scrollTo の唯一の呼び口**。
    /// 短縮の判定(`onceNonEmpty`)はここで一括して掛ける — 個々の注記は自分が何度目かを知らない。
    /// `disabled` は差し替え口(既定 = env 由来。テストは自分の集合を渡して**この関数を通す** ——
    /// 判定を自前で書くと、黙らせが効かなくなる変異を検出できない)
    func catalogNotes(_ input: NoteCatalog.Input, context: NoteCatalog.Context,
                      disabled: Set<String> = NoteCatalog.disabled) -> String {
        NoteCatalog.entries(for: context).reduce(into: "") { out, entry in
            guard !disabled.contains(entry.key) else { return }
            out += entry.abbreviates
                ? onceNonEmpty(entry.key) { entry.render(input, $0) }
                : entry.render(input, false)
        }
    }
}
