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

    /// 既にある転送の扱い: 同じ宛先(tcp:P → tcp:P)なら触らない(控えにも書かない = `down` で外さない)。別の宛先は衝突
    /// (アプリがそちらへ届いて別のサーバーを検証する)
    private static func noteExisting(serial: String, port: Int, destination: String, outcome: inout Outcome, log: (String) -> Void) {
        if destination == "tcp:\(port)" {
            log("→ services: \(serial) already forwards tcp:\(port) to tcp:\(port); left as it is (not set by fleetest, so not removed on down)")
            return
        }
        outcome.conflicts.append("device \(serial) already forwards tcp:\(port) to \(destination), so the app there would reach that"
            + " instead of the service; remove it with `adb -s \(serial) reverse --remove tcp:\(port)` or stop publishing \(port)")
    }

    struct Outcome: Equatable {
        /// 張れたもの(控えに書く = 解除の対象)
        var entries: [ServicesLease.AdbReverseEntry] = []
        /// 別の宛先への転送が既にあるポート(呼び手が起動を止める理由。1 件 1 行)
        var conflicts: [String] = []
    }

    /// 張る前に `--list` で既存を見る: 同じ宛先(tcp:<port> → tcp:<port>)なら触らない(控えにも書かない = `down` で外さない)・
    /// 別の宛先なら衝突(アプリがそちらへ届いて別のサーバーを検証してしまうので、呼び手が起動を止める)。
    /// 一覧が取れないデバイスはそのまま張りにいく。張れた = 転送は無かった。張れなかったときは理由を問わず(既存・時間切れ・
    /// 通信断)一覧を照会し直し、同じ宛先なら通す・別の宛先なら衝突・転送が無いと確認できたときだけ警告(届かない)・一覧も
    /// 読めなければ状態不明として衝突(「転送が無い」「届かない」は確認できたときだけ言う)
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
                    Self.noteExisting(serial: serial, port: port, destination: destination, outcome: &outcome, log: log)
                    continue
                }
                let result = run(addArguments(adb: adb, serial: serial, hostPort: port))
                if let result, result.status == 0 {
                    outcome.entries.append(.init(serial: serial, hostPort: port))
                    continue
                }
                let detail = result.map { "exit \($0.status): \(lastLines($0.output))" } ?? "adb did not finish within \(Int(timeoutSeconds))s"
                // 張れなかった理由が何でも転送の状態を照会し直す(時間切れや通信断は「転送が無い」を証明しない)
                let again = run(listArguments(adb: adb, serial: serial))
                guard let again, again.status == 0 else {
                    let listDetail = again.map { "exit \($0.status): \(lastLines($0.output))" } ?? "adb did not finish within \(Int(timeoutSeconds))s"
                    outcome.conflicts.append("device \(serial): `adb reverse --no-rebind tcp:\(port) tcp:\(port)` failed (\(detail)) and its forwards"
                        + " could not be read (\(listDetail)), so whether tcp:\(port) reaches the service is unknown;"
                        + " check the device (`adb -s \(serial) reverse --list`) and rerun")
                    continue
                }
                if let destination = parseList(again.output)[port] {
                    Self.noteExisting(serial: serial, port: port, destination: destination, outcome: &outcome, log: log)
                } else {
                    // 転送が無いと確認できた = 張れなかっただけ。デバイスの 127.0.0.1:<port> はデバイス自身に向く
                    log("⚠️ services: `adb -s \(serial) reverse --no-rebind tcp:\(port) tcp:\(port)` failed (\(detail)) and the device has"
                        + " no forward for tcp:\(port), so the app there cannot reach 127.0.0.1:\(port)")
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
