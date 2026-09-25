// ロケータ指紋(前回そのロケータが解決できた要素の type+label)を
// .fleetest/locator-fingerprints.json へ永続化する。鍵は `key(...)`(シナリオID+OS+file:line+セレクタ)
// なので、利用者がソースを直せば鍵が変わり自然に失効する。**OS を鍵に含める**: iOS と Android で回す共通の
// シナリオは同じ行を共有するが、型名が OS で違う(CMP のボタンは iOS `button` / Android `Cell`)ので、
// OS を跨いで上書きし合うと直前にもう一方で採った指紋と一致せず直らない。
//
// **record() はメモリへ溜めるだけで毎回 save() しない**。指紋はステップが解決に成功するたび
// 更新され得るので、成功のたびにファイル全体を書き直すと I/O がステップ数に比例する。
// 書き出しは flush() でシナリオ終了時に1回だけ行う(呼び出し口は ScenarioRunnerMain)。
//
// **インスタンスはシナリオ実行プロセスごと**(レーン並列で同時に走る)。flush() は自分の
// entries 全体を上書きしない ── flock で排他した上でディスクの最新を読み直し、この run が
// 実際に set/remove した鍵だけを併合する(TemplatePrintStore と同じ作法)。そうしないと、
// 同じシナリオ・同じ OS を並列プロファイルで同時に回したとき、先に flush した側が記録した
// 指紋を後に flush した側が読み直さずに上書きして消す。刈り取り(古い鍵の削除)も併合後の
// 内容に対して行う ── 自分の書き込み前に読んだ古い entries に対して刈ると、他プロセスが
// その間に足した鍵を巻き込んで消しかねない。

import Foundation
import FTCore

final class LocatorFingerprintCache {
    private let url: URL
    private var entries: [String: LocatorFingerprint]

    /// この run で lookup() または record() された鍵(失効判定の「触れた」集合)。マージ元の永続化
    /// entries とは別に持つ ── entries はロード時点で他 run 分の鍵も含むが、こちらは今回の実行だけを覚える。
    /// **lookup も数える**: 鍵はソースの行+セレクタなので、引かれた = その行は今も在る。record だけを
    /// 数えると、指紋で直ったステップ(record しない)の鍵が同じ run の終わりに刈られ、次の run で
    /// 指紋を失って赤に戻っていた
    private var touchedThisRun: Set<String> = []

    /// この run が record() で新しく持つに至った指紋(flush() でディスクの最新へ上書き併合する)
    private var setThisRun: [String: LocatorFingerprint] = [:]
    /// この run が record() で「名指しでなくなった」と判定した鍵(flush() でディスクから消す)
    private var removedThisRun: Set<String> = []

    init(url: URL = URL(fileURLWithPath: ".fleetest/locator-fingerprints.json")) {
        self.url = url
        entries = Self.load(url)
    }

    static func key(scenarioID: String, platform: String, file: String, line: Int, selector: String) -> String {
        scope(scenarioID: scenarioID, platform: platform) + "\(file):\(line)|\(selector)"
    }

    /// 1つのシナリオ・1つの OS の鍵が共有する接頭辞(`key` と `flush` の刈り取り範囲の唯一の定義元)
    static func scope(scenarioID: String, platform: String) -> String {
        "\(scenarioID)|\(platform)|"
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
            setThisRun[key] = fingerprint
            removedThisRun.remove(key)
        } else {
            entries.removeValue(forKey: key)
            setThisRun.removeValue(forKey: key)
            // ローカルの entries に無くても消去要求は残す ── flush() 時点のディスクには
            // 他プロセスが書いた同じ鍵が乗っているかもしれない
            removedThisRun.insert(key)
        }
    }

    /// シナリオ終了時に1回だけ呼ぶ。`scenarioID` と `platform` に属する鍵のうち、今回の run で
    /// 触れなかった(= lookup() も record() もされなかった)ものを刈ってから書き出す。
    /// 鍵は `key(...)` の形 `"<scenarioID>|<platform>|<file>:<line>|<selector>"` なので、
    /// 利用者がソースの行を足す/消す・セレクタを直すと鍵が変わり、古い鍵は二度と
    /// lookup されないまま永久に残る(90 エントリ/19.6KB 規模の実測あり)。失効規則は3条件を守る:
    ///
    /// 1. **`scenarioPassed` のときだけ刈る**。失敗・中断した run は後続ステップに到達していない
    ///    ので、そこから先の鍵はまだ現役 —— 「今回触れていない」だけで刈ると生きている指紋を落とす
    /// 2. **このシナリオの鍵に1件以上触れていたときだけ刈る**(`touchedThisRun` にこの
    ///    シナリオの鍵が1つも無ければ何もしない)。触れた集合が空の run(鍵を引く経路を
    ///    1度も通らなかった)で刈ると「1件も触れていない」を「全部古い」と誤読し、そのシナリオの鍵を
    ///    まるごと消してしまう(まだ現役の指紋を根こそぎ失う退化 —— 消してはいけないガード)
    /// 3. **他のシナリオ・他の OS の鍵には触れない**。接頭辞 `scope(...)` で自分のぶんだけを
    ///    対象にする。部分実行(`--scenario` 指定)でも他シナリオの指紋を巻き込まず、iOS の run が
    ///    同じシナリオの Android の指紋を刈らない(交互に回すと互いに消し合う)
    func flush(scenarioID: String, platform: String, scenarioPassed: Bool) {
        let prefix = Self.scope(scenarioID: scenarioID, platform: platform)
        let touchedOwnScope = touchedThisRun.contains { $0.hasPrefix(prefix) }
        let mayPrune = scenarioPassed && touchedOwnScope
        // 何も変える見込みが無ければロックすら取らない(dirty 相当のゲート)
        guard !setThisRun.isEmpty || !removedThisRun.isEmpty || mayPrune else { return }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // FileManager.createFile を使わない(既存の inode を置き換えて先客の flock と衝突しなくなる。
        // TemplatePrintStore と同じ罠)
        let fd = open(directory.appendingPathComponent("\(url.lastPathComponent).lock").path, O_WRONLY | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { close(fd) } }

        var diskEntries = Self.load(url)
        var changed = false
        for (key, fingerprint) in setThisRun where diskEntries[key] != fingerprint {
            diskEntries[key] = fingerprint
            changed = true
        }
        for key in removedThisRun where diskEntries.removeValue(forKey: key) != nil {
            changed = true
        }
        if mayPrune {
            let staleKeys = diskEntries.keys.filter {
                $0.hasPrefix(prefix) && !touchedThisRun.contains($0)
            }
            if !staleKeys.isEmpty {
                for key in staleKeys { diskEntries.removeValue(forKey: key) }
                changed = true
            }
        }
        guard changed else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(diskEntries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load(_ url: URL) -> [String: LocatorFingerprint] {
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([String: LocatorFingerprint].self, from: data) else { return [:] }
        return loaded
    }
}
