// RemoteProjectSync.swift
// **リモート機で fleetest を動かす前にプロジェクト一式を送る**(デバイス起動の fan-out・
// モニターの fan-out に共通)。`remote exec` は転送を一切しないので、向こうの作業ディレクトリに
// profiles/ が無い(または古い)ままだと「machines/ が空」で失敗する(2026-08-17 実機で確認)。
//
// 転送の規則(除外・宛先レイアウト)は run のディスパッチと同じ `RemoteTransferPlan.rsyncArgs`
// を使う —— 二重に持つと、片方だけ除外が増えたときに「run では動くのに fan-out では動かない」になる。

import FTBridgeClient  // RepoRoot
import FTCore
import Foundation

enum RemoteProjectSync {

    /// プロジェクト(シナリオ含む一式)をそのマシンへ送る。失敗は理由を1行返して false
    /// (呼び出し側はその機械のぶんを諦め、他のマシンと手元の処理は続ける)
    static func run(project: String, machine: String) -> String? {
        guard let localProjectsDir = localProjectsDir(project: project),
              let resolved = try? RemoteHostResolver.resolve(rawHost: machine, remoteDirOverride: nil),
              let issuer = try? resolveLayoutIssuer()
        else {
            return "\(machine): cannot resolve the machine, the project directory, or the issuer"
        }
        let layout = RemoteLayout(base: RemoteLayout.resolveBase(resolved.remoteDirRaw, home: "$HOME"),
                                  issuer: issuer)
        let args = RemoteTransferPlan.rsyncArgs(
            project: project, localProjectsDir: localProjectsDir,
            layout: layout, sshTarget: resolved.hostSpec.sshTarget,
            ignore: RemoteTransferPlan.projectIgnore(project: project, localProjectsDir: localProjectsDir))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "\(machine): rsync failed to start: \(error.localizedDescription)"
        }
        guard process.terminationStatus == 0 else {
            return "\(machine): rsync exited with \(process.terminationStatus)"
        }
        // run ディスパッチ(RemoteRunDispatcher.transfer)と同じく、エイリアスを残さない姿へ
        // 差し替える。**片方だけ変えない** —— 生のプロファイルを上書きすると次の実行で復活する
        if let failure = RunnerProfileTransfer.localizeAndUpload(
            localProjectDir: URL(fileURLWithPath: "\(localProjectsDir)/\(project)"),
            project: project, alias: machine,
            layout: layout, sshTarget: resolved.hostSpec.sshTarget) {
            return "\(machine): \(failure)"
        }
        return nil
    }

    /// 送り元の TestProjects/。**run のディスパッチと同じ基準**(`ScenarioHost.project(named:)` =
    /// 受け手パッケージ / FT_PACKAGE_ROOT)で引く。外部パッケージ構成ではプロジェクトはクローン側に
    /// 無いので、ツールのクローン(RepoRoot)から組むと rsync が 23 で落ち、リモートのタイルが
    /// 1枚も出ない(受け手報告 2026-08-23)。クローンへのフォールバックは clone 構成で cwd が
    /// パッケージの外にあるとき(拡張が任意の cwd で起こす)のため
    static func localProjectsDir(project: String) -> String? {
        localProjectsDir(
            resolvedProjectRoot: (try? ScenarioHost.project(named: project))?.rootURL,
            repoRoot: try? RepoRoot.find())
    }

    static func localProjectsDir(resolvedProjectRoot: URL?, repoRoot: URL?) -> String? {
        if let resolvedProjectRoot { return resolvedProjectRoot.deletingLastPathComponent().path }
        return repoRoot.map { ProjectStore.projectsDir(repoRoot: $0).path }
    }

    /// 実行中の fleetest バイナリ自身(FleetRunner.selfBinaryPath と同じ理由・同じ実装)。
    /// 子は必ず `remote exec` 経由で起こすので、ssh の張り方・PATH 補正・ホスト解決を
    /// そこへ委ねられる(専用の ssh 経路を新設しない = docs/remote-runner.md §14)
    static func selfBinaryPath() -> String {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().path
        }
        return CommandLine.arguments[0]
    }
}
