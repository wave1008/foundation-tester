// `--port` 直指定の iOS 経路は、ポートに結び付いた Simulator の udid を connection へ渡す(`fleetest run` と
// `fleetest api run` の両方)。nil を渡すと udid を鍵にする処理(simctl 経由の操作・デバイスの印)が黙って効かない

import XCTest

final class PortDirectSimulatorUDIDTests: XCTestCase {

    func testNoPortDirectPathPassesANilSimulatorUDID() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("ApiRunCommand.swift"), "走査が Sources/fleetest に届いていない")
        for name in names {
            let source = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(source.contains("simulatorUDID: nil"), "\(name) が udid を渡さずに直指定のワーカーを組んでいる")
        }
    }
}
