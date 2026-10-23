// in-app ブリッジ(シミュレータのアプリに dylib 注入)の起動・再起動器。
// in-app ブリッジは注入先アプリのプロセス内に常駐するため自己再起動できない。
// 状態リセット(シナリオ毎の fresh 起動)はこのホスト/サブプロセス側が simctl で担う。

import Foundation
import FTCore

public struct InAppLauncher: Sendable {
    public let repoRoot: URL
    public let udid: String
    public let port: UInt16
    /// 実機(物理 iPhone)なら true。true のとき simctl/CoreSimulator ではなく devicectl + iproxy で注入起動する
    public let physical: Bool
    /// 実機で注入する dylib の署名に使う証明書を割り出すアプリバンドル(appPathPhysical ?? appPath)。
    /// 署名可否は呼び手(供給)が `InAppCodeSign.inspect` で先に確かめてから渡す。シミュレータでは nil
    public let appBundle: String?
    /// USB(iproxy)で張るか。実機のみ参照(シミュレータはループバック共有)
    public let wired: Bool
    /// inapp モードの実機で、相方(xcuitest)のトンネルのポート。in-app の establish がこれを消さないように残す
    public let keepPeerPort: UInt16?

    var stateDir: URL { repoRoot.appendingPathComponent(".fleetest") }

    public init(repoRoot: URL, udid: String, port: UInt16,
                physical: Bool = false, appBundle: String? = nil, wired: Bool = false,
                keepPeerPort: UInt16? = nil) {
        self.repoRoot = repoRoot
        self.udid = udid
        self.port = port
        self.physical = physical
        self.appBundle = appBundle
        self.wired = wired
        self.keepPeerPort = keepPeerPort
    }

    /// 注入する dylib(InAppBridge/build.sh の出力)。実機は iphoneos 版(未署名・署名は relaunch 時に per-app)
    public static func dylibPath(repoRoot: URL, physical: Bool = false) -> URL {
        repoRoot.appendingPathComponent(
            physical ? "InAppBridge/build/libFTInAppBridge-device.dylib"
                     : "InAppBridge/build/libFTInAppBridge.dylib")
    }

    /// dylib が未ビルド**または古い**なら InAppBridge/build.sh でビルドする
    /// (BridgeLauncher の buildForTesting 相当)。
    /// **存在チェックだけにしてはいけない**: build/ は gitignore・手動ビルドなので、ブリッジの
    /// ソースを直しても注入されるのは古いバイナリのままになる。実害として、isChecked 追加と型の
    /// 役割正規化(b8a408c)がビルドされず ios-inapp/ios-heal だけ「checked が取れない」
    /// 「switch 型が出ない」で落ち続けた(判明した実例)。SUT の再ビルド判定(Scripts/e2e.sh の
    /// needs_rebuild)・シナリオの BuildFingerprint と同じ考え方を、ここにも置く。
    public func buildIfNeeded() throws {
        let deviceStale = physical && Self.deviceDylibStale(repoRoot: repoRoot)
        guard Self.needsBuild(repoRoot: repoRoot) || deviceStale else { return }
        let script = repoRoot.appendingPathComponent("InAppBridge/build.sh").path
        // script 不在は「repoRoot が受け手パッケージを指している」典型症状。bash の
        // "No such file or directory" だけでは原因に辿り着けないので、ここで言い当てる
        guard FileManager.default.fileExists(atPath: script) else {
            throw InAppLauncherError.repoRootInvalid(repoRoot.path)
        }
        let result = try Shell.run(["bash", script])
        guard result.status == 0 else {
            throw InAppLauncherError.buildFailed(result.tail)
        }
        // 実機は iphoneos 版も作る(署名は relaunch 時に per-app)
        if physical {
            let deviceResult = try Shell.run(["bash", script, "device"])
            guard deviceResult.status == 0 else {
                throw InAppLauncherError.buildFailed(deviceResult.tail)
            }
        }
        ToolchainFingerprint.store(at: Self.fingerprintPath(repoRoot: repoRoot))
    }

    /// dylib をどの Xcode/SDK で作ったかの記録(build/ 配下 = dylib と一緒に消える場所)
    static func fingerprintPath(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("InAppBridge/build/.toolchain")
    }

