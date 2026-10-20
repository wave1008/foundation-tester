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
    /// 勝った所有者のログ。所有者が控えを書けた(排他の中)ときに試みのログをここへ改名する = 前の所有者のログを置き換える
    static func logURL(stateDir: URL, prefix: String) -> URL {
        stateDir.appendingPathComponent("services").appendingPathComponent("\(prefix).log")
    }

    /// 起こす試みごとのログ。**`logURL` を起こす側で開かない** —— 同時の `up` で負ける所有者も起こすので、そこで空にすると
    /// 勝った所有者のログを消す。負けた試み・控えを書く前に落ちた試みのログはこちらに残る
    static func attemptLogURL(stateDir: URL, prefix: String) -> URL {
        stateDir.appendingPathComponent("services").appendingPathComponent("\(prefix).attempt-\(UUID().uuidString).log")
    }

    /// 控えを書けた所有者が排他の中で呼ぶ(控えを書けるのは同時に1つ = 改名も1つ)。改名できなくても起動は止めない(ログが試みの場所に残るだけ)
    static func claimLog(attempt: URL, stable: URL, log: (String) -> Void) {
        if rename(attempt.path, stable.path) != 0 {
            log("⚠️ services: cannot move the log \(attempt.path) to \(stable.path): \(String(cString: strerror(errno))); it stays there")
        }
    }

    static func arguments(project: String, profile: String, physical: Bool, serials: [String], logFile: URL) -> [String] {
        var argv = ["api", "services-owner", "--project", project, "--profile", profile]
        if physical { argv.append("--physical") }
        for serial in serials { argv += ["--serial", serial] }
        argv += ["--log-file", logFile.path]
        return argv
    }

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment[ParentDeathWatch.environmentKey] = nil   // 親(この CLI)の終了で死なない = 常駐
        environment[DispatchRefusalReport.environmentKey] = nil
        return environment
    }

    /// 戻りの `exited` は所有者の終了までブロックする(`ProcessExitWait.prepareBlocking` = `waitUntilExit()` を使わない規律)。
    /// `logReader` は試みのログの読み口(所有者が改名した後も同じ中身を読む = 失敗の表示に使う)
    static func spawn(executable: URL, project: String, profile: String, physical: Bool, serials: [String],
                      attemptLog: URL) throws -> (process: Process, exited: @Sendable () -> Void, logReader: FileHandle) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(project: project, profile: profile, physical: physical, serials: serials, logFile: attemptLog)
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        try FileManager.default.createDirectory(at: attemptLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        // symlink を辿らない(O_NOFOLLOW)・既存を開かない(O_EXCL)。パスで開き直さず、この fd をそのまま子へ渡す
        let fd = open(attemptLog.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw ServicesRefused("cannot create the services log \(attemptLog.path): \(String(cString: strerror(errno)))")
        }
        let readFD = dup(fd)
        guard readFD >= 0 else {
            close(fd)
            throw ServicesRefused("cannot open the services log \(attemptLog.path): \(String(cString: strerror(errno)))")
        }
        let logReader = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        let sink = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? sink.close() }   // 子は自分の複製を持つ
        process.standardOutput = sink
        process.standardError = sink
        process.qualityOfService = .utility
        let exited = ProcessExitWait.prepareBlocking(process)   // run() より前に設定する契約
        try process.run()
        return (process, exited, logReader)
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

    /// 開いている読み口から先頭より読む(パスで開き直さない = 所有者の改名・次の `up` の改名に左右されない)
    static func logTail(_ handle: FileHandle, lines: Int) -> [String] {
        guard (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init)
    }
}
