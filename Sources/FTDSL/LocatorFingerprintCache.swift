// ロケータ指紋(前回そのロケータが解決できた要素の type+label)を
// .fleetest/locator-fingerprints.json へ永続化する。鍵は `key(...)`(シナリオID+file:line+セレクタ)
// なので、利用者がソースを直せば鍵が変わり自然に失効する。**同じ形を修正提案の id
// (`HealFixInput.id`)と拡張の修復確認パネルも使う**(片方だけ変えない)。
//
// **record() はメモリへ溜めるだけで毎回 save() しない**。指紋はステップが解決に成功するたび
// 更新され得るので、成功のたびにファイル全体を書き直すと I/O がステップ数に比例する。
// 書き出しは flush() でシナリオ終了時に1回だけ行う(呼び出し口は ScenarioRunnerMain)。

import Foundation
import FTCore

final class LocatorFingerprintCache {
    private let url: URL
    private var entries: [String: LocatorFingerprint]
    private var dirty = false

    /// この run で lookup() または record() された鍵(失効判定の「触れた」集合)。マージ元の永続化
    /// entries とは別に持つ ── entries はロード時点で他 run 分の鍵も含むが、こちらは今回の実行だけを覚える。
    /// **lookup も数える**: 鍵はソースの行+セレクタなので、引かれた = その行は今も在る。record だけを
    /// 数えると、指紋で直ったステップ(record しない)の鍵が同じ run の終わりに刈られ、次の run で
    /// 指紋を失って赤に戻っていた
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

    static func key(scenarioID: String, file: String, line: Int, selector: String) -> String {
        "\(scenarioID)|\(file):\(line)|\(selector)"
    }

    func lookup(_ key: String) -> LocatorFingerprint? {
        touchedThisRun.insert(key)
        return entries[key]
    }

    /// メモリへ溜めるだけ(ディスクへは flush() まで書かない)。
    /// **名指しになっていない指紋(`isIdentifying` でない)は控えず、前の控えも消す** ——
    /// 今の要素がラベルを失ったのに古いラベルの控えを残すと、別の要素へ解決し得る
    func record(_ key: String, fingerprint: LocatorFingerprint) {
        touchedThisRun.insert(key)
        if fingerprint.isIdentifying {
            entries[key] = fingerprint
            dirty = true
        } else if entries.removeValue(forKey: key) != nil {
            dirty = true
        }
    }

    /// シナリオ終了時に1回だけ呼ぶ。`scenarioID` に属する鍵のうち、今回の run で
    /// 触れなかった(= lookup() も record() もされなかった)ものを刈ってから書き出す。
    /// 鍵は `key(...)` の形 `"<scenarioID>|<file>:<line>|<selector>"` なので、
    /// 利用者がソースの行を足す/消す・セレクタを直すと鍵が変わり、古い鍵は二度と
    /// lookup されないまま永久に残る(90 エントリ/19.6KB 規模の実測あり)。失効規則は3条件を守る:
    ///
    /// 1. **`scenarioPassed` のときだけ刈る**。失敗・中断した run は後続ステップに到達していない
    ///    ので、そこから先の鍵はまだ現役 —— 「今回触れていない」だけで刈ると生きている指紋を落とす
    /// 2. **このシナリオの鍵に1件以上触れていたときだけ刈る**(`touchedThisRun` にこの
    ///    シナリオの鍵が1つも無ければ何もしない)。触れた集合が空の run(鍵を引く経路を
    ///    1度も通らなかった)で刈ると「1件も触れていない」を「全部古い」と誤読し、そのシナリオの鍵を
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
            // 保存失敗は実行を止めない(次回は指紋なしで解決を試みるだけ)
        }
    }
}