    /// dylib が無い / 入力より古い / 判定不能 なら true(再ビルドが要る)
    static func needsBuild(repoRoot: URL, toolchain: String? = ToolchainFingerprint.current()) -> Bool {
        guard let built = modifiedAt(dylibPath(repoRoot: repoRoot)),
              let newest = newestSourceTimestamp(repoRoot: repoRoot) else { return true }
        if newest > built { return true }
        // Xcode/SDK を上げてもソースの mtime は動かない。指紋が変わっていたら作り直す
        // (旧 SDK でリンクした dylib を新ランタイムへ注入すると実行時に落ちる)
        return !ToolchainFingerprint.matches(
            storedAt: fingerprintPath(repoRoot: repoRoot), current: toolchain)
    }

    /// 実機 dylib が無い / 入力より古いなら true(simulator 用とは別物なので別に見る)
    static func deviceDylibStale(repoRoot: URL) -> Bool {
        guard let built = modifiedAt(dylibPath(repoRoot: repoRoot, physical: true)),
              let newest = newestSourceTimestamp(repoRoot: repoRoot) else { return true }
        return newest > built
    }

    /// dylib の入力(build.sh がコンパイルするソース一式 + build.sh 自身)の最終更新時刻。
    /// 一覧は BridgeSourceSet.inApp が唯一の定義元(ここに再掲するとズレる。実害: 共有 DTO の
    /// WebViewDOMSnapshot.swift が build.sh の SWIFT_SOURCES にあるのにこちらから漏れていた)。
    /// 取得できない場合は nil = 「判定不能」として再ビルドさせる(古いまま走らせるより安全)
    static func newestSourceTimestamp(repoRoot: URL) -> Date? {
        guard let paths = try? BridgeSourceSet.inApp.files(repoRoot: repoRoot) else { return nil }
        let inputs = paths.map { repoRoot.appendingPathComponent($0) }
        let dates = inputs.compactMap(modifiedAt)
        return dates.count == inputs.count ? dates.max() : nil
    }

