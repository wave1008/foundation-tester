// 失敗時の証跡の絵は画面全体を撮れる XCUITest(hybrid の fallbackDriver)から撮る(FTRuntime.handleFailure)。
// in-app の /screenshot はアプリの window しか描かないので、SpringBoard の権限アラートが出ていても写らず、
// E2E-iOS 16 S0010 の赤で「アラートが出なかった」のか「出ていたのに見つけられなかった」のかを判別できなかった。

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTDSL
import FTCore

final class FailureEvidenceScreenshotTests: XCTestCase {

    /// 撮るたびに shots を先頭から返す(最後の1枚は繰り返す)。空なら撮れない
    private final class ShotDriver: AppDriver {
        private var shots: [Data]
        init(shot: Data?) { shots = shot.map { [$0] } ?? [] }
        init(shots: [Data]) { self.shots = shots }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func clearAppData(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data {
            guard let shot = shots.first else { throw URLError(.cannotConnectToHost) }
            if shots.count > 1 { shots.removeFirst() }
            return shot
        }
        func terminate() async throws {}
    }

    private let inApp = Data("in-app".utf8)
    private let wholeScreen = Data("whole-screen".utf8)

    private func failureScreenshot(fallback: AppDriver?, primary: AppDriver? = nil,
                                   physical: Bool = true) -> Data? {
        let core = FTDriveCore(driver: primary ?? ShotDriver(shot: inApp), platform: "ios",
                               app: "com.example.app", scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false,
                               fallbackDriver: fallback, physical: physical, emit: { _ in })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario {
            scene(1, "失敗する") {
                action { exist("#missing", requireVisible: false, waitSeconds: 0) }
            }
        }
        return core.finalRecord.scenes.first?.failureScreenshot
    }

    func testUsesTheXCUITestScreenshotWhenAFallbackDriverExists() {
        XCTAssertEqual(failureScreenshot(fallback: ShotDriver(shot: wholeScreen)), wholeScreen)
    }

    func testFallsBackToThePrimaryWhenTheXCUITestScreenshotFails() {
        XCTAssertEqual(failureScreenshot(fallback: ShotDriver(shot: nil)), inApp)
    }

    func testUsesThePrimaryWithoutAFallbackDriver() {
        XCTAssertEqual(failureScreenshot(fallback: nil), inApp)
    }

    /// 白一色の絵(凍結の疑い)を撮り直すときも同じ撮り方を使う(主ドライバへ切り替えない)
    func testTheBlankFrameRetakeAlsoUsesTheXCUITestScreenshot() {
        let blank = Self.png { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let content = Self.png { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 24, y: 24, width: 16, height: 16))
        }
        let appContent = Self.png { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        XCTAssertEqual(failureScreenshot(fallback: ShotDriver(shots: [blank, content]),
                                         primary: ShotDriver(shot: appContent), physical: false),
                       content)
    }

    private static func png(_ draw: (CGContext) -> Void) -> Data {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
