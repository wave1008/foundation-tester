// RemoteDeviceFanout.swift
// **デバイスの起動・停止を機械ごとに分散する**(docs/remote-runner.md §13)。
// 1つの実行プロファイルのデバイスが複数の機械にまたがるとき、`api devices-up` / `devices-down` は
// 手元のぶんを自分で処理しつつ、**リモートのぶんをその機械へ投げる**。
//
// 分散する理由は速さ: 起動は機械ごとに独立した資源(CPU・GPU・ディスク)を使うので、
// 「同時2台」の上限は**機械ごとに**持てる。3台の機械なら 3×2 台が同時に立ち上がる。
//
// 実装の方針:
// - 子は `ftester remote exec <host> -- api devices-up … --device-host <host>` を**自分自身の
//   バイナリ**で起動する(ssh の張り方・PATH 補正・ホスト解決を remote exec に委ねる。
//   FleetRunner が子プロセスで ftester を呼ぶのと同じ形)
// - **--device-host が要る** —— リモート機のプロファイルにはそのデバイスの host(= その機械の
//   登録名)が書いてあり、CLI には「自分が誰か」を知る手段が無い(マシン登録名は廃止済み)。
//   親が明示することで、向こうは自分のデバイスを「手元のもの」として扱える
// - 子の stdout は **NDJSON のまま中継する**(行を作り直さない)。host は子が各イベントへ
//   入れているので、受け手(拡張)はそのままタイルを特定できる

import FTCore
import Foundation

enum RemoteDeviceFanout {

    /// 実行プロファイルが参照するデバイスのうち、**手元でない機械**のホスト名(登場順)。
    /// `--device-host` を明示している呼び出しでは分散しない(その機械のぶんだけを扱う指示なので)
    static func remoteHosts(project: String?, profile: String?, deviceHost: String?) -> [String] {
        guard deviceHost == nil, let profile else { return [] }
        guard let testProject = try? ScenarioHost.project(named: project),
              let machine = try? ProfileResolver.determineMachine(
                  project: testProject, runProfileName: profile),
              let devices = try? ProfileResolver.runDeviceHosts(
                  project: testProject, runProfileName: profile, machineName: machine.name)
        else { return [] }
        return DeviceHostGrouping.groups(devices, host: { $0.host })
            .compactMap(\.host)
    }

    /// 各ホストへ `api <subcommand>` を投げ、stdout の NDJSON を1行ずつ `relay` へ渡す。
    /// **1台の失敗で他を止めない**(その機械のぶんが立ち上がらないだけ。呼び出し側は手元の
    /// 処理を続ける)。失敗は理由を1行 relay して次へ進む
    static func dispatch(subcommand: String, hosts: [String], project: String?, profile: String?,
                         extraArgs: [String] = [],
                         relay: @escaping @Sendable (String) -> Void) async {
        guard !hosts.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask {
                    var args = ["remote", "exec", host, "--", "api", subcommand]
                    if let project { args += ["--project", project] }
                    if let profile { args += ["--profile", profile] }
                    args += ["--device-host", host]
                    args += extraArgs
                    await runChild(args: args, host: host, relay: relay)
                }
            }
        }
    }

    /// 子プロセス1件。stdout を行単位で中継する(読み取りは専用スレッド。
    /// RemoteRunDispatcher/FleetRunner と同じ規律)。stderr は親の stderr へ素通しする
    private static func runChild(args: [String], host: String,
                                 relay: @escaping @Sendable (String) -> Void) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: selfBinaryPath())
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            relay(#"{"kind":"log","message":"❌ \#(host): cannot start the fan-out child: "#
                + "\(error.localizedDescription)\"}")
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

    /// 実行中の ftester バイナリ自身(FleetRunner.selfBinaryPath と同じ理由・同じ実装)
    private static func selfBinaryPath() -> String {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().path
        }
        return CommandLine.arguments[0]
    }
}
