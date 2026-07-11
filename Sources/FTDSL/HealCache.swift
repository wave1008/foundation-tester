// シナリオソースは自動書換しない方針のため、FM 自己修復の結果を
// .ftester/heal-cache.json に永続化し、2 回目以降は FM なしで解決する。
// キー = シナリオID+file:line+旧セレクタ文字列。ソースを直すとキー不一致で自然に無効化される。

import Foundation
import FTCore

final class HealCache {
    struct Entry: Codable {
        let locators: [FlowLocator]
        let newSelector: String
        let rationale: String
    }

    private let url: URL
    private var entries: [String: Entry]

    init(url: URL = URL(fileURLWithPath: ".ftester/heal-cache.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = loaded
        } else {
            entries = [:]
        }
    }

    static func key(scenarioID: String, file: String, line: Int, selector: String) -> String {
        "\(scenarioID)|\(file):\(line)|\(selector)"
    }

    func lookup(_ key: String) -> Entry? {
        entries[key]
    }

    func store(_ key: String, locators: [FlowLocator], newSelector: String, rationale: String) {
        entries[key] = Entry(locators: locators, newSelector: newSelector, rationale: rationale)
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            // キャッシュ保存失敗は実行を止めない(次回また FM ヒールされるだけ)
        }
    }
}
