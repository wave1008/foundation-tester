// Android 実機への `adb reverse`(docs/remote-runner.md §17「実機」)。親(fleetest)が撃つ —— スクリプトとシナリオは adb に繋げない。
// 張るのは TCP の公開ポートごと(デバイスの <port> → ホストの 127.0.0.1:<port>。同じ番号)。解除は控えの `adbReverse` から
// (通常終了・孤児の回収・`services down` が同じ `ServicesTeardown.remove` を通る)。
// 解除に失敗した転送(adb が応答しない等)はデバイスに残る = 既知の制約: 次の起動は同じ宛先なら触らず、公開ポートを変えたら旧い
// 転送について何も言わない(人が `adb reverse --list` で見て `--remove`。docs/user-docs の services ページに書いてある)

import FTCore
import FTServices
import Foundation

enum ServicesAdbReverse {
    /// adb 1 回の上限(秒)。`reverse` は adb サーバとの 1 往復(ms)で、繋がっていない・offline のデバイスは即
    /// "device … not found" / "offline" で返る。超えるのは刺さった adb サーバだけ。尽きたとき = 失敗として警告(張れていないことを言う)。
    static let timeoutSeconds: Double = 10

    /// 終了コードと出力(nil = 起こせなかった・時間切れ)。テストは差し替える(`Shell.Result` は組み立てられない)
    typealias Runner = ([String]) -> (status: Int32, output: String)?

    static func defaultRunner(_ argv: [String]) -> (status: Int32, output: String)? {
        (try? Shell.run(argv, timeout: timeoutSeconds)).map { ($0.status, $0.output) }
    }

    private static func lastLines(_ output: String) -> String {
        output.split(separator: "\n").suffix(2).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")
    }

    /// `--no-rebind`: デバイスに同じ番号の転送が既にあれば上書きしない(利用者が張った転送を黙って差し替え、`down` で消してしまわない)
    static func addArguments(adb: String, serial: String, hostPort: Int) -> [String] {
        [adb, "-s", serial, "reverse", "--no-rebind", "tcp:\(hostPort)", "tcp:\(hostPort)"]
    }

    static func removeArguments(adb: String, serial: String, hostPort: Int) -> [String] {
        [adb, "-s", serial, "reverse", "--remove", "tcp:\(hostPort)"]
    }

    static func listArguments(adb: String, serial: String) -> [String] {
        [adb, "-s", serial, "reverse", "--list"]
    }

    /// `adb reverse --list` の 1 行 = `<transport> tcp:<デバイス側> tcp:<ホスト側>`(空白区切り。先頭の語は adb の版で変わるので見ない)。
    /// デバイス側のポート → ホスト側の宛先(`tcp:9000` 等)
    static func parseList(_ output: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[1].hasPrefix("tcp:"), let port = Int(fields[1].dropFirst(4)) else { continue }
            map[port] = fields[2]
        }
        return map
    }

    struct Outcome: Equatable {
        /// 張れたもの(控えに書く = 解除の対象)
        var entries: [ServicesLease.AdbReverseEntry] = []
        /// 別の宛先への転送が既にあるポート(呼び手が起動を止める理由。1 件 1 行)
        var conflicts: [String] = []
    }

    /// 張る前に `--list` で既存を見る: 同じ宛先(tcp:<port> → tcp:<port>)なら触らない(控えにも書かない = `down` で外さない)・
    /// 別の宛先なら衝突(アプリがそちらへ届いて別のサーバーを検証してしまうので、呼び手が起動を止める)。
    /// 一覧が取れないデバイスはそのまま張りにいき、張れなければ警告(起動は止めない。宛先が分からない失敗は届く・届かないを言わない)
    static func addAll(serials: [String], hostPorts: [Int], adb: String? = AdbLocator.adbPath(),
                       run: Runner = defaultRunner, log: (String) -> Void) -> Outcome {
        guard !serials.isEmpty, !hostPorts.isEmpty else { return Outcome() }
        guard let adb else {
            log("⚠️ services: adb is not installed, so no `adb reverse` was set for " + serials.joined(separator: ", "))
            return Outcome()
        }
        var outcome = Outcome()
        for serial in serials {
            let listed = run(listArguments(adb: adb, serial: serial))
            let existing: [Int: String]? = (listed?.status == 0) ? parseList(listed?.output ?? "") : nil
            if existing == nil {
                log("→ services: `adb -s \(serial) reverse --list` failed, so existing forwards on \(serial) were not checked")
            }
            for port in hostPorts {
                if let destination = existing?[port] {
                    if destination == "tcp:\(port)" {
                        log("→ services: \(serial) already forwards tcp:\(port) to tcp:\(port); left as it is (not set by fleetest, so not removed on down)")
                    } else {
                        outcome.conflicts.append("device \(serial) already forwards tcp:\(port) to \(destination), so the app there would reach that"
                            + " instead of the service; remove it with `adb -s \(serial) reverse --remove tcp:\(port)` or stop publishing \(port)")
                    }
                    continue
                }
                let result = run(addArguments(adb: adb, serial: serial, hostPort: port))
                if let result, result.status == 0 {
                    outcome.entries.append(.init(serial: serial, hostPort: port))
                } else {
                    let detail = result.map { "exit \($0.status): \(lastLines($0.output))" } ?? "adb did not finish within \(Int(timeoutSeconds))s"
                    // 一覧の後に張られた・一覧が取れなかったデバイス = 宛先が分からないので、届く・届かないは言わない
                    let note = (result?.output.contains("rebind") ?? false)
                        ? "; the device already forwards tcp:\(port) somewhere — see `adb -s \(serial) reverse --list` and remove it with"
                            + " `adb -s \(serial) reverse --remove tcp:\(port)` if it is stale"
                        : "; the app on that device cannot reach 127.0.0.1:\(port)"
                    log("⚠️ services: `adb -s \(serial) reverse --no-rebind tcp:\(port) tcp:\(port)` failed (\(detail))\(note)")
                }
            }
        }
        if !outcome.entries.isEmpty {
            let text = outcome.entries.map { "\($0.serial) tcp:\($0.hostPort)" }.joined(separator: ", ")
            log("→ services: adb reverse set (\(text))")
        }
        return outcome
    }

    static func removeAll(_ entries: [ServicesLease.AdbReverseEntry], adb: String? = AdbLocator.adbPath(),
                          run: Runner = defaultRunner, log: (String) -> Void) {
        guard !entries.isEmpty else { return }
        guard let adb else {
            log("⚠️ services: adb is not installed, so \(entries.count) adb reverse entry(ies) were not removed")
            return
        }
        for entry in entries {
            let result = run(removeArguments(adb: adb, serial: entry.serial, hostPort: entry.hostPort))
            if result == nil || result?.status != 0 {
                // 外れたデバイスの reverse は一緒に消えている = 失敗は事実だけ言う
                log("⚠️ services: `adb -s \(entry.serial) reverse --remove tcp:\(entry.hostPort)` failed"
                    + (result.map { " (exit \($0.status))" } ?? " (timed out)"))
            }
        }
    }
}
