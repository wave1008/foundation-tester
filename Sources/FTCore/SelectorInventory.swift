// 「そのプロジェクトで実際に観測された `#id`」の台帳(`<プロジェクト>/.fleetest/selector-inventory.json`)。
//
// 目的は**シナリオ生成の誤りをデバイス実行の前に落とす**こと1点:
// セレクタの綴り誤り・でっち上げはコンパイルも構文検証も通り、実行して初めて「見つからない」になる。
// 探索フェーズで撮ったスナップショットの id を貯めておけば、dry-run が突き合わせて先に言える。
//
// 規律:
// - **書き手は MCP の `ft_snapshot` だけ**(シナリオを書くエージェントが必ず通る道)。
//   実行(run)の hot path では書かない —— スナップショット毎のファイル I/O を実行時間に載せない
// - **和集合で単調に増やす**(画面ごとに撮るので、消すと他画面の id が失われる)。
//   古い id が残っても**警告が減る方向**にしか効かないので誤検知は増えない
// - 判定は**完全一致の id だけ**。`#row_*` のようなワイルドカードとラベルは対象外
//   (ラベルは文言変更で普通に変わるため、警告にすると必ずオオカミ少年になる)
// - **台帳が無い/そのプラットフォームの記録が無いなら黙る**(「知らない」を「間違い」と言わない)

import Foundation

public struct SelectorInventory: Codable, Sendable {

    public struct PlatformEntry: Codable, Sendable {
        /// 最後に記録した時刻(警告文で「いつのスナップショットか」を示す)
        public var updatedAt: Date
        /// 記録回数(= ft_snapshot を撮った回数。台帳の厚みの目安)
        public var captures: Int
        /// 観測した id の和集合(ソート済み・重複なし)
        public var ids: [String]
    }

    /// 形式が変わったら +1(読めない版は無視して黙る = 誤検知を出さない)
    public static let currentVersion = 1
    /// 暴走防止の上限。超えたら**新しい id を足さない**(既存は消さない = 警告が増える方向へ倒れない)
    public static let maxIDs = 5000

    public var version: Int
    /// "ios" / "android" → 記録
    public var platforms: [String: PlatformEntry]

    public init(version: Int = SelectorInventory.currentVersion,
                platforms: [String: PlatformEntry] = [:]) {
        self.version = version
        self.platforms = platforms
    }

    /// 台帳の置き場所。ヒールキャッシュ(`.fleetest/heal-cache.json`)と同じディレクトリ
    public static func url(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".fleetest/selector-inventory.json")
    }

    public static func load(at url: URL) -> SelectorInventory? {
        guard let data = try? Data(contentsOf: url),
              let inventory = try? JSONDecoder.ftInventory.decode(SelectorInventory.self, from: data),
              inventory.version == currentVersion else { return nil }
        return inventory
    }

    /// 観測した id を台帳へ足す(best-effort。失敗しても呼び出し側の結果には影響させない)
    @discardableResult
    public static func record(ids: [String], platform: String, at url: URL,
                              now: Date = Date()) -> SelectorInventory {
        var inventory = load(at: url) ?? SelectorInventory()
        var entry = inventory.platforms[platform]
            ?? PlatformEntry(updatedAt: now, captures: 0, ids: [])
        var merged = Set(entry.ids)
        for id in ids where !id.isEmpty {
            guard merged.count < maxIDs else { break }
            merged.insert(id)
        }
        entry.ids = merged.sorted()
        entry.captures += 1
        entry.updatedAt = now
        inventory.platforms[platform] = entry

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder.ftInventory.encode(inventory) {
            try? data.write(to: url, options: .atomic)
        }
        return inventory
    }

    /// スナップショットから記録対象の id を取り出す。
    /// **placeholder も入れる**: `#x` は identifier で引けなければ placeholder を
    /// 引く(`StepExecutor.candidates`)ので、入れないと dry-run が**実在する入力欄を
    /// 「撮った画面に無い id」と誤警告する** —— 台帳は「`#` で指せる名前の集合」であって
    /// identifier の集合ではない
    public static func ids(in snapshot: SnapshotResponse) -> [String] {
        snapshot.elements.flatMap { element in
            [element.identifier, element.placeholder]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
    }

    public func ids(platform: String) -> Set<String>? {
        platforms[platform].map { Set($0.ids) }
    }

    // MARK: - 照合の対象になる id の抽出

    /// ロケータ木から**完全一致で指定された id** を集める(スコープ・相対の対象・除外条件も辿る)。
    /// ワイルドカード(`#row_*` = idMatch あり)は台帳に無くて当然なので**外す**
    public static func exactIDs(in locator: FlowLocator) -> [String] {
        var found: [String] = []
        collect(locator, into: &found)
        return found
    }

    private static func collect(_ locator: FlowLocator, into found: inout [String]) {
        if let id = locator.id, locator.idMatch == nil, !id.isEmpty { found.append(id) }
        for scoped in locator.scope ?? [] { collect(scoped, into: &found) }
        for excluded in locator.not ?? [] { collect(excluded, into: &found) }
        for step in locator.relative ?? [] {
            for clause in step.filter ?? [] { collect(clause, into: &found) }
        }
    }
}

private extension JSONEncoder {
    static var ftInventory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var ftInventory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