    private static func modifiedAt(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// シミュレータが Shutdown なら boot して待つ(ブート済みなら即返るが ~200ms かかるため
    /// プロビジョニング時のみ呼ぶ。relaunch には入れない=シナリオ毎の launch を遅くしない)。
    /// XCUITest 経路は xcodebuild が自動ブートするが、simctl launch はブート済みが前提。
    public func ensureBooted(log: (String) -> Void) throws {
        do { try SimulatorBoot.ensureBooted(udid: udid, log: log) } catch SimulatorBoot.Error.failed(_, let detail) {
            throw InAppLauncherError.bootFailed(detail)
        }
    }

    /// アプリを dylib 注入付きで再起動 → /status 到達待ち。
    /// シナリオ開始時の fresh 状態確保(launchApp/relaunchApp)に使う。
    /// 戻り値は AppDriver.lastLaunchTiming 用の内訳(actionMs=launchViaCoreSimOrSimctl・
    /// waitMs=waitUntilReady())。BridgeProvisioner からは戻り値を使わず呼ぶ
    @discardableResult
    public func relaunch(bundleID: String) async throws -> LaunchTiming {
        if physical { return try await relaunchPhysical(bundleID: bundleID) }
        let dylib = Self.dylibPath(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw InAppLauncherError.dylibMissing(dylib.path)
        }
        // dylib 注入とブリッジポートの指定。**接頭辞なし**の名前で持つ(simctl 経路のときだけ
        // launchViaCoreSimOrSimctl が SIMCTL_CHILD_ を前置する。CoreSimulator 経路にこの接頭辞は無い
        // ので剥がし忘れると dylib が注入されずブリッジが上がらない=in-app ブリッジが丸ごと死ぬ)。
        // DOM 経路の殺しスイッチはホスト側の環境変数で受けて注入先へ引き渡す
        // (dylib はアプリのプロセスで動くので、そこへ伝えないと効かない)
        var env = [
            "DYLD_INSERT_LIBRARIES": dylib.path,
            ProcessEnvironmentKey.port: "\(port)",
            // 起動元の自己申告(/status の ownerRepo。doctor の刈り取り判定が依存)
            ProcessEnvironmentKey.ownerRepo: repoRoot.path,
        ]
        if let webViewDOM = ProcessInfo.processInfo.environment[ProcessEnvironmentKey.webViewDOM] {
            env[ProcessEnvironmentKey.webViewDOM] = webViewDOM
        }
        let clock = ContinuousClock()
        let actionStart = clock.now
        try launchViaCoreSimOrSimctl(bundleID: bundleID, environment: env)
        let actionMs = continuousClockMs(clock.now - actionStart)
        // pid ファイルを持たない in-app ブリッジを bridge down 系コマンドが後始末できるよう記録。
        // **ready を待つ前に書く**: 待っている間に run が中断される・アプリの起動が
        // 遅れて期限を超えると、注入済みで後から待受を始めるアプリが**記録の無い残骸**として
        // 残り、次の供給がそのポートを空きと誤認して衝突する(受け手報告の never joined)。
        // 失敗時は呼び手(BridgeProvisioner)が terminate と記録の削除まで行う。
        // **sourceDigest も残す**: これが無いと、次の run が「ソースが変わったのに稼働中の
        // ブリッジを再利用する」= 変更が1度も実行されないまま緑になる(InAppBridgeState 冒頭)
        InAppBridgeState.write(stateDir: stateDir, port: port, udid: udid, bundleID: bundleID,
                               sourceDigest: try? BridgeSourceSet.inApp.digest(repoRoot: repoRoot))
        let waitStart = clock.now
        do {
            try await waitUntilReady()
        } catch let InAppLauncherError.notReady(detail) {
            // **一次原因を添える**: 「did not respond in time: connection refused」の裏が
            // アプリの即死(例: ランタイム共有キャッシュ破損の dyld エラー = OS_REASON_DYLD。
            // simctl shutdown→boot で回復)でも、素の文言からは見えず simctl のログを手で
            // 掘ることになる(受け手報告)。ここは bundleID を知っている唯一の層。
            // 30 秒待った後なので .ips の書き込み遅延(約2秒)はもう待たなくてよい
            throw InAppLauncherError.notReady(crashAnnotated(detail, bundleID: bundleID))
        }
        let waitMs = continuousClockMs(clock.now - waitStart)
        return LaunchTiming(actionMs: actionMs, waitMs: waitMs)
    }

    /// 実機 in-app。**署名・配置・iproxy は供給(親プロセス)でだけ行い**、シナリオ(サンドボックスの中)の
    /// 起こし直しは devicectl の起動だけにする —— サンドボックスはキーチェーン(codesign)も iproxy の
    /// spawn も通さないため。初回(台帳が無い)は full、以降は token と container パスを台帳から再利用する。
    @discardableResult
    private func relaunchPhysical(bundleID: String) async throws -> LaunchTiming {
        // 再利用: 供給で署名済みの dylib がホストに残っていれば、**毎回コンテナへコピーし直して**起動する。
        // clearAppData は実機ではアプリの再インストール = データコンテナごと消えるので、置きっぱなしの
        // パスを使い回すと注入なしで起動して落ちる。コピーはサンドボックスでも許す(codesign は供給だけ)
        let signed = Self.signedDylibPath(repoRoot: repoRoot, port: port)
        if FileManager.default.fileExists(atPath: signed.path),
           let endpoint = BridgeEndpoint.recorded(port: port, repoRoot: repoRoot), let token = endpoint.token {
            let clock = ContinuousClock()
            let copyStart = clock.now
            let containerPath = try copyDylibToContainer(signed: signed, bundleID: bundleID)
            let copyMs = continuousClockMs(clock.now - copyStart)
            return try await launchPhysical(bundleID: bundleID, containerPath: containerPath,
                                            token: token, endpoint: endpoint, setupMs: copyMs)
        }
        // 初回(供給・親): 署名(か発行側の署名済みの写し)→ データコンテナへ配置 → iproxy トンネル → 起動 → 到達待ち
        guard let appBundle else { throw InAppLauncherError.launchFailed("no app bundle to sign the in-app dylib against") }
        let info = InAppCodeSign.inspect(appBundle: appBundle,
                                         sourceDigest: try? BridgeSourceSet.inApp.digest(repoRoot: repoRoot))
        let clock = ContinuousClock()
        let setupStart = clock.now
        let signedNew: URL
        if let identity = info.identitySHA1 {
            let deviceDylib = Self.dylibPath(repoRoot: repoRoot, physical: true)
            guard FileManager.default.fileExists(atPath: deviceDylib.path) else {
                throw InAppLauncherError.dylibMissing(deviceDylib.path)
            }
            signedNew = try InAppCodeSign.signedCopy(
                deviceDylib: deviceDylib, identitySHA1: identity,
                outputDir: Self.signedDylibPath(repoRoot: repoRoot, port: port).deletingLastPathComponent(),
                basename: "libFTInAppBridge-\(port).dylib")
        } else if let presigned = info.presignedDylib {
            // シナリオの起こし直しは per-port の置き場から再コピーするので、同じ場所へ写す
            signedNew = Self.signedDylibPath(repoRoot: repoRoot, port: port)
            try FileManager.default.createDirectory(at: signedNew.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: signedNew)
            try FileManager.default.copyItem(at: presigned, to: signedNew)
        } else {
            // 供給が inspect で注入可を確かめてから in-app を選ぶので、ここへは来ない(保険)
            throw InAppLauncherError.launchFailed("the app is not injectable (\(info.reason ?? "unknown")); it should have fallen back to XCUITest")
        }
        let containerPath = try copyDylibToContainer(signed: signedNew, bundleID: bundleID)
        let setupMs = continuousClockMs(clock.now - setupStart)
        let token = BridgeAPI.makeBridgeToken()
        // iproxy トンネルを張り endpoint(token 入り)を台帳へ記録する。XCUITest 実機と同じ経路を流用。
        // **起動より先に張る**(起動は devicectl なのでトンネルに依らず、以降の到達待ちにトンネルが要る)
        let endpoint = try await IOSDeviceTransport.establish(
            port: port, deviceUDID: udid, repoRoot: repoRoot, wired: wired, token: token,
            keepPeerPorts: keepPeerPort.map { [$0] } ?? [])
        return try await launchPhysical(bundleID: bundleID, containerPath: containerPath,
                                        token: token, endpoint: endpoint, setupMs: setupMs)
    }

    /// 署名済み dylib(供給が per-port で署名して残す。シナリオの起こし直しはこれをコンテナへ再コピーする)
    static func signedDylibPath(repoRoot: URL, port: UInt16) -> URL {
        repoRoot.appendingPathComponent("InAppBridge/build/signed/libFTInAppBridge-\(port).dylib")
    }

    /// devicectl で注入起動して /status 到達を待つ(供給・シナリオの共通部分)。
    /// `setupMs` は供給の署名・配置ぶん(再利用時は 0)で actionMs に足す
    private func launchPhysical(bundleID: String, containerPath: String, token: String,
                                endpoint: BridgeEndpoint, setupMs: Int) async throws -> LaunchTiming {
        let clock = ContinuousClock()
        let actionStart = clock.now
        var env = [
            "DYLD_INSERT_LIBRARIES": containerPath,
            ProcessEnvironmentKey.port: "\(port)",
            ProcessEnvironmentKey.ownerRepo: repoRoot.path,
            BridgeAPI.bindAllEnvKey: "1",
            BridgeAPI.bridgeTokenEnvKey: token,
        ]
        if let webViewDOM = ProcessInfo.processInfo.environment[ProcessEnvironmentKey.webViewDOM] {
            env[ProcessEnvironmentKey.webViewDOM] = webViewDOM
        }
        try deviceLaunch(bundleID: bundleID, environment: env)
        let actionMs = setupMs + continuousClockMs(clock.now - actionStart)
        InAppBridgeState.write(stateDir: stateDir, port: port, udid: udid, bundleID: bundleID,
                               sourceDigest: try? BridgeSourceSet.inApp.digest(repoRoot: repoRoot))
        let waitStart = clock.now
        do {
            try await waitUntilReady(endpoint: endpoint)
        } catch let InAppLauncherError.notReady(detail) {
            throw InAppLauncherError.notReady(crashAnnotated(detail, bundleID: bundleID))
        }
        return LaunchTiming(actionMs: actionMs, waitMs: continuousClockMs(clock.now - waitStart))
    }


    /// 署名済み dylib をアプリのデータコンテナ(`tmp/`)へ置き、デバイス上の絶対パスを返す。
    /// **コマンド形は固定**(サンドボックスの DevicectlPolicy の許可表と1対1)
    private func copyDylibToContainer(signed: URL, bundleID: String) throws -> String {
        let result = try Shell.run([
            "xcrun", "devicectl", "device", "copy", "to", "--device", udid,
            "--source", signed.path, "--destination", "tmp/libFTInAppBridge.dylib",
            "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
            "--json-output", "-", "-q",
        ], timeout: 120)
        guard result.status == 0 else { throw InAppLauncherError.launchFailed("devicectl copy to failed:\n\(result.tail)") }
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = json["result"] as? [String: Any],
              let dest = r["destination"] as? String else {
            throw InAppLauncherError.launchFailed("devicectl copy to: could not read the destination path")
        }
        return dest.replacingOccurrences(of: "file://", with: "")
    }

    /// devicectl で注入起動(既存プロセスは終了)。**コマンド形は固定**(DevicectlPolicy の許可表と1対1)。
    /// `--environment-variables` は JSON 1引数(値にスペースを含まないので引用は不要)
    private func deviceLaunch(bundleID: String, environment: [String: String]) throws {
        let envJSON = String(data: try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys]),
                             encoding: .utf8) ?? "{}"
        let result = try Shell.run([
            "xcrun", "devicectl", "device", "process", "launch", "--device", udid,
            "--terminate-existing", "--environment-variables", envJSON, bundleID, "-q",
        ], timeout: 120)
        guard result.status == 0 else { throw InAppLauncherError.launchFailed("devicectl process launch failed:\n\(result.tail)") }
    }

    /// InAppDriver.crashAnnotated と同型(あちらは切断直後なのでポーリングが要る。こちらは
    /// waitUntilReady のタイムアウト後 = クラッシュから数十秒経っているので1回だけ引く。
    /// 窓は待った時間ぶん広くとる — 即死は待ちの先頭で起きている)
    private func crashAnnotated(_ detail: String, bundleID: String) -> String {
        guard let hit = SimulatorCrashReport.findRecent(bundleID: bundleID,
                                                        udid: udid == "booted" ? nil : udid,
                                                        within: 60) else {
            return detail + " (no recent crash report for \(bundleID) —"
                + " the app process may have been killed without one, or never launched)"
        }
        let suffix = hit.reason.map { " (\($0))" } ?? ""
        LastAppCrash.shared.record(AppCrashRecord(evidence: .crashReport, path: hit.path, summary: hit.reason))
        return detail + " / the app crashed on launch: \(hit.path)\(suffix)"
    }

    /// CoreSimulator 直叩き優先(simctl launch 883〜909ms → ほぼ0ms・実測)。
    /// **フォールバックするのは「シムが使えない」ときだけ**(nil)。起動そのものの失敗は投げる
    /// (simctl で撃ち直しても同じ結果になり、本物の失敗を隠して二重に時間を使うだけ)。
    /// 強制的に simctl へ戻すには FT_SIMULATOR_CONTROL=simctl
    /// simctl 経路だけ環境変数キーへ SIMCTL_CHILD_ を前置する(simctl がこの接頭辞を剥がして
    /// 子プロセスへ渡す仕様。CoreSimulator 経路の options.environment には接頭辞なしで渡す契約)
    private func launchViaCoreSimOrSimctl(bundleID: String, environment: [String: String]) throws {
        if let result = CoreSimAppControl.launch(
            udid: udid, bundleID: bundleID, environment: environment, terminateRunningProcess: true) {
            guard result.success else {
                throw InAppLauncherError.launchFailed(result.error ?? "unknown")
            }
            return
        }
        // --terminate-running-process で terminate+launch を1コールに(simctl 往復を2→1)。
        // Shell.run は /usr/bin/env 経由なので、先頭に NAME=VALUE を置けば launch されるアプリへ
        // SIMCTL_CHILD_* が伝わる
        let simctlEnv = environment.map { "SIMCTL_CHILD_\($0.key)=\($0.value)" }
        let result = try Shell.run(simctlEnv + [
            "xcrun", "simctl", "launch", "--terminate-running-process", udid, bundleID,
        ])
        guard result.status == 0 else {
            throw InAppLauncherError.launchFailed(result.tail)
        }
    }

    public func terminate(bundleID: String) {
        if physical {
            Self.terminateOnPhysicalDevice(udid: udid, bundleID: bundleID)
            return
        }
        _ = try? Shell.run(["xcrun", "simctl", "terminate", udid, bundleID], timeout: 15)
    }

    /// 失敗は飲む(呼び手は後始末・撃ち直しの前段で、止められなくても次の手が理由を言う)。実体は IOSPhysicalRunningApps.terminate
    public static func terminateOnPhysicalDevice(udid: String, bundleID: String) {
        _ = try? IOSPhysicalRunningApps.terminate(udid: udid, bundleID: bundleID, timeout: 15)
    }

    /// 実機は endpoint(iproxy のループバック + token)へ、シミュレータはループバックへ到達待ちする
    public func waitUntilReady(endpoint: BridgeEndpoint? = nil, timeout: TimeInterval = 30) async throws {
        let client: BridgeClient
        if let endpoint {
            client = BridgeClient(endpoint: endpoint, timeoutSeconds: 3, physicalUDID: physical ? udid : nil)
        } else {
            client = BridgeClient(port: port, timeoutSeconds: 3)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                // **答えた相手が自分の注入先かも見る**: ポートが別の端末のブリッジに使われていると、その `ready` で
                // 起動できたと読み、以後の操作が別の端末へ届く(ポートは端末をまたいで使い回され、台帳は古いまま残る)。
                // udid を申告しない旧ブリッジは従来どおり ready だけで判断する
                let status = try await client.status()
                if status.ready, Self.isOwnBridge(reportedUDID: status.udid, udid: udid) { return }
                if status.ready { lastError = InAppLauncherError.notReady("port \(port) is answered by another device (\(status.udid ?? "?"))") }
            } catch { lastError = error }
            // 80ms 間隔(ready 検知の遅れは平均でこの半分。300ms だと最大 +300ms 遅れる)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        throw InAppLauncherError.notReady(lastError.map(BridgeClient.readinessDetail) ?? "no response")
    }
}

