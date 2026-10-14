// Android 実機への `adb reverse`(docs/remote-runner.md §17「実機」)。親(fleetest)が撃つ —— スクリプトとシナリオは adb に繋げない。
// 張るのは TCP の公開ポートごと(デバイスの <port> → ホストの 127.0.0.1:<port>。同じ番号)。解除は控えの `adbReverse` から
// (通常終了・孤児の回収・`services down` が同じ `ServicesTeardown.remove` を通る)。

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

    /// `--no-rebind`: デバイスに同じ番号の転送が既にあれば上書きせず失敗する(利用者が張った転送を黙って差し替え、
    /// `down` で消してしまわない。失敗は "cannot rebind existing socket" の警告 = 既存の転送の始末は利用者)
    static func addArguments(adb: String, serial: String, hostPort: Int) -> [String] {
        [adb, "-s", serial, "reverse", "--no-rebind", "tcp:\(hostPort)", "tcp:\(hostPort)"]
    }

    static func removeArguments(adb: String, serial: String, hostPort: Int) -> [String] {
        [adb, "-s", serial, "reverse", "--remove", "tcp:\(hostPort)"]
    }

    /// 張れたものだけを返す(控えに書く)。張れなかったものは警告で、起動は止めない
    /// (そのレーンは供給段で弾かれるか、アプリが 127.0.0.1 に繋げない失敗として出る)。
    static func addAll(serials: [String], hostPorts: [Int], adb: String? = AdbLocator.adbPath(),
                       run: Runner = defaultRunner, log: (String) -> Void) -> [ServicesLease.AdbReverseEntry] {
        guard !serials.isEmpty, !hostPorts.isEmpty else { return [] }
        guard let adb else {
            log("⚠️ services: adb is not installed, so no `adb reverse` was set for " + serials.joined(separator: ", "))
            return []
        }
        var entries: [ServicesLease.AdbReverseEntry] = []
        for serial in serials {
            for port in hostPorts {
                let result = run(addArguments(adb: adb, serial: serial, hostPort: port))
                if let result, result.status == 0 {
                    entries.append(.init(serial: serial, hostPort: port))
                } else {
                    let detail = result.map { "exit \($0.status): \(lastLines($0.output))" } ?? "adb did not finish within \(Int(timeoutSeconds))s"
                    let existing = (result?.output.contains("rebind") ?? false)
                        ? "; the device already forwards tcp:\(port) — remove it with `adb -s \(serial) reverse --remove tcp:\(port)` if it is stale" : ""
                    log("⚠️ services: `adb -s \(serial) reverse --no-rebind tcp:\(port) tcp:\(port)` failed (\(detail));"
                        + " the app on that device cannot reach 127.0.0.1:\(port)\(existing)")
                }
            }
        }
        if !entries.isEmpty {
            let text = entries.map { "\($0.serial) tcp:\($0.hostPort)" }.joined(separator: ", ")
            log("→ services: adb reverse set (\(text))")
        }
        return entries
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
