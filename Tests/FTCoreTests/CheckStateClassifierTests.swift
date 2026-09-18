// CheckStateClassifier(Shirates Vision の移植)の学習データの読み方・学習・判定と、
// checkIsON / checkIsOFF への組み込み(優先の切り替え)。学習は合成した画像で実際に Create ML に掛ける。

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

final class CheckStateClassifierTests: XCTestCase {

    // MARK: - 合成画像

    /// オン = 塗りつぶした箱、オフ = 枠だけの箱。`shift` で位置と大きさを少しずらして見本を増やす
    static func checkboxPNG(on: Bool, shift: Int, canvas: Int = 64) -> Data {
        let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        let box = CGRect(x: 12 + shift, y: 12 + shift, width: 36 - shift, height: 36 - shift)
        context.setStrokeColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.setLineWidth(4)
        if on { context.fill(box) } else { context.stroke(box) }
        return png(context.makeImage()!)
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// プロジェクトのルート(vision/classifiers/CheckStateClassifier/[ON]|[OFF] に見本を置いたもの)
    static func makeProject(samples: Int = 6, script: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("csc-\(UUID().uuidString)", isDirectory: true)
        let dir = CheckStateClassifier.directory(projectRoot: root)
        for (label, on) in [("[ON]", true), ("[OFF]", false)] {
            let labelDir = dir.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: labelDir, withIntermediateDirectories: true)
            for i in 0..<samples {
                try checkboxPNG(on: on, shift: i).write(to: labelDir.appendingPathComponent("s\(i).png"))
            }
        }
        if let script { try script.write(to: dir.appendingPathComponent("MLImageClassifier.swift"), atomically: true, encoding: .utf8) }
        return root
    }

    // MARK: - 学習データの読み方

    func testShiratesScriptHeaderIsParsed() {
        let options = CheckStateClassifier.Options.parse(scriptText: "// options=-noise,-blur\n// imageFilter=binary\n1\n")
        XCTAssertEqual(options.augmentation, ["noise", "blur"])
        XCTAssertTrue(options.binary)
        XCTAssertEqual(options.featurePrintRevision, 2)
        XCTAssertEqual(CheckStateClassifier.Options.parse(scriptText: "// options=-fp:1").featurePrintRevision, 1)
        XCTAssertEqual(CheckStateClassifier.Options.parse(scriptText: nil), CheckStateClassifier.Options())
    }

    func testLabelsMapToStatesLikeShirates() {
        XCTAssertEqual(CheckStateClassifier.state(forLabel: "[ON]"), .on)
        XCTAssertEqual(CheckStateClassifier.state(forLabel: "switch[OFF]"), .off)
        XCTAssertNil(CheckStateClassifier.state(forLabel: "ON"))
    }

