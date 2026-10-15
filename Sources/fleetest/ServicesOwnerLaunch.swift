// `fleetest services up` が起こす常駐の所有者(`fleetest api services-owner`)の起こし方と、上がるまでの観測
// (docs/remote-runner.md §17「調停」)。所有者は親より長く生きる(FT_PARENT_PID を消す・stdin は /dev/null・出力はログファイル)
// = fm-serve と同じ形。**上がったかは所有者が書く控え**(kind = owner・phase = running)で見る。待ちに期限は置かない ——
// 所有者の終了(失敗)か控えの running のどちらかは必ず起きる(起動の上限は healthcheck が決める。pull / build はネットワーク次第)。
// `services up` への Ctrl-C は所有者へ SIGTERM を転送する(所有者はプロセスグループの長なので端末の Ctrl-C は届かない)。

import ArgumentParser
import FTCore
import FTServices
import Foundation

enum ServicesOwnerLaunch {
    /// 所有者の出力。`services up` ごとに空から書く(前の所有者のログを混ぜない)
    static func logURL(stateDir: URL, prefix: String) -> URL {
        stateDir.appendingPathComponent("services").appendingPathComponent("\(prefix).log")
    }

    static func arguments(project: String, profile: String, physical: Bool, serials: [String]) -> [String] {
        var argv = ["api", "services-owner", "--project", project, "--profile", profile]
        if physical { argv.append("--physical") }
        for serial in serials { argv += ["--serial", serial] }
        return argv
    }

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment[ParentDeathWatch.environmentKey] = nil   // 親(この CLI)の終了で死なない = 常駐
        environment[DispatchRefusalReport.environmentKey] = nil
        return environment
    }

    /// 戻りの `exited` は所有者の終了までブロックする(`ProcessExitWait.prepareBlocking` = `waitUntilExit()` を使わない規律)
    static func spawn(executable: URL, project: String, profile: String, physical: Bool, serials: [String],
                      logURL: URL) throws -> (process: Process, exited: @Sendable () -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(project: project, profile: profile, physical: physical, serials: serials)
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // symlink を辿らない(O_NOFOLLOW)・毎回空から。パスで開き直さず、この fd をそのまま子へ渡す
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw ServicesRefused("cannot create the services log \(logURL.path): \(String(cString: strerror(errno)))")
        }
        let sink = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? sink.close() }   // 子は自分の複製を持つ
        process.standardOutput = sink
        process.standardError = sink
        process.qualityOfService = .utility
        let exited = ProcessExitWait.prepareBlocking(process)   // run() より前に設定する契約
        try process.run()
        return (process, exited)
    }

    enum Readiness: Equatable {
        case running(ServicesLease)
        case exited
        case waiting
    }

    /// `ownerRunning` は `entries` を読んだ**後**に見る(控えが running でも所有者が死んでいれば exited)。
    static func readiness(entries: [ServicesLeaseEntry], ownerPid: Int32, ownerRunning: Bool) -> Readiness {
        guard ownerRunning else { return .exited }
        if let lease = entries.compactMap(\.lease)
            .first(where: { $0.pid == ownerPid && $0.kind == .owner && $0.phase == .running }) {
            return .running(lease)
        }
        return .waiting
    }

    static func logTail(_ url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init)
    }
}