extension InAppLauncher {
    /// 起動待ちで答えた相手が、注入した端末のブリッジか(udid の申告が無ければ判断しない = true)
    static func isOwnBridge(reportedUDID: String?, udid: String) -> Bool {
        guard let reportedUDID else { return true }
        return reportedUDID.caseInsensitiveCompare(udid) == .orderedSame
    }
}

/// Duration → 整数ミリ秒。StepExecutor.ms / continuousClockMilliseconds と同じ計算式だが、
/// モジュールを跨いで参照できないためここに複製している(要同期)
func continuousClockMs(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}

public enum InAppLauncherError: Error, LocalizedError {
    case dylibMissing(String)
    case repoRootInvalid(String)
    case buildFailed(String)
    case bootFailed(String)
    case launchFailed(String)
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .dylibMissing(let path):
            return "the in-app bridge dylib was not found (build it with InAppBridge/build.sh): \(path)"
        case .repoRootInvalid(let root):
            return "\(root) has no InAppBridge/build.sh. "
                + "This must be the root of the tool itself (the foundation-tester clone)"
                + " — not the root of the scenario package. "
                + "If it cannot be resolved, set the clone root via the FT_TOOL_ROOT environment variable"
        case .buildFailed(let tail):
            return "InAppBridge/build.sh failed:\n\(tail)"
        case .bootFailed(let tail):
            return "could not boot the simulator (simctl bootstatus -b):\n\(tail)"
        case .launchFailed(let tail):
            return "the injected app launch failed"
                + " (the install was verified during provisioning, so look for simulator trouble "
                + "or an app crash):\n\(tail)"
        case .notReady(let detail):
            return "the in-app bridge did not respond in time: \(detail)"
        }
    }
}
