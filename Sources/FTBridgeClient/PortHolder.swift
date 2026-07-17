// ポートを掴んだまま残留するプロセス(ウェッジした in-app ブリッジ・残骸 xcodebuild ランナー)の
// 検出と、自分たちの管理下にあると確認できた場合のみの後始末。無関係プロセスは絶対に kill しない
// (lsof で見つかった pid が偶然そのポートを使っている無関係プロセスの可能性があるため)。

import Foundation
import FTCore

public enum PortHolderOutcome {
    case stopped(description: String)
    /// 停止対象外の無関係プロセス、または停止を試みたがポートが解放されなかった(どちらも再試行しない)
    case foreign(description: String)
    case notFound
}

public enum PortHolder {
    /// port を LISTEN しているプロセスを特定し、以下のどちらかに一致する場合だけ後始末する:
    /// - シミュレータ内アプリ(コマンドパスが CoreSimulator/Devices と data/Containers/Bundle を
    ///   両方含む)。同ポートの .inapp があれば simctl terminate(in-app ブリッジの正しい後始末。
    ///   プロセス kill だけだと XCUITest/シミュレータ側の整合が崩れる)、無ければ SIGTERM→SIGKILL
    /// - このポート専用の xctestrun を引数に持つ xcodebuild(残骸ランナー)。SIGTERM→SIGKILL
    /// それ以外(.foreign)は kill しない。
    public static func stopIfOwnedBridge(port: UInt16, stateDir: URL,
                                         derivedDataPath: URL) -> PortHolderOutcome {
        guard let lsof = try? Shell.run(["lsof", "-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]),
              lsof.status == 0,
              let pidLine = lsof.output.split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let pid = Int32(pidLine.trimmingCharacters(in: .whitespaces)) else {
            return .notFound
        }
        guard let ps = try? Shell.run(["ps", "-p", String(pid), "-o", "command="]),
              ps.status == 0 else {
            // lsof が見つけた直後に死んだ等。占有者は既にいない
            return .notFound
        }
        let command = ps.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = "pid \(pid): \(command)"

        if command.contains("/CoreSimulator/Devices/"), command.contains("/data/Containers/Bundle/") {
            // .inapp は記録 udid が占有プロセスの実パスの udid と一致するときだけ信用する
            // (別デバイスの stale .inapp を頼ると無関係アプリを terminate して実占有者が残る)
            let inappPath = InAppBridgeState.url(stateDir: stateDir, port: port)
            if let state = InAppBridgeState.read(at: inappPath),
               command.contains("/CoreSimulator/Devices/\(state.udid)/") {
                InAppBridgeState.terminateAndRemove(at: inappPath)
            } else {
                terminateThenKill(pid: pid)
            }
            return waitForRelease(port: port, description: description)
        }

        // killOrphanRunners と同じ照合(ポートごとに別ファイルなので他ポートは誤爆しない)
        let xctestrunPath = derivedDataPath
            .appendingPathComponent("Build/Products/FTesterRunner-\(port).xctestrun").path
        if command.contains("xcodebuild"), command.contains(xctestrunPath) {
            terminateThenKill(pid: pid)
            return waitForRelease(port: port, description: description)
        }

        return .foreign(description: description)
    }

    private static func terminateThenKill(pid: Int32) {
        kill(pid, SIGTERM)
        BridgeLauncher.confirmDeaths(pids: [pid], timeout: 5)
    }

    private static func waitForRelease(port: UInt16, description: String) -> PortHolderOutcome {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let stillListening = (try? Shell.run(["lsof", "-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]))
                .map { $0.status == 0 } ?? false
            if !stillListening { return .stopped(description: description) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // 解放を確認できないまま .stopped を返すと、呼び出し元が見込みのない同一ポート再試行
        // (ランナー起動〜bindFailed 検知まで数分)へ進んでしまう
        return .foreign(description: description + "(停止後もポートが解放されません)")
    }
}
