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
    /// port を LISTEN しているプロセスの説明("pid N: <command>")。**止めない**(原因の名指し専用)。
    /// 誰も LISTEN していなければ nil。
    /// in-app ブリッジは注入先アプリが背面に回ると TCP は受け付けるが HTTP に答えないので、
    /// 注入の失敗を「応答が無い」とだけ言うと残骸が原因だと分からない(受け手報告)
    public static func describe(port: UInt16) -> String? {
        lookup(port: port).map { "pid \($0.pid): \($0.command)" }
    }

    /// そのポートを握っているのが**実機の USB トンネル(iproxy)だけ**か。
    /// ブリッジが死んでもトンネルは残るので、この形のポートは誰から見ても「使用中」に見えるのに
    /// 誰も駆動できない(doctor がこれを見落として「異常なし」と言っていた。実地で確認)。
    /// **プロセスの実体で判定する** —— 応答の速さ(`probeStatus`)で決めると、駆動中で答えない
    /// だけの in-app ブリッジまで拾う
    public static func isHeldByTunnelOnly(port: UInt16) -> Bool {
        guard let (_, command) = lookup(port: port) else { return false }
        return commandIsIproxyForPort(command, port: port)
    }

    /// `describe` の有無と `isHeldByTunnelOnly` を1回の lsof/ps で両方返す
    /// (`BridgeDiscovery.probeStatus` が `.transportFailed` の再分類に使う。別々に呼ぶと lsof を2回払う)
    static func listenerFacts(port: UInt16) -> (exists: Bool, isTunnelOnly: Bool) {
        guard let (_, command) = lookup(port: port) else { return (exists: false, isTunnelOnly: false) }
        return (exists: true, isTunnelOnly: commandIsIproxyForPort(command, port: port))
    }

    /// ポートを握っているのが**トンネルだけ**なら止める(`isHeldByTunnelOnly` と同じ判定)。
    /// 戻り値は止めたか。**名指しで `bridge down --port N` された経路からだけ**呼ぶ ——
    /// 台帳を辿る通常の停止(`IOSDeviceTransport.stopIproxy`)で足りるときはそちらが先に効く
    public static func stopTunnelHolder(port: UInt16) -> Bool {
        guard let (pid, command) = lookup(port: port),
              commandIsIproxyForPort(command, port: port) else { return false }
        terminateThenKill(pid: pid)
        return true
    }

    /// 応答しないポートの listener 記述からデバイスの udid を読む純粋関数。シミュレータの
    /// XCUITest ランナーは `-destination …,id=<UDID>` を、iproxy トンネルは `-u <UDID>` を持つ ——
    /// **2つ目のパーサは書かず** `RunnerDestination.udidTokens` を再利用する。複数の識別子が
    /// 出てきても最初の1つだけを使う(そのポートの持ち主は1台のはず)。listener が居ない・
    /// 識別子が読めない形は nil(= 「分からないから断らない」に倒す。呼び手はこの場合、
    /// lease を照合できないまま止めてよい)
    static func udidFromListener(_ listener: String?) -> String? {
        listener.flatMap { RunnerDestination.udidTokens(inCommand: $0).first }
    }

    /// `udidFromListener` の I/O ラッパー(lsof/ps → 純粋関数)。`bridge down` の口が呼ぶ。
    /// **トンネルだけが握るポート(ブリッジは死んでいる)は nil** —— 印を照合して断ると、
    /// 止めることが唯一の回復手段なのに「使用中」と言い続ける袋小路になる(maintainer-notes §46.4)
    public static func deviceUDID(fromListenerOn port: UInt16) -> String? {
        guard let (_, command) = lookup(port: port), !commandIsIproxyForPort(command, port: port) else {
            return nil
        }
        return udidFromListener(command)
    }

    /// `/status` が答えないポートの占有者が**別のデバイスのもの**か(プロセスの実体から読む)。
    /// **肯定的に別デバイスと読めたときだけ** true —— 占有者が読めない・識別子が出てこない形は
    /// false(= 自分のブリッジが駆動中で答えられないだけ、という扱い)。
    ///
    /// 用途はライブ操作の宛先決定: 既定ポートが「待受しているが答えない」とき、
    /// **自分の busy なブリッジ**なら待てばよく、**別のデバイスのもの**なら掴んではいけない
    /// (掴むと自動起動がそのポートへ自分のブリッジを立て、占有者を残骸として殺す)
    public static func isHeldByAnotherDevice(port: UInt16, udid: String) -> Bool {
        guard let listener = describe(port: port) else { return false }
        let tokens = RunnerDestination.udidTokens(inCommand: listener)
        guard !tokens.isEmpty else { return false }
        return !tokens.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    /// 記録された in-app ブリッジ(`.inapp`)から見て、**今そのポートを握っているのが別のデバイスか**。
    /// 判定は**肯定的に別のシミュレータと読めたときだけ** true —— 実機の in-app(ポートを握るのは
    /// iproxy)や、形の分からない占有者は false(= 「生きている」側)に倒す。
    ///
    /// これが要るのは、台帳の生死を「誰かが待受しているか」だけで決めていたため:
    /// 別のデバイスのブリッジがそのポートを取ると、**古い `.inapp` が生き続け**、供給が
    /// 「別アプリに注入された in-app ブリッジ」と読んで**無関係なデバイスのアプリを terminate** する
    /// (実地の負荷テストで確認)
    public static func listenerIsAnotherSimulator(listener: String, recordedUDID: String) -> Bool {
        guard listener.contains("/CoreSimulator/Devices/") else { return false }
        return !listener.contains("/CoreSimulator/Devices/\(recordedUDID)/")
    }

    /// lsof → ps で LISTEN しているプロセスを引く。lsof が見つけた直後に死んだ等は nil
    private static func lookup(port: UInt16) -> (pid: Int32, command: String)? {
        guard let lsof = try? Shell.run(["lsof", "-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]),
              lsof.status == 0,
              let pidLine = lsof.output.split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let pid = Int32(pidLine.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        guard let ps = try? Shell.run(["ps", "-p", String(pid), "-o", "command="]),
              ps.status == 0 else { return nil }
        return (pid, ps.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// iproxy がこのポートの USB トンネルを表しているか(コマンド文字列だけで判定。純粋関数)。
    /// iproxy は `<hostPort> <devicePort> -u <UDID>` の形で起動する(IOSDeviceTransport.startIproxy)。
    /// 第1引数がこのポートのものだけ「このポートのトンネル」とみなす(別ポート向けは無関係)
    static func commandIsIproxyForPort(_ command: String, port: UInt16) -> Bool {
        command.contains("iproxy")
            && command.split(separator: " ").dropFirst().first.flatMap({ UInt16($0) }) == port
    }

    enum IproxyOwnership: Equatable { case owned, foreign }

    /// iproxy 分岐の所有判定(純粋関数。lsof/kill を伴う stopIfOwnedBridge から切り出してテストする)。
    /// **台帳(bridge-<port>.device)の UDID が ownerUDID(呼び手が今回供給しようとしているデバイス)
    /// と一致するときだけ** .owned。記録が無い・不一致・ownerUDID 不明(呼び手が対象デバイスを
    /// 渡していない)はすべて .foreign —— **F8 実測**: 「第1引数がポート一致なら
    /// 自分の資産」とだけ判定していたため、別プロセスが実機へ張った iproxy を誤って kill し、
    /// 跡地に立てたシミュレータの in-app ブリッジが実機向けシナリオを代わりに実行して
    /// 誤った PASS を作った(実機レーンは "Cannot reach the driver" で全滅)。
    static func classifyIproxy(recordedDeviceUDID: String?, ownerUDID: String?) -> IproxyOwnership {
        guard let recordedDeviceUDID, let ownerUDID, recordedDeviceUDID == ownerUDID else { return .foreign }
        return .owned
    }

    /// port を LISTEN しているプロセスを特定し、以下のどちらかに一致する場合だけ後始末する:
    /// - シミュレータ内アプリ(コマンドパスが CoreSimulator/Devices と data/Containers/Bundle を
    ///   両方含む)。同ポートの .inapp があれば simctl terminate(in-app ブリッジの正しい後始末。
    ///   プロセス kill だけだと XCUITest/シミュレータ側の整合が崩れる)、無ければ SIGTERM→SIGKILL
    /// - このポート専用の xctestrun を引数に持つ xcodebuild(残骸ランナー)。SIGTERM→SIGKILL
    /// - 実機の USB トンネル(iproxy)。**ownerUDID と台帳の UDID が一致するときだけ**(classifyIproxy)
    /// それ以外(.foreign)は kill しない。
    /// - ownerUDID: 呼び手が「今回このポートに供給しようとしているデバイス」の UDID を分かって
    ///   いれば渡す。既定 nil = iproxy 分岐は常に .foreign(確認できない資産は殺さない安全側)。
    ///   xcodebuild 分岐では**肯定的に別デバイスと読めた回だけ** .foreign へ倒す
    ///   (RunnerDestination。xctestrun のファイル名はポートしか持たないので、同じポートに居る
    ///   別デバイスの生きたランナーを残骸として殺していた)。in-app 分岐では使わない
    public static func stopIfOwnedBridge(port: UInt16, stateDir: URL,
                                         derivedDataPath: URL,
                                         ownerUDID: String? = nil) -> PortHolderOutcome {
        guard let (pid, command) = lookup(port: port) else { return .notFound }
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
            .appendingPathComponent("Build/Products/FleetestRunner-\(port).xctestrun").path
        if command.contains("xcodebuild"), command.contains(xctestrunPath) {
            // **別のデバイスのランナーは残骸ではない**(killOrphanRunners と同じ判定)。
            // 照合できるのは呼び手が宛先を知っているときだけなので、ownerUDID が無ければそのまま
            if let ownerUDID, let other = RunnerDestination.belongsToOtherDevice(
                command: command, ourDevice: ownerUDID) {
                return .foreign(description: "another device's xcuitest runner (udid \(other))")
            }
            terminateThenKill(pid: pid)
            return waitForRelease(port: port, description: description)
        }

        // 実機の USB トンネル(iproxy <hostPort> ...)。LAN モードではそもそもホスト側に
        // LISTEN が無いのでここに来ない
        if commandIsIproxyForPort(command, port: port) {
            // stateDir は常に "<repoRoot>/.fleetest"(全呼び出し元が repoRoot.appendingPathComponent
            // (".fleetest") で渡す契約)なので、1つ上が repoRoot
            let recordedUDID = BridgeDeviceRecord.load(
                port: port, repoRoot: stateDir.deletingLastPathComponent())
            if classifyIproxy(recordedDeviceUDID: recordedUDID, ownerUDID: ownerUDID) == .owned {
                terminateThenKill(pid: pid)
                return waitForRelease(port: port, description: description)
            }
            let named = recordedUDID.map { "a physical device's USB tunnel (udid \($0))" } ?? description
            return .foreign(description: named)
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
        return .foreign(description: description + " (the port is not released even after stopping)")
    }
}
