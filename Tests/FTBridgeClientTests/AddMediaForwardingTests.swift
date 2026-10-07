// `addMedia(path:)` を**包むドライバが必ず素通しする**ことと、iOS 実機が失敗になること。
// 既定実装は 501 を返すだけなので、ラッパーが転送を足し忘れると、そのエンジン構成では addMedia が一度も届かない
// (OpenURLForwardingTests と同じ作法: ソースを走査して、snapshot() を実装する型に addMedia が無いものを検出する)。

import XCTest
@testable import FTBridgeClient
import FTCore

final class AddMediaForwardingTests: XCTestCase {

    /// 意図して既定のままにしているドライバだけ(springboard 参照専用でアプリも写真も持たない)
    private static let exempt: Set<String> = ["AppDriver.swift", "SystemUIDriver.swift"]

    func testEveryDriverImplementingSnapshotAlsoForwardsAddMedia() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var missing: [String] = []
        var checked = 0
        for dir in ["Sources/FTBridgeClient", "Sources/FTAndroid", "Sources/FTCore"] {
            let base = root.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" && !Self.exempt.contains(file.lastPathComponent) {
                guard let source = try? String(contentsOf: file, encoding: .utf8),
                      source.contains("func snapshot() async throws -> SnapshotResponse") else { continue }
                checked += 1
                if !source.contains("func addMedia(path: String) async throws") { missing.append(file.lastPathComponent) }
            }
        }
        XCTAssertGreaterThan(checked, 3, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(missing.isEmpty, "snapshot() を実装する型は addMedia(path:) も実装して素通しすること: \(missing)")
    }

    /// iOS 実機は写真ライブラリへの口が無いので、simctl も devicectl も撃たずに失敗にする
    func testPhysicalIOSDeviceFailsWithoutRunningAnything() async {
        let client = BridgeClient(port: 8123, physicalUDID: "00008110-000000000000001E")
        do {
            try await client.addMedia(path: "/nonexistent/photo.png")
            XCTFail("実機は失敗になる")
        } catch let DriverError.badResponse(status, body) {
            XCTAssertEqual(status, 501)
            XCTAssertTrue(body.contains("physical devices have no way to add media"), body)
        } catch {
            XCTFail("\(error)")
        }
    }
}
