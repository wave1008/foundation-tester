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
    }

    /// dylib が無い / 入力より古い / 判定不能 なら true(再ビルドが要る)
    static func needsBuild(repoRoot: URL) -> Bool {
        guard let built = modifiedAt(dylibPath(repoRoot: repoRoot)),
              let newest = newestSourceTimestamp(repoRoot: repoRoot) else { return true }
        return newest > built
    }

    /// dylib の入力(build.sh がコンパイルするソース一式 + build.sh 自身)の最終更新時刻。
    /// 共有 DTO(Sources/FTCore/BridgeDTO.swift)も入力なので必ず含める(build.sh の SWIFT_SOURCES と対)。
    /// 取得できない場合は nil = 「判定不能」として再ビルドさせる(古いまま走らせるより安全)
    static func newestSourceTimestamp(repoRoot: URL) -> Date? {
        var inputs = [
            repoRoot.appendingPathComponent("InAppBridge/build.sh"),
            repoRoot.appendingPathComponent("Sources/FTCore/BridgeDTO.swift"),
        ]
        let sourcesDir = repoRoot.appendingPathComponent("InAppBridge/Sources")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sourcesDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        inputs += entries
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
    public func relaunch(bundleID: String) async throws {
        let dylib = Self.dylibPath(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw InAppLauncherError.dylibMissing(dylib.path)
        }
        // --terminate-running-process で terminate+launch を1コールに(simctl 往復を2→1)。
        // Shell.run は /usr/bin/env 経由なので、先頭に NAME=VALUE を置けば launch されるアプリへ
        // SIMCTL_CHILD_* が伝わる(dylib 注入とブリッジポートの指定)。
        let result = try Shell.run([
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(dylib.path)",
            "SIMCTL_CHILD_FT_PORT=\(port)",
            "xcrun", "simctl", "launch", "--terminate-running-process", udid, bundleID,
        ])
        guard result.status == 0 else {
            throw InAppLauncherError.launchFailed(result.tail)
        }
        try await waitUntilReady()
        // pid ファイルを持たない in-app ブリッジを bridge down 系コマンドが後始末できるよう記録
        InAppBridgeState.write(stateDir: stateDir, port: port, udid: udid, bundleID: bundleID)
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
            return "in-app ブリッジの dylib が見つかりません(InAppBridge/build.sh でビルド): \(path)"
        case .repoRootInvalid(let root):
            return "\(root) に InAppBridge/build.sh がありません。"
                + "ここはツール本体(foundation-tester のクローン)のルートである必要があります"
                + "(シナリオ側パッケージのルートではありません)。"
                + "解決できないときは環境変数 FT_TOOL_ROOT にクローンのルートを指定してください"
        case .buildFailed(let tail):
            return "InAppBridge/build.sh が失敗しました:\n\(tail)"
        case .bootFailed(let tail):
            return "シミュレータをブートできませんでした(simctl bootstatus -b):\n\(tail)"
        case .launchFailed(let tail):
            return "アプリの注入起動(simctl launch)に失敗しました"
                + "(プロビジョニング時にインストール確認済みのため、シミュレータの状態異常や"
                + "アプリのクラッシュ等を確認してください):\n\(tail)"
        case .notReady(let detail):
            return "in-app ブリッジが時間内に応答しませんでした: \(detail)"
        }
    }
}
