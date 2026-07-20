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

    /// bridgeConnectionRefused だけ、直近クラッシュレポートのパス/理由を detail 末尾に付与して
    /// 同じ case で再 throw する(呼び出し側は catch DriverError.bridgeConnectionRefused のまま動く)。
    private func withCrashContext<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let DriverError.bridgeConnectionRefused(detail) {
            guard let bundleID = lastBundleID,
                  let hit = SimulatorCrashReport.findRecent(bundleID: bundleID) else {
                throw DriverError.bridgeConnectionRefused(detail)
            }
            let suffix = hit.reason.map { " (\($0))" } ?? ""
            throw DriverError.bridgeConnectionRefused(detail + " / クラッシュレポート: \(hit.path)\(suffix)")
        }
    }
}
