// in-app ブリッジ(シミュレータのアプリに dylib 注入)の起動・再起動器。
// in-app ブリッジは注入先アプリのプロセス内に常駐するため自己再起動できない。
// 状態リセット(シナリオ毎の fresh 起動)はこのホスト/サブプロセス側が simctl で担う。

import Foundation
import FTCore

public struct InAppLauncher {
    public let repoRoot: URL
    public let udid: String
    public let port: UInt16

    var stateDir: URL { repoRoot.appendingPathComponent(".ftester") }

    public init(repoRoot: URL, udid: String, port: UInt16) {
        self.repoRoot = repoRoot
        self.udid = udid
        self.port = port
    }

    /// 注入する dylib(InAppBridge/build.sh の出力)
    public static func dylibPath(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("InAppBridge/build/libFTInAppBridge.dylib")
    }

    /// dylib が未ビルド**または古い**なら InAppBridge/build.sh でビルドする
    /// (BridgeLauncher の buildForTesting 相当)。
    /// **存在チェックだけにしてはいけない**: build/ は gitignore・手動ビルドなので、ブリッジの
    /// ソースを直しても注入されるのは古いバイナリのままになる。実害として、isChecked 追加と型の
    /// 役割正規化(b8a408c)がビルドされず ios-inapp/ios-heal だけ「checked が取れない」
    /// 「switch 型が出ない」で落ち続けた(2026-07-27 に判明)。SUT の再ビルド判定(Scripts/e2e.sh の
    /// needs_rebuild)・シナリオの BuildFingerprint と同じ考え方を、ここにも置く。
    public func buildIfNeeded() throws {
        guard Self.needsBuild(repoRoot: repoRoot) else { return }
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
    public func ensureBooted() throws {
        let result = try Shell.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        guard result.status == 0 else {
            throw InAppLauncherError.bootFailed(result.tail)
        }
    }

    /// アプリを dylib 注入付きで再起動 → /status 到達待ち。
    /// シナリオ開始時の fresh 状態確保(launchApp/relaunchApp)に使う。
    /// 戻り値は AppDriver.lastLaunchTiming 用の内訳(actionMs=launchViaCoreSimOrSimctl・
    /// waitMs=waitUntilReady())。BridgeProvisioner からは戻り値を使わず呼ぶ
    @discardableResult
    public func relaunch(bundleID: String) async throws -> LaunchTiming {
        let dylib = Self.dylibPath(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw InAppLauncherError.dylibMissing(dylib.path)
        }
        // dylib 注入とブリッジポートの指定。**接頭辞なし**の名前で持つ(simctl 経路のときだけ
        // launchViaCoreSimOrSimctl が SIMCTL_CHILD_ を前置する。CoreSimulator 経路にこの接頭辞は無い
        // ので剥がし忘れると dylib が注入されずブリッジが上がらない=in-app エンジンが丸ごと死ぬ)。
        // DOM 経路の殺しスイッチはホスト側の環境変数で受けて注入先へ引き渡す
        // (dylib はアプリのプロセスで動くので、そこへ伝えないと効かない)
        var env = [
            "DYLD_INSERT_LIBRARIES": dylib.path,
            "FT_PORT": "\(port)",
            // 起動元の自己申告(/status の ownerRepo。doctor の刈り取り判定が依存)
            "FT_OWNER_REPO": repoRoot.path,
        ]
        if let webViewDOM = ProcessInfo.processInfo.environment["FT_WEBVIEW_DOM"] {
            env["FT_WEBVIEW_DOM"] = webViewDOM
        }
        let clock = ContinuousClock()
        let actionStart = clock.now
        try launchViaCoreSimOrSimctl(bundleID: bundleID, environment: env)
        let actionMs = continuousClockMs(clock.now - actionStart)
        let waitStart = clock.now
        try await waitUntilReady()
        let waitMs = continuousClockMs(clock.now - waitStart)
        // pid ファイルを持たない in-app ブリッジを bridge down 系コマンドが後始末できるよう記録。
        // **sourceDigest も残す**: これが無いと、次の run が「ソースが変わったのに稼働中の
        // ブリッジを再利用する」= 変更が1度も実行されないまま緑になる(InAppBridgeState 冒頭)
        InAppBridgeState.write(stateDir: stateDir, port: port, udid: udid, bundleID: bundleID,
                               sourceDigest: try? BridgeSourceSet.inApp.digest(repoRoot: repoRoot))
        return LaunchTiming(actionMs: actionMs, waitMs: waitMs)
    }

    /// CoreSimulator 直叩き優先(simctl launch 883〜909ms → ほぼ0ms・2026-08-02実測)。
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
        _ = try? Shell.run(["xcrun", "simctl", "terminate", udid, bundleID], timeout: 15)
    }

    public func waitUntilReady(timeout: TimeInterval = 30) async throws {
        let client = BridgeClient(port: port, timeoutSeconds: 3)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                if try await client.status().ready { return }
            } catch { lastError = error }
            // 80ms 間隔(ready 検知の遅れは平均でこの半分。300ms だと最大 +300ms 遅れる)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        throw InAppLauncherError.notReady(lastError.map { "\($0)" } ?? "no response")
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
