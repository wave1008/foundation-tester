// RemoteDeviceFanout.swift
// **デバイスの起動・停止を機械ごとに分散する**(docs/remote-runner.md §13)。
// 1つの実行プロファイルのデバイスが複数の機械にまたがるとき、`api devices-up` / `devices-down` は
// 手元のぶんを自分で処理しつつ、**リモートのぶんをその機械へ投げる**。
//
// 分散する理由は速さ: 起動は機械ごとに独立した資源(CPU・GPU・ディスク)を使うので、
// 「同時2台」の上限は**機械ごとに**持てる。3台の機械なら 3×2 台が同時に立ち上がる。
//
// 実装の方針:
// - 子は `fleetest remote exec <machine> -- api devices-up … --device-machine local` を**自分自身の
//   バイナリ**で起動する(ssh の張り方・PATH 補正・宛先解決を remote exec に委ねる。
//   FleetRunner が子プロセスで fleetest を呼ぶのと同じ形)
// - **--device-machine が要る** —— リモート機のプロファイルにはそのデバイスの machine(= その
//   機械の登録名)が書いてあり、CLI には「自分が誰か」を知る手段が無い(マシン登録名は持たない)。
//   親が明示することで、向こうは自分のデバイスを「手元のもの」として扱える
// - 子の stdout は NDJSON のまま中継するが、**per-device の行には親が machine を入れる** ——
//   子は `--device-machine local` で走る(エイリアスはリモートへ出さない規律)ので、自分の台を
//   machine:null と名乗る。入れずに流すと受け手(拡張)が**同名の手元のタイル**を書き換え、
//   リモートの台が1枚も進まないように見える(= 機械ごとに2台ずつ起きていても「全体で2台」に
//   見える)。RemoteMonitorFanout.ingest / ApiRunMachineFanout の rehost と同じ規律

import FTCore
import Foundation

enum RemoteDeviceFanout {

    /// 実行プロファイルが参照するデバイスのうち、**手元でない機械**のマシン名(登場順)。
    /// `--device-machine` を明示している呼び出しでは分散しない(その機械のぶんだけを扱う指示なので)
    static func remoteMachines(project: String?, profile: String?, deviceMachine: String?) -> [String] {
        guard deviceMachine == nil, let profile else { return [] }
        guard let testProject = try? ScenarioHost.project(named: project),
              let machine = try? ProfileResolver.determineMachine(
                  project: testProject, runProfileName: profile),
              let devices = try? ProfileResolver.runDeviceMachines(
                  project: testProject, runProfileName: profile, machineName: machine.name)
        else { return [] }
        return DeviceMachineGrouping.groups(devices, machine: { $0.machine })
            .compactMap(\.machine)
    }

    /// 各機械へ `api <subcommand>` を投げ、stdout の NDJSON を1行ずつ `relay` へ渡す
    /// (machine は `machineStamped` が入れる)。**1台の失敗で他を止めない**(その機械のぶんが
    /// 立ち上がらないだけ。呼び出し側は手元の処理を続ける)。失敗は理由を1行 relay して次へ進む
    static func dispatch(subcommand: String, machines: [String], project: String?, profile: String?,
                         extraArgs: [String] = [],
                         relay: @escaping @Sendable (String) -> Void) async {
        guard !machines.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for machine in machines {
                group.addTask {
                    // **先にプロファイルを送る** —— `remote exec` は何も転送しないので、
                    // 向こうの作業ディレクトリに profiles/ が無い(または古い)ままだと
                    // 「machines/ が空」で失敗する(2026-08-17 実機で確認)。run のディスパッチと
                    // 同じ rsync 引数(RemoteTransferPlan)を使う = 転送の規則を二重に持たない
                    if let project, let failure = RemoteProjectSync.run(project: project, machine: machine) {
                        relay(logLine("❌ \(failure)"))
                        return
                    }
                    var args = ["remote", "exec", machine, "--", "api", subcommand]
                    if let project { args += ["--project", project] }
                    if let profile { args += ["--profile", profile] }
                    // エイリアスは渡さない(転送時に畳んである。FTCore.RunnerProfileView)
                    args += ["--device-machine", DeviceMachineGrouping.localDisplayName]
                    args += extraArgs
                    await runChild(args: args, machine: machine,
                                   relay: { line in
                                       if let out = machineStamped(line: line, machine: machine) {
                                           relay(out)
                                       }
                                   })
                }
            }
        }
    }

    /// 中継する1行を受け手向けに直す(nil = 流さない)。3つだけ:
    /// - per-device の行に `machine` を入れる。**子は自分の台を machine:null と名乗る**
    ///   (`--device-machine local`)ので、入れないと受け手が同名の手元のタイルを書き換える
    ///   (ファイル冒頭の規律)
    /// - log 行の先頭に `[<machine>]` を付ける(手元の行と混ざるとどの機械の声か読めない)
    /// - 子の `finished` は**流さない**。あれは「1機械ぶんの締め」で、受け手の契約では
    ///   `finished` はストリーム全体の終端が1つだけ(親が `await fanout` の後に出す)。
    ///   **失敗だけは log へ移し替える**(捨てると、その機械が丸ごと起きなかった理由が
    ///   stdout から消える)
    /// **読めない行・想定外の形はそのまま流す**(RemoteMonitorFanout.machineScoped と同じ方針)
    static let deviceKinds: Set<String> = ["deviceStopping", "deviceStarting", "deviceFinished"]

    static func machineStamped(line: String, machine: String) -> String? {
        guard let data = line.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = object["kind"] as? String
        else { return line }
        if deviceKinds.contains(kind) {
            object["machine"] = machine
        } else if kind == "log", let message = object["message"] as? String {
            object["message"] = "[\(machine)] \(message)"
        } else if kind == "finished" {
            guard object["ok"] as? Bool == false else { return nil }
            let detail = object["error"] as? String ?? "the devices on this machine did not start"
            return logLine("❌ [\(machine)] \(detail)")
        } else {
            return line
        }
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return line }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// NDJSON の log 行(中継経路に流すので JSON で作る)
    static func logLine(_ message: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Log: Encodable { let kind = "log"; let message: String }
        guard let data = try? encoder.encode(Log(message: message)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 子プロセス1件。stdout を行単位で中継する(読み取りは専用スレッド。
    /// RemoteRunDispatcher/FleetRunner と同じ規律)。stderr は親の stderr へ素通しする
    private static func runChild(args: [String], machine: String,
                                 relay: @escaping @Sendable (String) -> Void) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteProjectSync.selfBinaryPath())
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            relay(logLine("❌ \(machine): cannot start the fan-out child: \(error.localizedDescription)"))
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                var buffer = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if !line.isEmpty { relay(line) }
                    }
                }
                process.waitUntilExit()
                continuation.resume()
            }
            thread.start()
        }
    }

}
