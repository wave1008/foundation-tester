// RemoteProjectSync.swift
// **リモート機で ftester を動かす前にプロジェクト一式を送る**(デバイス起動の fan-out・
// モニターの fan-out に共通)。`remote exec` は転送を一切しないので、向こうの作業ディレクトリに
// profiles/ が無い(または古い)ままだと「machines/ が空」で失敗する(2026-08-17 実機で確認)。
//
// 転送の規則(除外・宛先レイアウト)は run のディスパッチと同じ `RemoteTransferPlan.rsyncArgs`
// を使う —— 二重に持つと、片方だけ除外が増えたときに「run では動くのに fan-out では動かない」になる。

import FTBridgeClient  // RepoRoot
import FTCore
import Foundation

enum RemoteProjectSync {

    /// プロジェクト(シナリオ含む一式)をそのホストへ送る。失敗は理由を1行返して false
    /// (呼び出し側はその機械のぶんを諦め、他のホストと手元の処理は続ける)
    static func run(project: String, host: String) -> String? {
        guard let repoRoot = try? RepoRoot.find(),
              let resolved = try? RemoteHostResolver.resolve(rawHost: host, remoteDirOverride: nil)
        else {
            return "\(host): cannot resolve the host or the repository root"
        }
        let layout = RemoteLayout(base: RemoteLayout.resolveBase(resolved.remoteDirRaw, home: "$HOME"))
        let args = RemoteTransferPlan.rsyncArgs(
            project: project,
            localProjectsDir: repoRoot.appendingPathComponent("TestProjects").path,
            layout: layout, sshTarget: resolved.hostSpec.sshTarget)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "\(host): rsync failed to start: \(error.localizedDescription)"
        }
        guard process.terminationStatus == 0 else {
            return "\(host): rsync exited with \(process.terminationStatus)"
        }
        return nil
    }

    /// 実行中の ftester バイナリ自身(FleetRunner.selfBinaryPath と同じ理由・同じ実装)。
    /// 子は必ず `remote exec` 経由で起こすので、ssh の張り方・PATH 補正・ホスト解決を
    /// そこへ委ねられる(専用の ssh 経路を新設しない = docs/remote-runner.md §14)
    static func selfBinaryPath() -> String {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().path
        }
        return CommandLine.arguments[0]
    }
}