    func testTrainingSetNeedsTwoLabelsWithImages() throws {
        let root = try Self.makeProject(samples: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root)
        XCTAssertEqual(CheckStateClassifier.trainingSet(at: dir)?.labels.count, 2)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("[OFF]/s0.png"))
        XCTAssertNil(CheckStateClassifier.trainingSet(at: dir), "1ラベルでは分類器にならない")
        XCTAssertNil(CheckStateClassifier.trainingSet(at: root.appendingPathComponent("missing")))
    }

    func testDigestFollowsImageContentAndOptions() throws {
        let root = try Self.makeProject(samples: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root)
        let first = try XCTUnwrap(CheckStateClassifier.trainingSet(at: dir)).digest
        XCTAssertEqual(CheckStateClassifier.trainingSet(at: dir)?.digest, first)
        try Self.checkboxPNG(on: true, shift: 5).write(to: dir.appendingPathComponent("[ON]/s0.png"))
        let changedImage = try XCTUnwrap(CheckStateClassifier.trainingSet(at: dir)).digest
        XCTAssertNotEqual(changedImage, first, "画像の中身が変われば学び直す")
        try "// options=-noise".write(to: dir.appendingPathComponent("MLImageClassifier.swift"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(CheckStateClassifier.trainingSet(at: dir)?.digest, changedImage, "オプションが変われば学び直す")
    }

    // MARK: - 画像

    func testCropScalesFromPointsToPixels() throws {
        let png = Self.checkboxPNG(on: true, shift: 0, canvas: 120)
        // 画面 40pt 幅 = 画像 120px(3倍)
        let image = try XCTUnwrap(CheckStateClassifier.crop(
            png: png, frame: FTRect(x: 10, y: 5, width: 20, height: 10), screen: FTRect(x: 0, y: 0, width: 40, height: 40)))
        XCTAssertEqual(image.width, 60)
        XCTAssertEqual(image.height, 30)
        XCTAssertNil(CheckStateClassifier.crop(png: png, frame: FTRect(x: 100, y: 100, width: 5, height: 5),
                                               screen: FTRect(x: 0, y: 0, width: 40, height: 40)), "画面外")
    }

    func testOtsuSplitsTwoPeaks() {
        let pixels = [UInt8](repeating: 20, count: 50) + [UInt8](repeating: 220, count: 50)
        let threshold = CheckStateClassifier.otsuThreshold(pixels)
        XCTAssertTrue((20..<220).contains(threshold), "\(threshold)")
    }

    // MARK: - 学習と判定(Create ML を実際に回す)

    func testTrainsClassifiesAndReusesTheCachedModel() throws {
        let root = try Self.makeProject(script: "// options=-noise\n// imageFilter=binary")
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try XCTUnwrap(CheckStateClassifier.trainingSet(at: CheckStateClassifier.directory(projectRoot: root)))
        let cache = CheckStateClassifier.cacheDirectory(projectRoot: root)
        let model = try CheckStateClassifier.loadBlocking(set, cacheDirectory: cache)
        let modelFile = cache.appendingPathComponent("\(set.digest)/model.mlmodel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelFile.path))
        // imageFilter=binary は学習画像に二値化の2枚を足す
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent("\(set.digest)/training/[ON]/s0_binary2.png").path))

        for (on, expected) in [(true, "[ON]"), (false, "[OFF]")] {
            let source = CGImageSourceCreateWithData(Self.checkboxPNG(on: on, shift: 3) as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            XCTAssertEqual(try model.classify(image)?.label, expected)
        }
        let modified = try FileManager.default.attributesOfItem(atPath: modelFile.path)[.modificationDate] as? Date
        CheckStateClassifier.forgetLoadedModelsForTesting()   // 別プロセス(次のシナリオ)と同じ条件
        _ = try CheckStateClassifier.loadBlocking(set, cacheDirectory: cache)
        let again = try FileManager.default.attributesOfItem(atPath: modelFile.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, again, "同じ見本なら学び直さない")
    }

    // MARK: - 子プロセス境界の配線(型の効かない継ぎ目。OCRToggleWiringTests と同じ作法)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testPreferenceAndProjectRootReachTheExecutor() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("if !preferCheckStateClassifier { args.append(\"--no-prefer-check-state-classifier\") }"),
                      "preferCheckStateClassifier が子ランナーへ伝わっていない")
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"no-prefer-check-state-classifier\")"))
        XCTAssertTrue(runner.contains("preferCheckStateClassifier: !noPreferCheckStateClassifier"))
        XCTAssertTrue(runner.contains("checkStateClassifierProjectRoot: projectDir.map { URL(fileURLWithPath: $0) }"),
                      "見本画像を探すプロジェクトのルートを渡していない(分類器が一度も使われない)")
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
        XCTAssertTrue(runtime.contains("self.executor.checkStateClassifierProjectRoot = checkStateClassifierProjectRoot"))
        XCTAssertTrue(runtime.contains("self.executor.preferCheckStateClassifier = preferCheckStateClassifier"))
    }

    // MARK: - checkIsON / checkIsOFF への組み込み

    private final class ImageDriver: AppDriver {
        let element: ElementInfo
        let screenPNG: Data
        init(element: ElementInfo, screenPNG: Data) { self.element = element; self.screenPNG = screenPNG }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 64, height: 64),
                             elements: [element], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { screenPNG }
        func terminate() async throws {}
    }

    private func run(_ assert: String, a11y element: ElementInfo, imageOn: Bool, projectRoot: URL?,
                     prefer: Bool) async -> StepOutcome {
        let driver = ImageDriver(element: element, screenPNG: Self.checkboxPNG(on: imageOn, shift: 2))
        let executor = StepExecutor(driver: driver, isAndroid: false)
        executor.checkStateClassifierProjectRoot = projectRoot
        executor.preferCheckStateClassifier = prefer
        return await executor.execute(FlowStep(assert: assert, locator: FlowLocator(id: "cb"), timeout: 0))
    }

    private func element(type: String, value: String? = nil) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: "cb", label: nil, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 64, height: 64), depth: 1)
    }

    private func passed(_ outcome: StepOutcome) -> Bool {
        if case .passed = outcome.status { return true }
        return false
    }

    func testClassifierDecidesAndPreferenceOrdersTheSources() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        // a11y が何も報告しない要素(SwiftUI の自作ボタン)を画像で判定する
        let silentOn = await run("checked", a11y: element(type: "button"), imageOn: true, projectRoot: root, prefer: false)
        XCTAssertTrue(passed(silentOn), "\(silentOn.status)")
        XCTAssertTrue(silentOn.notes.contains(.checkStateClassified))
        XCTAssertEqual(silentOn.observedChecked, true)
        let silentOff = await run("checked", a11y: element(type: "button"), imageOn: false, projectRoot: root, prefer: false)
        XCTAssertFalse(passed(silentOff))
        if case .failed(let reason) = silentOff.status {
            XCTAssertTrue(reason.hasPrefix("the element is off"), reason)
            XCTAssertTrue(reason.contains("CheckStateClassifier"), reason)
        }

        // a11y がオフと報告し、画像はオン: 優先するなら画像、しないなら a11y
        let a11yOff = element(type: "switch", value: "0")
        let preferred = await run("checked", a11y: a11yOff, imageOn: true, projectRoot: root, prefer: true)
        XCTAssertTrue(passed(preferred), "\(preferred.status)")
        let notPreferred = await run("checked", a11y: a11yOff, imageOn: true, projectRoot: root, prefer: false)
        XCTAssertFalse(passed(notPreferred))
        XCTAssertFalse(notPreferred.notes.contains(.checkStateClassified))

        // 見本が無ければ従来どおり a11y だけ
        let noSamples = await run("checked", a11y: element(type: "button"), imageOn: true, projectRoot: nil, prefer: true)
        XCTAssertFalse(passed(noSamples))
        XCTAssertFalse(noSamples.notes.contains(.checkStateClassified))
    }
}
