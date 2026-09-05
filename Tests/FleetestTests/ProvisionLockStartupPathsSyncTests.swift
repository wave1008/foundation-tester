import XCTest

/// 「空きポート選択 → 起動(pid ファイルが書かれるまで)」を ProvisionLock で直列化している
/// 起動経路の集合を固定する。BridgeProvisioner.provision() 以外にも、ロックを取らずに
/// freePort/startDetached を撃つ経路(XCUIBridgeResolver.start / LiveBridgeAutoStarter.launchBridge)
/// があり、同時に走ると同じ空きポートを選んで bindFailed(48) で衝突していた。
/// **新しい起動経路を足したら、ここへの追随を忘れずに**(等号照合なので追加漏れは落ちる)。
final class ProvisionLockStartupPathsSyncTests: XCTestCase {

    /// ロックを取る(はずの)起動経路。ファイルパスは repo root からの相対
    private static let expectedLockingSources: Set<String> = [
        "Sources/FTBridgeClient/BridgeProvisioner.swift",
        "Sources/FTBridgeClient/XCUIBridgeResolver.swift",
        "Sources/fleetest/LiveBridgeAutoStarter.swift",
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEachExpectedSourceReferencesProvisionLock() throws {
        for relativePath in Self.expectedLockingSources {
            let url = repoRoot().appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("ProvisionLock"),
                          "\(relativePath) は起動をロックで直列化しているはず(ProvisionLock 未参照)")
        }
    }
}
