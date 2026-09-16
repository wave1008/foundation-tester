// 停止の確認で「一覧が読めない」を「止まった」と読まない(SimulatorCatalog.shutdownObservation)。
// 戻すと落ちる根拠: 従来は `(try? devices())?....booted ?? false` で、読めないと ✅ を名乗っていた

import XCTest
@testable import FTBridgeClient

final class SimulatorShutdownObservationTests: XCTestCase {
    private struct ReadFailure: LocalizedError {
        var errorDescription: String? { "simctl list devices failed: timed out\nsecond line" }
    }

    private let sims = [
        SimDeviceInfo(udid: "A", name: "iPhone A", os: "iOS 27.0", booted: false),
        SimDeviceInfo(udid: "B", name: "iPhone B", os: "iOS 27.0", booted: true),
    ]

    func testUnreadableListIsNotStopped() {
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.failure(ReadFailure()), udid: nil),
                       .unreadable("simctl list devices failed: timed out"))
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.failure(ReadFailure()), udid: "A"),
                       .unreadable("simctl list devices failed: timed out"))
    }

    func testAnyBootedDeviceKeepsTheSweepUnconfirmed() {
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.success(sims), udid: nil), .stillBooted)
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.success([sims[0]]), udid: nil), .stopped)
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.success([]), udid: nil), .stopped)
    }

    func testSingleDeviceLooksOnlyAtThatDevice() {
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.success(sims), udid: "A"), .stopped)
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.success(sims), udid: "B"), .stillBooted)
        // 一覧から消えた台は止まっている(削除済み)
        XCTAssertEqual(SimulatorCatalog.shutdownObservation(.success(sims), udid: "GONE"), .stopped)
    }

    /// 同じ形(読めないと false = 停止)を Sources に戻さない
    func testNoSourceReadsAnUnreadableCatalogAsNotBooted() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(
            // `first(where: { … })?.booted ?? false`(改行・波括弧を挟む)と `contains(where: \.booted) ?? false` の両方
            pattern: #"\(try\? SimulatorCatalog\.devices\(\)\)\?[\s\S]{0,200}?\.booted\)? \?\? false"#)
        var scanned = 0
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scanned, 100, "走査が Sources に届いていない")
        XCTAssertEqual(offenders, [], "一覧が読めないと停止扱いになる形: SimulatorCatalog.shutdownObservation を使う")
    }
}
