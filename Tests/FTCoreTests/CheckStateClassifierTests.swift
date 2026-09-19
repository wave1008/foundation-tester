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
        let options = VisionClassifier.Options.parse(scriptText: "// options=-noise,-blur\n// imageFilter=binary\n1\n")
        XCTAssertEqual(options.augmentation, ["noise", "blur"])
        XCTAssertTrue(options.binary)
        XCTAssertEqual(options.featurePrintRevision, 2)
        XCTAssertEqual(VisionClassifier.Options.parse(scriptText: "// options=-fp:1").featurePrintRevision, 1)
        XCTAssertEqual(VisionClassifier.Options.parse(scriptText: nil), VisionClassifier.Options())
    }

    func testLabelsMapToStatesLikeShirates() {
        XCTAssertEqual(CheckStateClassifier.state(forLabel: "[ON]"), .on)
        XCTAssertEqual(CheckStateClassifier.state(forLabel: "switch[OFF]"), .off)
        XCTAssertNil(CheckStateClassifier.state(forLabel: "ON"))
        XCTAssertEqual(CheckStateClassifier.state(forLabel: "[INDETERMINATE]"), .indeterminate, "fleetest 独自のラベル")
    }

    func testTrainingSetNeedsTwoLabelsWithImages() throws {
        let root = try Self.makeProject(samples: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root)
        XCTAssertEqual(try VisionClassifier.trainingSet(at: dir)?.labels.count, 2)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("[OFF]/s0.png"))
        XCTAssertNil(try VisionClassifier.trainingSet(at: dir), "1ラベルでは分類器にならない")
        XCTAssertNil(try VisionClassifier.trainingSet(at: root.appendingPathComponent("missing")))
    }

    func testDigestFollowsImageContentAndOptions() throws {
        let root = try Self.makeProject(samples: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root)
        let first = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir)).digest
        XCTAssertEqual(try VisionClassifier.trainingSet(at: dir)?.digest, first)
        try Self.checkboxPNG(on: true, shift: 5).write(to: dir.appendingPathComponent("[ON]/s0.png"))
        let changedImage = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir)).digest
        XCTAssertNotEqual(changedImage, first, "画像の中身が変われば学び直す")
        try "// options=-noise".write(to: dir.appendingPathComponent("MLImageClassifier.swift"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try VisionClassifier.trainingSet(at: dir)?.digest, changedImage, "オプションが変われば学び直す")
    }

    // MARK: - 画像

    func testCropScalesFromPointsToPixels() throws {
        let png = Self.checkboxPNG(on: true, shift: 0, canvas: 120)
        // 画面 40pt 幅 = 画像 120px(3倍)
        let image = try XCTUnwrap(VisionClassifier.crop(
            png: png, frame: FTRect(x: 10, y: 5, width: 20, height: 10), screen: FTRect(x: 0, y: 0, width: 40, height: 40)))
        XCTAssertEqual(image.width, 60)
        XCTAssertEqual(image.height, 30)
        XCTAssertNil(VisionClassifier.crop(png: png, frame: FTRect(x: 100, y: 100, width: 5, height: 5),
                                               screen: FTRect(x: 0, y: 0, width: 40, height: 40)), "画面外")
    }

    func testOtsuSplitsTwoPeaks() {
        let pixels = [UInt8](repeating: 20, count: 50) + [UInt8](repeating: 220, count: 50)
        let threshold = VisionClassifier.otsuThreshold(pixels)
        XCTAssertTrue((20..<220).contains(threshold), "\(threshold)")
    }

    // MARK: - 学習と判定(Create ML を実際に回す)

    func testTrainsClassifiesAndReusesTheCachedModel() throws {
        let root = try Self.makeProject(script: "// options=-noise\n// imageFilter=binary")
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: CheckStateClassifier.directory(projectRoot: root)))
        let cache = CheckStateClassifier.cacheDirectory(projectRoot: root)
        let model = try VisionClassifier.loadBlocking(set, cacheDirectory: cache)
        let modelFile = cache.appendingPathComponent("model.mlmodel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelFile.path))
        // imageFilter=binary は学習画像に二値化の2枚を足す
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent("training/[ON]/s0_binary2.png").path))

        for (on, expected) in [(true, "[ON]"), (false, "[OFF]")] {
            let source = CGImageSourceCreateWithData(Self.checkboxPNG(on: on, shift: 3) as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            XCTAssertEqual(try model.classify(image)?.label, expected)
        }
        let modified = try FileManager.default.attributesOfItem(atPath: modelFile.path)[.modificationDate] as? Date
        VisionClassifier.forgetLoadedModelsForTesting()   // 別プロセス(次のシナリオ)と同じ条件
        _ = try VisionClassifier.loadBlocking(set, cacheDirectory: cache)
        let again = try FileManager.default.attributesOfItem(atPath: modelFile.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, again, "同じ見本なら学び直さない")
    }

    // MARK: - 置き場所(分類器ごとに1組・見本の更新1回につき学習1回)

    /// 見本が変わったら同じ場所へ上書きする(置き場所のモデルは常に1組)。digest は最後に書き換わる
    func testSampleChangeRetrainsInPlace() throws {
        let root = try Self.makeProject(samples: 5)   // 他のテストと別の見本 = プロセス内の控えを共有しない
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root)
        let cache = CheckStateClassifier.cacheDirectory(projectRoot: root)
        let first = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir))
        _ = try VisionClassifier.loadBlocking(first, cacheDirectory: cache)
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent("digest"), encoding: .utf8), first.digest)

        try Self.checkboxPNG(on: true, shift: 7).write(to: dir.appendingPathComponent("[ON]/added.png"))
        let second = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir))
        XCTAssertNotEqual(first.digest, second.digest)
        _ = try VisionClassifier.loadBlocking(second, cacheDirectory: cache)
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent("digest"), encoding: .utf8), second.digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("training/[ON]/added.png").path),
                      "新しい見本で学び直した")
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        XCTAssertEqual(entries, ["model.mlmodel", "selfcheck.json", "digest", "training", "train.lock"],
                       "モデルは1組だけ")
    }

    /// **同時に来たプロセスのうち学ぶのは1本だけ**。flock は open ごとの記述子に付くので、同じプロセスの
    /// 別スレッドで取っても互いに待つ = 別プロセスと同じ条件で確かめられる
    func testConcurrentLoadersTrainOnlyOnce() throws {
        let root = try Self.makeProject(samples: 4)
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: CheckStateClassifier.directory(projectRoot: root)))
        let cache = CheckStateClassifier.cacheDirectory(projectRoot: root)
        let lock = NSLock()
        var trained = 0
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            var usage = VisionClassifier.VisionUsage()
            do {
                let didTrain = try VisionClassifier.withCacheLock(cache) {
                    try VisionClassifier.ensureModel(set, cacheDirectory: cache, usage: &usage)
                }
                lock.lock(); if didTrain { trained += 1 }; lock.unlock()
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(trained, 1, "見本1組につき学習は1回")
    }

    // MARK: - 学習の点検(自分の見本を取り違えないか)

    func testSelfCheckReportsSamplesTheModelCannotTellApart() throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root)
        let cache = CheckStateClassifier.cacheDirectory(projectRoot: root)
        let clean = try VisionClassifier.loadBlocking(try XCTUnwrap(try VisionClassifier.trainingSet(at: dir)),
                                                      cacheDirectory: cache)
        XCTAssertEqual(clean.mismatches, [], "見分けられる見本なら取り違えは無い")

        // オンの絵を [OFF] に紛れ込ませる = 見本どうしが矛盾する。**shift はこのテストだけの値にする** ——
        // 学習済みモデルはプロセス内で digest ごとに控えられ(VisionClassifier.load)、他のテストと同じ見本だと
        // 1プロセスで続けて走ったとき点検が走らず、この一時フォルダに selfcheck.json が書かれない
        try Self.checkboxPNG(on: true, shift: 3).write(to: dir.appendingPathComponent("[OFF]/wrong.png"))
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir))
        let model = try VisionClassifier.loadBlocking(set, cacheDirectory: cache)
        XCTAssertTrue(model.mismatches.contains { $0.sample == "[OFF]/wrong.png" && $0.expected == "[OFF]" },
                      "\(model.mismatches)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent("selfcheck.json").path), "点検の結果を控える")
        XCTAssertTrue(VisionClassifier.describe(model.mismatches[0]).contains("is classified as"))
    }

    /// 実行器は読み込んだモデルの取り違えを覚える(FTRuntime がシナリオ終了時に警告する元)
    func testExecutorRemembersTheSelfCheckMismatches() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root)
        try Self.checkboxPNG(on: true, shift: 1).write(to: dir.appendingPathComponent("[OFF]/wrong.png"))
        let executor = StepExecutor(driver: ImageDriver(element: element(type: "button"),
                                                        screenPNG: Self.checkboxPNG(on: true, shift: 2)),
                                    isAndroid: false)
        executor.visionClassifierProjectRoot = root
        _ = await executor.execute(FlowStep(assert: "checked", locator: FlowLocator(id: "cb"), timeout: 0))
        XCTAssertEqual(executor.visionClassifierMismatches[CheckStateClassifier.name]?.contains { $0.sample == "[OFF]/wrong.png" },
                       true)
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
        XCTAssertTrue(runner.contains("visionClassifierProjectRoot: projectDir.map { URL(fileURLWithPath: $0) }"),
                      "見本画像を探すプロジェクトのルートを渡していない(分類器が一度も使われない)")
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
        XCTAssertTrue(runtime.contains("self.executor.visionClassifierProjectRoot = visionClassifierProjectRoot"))
        XCTAssertTrue(runtime.contains("self.executor.preferCheckStateClassifier = preferCheckStateClassifier"))
    }

    // MARK: - indeterminate([INDETERMINATE] の見本。fleetest 独自)

    /// 枠の中に横棒だけの箱(一部だけ選択の見た目)
    static func indeterminatePNG(shift: Int, canvas: Int = 64) -> Data {
        let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        context.setStrokeColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.setLineWidth(4)
        let box = CGRect(x: 12 + shift, y: 12 + shift, width: 36 - shift, height: 36 - shift)
        context.stroke(box)
        context.fill(CGRect(x: box.minX + 8, y: box.midY - 3, width: box.width - 16, height: 6))
        return png(context.makeImage()!)
    }

    func testIndeterminateSamplesFailBothAssertionsWithTheReason() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = CheckStateClassifier.directory(projectRoot: root).appendingPathComponent("[INDETERMINATE]")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<6 { try Self.indeterminatePNG(shift: i).write(to: dir.appendingPathComponent("s\(i).png")) }

        for assert in ["checked", "notChecked"] {
            let driver = ImageDriver(element: element(type: "button"), screenPNG: Self.indeterminatePNG(shift: 2))
            let executor = StepExecutor(driver: driver, isAndroid: false)
            executor.visionClassifierProjectRoot = root
            let outcome = await executor.execute(FlowStep(assert: assert, locator: FlowLocator(id: "cb"), timeout: 0))
            guard case .failed(let reason) = outcome.status else { return XCTFail("\(assert) は落ちるはず") }
            XCTAssertTrue(reason.contains("indeterminate"), reason)
            XCTAssertTrue(reason.contains("[INDETERMINATE]"), reason)
        }
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
                     prefer: Bool, stepPrefer: Bool? = nil) async -> StepOutcome {
        let driver = ImageDriver(element: element, screenPNG: Self.checkboxPNG(on: imageOn, shift: 2))
        let executor = StepExecutor(driver: driver, isAndroid: false)
        executor.visionClassifierProjectRoot = projectRoot
        executor.preferCheckStateClassifier = prefer
        return await executor.execute(FlowStep(assert: assert, locator: FlowLocator(id: "cb"), timeout: 0,
                                               preferCheckStateClassifier: stepPrefer))
    }

    /// DSL の `prefer:`(FlowStep.preferCheckStateClassifier)は実行プロファイルの既定を**両方向に**上書きする
    func testStepPreferenceOverridesTheProfileInBothDirections() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        // a11y はオフ・画像はオン = どちらで判定したかが結果に出る
        let a11yOff = element(type: "switch", value: "0")
        let toClassifier = await run("checked", a11y: a11yOff, imageOn: true, projectRoot: root,
                                     prefer: false, stepPrefer: true)
        XCTAssertTrue(passed(toClassifier), "プロファイルが a11y 優先でも、ステップ指定で分類器: \(toClassifier.status)")
        XCTAssertTrue(toClassifier.notes.contains(.checkStateClassified))
        let toAccessibility = await run("checked", a11y: a11yOff, imageOn: true, projectRoot: root,
                                        prefer: true, stepPrefer: false)
        XCTAssertFalse(passed(toAccessibility), "プロファイルが分類器優先でも、ステップ指定で a11y")
        XCTAssertFalse(toAccessibility.notes.contains(.checkStateClassified))
        // a11y 優先でも、a11y が状態を報告しない要素は分類器へ落ちる(プロファイルの false と同じ意味)
        let silent = await run("checked", a11y: element(type: "button"), imageOn: true, projectRoot: root,
                               prefer: true, stepPrefer: false)
        XCTAssertTrue(passed(silent), "\(silent.status)")
        XCTAssertTrue(silent.notes.contains(.checkStateClassified))
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

    // MARK: - 推論の対照(壊れた推論の答えを使わない)

    /// 対照はラベルの違う見本2枚。点検で取り違えた見本は選ばない(健全なときも外すので対照にならない)
    func testControlsAreTwoSamplesOfDifferentLabelsTheModelGetsRight() throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: CheckStateClassifier.directory(projectRoot: root)))
        let controls = VisionClassifier.controlSamples(set, excluding: [])
        XCTAssertEqual(controls.map(\.label), ["[OFF]", "[ON]"])
        let skipFirstOff = VisionClassifier.controlSamples(set, excluding: [
            VisionClassifier.Mismatch(sample: "[OFF]/s0.png", expected: "[OFF]", predicted: "[ON]", confidence: 0.9)])
        XCTAssertEqual(skipFirstOff.map(\.label), ["[OFF]", "[ON]"], "取り違えた s0 の代わりに次の見本を選ぶ")
        XCTAssertEqual(VisionClassifier.controlSamples(set, excluding: (0..<6).map {
            VisionClassifier.Mismatch(sample: "[OFF]/s\($0).png", expected: "[OFF]", predicted: "[ON]", confidence: 0.9)
        }).count, 0, "2 ラベルそろわなければ確かめない(空)")
    }

    /// **壊れた推論は失敗を返さず、どの画像にも同じラベルを確信度 1.00 で答える**(2026-09-19 負荷テスト:
    /// ON が写った crop を [OFF] 1.00 と答えた)。対照が外れたら答えを使わず a11y で判定する ——
    /// とくに**誤った緑**(a11y はオンなのに checkIsOFF が分類器の [OFF] で通る)を塞ぐ
    func testAnswerIsNotUsedWhenAControlSampleIsMisclassified() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: CheckStateClassifier.directory(projectRoot: root)))
        let model = try VisionClassifier.loadBlocking(set, cacheDirectory: CheckStateClassifier.cacheDirectory(projectRoot: root))
        XCTAssertEqual(model.controls.count, 2)
        model.inferenceForTesting = { _ in VisionClassifier.Classification(label: "[OFF]", confidence: 1) }
        defer { model.inferenceForTesting = nil }   // 同じ見本のモデルはプロセス内で共有される

        let a11yOn = element(type: "switch", value: "1")
        let off = await run("notChecked", a11y: a11yOn, imageOn: true, projectRoot: root, prefer: true)
        XCTAssertFalse(passed(off), "a11y はオン。壊れた分類器の [OFF] で checkIsOFF を通さない")
        XCTAssertTrue(off.notes.contains(.checkStateClassifierFailed))
        XCTAssertFalse(off.notes.contains(.checkStateClassified))
        let on = await run("checked", a11y: a11yOn, imageOn: true, projectRoot: root, prefer: true)
        XCTAssertTrue(passed(on), "a11y のオンで判定する: \(on.status)")

        // a11y が状態を持たない要素は判定材料が無い = 落ち、理由を言う
        let silent = await run("checked", a11y: element(type: "button"), imageOn: true, projectRoot: root, prefer: true)
        guard case .failed(let reason) = silent.status else { return XCTFail("\(silent.status)") }
        XCTAssertTrue(reason.contains("not answering reliably"), reason)
        XCTAssertTrue(reason.contains("\"[ON]\""), "どの対照を外したかを言う: \(reason)")
    }

    /// **分類器の判定で落ちたときだけ、判定に使ったスクリーンショットを持ち帰る**(レポートに添える)。
    /// 通ったとき・分類器を使わずに落ちたときは持たない(失敗の証拠であって毎ステップの記録ではない)
    func testFailureJudgedByTheClassifierCarriesTheScreenshotItJudged() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let failed = await run("checked", a11y: element(type: "button"), imageOn: false, projectRoot: root, prefer: true)
        XCTAssertFalse(passed(failed))
        XCTAssertEqual(failed.evidenceImage, Self.checkboxPNG(on: false, shift: 2),
                       "判定に使ったスクリーンショットそのもの(切り出しではない)を持ち帰るはず")
        if case .failed(let reason) = failed.status {
            XCTAssertTrue(reason.contains("attached to the report"), reason)
        }

        let ok = await run("checked", a11y: element(type: "button"), imageOn: true, projectRoot: root, prefer: true)
        XCTAssertTrue(passed(ok), "\(ok.status)")
        XCTAssertNil(ok.evidenceImage, "通ったステップは画像を持たない")

        let a11yOnly = await run("checked", a11y: element(type: "button"), imageOn: true, projectRoot: nil, prefer: true)
        XCTAssertFalse(passed(a11yOnly))
        XCTAssertNil(a11yOnly.evidenceImage, "分類器を使っていない失敗は画像を持たない")
    }
}
