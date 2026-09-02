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

    /// この run で record() された鍵(失効判定の「触れた」集合)。マージ元の永続化 entries とは
    /// 別に持つ ── entries はロード時点で他 run 分の鍵も含むが、こちらは今回の実行だけを覚える
    private var touchedThisRun: Set<String> = []

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
        touchedThisRun.insert(key)
        dirty = true
    }

    /// シナリオ終了時に1回だけ呼ぶ。`scenarioID` に属する鍵のうち、今回の run で
    /// 触れなかった(= record() されなかった)ものを刈ってから書き出す。
    /// 鍵は `HealCache.key` と同じ形 `"<scenarioID>|<file>:<line>|<selector>"` なので、
    /// 利用者がソースの行を足す/消す・セレクタを直すと鍵が変わり、古い鍵は二度と
    /// lookup されないまま永久に残る(90 エントリ/19.6KB 規模の実測あり)。失効規則は3条件を守る:
    ///
    /// 1. **`scenarioPassed` のときだけ刈る**。失敗・中断した run は後続ステップに到達していない
    ///    ので、そこから先の鍵はまだ現役 —— 「今回触れていない」だけで刈ると生きている指紋を落とす
    /// 2. **このシナリオで1件以上 record() していたときだけ刈る**(`touchedThisRun` にこの
    ///    シナリオの鍵が1つも無ければ何もしない)。全ステップがキャッシュ/指紋/FM ヒール
    ///    (`.healed`)で解決した run は record() が一度も呼ばれず touchedThisRun が空になる。
    ///    このガードを外すと「1件も触れていない」を「全部古い」と誤読し、そのシナリオの鍵を
    ///    まるごと消してしまう(まだ現役の指紋を根こそぎ失う退化 —— 消してはいけないガード)
    /// 3. **他のシナリオの鍵には触れない**。鍵の接頭辞 `"<scenarioID>|"` で自分のぶんだけを
    ///    対象にする。部分実行(`--scenario` 指定)でも他シナリオの指紋を巻き込まない
    func flush(scenarioID: String, scenarioPassed: Bool) {
        if scenarioPassed {
            let prefix = scenarioID + "|"
            let recordedThisRun = touchedThisRun.contains { $0.hasPrefix(prefix) }
            if recordedThisRun {
                let staleKeys = entries.keys.filter {
                    $0.hasPrefix(prefix) && !touchedThisRun.contains($0)
                }
                if !staleKeys.isEmpty {
                    for key in staleKeys { entries.removeValue(forKey: key) }
                    dirty = true
                }
            }
        }
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
