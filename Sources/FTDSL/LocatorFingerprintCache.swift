// ロケータ指紋(前回そのロケータが解決できた要素の type+label)を
// .fleetest/locator-fingerprints.json へ永続化する。鍵は HealCache と同じ形
// (`HealCache.key(...)` を再利用)なので、利用者がソースを直せば鍵が変わり自然に失効する
// (新しい失効規則は発明しない)。
//
// **HealCache.store と違い、record() はメモリへ溜めるだけで毎回 save() しない**。
// 指紋はステップが解決に成功するたび(プライマリ/フォールバック解決のたび)更新され得るため、
// HealCache と同じ「成功のたびにファイル全体を書き直す」作りにすると I/O がステップ数に比例して
// しまう。書き出しは flush() でシナリオ終了時に1回だけ行う(呼び出し口は ScenarioRunnerMain)。

import Foundation
import FTCore

final class LocatorFingerprintCache {
    private let url: URL
    private var entries: [String: LocatorFingerprint]
    private var dirty = false

    init(url: URL = URL(fileURLWithPath: ".fleetest/locator-fingerprints.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([String: LocatorFingerprint].self, from: data) {
            entries = loaded
        } else {
            entries = [:]
        }
    }

    func lookup(_ key: String) -> LocatorFingerprint? {
        entries[key]
    }

    /// メモリへ溜めるだけ(ディスクへは flush() まで書かない)
    func record(_ key: String, fingerprint: LocatorFingerprint) {
        entries[key] = fingerprint
        dirty = true
    }

    /// シナリオ終了時に1回だけ呼ぶ。溜まった書き込みが無ければ何もしない
    func flush() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
            dirty = false
        } catch {
            // 保存失敗は実行を止めない(次回また指紋なしで FM ヒールされるだけ)
        }
    }
}
