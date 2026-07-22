// シミュレータのアプリに dylib 注入した in-app ブリッジを駆動する AppDriver 実装。
// launch/terminate は simctl 再起動+注入(自己再起動できないため)、他は HTTP で
// BridgeClient に委譲する。HTTP プロトコルは XCUITest ブリッジと同一なので委譲でよい。

import Foundation
import FTCore

public final class InAppDriver: AppDriver {
    private let client: BridgeClient
    private let launcher: InAppLauncher
    // terminate() は bundleID を取らないため、直近 launch のものを使う
    private var lastBundleID: String?

    public init(repoRoot: URL, udid: String, port: UInt16) {
        self.client = BridgeClient(port: port)
        self.launcher = InAppLauncher(repoRoot: repoRoot, udid: udid, port: port)
    }

    // launch/terminate だけ simctl(注入起動)

    public func launch(bundleID: String) async throws {
        lastBundleID = bundleID
        try await launcher.relaunch(bundleID: bundleID)
    }

    public func terminate() async throws {
        guard let bundleID = lastBundleID else { return }
        launcher.terminate(bundleID: bundleID)
    }

    // 以下は in-app ブリッジへ HTTP 委譲(XCUITest と同一プロトコル)

    public func status() async throws -> StatusResponse { try await withCrashContext { try await client.status() } }
    public func install(packagePath: String) async throws {
        try await withCrashContext { try await client.install(packagePath: packagePath) }
    }
    public func snapshot() async throws -> SnapshotResponse {
        try await withCrashContext { try await client.snapshot() }
    }
    public func tap(ref: Int) async throws { try await withCrashContext { try await client.tap(ref: ref) } }
    public func tap(x: Double, y: Double) async throws {
        try await withCrashContext { try await client.tap(x: x, y: y) }
    }
    public func type(ref: Int?, text: String) async throws {
        try await withCrashContext { try await client.type(ref: ref, text: text) }
    }
    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withCrashContext { try await client.swipe(direction) }
    }
    public func press(ref: Int, duration: Double) async throws {
        try await withCrashContext { try await client.press(ref: ref, duration: duration) }
    }
    public func screenshot() async throws -> Data { try await withCrashContext { try await client.screenshot() } }

    /// 接続系エラーに、直近クラッシュレポートの有無に応じた切り分け情報を detail 末尾に付与して
    /// **同じ case のまま**再 throw する(呼び出し側の catch は変えなくてよい)。
    /// lastBundleID が nil(launch 未実施)なら素の detail のまま re-throw。
    ///
    /// refused だけでなく unreachable も見るのが要点: **操作自体がクラッシュを引き起こした場合**は
    /// リクエスト配送中に切断されるため URLSession は networkConnectionLost を返し、
    /// `isDefiniteDeliveryFailure` が false → bridgeUnreachable に分類される。refused だけを
    /// 見ていると「最も普通のクラッシュ」でレポート添付を取り逃す(2026-07-22 実測)。
    /// 分類自体は変えない(unreachable は「届いたか不明」= リトライ可否の意味論を持つため)。
    private func withCrashContext<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let DriverError.bridgeConnectionRefused(detail) {
            throw DriverError.bridgeConnectionRefused(crashAnnotated(detail))
        } catch let DriverError.bridgeUnreachable(detail) {
            throw DriverError.bridgeUnreachable(crashAnnotated(detail))
        }
    }

    private func crashAnnotated(_ detail: String) -> String {
        guard let bundleID = lastBundleID else { return detail }
        if let hit = SimulatorCrashReport.findRecent(bundleID: bundleID) {
            let suffix = hit.reason.map { " (\($0))" } ?? ""
            return detail + " / アプリがクラッシュしました: \(hit.path)\(suffix)"
        }
        return detail + " / 直近のクラッシュレポートは見つかりませんでした"
            + "(OS によるプロセス終了・メモリ圧・自発終了の可能性。"
            + "ハイブリッド混在実行では背面アプリが suspend/終了されることがあります)"
    }
}
