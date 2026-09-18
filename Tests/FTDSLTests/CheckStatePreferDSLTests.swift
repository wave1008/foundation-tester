// checkIsON / checkIsOFF の `prefer:` が **DSL から executor まで届く**ことの通しの確認。
// FTCore 側の CheckStateClassifierTests は FlowStep を直接作るので、DSL の写像
// (`prefer:` → `FlowStep.preferCheckStateClassifier`)を逆にしても・渡し忘れても緑のまま通る。
// E2E の 21 も合否しか見ない(どちらが判定したかはシナリオから読めない)ので、ここで縛る。
// witness: a11y は「オフ」・画像は「オン」の要素 = どちらで判定したかが合否に出る。

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore
@testable import FTDSL

final class CheckStatePreferDSLTests: XCTestCase {

    /// オン = 塗りつぶした箱、オフ = 枠だけの箱(FTCoreTests の CheckStateClassifierTests と同じ描き方)
    private static func checkboxPNG(on: Bool, shift: Int) -> Data {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let box = CGRect(x: 12 + shift, y: 12 + shift, width: 36 - shift, height: 36 - shift)
        context.setStrokeColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.setLineWidth(4)
        if on { context.fill(box) } else { context.stroke(box) }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csp-\(UUID().uuidString)")
        for (label, on) in [("[ON]", true), ("[OFF]", false)] {
            let dir = CheckStateClassifier.directory(projectRoot: root).appendingPathComponent(label)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<6 { try checkboxPNG(on: on, shift: i).write(to: dir.appendingPathComponent("s\(i).png")) }
        }
        return root
    }

    /// a11y はオフ(switch・value "0")・画面の絵はオン
    private final class DisagreeingDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 64, height: 64),
                             elements: [ElementInfo(ref: 1, type: "switch", identifier: "cb", label: nil, value: "0",
                                                    placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 0, y: 0, width: 64, height: 64), depth: 1)],
                             truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { CheckStatePreferDSLTests.checkboxPNG(on: true, shift: 2) }
        func terminate() async throws {}
    }

    /// 1シナリオ = 1ステップで回し、(通ったか, 記録の説明)を返す
    private func run(projectRoot: URL, profilePrefersClassifier: Bool,
                     _ body: @escaping () -> Void) -> (passed: Bool, description: String) {
        let core = FTDriveCore(driver: DisagreeingDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-prefer-test-\(UUID().uuidString).json"),
                               emit: { _ in })
        core.executor.visionClassifierProjectRoot = projectRoot
        core.executor.preferCheckStateClassifier = profilePrefersClassifier
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        let steps = core.finalRecord.scenes.flatMap(\.steps)
        return (core.finalRecord.passed, steps.last?.description ?? "")
    }

    func testPreferReachesTheExecutorFromBothCallForms() throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        // プロファイルは a11y 優先。`.classifier` の指定で画像(オン)が判定する
        let chained = run(projectRoot: root, profilePrefersClassifier: false) {
            select("#cb", requireVisible: false).checkIsON(prefer: .classifier, timeout: 0)
        }
        XCTAssertTrue(chained.passed, chained.description)
        XCTAssertTrue(chained.description.contains("(prefer: classifier)"), chained.description)

        // プロファイルは分類器優先。`.accessibility` の指定で a11y(オフ)が判定する = checkIsON は落ちる
        let toA11y = run(projectRoot: root, profilePrefersClassifier: true) {
            select("#cb", requireVisible: false).checkIsON(prefer: .accessibility, timeout: 0)
        }
        XCTAssertFalse(toA11y.passed, "a11y はオフなので落ちるはず: \(toA11y.description)")
        XCTAssertTrue(toA11y.description.contains("(prefer: accessibility)"), toA11y.description)

        // 暗黙形(自由関数)も同じ引数を運ぶ
        let implicitOff = run(projectRoot: root, profilePrefersClassifier: true) {
            select("#cb", requireVisible: false)
            checkIsOFF(prefer: .accessibility, timeout: 0)
        }
        XCTAssertTrue(implicitOff.passed, implicitOff.description)
        let implicitOn = run(projectRoot: root, profilePrefersClassifier: false) {
            select("#cb", requireVisible: false)
            checkIsON(prefer: .classifier, timeout: 0)
        }
        XCTAssertTrue(implicitOn.passed, implicitOn.description)

        // 省略時は実行プロファイルに従う(説明に印を足さない)
        let byProfile = run(projectRoot: root, profilePrefersClassifier: false) {
            select("#cb", requireVisible: false).checkIsON(timeout: 0)
        }
        XCTAssertFalse(byProfile.passed)
        XCTAssertFalse(byProfile.description.contains("prefer:"), byProfile.description)
    }
}
