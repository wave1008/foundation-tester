// existImage の DSL の写像(FTCore の単体は FlowStep を直接作るので、DSL 側の渡し忘れ・反転は通ってしまう):
// 見つけた要素を返す / 見つからなければシナリオを中断する / timeout 省略 = core.defaultTimeout /
// `scroll: .noScroll` は withScroll* の中でも送らない / スクロールは `scroll:` だけで指定する

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore
@testable import FTDSL

final class ExistImageDSLTests: XCTestCase {

    private static let screen = FTRect(x: 0, y: 0, width: 300, height: 100)

    /// 100x100 の図形を3つ(丸・四角・横線)並べた画面
    private static func screenPNG() -> Data {
        let context = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 15, y: 15, width: 70, height: 70))
        context.fill(CGRect(x: 115, y: 15, width: 70, height: 70))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 205, y: 45, width: 90, height: 10))
        return png(context.makeImage()!)
    }

    private static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private final class ScreenDriver: AppDriver {
        private(set) var swipes: [FTSwipeDirection] = []
        private(set) var screenshots = 0
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            func element(_ ref: Int, _ id: String, _ x: Double) -> ElementInfo {
                ElementInfo(ref: ref, type: "image", identifier: id, label: nil, value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: x, y: 0, width: 100, height: 100), depth: 1)
            }
            return SnapshotResponse(sessionBundleID: nil, screen: ExistImageDSLTests.screen,
                                    elements: [element(1, "circle", 0), element(2, "square", 100),
                                               element(3, "line", 200)],
                                    truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws { swipes.append(direction) }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data {
            screenshots += 1
            return ExistImageDSLTests.screenPNG()
        }
        func terminate() async throws {}
    }

    /// `@i/Home/[Circle Icon]` に画面の丸と同じ切り出しを置いたプロジェクト
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eid-\(UUID().uuidString)")
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
            .appendingPathComponent("@i/Home/[Circle Icon]", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crop = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(),
                                                       frame: FTRect(x: 0, y: 0, width: 100, height: 100),
                                                       screen: Self.screen))
        try Self.png(crop).write(to: dir.appendingPathComponent("circle.png"))
        return root
    }

    private func makeCore(driver: AppDriver, root: URL, defaultTimeout: Double) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0040", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false,
                    visionClassifierProjectRoot: root, dryRun: false,
                    fingerprintCacheURL: root.appendingPathComponent("fp.json"),
                    defaultTimeout: defaultTimeout,
                    emit: { _ in })
    }

    /// 画像系のスクロールは `scroll:` で指定する(関数名の別名は置かない)。明示の向きが送りに届くこと
    func testScrollParameterDrivesTheSearch() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        func swipes(_ body: @escaping () -> Void) -> [FTSwipeDirection] {
            let driver = ScreenDriver()
            let core = makeCore(driver: driver, root: root, defaultTimeout: 0)
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            scenario { scene(1, "s") { FTDSL.expectation { body() } } }
            return driver.swipes
        }
        XCTAssertTrue(swipes { existImage("[Circle Icon]", threshold: -1) }.isEmpty, "scroll 無指定は送らない")
        // コンテンツ .down = 指は上へ(FTScrollDirection.swipe)
        XCTAssertEqual(Set(swipes { existImage("[Circle Icon]", threshold: -1, scroll: .down) }), [.up])
        XCTAssertEqual(Set(swipes { findImage("[Circle Icon]", threshold: -1, scroll: .up) }), [.down])
    }

    private func failures(_ core: FTDriveCore) -> [String] {
        core.finalRecord.scenes.flatMap(\.steps).compactMap { step -> String? in
            if case .failed(let reason) = step.status { return reason }
            return nil
        }
    }

    func testExistImageReturnsTheFoundElementAndCountsAsAnAssertion() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let core = makeCore(driver: ScreenDriver(), root: root, defaultTimeout: 0)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        var element: FTElement!
        scenario { scene(1, "s") { FTDSL.expectation { element = existImage("[Circle Icon]") } } }
        XCTAssertTrue(core.finalRecord.passed, "\(failures(core))")
        XCTAssertEqual(element.id, "circle")
        XCTAssertEqual(core.scenarioAssertionCount, 1)
    }

    func testExistImageNotFoundAbortsTheScenario() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let core = makeCore(driver: ScreenDriver(), root: root, defaultTimeout: 0)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        var element: FTElement!
        scenario {
            scene(1, "s") {
                FTDSL.expectation {
                    element = existImage("[Circle Icon]", threshold: -1)
                    exist("#circle")
                }
            }
        }
        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertEqual(failures(core).count, 1, "\(failures(core))")
        XCTAssertTrue(failures(core)[0].hasPrefix("image \"[Circle Icon]\" does not exist"), failures(core)[0])
        XCTAssertTrue(element.isEmpty)
        let skipped = core.finalRecord.scenes.flatMap(\.steps).filter {
            if case .skipped = $0.status { return true } else { return false }
        }
        XCTAssertEqual(skipped.count, 1, "失敗したらシナリオの残りは実行しない")
    }

    /// timeout 省略 = core.defaultTimeout まで撮り直す / 0 を渡せば1回だけ見る
    /// (壁時計でなく撮った回数で見る)
    func testOmittedTimeoutFollowsTheDefaultTimeoutOfTheCore() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        func screenshots(timeout: Double?) -> Int {
            let driver = ScreenDriver()
            let core = makeCore(driver: driver, root: root, defaultTimeout: 0.6)
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            scenario { scene(1, "s") { FTDSL.expectation { existImage("[Circle Icon]", threshold: -1, timeout: timeout) } } }
            return driver.screenshots
        }
        // 失敗時はランタイムがレポート用にもう1枚撮るので、枚数は「1回だけ見た」場合との差で見る
        let once = screenshots(timeout: 0)
        XCTAssertGreaterThan(screenshots(timeout: nil), once, "省略時は defaultTimeout まで撮り直して待つこと")
    }

    func testNoScrollDoesNotScrollInsideAScrollContext() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        func swipes(_ body: @escaping () -> Void) -> [FTSwipeDirection] {
            let driver = ScreenDriver()
            let core = makeCore(driver: driver, root: root, defaultTimeout: 0)
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            defer { FTRuntime.tearDown() }
            scenario { scene(1, "s") { FTDSL.expectation { withScrollDown { body() } } } }
            return driver.swipes
        }
        // 陽性対照: 同じ文脈で existImage は送る(見つからないので端まで)。これが空だと下の検査は何も言えない
        XCTAssertFalse(swipes { existImage("[Circle Icon]", threshold: -1) }.isEmpty)
        XCTAssertTrue(swipes { existImage("[Circle Icon]", threshold: -1, scroll: .noScroll) }.isEmpty)
        XCTAssertFalse(swipes { findImage("[Circle Icon]", threshold: -1) }.isEmpty)
        XCTAssertTrue(swipes { findImage("[Circle Icon]", threshold: -1, scroll: .noScroll) }.isEmpty)
    }
}
