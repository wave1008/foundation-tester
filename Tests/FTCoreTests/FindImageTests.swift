// findImage / findImages(Shirates Vision の移植)。候補の絞り込み・テンプレートの引き当ては純粋関数で、
// 距離は合成した画面を実際に Vision の画像特徴量に掛けて確かめる。

import CoreGraphics
import XCTest
@testable import FTCore

final class FindImageTests: XCTestCase {

    private func element(_ ref: Int, id: String?, label: String? = nil,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "image", identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    // MARK: - アスペクト比(Shirates の SegmentContainer.filterByAspectRatio)

    func testAspectRatioRangeFollowsShiratesFormula() {
        let range = FindImage.aspectRatioRange(width: 100, height: 50, tolerance: 0.2)
        XCTAssertEqual(range.lowerBound, 100 * 0.8 / (50 * 1.2), accuracy: 1e-9)
        XCTAssertEqual(range.upperBound, 100 * 1.2 / (50 * 0.8), accuracy: 1e-9)
    }

    /// 既定値はリテラルで固定する(他のテストは timeout を明示するので、既定を戻す変更が素通りする)
    func testDefaultsArePinned() throws {
        XCTAssertEqual(FindImage.defaultWaitSeconds, 0)
        XCTAssertEqual(FindImage.defaultThreshold, 0.15)
        XCTAssertEqual(FindImage.defaultAspectRatioTolerance, 0.2)
        // DSL の findImage がこの定数を既定にしていること(実行プロファイルの defaultTimeout へ落とさない)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTDSL/CommandsVerify.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func findImage(_ label: String"))
        let signature = source[start.lowerBound...].prefix(while: { $0 != "{" })
        XCTAssertTrue(signature.contains("waitSeconds: Double = FindImage.defaultWaitSeconds"), String(signature))
        let body = source[start.upperBound...].prefix(1200)
        XCTAssertFalse(body.contains("core.defaultTimeout"), "findImage は実行プロファイルの defaultTimeout を使わない")
    }

    func testToleranceMustBeWithinShiratesBounds() {
        XCTAssertNotNil(FindImage.validate(aspectRatioTolerance: 0))
        XCTAssertNil(FindImage.validate(aspectRatioTolerance: 0.5))
        XCTAssertNotNil(FindImage.validate(aspectRatioTolerance: 0.51))
    }

    // MARK: - 候補

    func testCandidatesAreFilteredAndOrderedByAspectRatioCloseness() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let elements = [
            element(1, id: "wide", 0, 0, 300, 100),        // 3.0: 許容幅の外
            element(2, id: "slightlyTall", 0, 100, 90, 100),  // 0.9
            element(3, id: "square", 100, 100, 100, 100),     // 1.0
            element(4, id: "slightlyWide", 200, 100, 110, 100), // 1.1
        ]
        let picked = FindImage.candidates(in: elements, screen: screen, templateWidth: 64, templateHeight: 64,
                                          tolerance: 0.2)
        XCTAssertEqual(picked.map(\.element.identifier), ["square", "slightlyWide", "slightlyTall"])
    }

    func testSameVisibleFrameIsComparedOnceKeepingTheNamedElement() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let elements = [
            element(1, id: nil, 0, 0, 100, 100),
            element(2, id: nil, label: "Camera", 0, 0, 100, 100),
            element(3, id: "camera", 0, 0, 100, 100),
        ]
        let picked = FindImage.candidates(in: elements, screen: screen, templateWidth: 1, templateHeight: 1,
                                          tolerance: 0.2)
        XCTAssertEqual(picked.map(\.element.identifier), ["camera"])
    }

    /// XCUITest の木: ボタン(id だけ)の内側に、同じ枠の飾りの Image(SF Symbol 名の id + ラベル)が載る
    func testSameVisibleFrameKeepsTheOuterElementAmongThoseWithID() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let elements = [
            element(1, id: "radio_a", 85, 275, 44, 44),
            element(2, id: "largecircle.fill.circle", label: "Large Filled Circle Inside A Circle", 85, 275, 44, 44),
        ]
        let picked = FindImage.candidates(in: elements, screen: screen, templateWidth: 1, templateHeight: 1,
                                          tolerance: 0.2)
        XCTAssertEqual(picked.map(\.element.identifier), ["radio_a"])
    }

    func testOffscreenPartIsCutAndFullyOffscreenIsDropped() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let elements = [
            element(1, id: "half", 0, 750, 100, 100),   // 見えるのは 100x50(2.0)
            element(2, id: "gone", 0, 900, 100, 100),
        ]
        let square = FindImage.candidates(in: elements, screen: screen, templateWidth: 1, templateHeight: 1,
                                          tolerance: 0.2)
        XCTAssertTrue(square.isEmpty, "見えている部分の形で比べる(画面外の要素は候補にしない)")
        let wide = FindImage.candidates(in: elements, screen: screen, templateWidth: 2, templateHeight: 1,
                                        tolerance: 0.2)
        XCTAssertEqual(wide.map(\.element.identifier), ["half"])
        XCTAssertEqual(wide.first?.visibleFrame, FTRect(x: 0, y: 750, width: 100, height: 50))
    }

    // MARK: - テンプレート(Shirates の VisionClassifierShard.getFiles / findImageCore)

    func testTemplatesEndWithTheLabelAndPreferThisPlatform() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
        let png = DefaultClassifierTests.iconPNG(circle: true, shift: 0)
        for path in ["@a/Home/[Camera Icon]/a.png", "@i/Home/[Camera Icon]/i.png", "Common/[Camera Icon]/c@i.png",
                     "Common/[Camera Icon]/x.png", "Common/[Camera Icon]/x_binary.png",
                     "Common/[Camera Icon]/#text.png", "Common/[Other Icon]/o.png", "loose[Camera Icon].png"] {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
        }
        let ios = FindImage.templateFiles(label: "[Camera Icon]", classifierDirectory: dir, isAndroid: false)
        // 自 OS 用(フォルダかファイル名に @i)→ それ以外。組の中はパス順
        XCTAssertEqual(ios.map(\.lastPathComponent), ["i.png", "c@i.png", "a.png", "x.png"])
        let android = FindImage.templateFiles(label: "[Camera Icon]", classifierDirectory: dir, isAndroid: true)
        XCTAssertEqual(android.map(\.lastPathComponent), ["a.png", "i.png", "c@i.png", "x.png"])
    }

    // MARK: - 距離(実際に Vision に掛ける)

    /// 幅 300・高さ 100 の画面に 100x100 の図形を3つ(丸・四角・横線)並べる
    static func screenPNG() -> Data {
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
        return CheckStateClassifierTests.png(context.makeImage()!)
    }

    var screenElements: [ElementInfo] {
        [element(1, id: "circle", 0, 0, 100, 100), element(2, id: "square", 100, 0, 100, 100),
         element(3, id: "line", 200, 0, 100, 100)]
    }

    func makeProjectForExtension() throws -> URL { try makeProject() }

    /// `@i/Home/[Circle Icon]` に画面の丸と同じ切り出しを置いたプロジェクト
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fi-\(UUID().uuidString)")
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
            .appendingPathComponent("@i/Home/[Circle Icon]", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crop = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: FTRect(x: 0, y: 0, width: 100, height: 100),
                                                       screen: FTRect(x: 0, y: 0, width: 300, height: 100)))
        try CheckStateClassifierTests.png(crop).write(to: dir.appendingPathComponent("circle.png"))
        return root
    }

    func testMatchRanksTheSameImageFirst() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try XCTUnwrap(FindImage.templateFiles(
            label: "[Circle Icon]", classifierDirectory: VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name),
            isAndroid: false).first)
        let screenshot = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: FTRect(x: 0, y: 0, width: 300, height: 100),
                                                             screen: FTRect(x: 0, y: 0, width: 300, height: 100)))
        let matches = try await FindImage.match(template: template, elements: screenElements,
                                                screen: FTRect(x: 0, y: 0, width: 300, height: 100),
                                                screenshot: screenshot, tolerance: 0.2,
                                                prints: FindImage.CandidatePrints())
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.first?.element.identifier, "circle")
        XCTAssertLessThan(try XCTUnwrap(matches.first?.distance), FindImage.defaultThreshold)
        XCTAssertGreaterThan(matches[1].distance, try XCTUnwrap(matches.first?.distance))
    }

    // MARK: - アクション(StepExecutor)

    private final class ScreenDriver: AppDriver {
        let elements: [ElementInfo]
        init(elements: [ElementInfo]) { self.elements = elements }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 300, height: 100),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { FindImageTests.screenPNG() }
        func terminate() async throws {}
    }

    private func run(_ action: String, label: String = "[Circle Icon]", threshold: Double?,
                     projectRoot: URL?) async -> StepOutcome {
        let executor = StepExecutor(driver: ScreenDriver(elements: screenElements), isAndroid: false)
        executor.visionClassifierProjectRoot = projectRoot
        return await executor.execute(FlowStep(action: action, expected: label, timeout: 0,
                                               imageThreshold: threshold))
    }

    func testFindImageGrabsTheNearestElementAndSaysTheDistance() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run("findImage", threshold: FindImage.defaultThreshold, projectRoot: root)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(outcome.imageMatches?.map(\.element.identifier), ["circle"])
        XCTAssertEqual(outcome.imageMatches?.first?.selector, "#circle")
        XCTAssertEqual(outcome.resolvedElement?.identifier, "circle")
        XCTAssertTrue(outcome.driverFallback?.hasPrefix("found (distance ") == true, outcome.driverFallback ?? "")
    }

    func testFindImageNotFoundIsAnEmptyResultWithTheNearestDistance() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        // 同じ画像でも距離は 0 を割らないので、閾値 < 0 は必ず見つからない
        let outcome = await run("findImage", threshold: -1, projectRoot: root)
        guard case .passed = outcome.status else {
            return XCTFail("見つからなくても失敗にしない(select と同じ): \(outcome.status)")
        }
        XCTAssertEqual(outcome.imageMatches?.count, 0)
        XCTAssertNil(outcome.resolvedElement)
        XCTAssertTrue(outcome.driverFallback?.hasPrefix("not found (nearest distance ") == true,
                      outcome.driverFallback ?? "")
    }

    func testFindImagesReturnsBelowThresholdNearestFirst() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = await run("findImages", threshold: nil, projectRoot: root)
        XCTAssertEqual(all.imageMatches?.map(\.element.identifier).first, "circle")
        XCTAssertEqual(all.imageMatches?.count, 3, "threshold: nil は絞らない")
        let filtered = await run("findImages", threshold: FindImage.defaultThreshold, projectRoot: root)
        XCTAssertEqual(filtered.imageMatches?.map(\.element.identifier), ["circle"],
                       "\(filtered.status) / \(filtered.driverFallback ?? "-") / all: \(all.driverFallback ?? "-")")
        XCTAssertNil(filtered.resolvedElement, "findImages は要素を1つに定めない")
    }

    // MARK: - findImages はラベルの見本を全部使う(Shirates は1枚。docs/shirates-parity.md)

    private func match(_ e: ElementInfo, _ distance: Double, _ template: String) -> FindImage.Match {
        FindImage.Match(element: e, visibleFrame: e.frame, distance: distance,
                        template: URL(fileURLWithPath: "/t/\(template).png"))
    }

    func testMergeKeepsEachElementOnceAtItsNearestDistance() {
        let a = element(1, id: "a", 0, 0, 10, 10), b = element(2, id: "b", 10, 0, 10, 10),
            c = element(3, id: "c", 20, 0, 10, 10)
        let merged = FindImage.mergeAcrossTemplates(
            [[match(a, 0.02, "off"), match(b, 0.20, "off"), match(c, 0.14, "off")],
             [match(b, 0.03, "on"), match(a, 0.30, "on"), match(c, 0.05, "on")]],
            threshold: 0.15)
        XCTAssertEqual(merged.map(\.element.identifier), ["a", "b", "c"], "距離順・1要素1件")
        // c は両方の見本が閾値内(0.14 / 0.05)= 先に出た距離ではなく近いほうを残す
        XCTAssertEqual(merged.map(\.distance), [0.02, 0.03, 0.05], "要素ごとに最も近い見本の距離")
        XCTAssertEqual(merged.map { $0.template.lastPathComponent }, ["off.png", "on.png", "on.png"])
        XCTAssertEqual(FindImage.mergeAcrossTemplates([[match(c, 0.15, "on")]], threshold: 0.15).count, 0,
                       "findImages は閾値未満(<)だけ(Shirates のまま)")
        XCTAssertEqual(FindImage.mergeAcrossTemplates([[match(a, 0.9, "off")], [match(b, 0.8, "on")]],
                                                      threshold: nil).map(\.element.identifier), ["b", "a"],
                       "threshold: nil は絞らない")
    }

    /// 1枚目の見本(丸)には当たらない要素(四角)も、2枚目の見本で返る(実行経路で確かめる)
    func testFindImagesUsesEveryTemplateOfTheLabel() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
            .appendingPathComponent("@i/Home/[Circle Icon]", isDirectory: true)
        let square = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: FTRect(x: 100, y: 0, width: 100, height: 100),
                                                        screen: FTRect(x: 0, y: 0, width: 300, height: 100)))
        // パス順で circle.png の後ろ = 1枚しか使わなければ試されない
        try CheckStateClassifierTests.png(square).write(to: dir.appendingPathComponent("square.png"))
        let outcome = await run("findImages", threshold: FindImage.defaultThreshold, projectRoot: root)
        XCTAssertEqual(outcome.imageMatches?.map { $0.element.identifier ?? "-" }.sorted(), ["circle", "square"],
                       "\(outcome.status) / \(outcome.driverFallback ?? "-")")
    }

    /// 見本が複数でも、候補の特徴量は走査につき1回だけ計算し、距離は控え無しと同じ
    func testCandidatePrintsAreComputedOncePerScan() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
            .appendingPathComponent("@i/Home/[Circle Icon]", isDirectory: true)
        let screen = FTRect(x: 0, y: 0, width: 300, height: 100)
        let square = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: FTRect(x: 100, y: 0, width: 100, height: 100),
                                                        screen: screen))
        try CheckStateClassifierTests.png(square).write(to: dir.appendingPathComponent("square.png"))
        let templates = FindImage.templateFiles(label: "[Circle Icon]", classifierDirectory: VisionClassifier.directory(
            projectRoot: root, name: DefaultClassifier.name), isAndroid: false)
        XCTAssertEqual(templates.count, 2)
        let screenshot = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: screen, screen: screen))
        let shared = FindImage.CandidatePrints()
        for template in templates {
            let cached = try await FindImage.match(template: template, elements: screenElements, screen: screen,
                                                   screenshot: screenshot, tolerance: 0.2, prints: shared)
            let fresh = try await FindImage.match(template: template, elements: screenElements, screen: screen,
                                                  screenshot: screenshot, tolerance: 0.2, prints: FindImage.CandidatePrints())
            XCTAssertEqual(cached.map(\.distance), fresh.map(\.distance))
        }
        XCTAssertEqual(shared.computed, screenElements.count, "見本2枚でも候補3つぶんしか計算しない")
    }

    /// 1回の走査の Vision の控えは1回だけ書く(特徴量1回ごとに書くと照合より重い。performance-tuning §3.30)
    func testEachScanWritesTheVisionLedgerOnce() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+FindImage.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func scanImage(templates:"))
        let end = try XCTUnwrap(source.range(of: "private func scanImageOnce(templates:"))
        XCTAssertTrue(source[start.upperBound..<end.lowerBound].contains("VisionUsageLedger.batched"),
                      "走査を batched で包んでいない")
        XCTAssertEqual(source.components(separatedBy: "scanImageOnce(").count - 1, 2,
                       "scanImageOnce を直に呼ぶのは scanImage だけ(宣言 + 1か所)")
    }

    func testExistImagePassesAndGrabsTheElementLikeFindImage() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run("existImage", threshold: FindImage.defaultThreshold, projectRoot: root)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(outcome.imageMatches?.map(\.element.identifier), ["circle"])
        XCTAssertEqual(outcome.resolvedElement?.identifier, "circle")
        XCTAssertNil(outcome.evidenceImage, "通ったステップは証跡を持ち帰らない")
    }

    func testExistImageNotFoundFailsWithTheNearestDistanceAndTheJudgedScreenshot() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run("existImage", threshold: -1, projectRoot: root)
        guard case .failed(let reason) = outcome.status else {
            return XCTFail("existImage は見つからなければ失敗: \(outcome.status)")
        }
        XCTAssertTrue(reason.hasPrefix("image \"[Circle Icon]\" does not exist: not found (nearest distance "), reason)
        XCTAssertTrue(reason.contains("threshold -1.000"), reason)
        XCTAssertEqual(outcome.failureKind, .notFound)
        XCTAssertNil(outcome.imageMatches)
        XCTAssertNil(outcome.resolvedElement)
        XCTAssertEqual(outcome.evidenceImage, Self.screenPNG())
    }

    func testExistImageCountsAsVerificationButFindImageDoesNot() {
        XCTAssertTrue(FlowStep(action: "existImage", expected: "x").isVerification)
        XCTAssertFalse(FlowStep(action: "findImage", expected: "x").isVerification)
        XCTAssertTrue(FlowStep(assert: "exists").isVerification)
    }

    func testMissingTemplateFailsAndSaysWhereToPutIt() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run("findImage", label: "[Camera Icon]", threshold: 0.15, projectRoot: root)
        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("vision/classifiers/DefaultClassifier"), reason)
    }
}

// MARK: - 分類器による救済の確かめ(Shirates の VisionElement.classifyFull)

extension FindImageTests {
    private func templateAndCrops() throws -> (templates: [URL], root: URL, same: CGImage, other: CGImage) {
        let root = try makeProjectForExtension()
        let templates = FindImage.templateFiles(
            label: "[Circle Icon]", classifierDirectory: VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name),
            isAndroid: false)
        let screen = FTRect(x: 0, y: 0, width: 300, height: 100)
        let same = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: FTRect(x: 0, y: 0, width: 100, height: 100), screen: screen))
        let other = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: FTRect(x: 200, y: 0, width: 100, height: 100), screen: screen))
        return (templates, root, same, other)
    }

    func testLabelAloneDoesNotConfirmAnUnrelatedImage() async throws {
        let (templates, root, same, other) = try templateAndCrops()
        defer { try? FileManager.default.removeItem(at: root) }
        let confident = VisionClassifier.Classification(label: "@i_Home_[Circle Icon]", confidence: 0.9)
        let unrelated = try await StepExecutor.classificationConfirmed(confident, crop: other, templates: templates,
                                                                        threshold: FindImage.defaultThreshold)
        XCTAssertFalse(unrelated, "ラベルが一致しても見本と似ていなければ採らない")
        let related = try await StepExecutor.classificationConfirmed(confident, crop: same, templates: templates,
                                                                      threshold: FindImage.defaultThreshold)
        XCTAssertTrue(related)
    }

    func testLowConfidenceBranchFollowsShirates() async throws {
        let (templates, root, _, other) = try templateAndCrops()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsure = VisionClassifier.Classification(label: "@i_Home_[Circle Icon]", confidence: 0.12)
        let confirmed = try await StepExecutor.classificationConfirmed(unsure, crop: other, templates: templates,
                                                                        threshold: FindImage.defaultThreshold)
        XCTAssertTrue(confirmed, "Shirates は shard 1 で確信度が閾値以下ならそのラベルを返す")
    }
}

// MARK: - Vision の縮退(異なる画像に同一の特徴量)

extension FindImageTests {
    func testDegenerateVisionIsRefusedNotAnswered() async throws {
        XCTAssertTrue(FindImage.isDegenerate(templateDistanceToBlank: 0), "白紙と距離 0 = 何も見分けられない")
        XCTAssertFalse(FindImage.isDegenerate(templateDistanceToBlank: 1.44), "実物の見本と白紙は 1.4 ほど離れる(実測)")
        XCTAssertFalse(FindImage.isDegenerate(templateDistanceToBlank: 0.001))
        // 白紙そのものをテンプレートにすると門に当たる(縮退と区別できないので同じ断り方をする)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blank = root.appendingPathComponent("blank.png")
        try CheckStateClassifierTests.png(FindImage.blankSentinel).write(to: blank)
        let screen = FTRect(x: 0, y: 0, width: 300, height: 100)
        let screenshot = try XCTUnwrap(VisionClassifier.crop(png: Self.screenPNG(), frame: screen, screen: screen))
        do {
            _ = try await FindImage.match(template: blank, elements: screenElements, screen: screen,
                                          screenshot: screenshot, tolerance: 0.5,
                                          prints: FindImage.CandidatePrints())
            XCTFail("白紙のテンプレートで照合が通ってはいけない")
        } catch let error as FindImage.MatchError {
            guard case .degeneratePrints = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.description.contains("blank"), error.description)
        }
    }
}

// MARK: - Vision の半端な異常(同じ画像に違う特徴量)

extension FindImageTests {
    func testTheSameImageMustGiveTheSamePrint() {
        XCTAssertTrue(FindImage.isConsistent(selfDistance: 0), "健全なら同じ画像の特徴量は完全に一致する(実測 1,200/1,200)")
        XCTAssertFalse(FindImage.isConsistent(selfDistance: 0.0011), "異なる見本どうしの最小距離(実測)は通さない")
        XCTAssertFalse(FindImage.isConsistent(selfDistance: 0.33), "負荷テストで見た半端な異常の距離")
    }

    /// match は縮退の門の後・候補の照合の前に、見本を取り直して控えと比べ、ずれたら照合せずに断る
    func testMatchReMeasuresTheTemplateBeforeComparingCandidates() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/FindImage.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public static func match(template:"))
        let body = source[start.upperBound...]
        let degenerate = try XCTUnwrap(body.range(of: "throw MatchError.degeneratePrints"))
        let consistent = try XCTUnwrap(body.range(of: "if !isConsistent(selfDistance:"))
        let inconsistent = try XCTUnwrap(body.range(of: "throw MatchError.inconsistentPrints"))
        let loop = try XCTUnwrap(body.range(of: "for candidate in candidates"))
        XCTAssertLessThan(degenerate.lowerBound, consistent.lowerBound)
        XCTAssertLessThan(inconsistent.lowerBound, loop.lowerBound, "候補を照合する前に断る")
        XCTAssertTrue(body[consistent.lowerBound..<inconsistent.lowerBound].contains("discardTemplatePrints(after: template)"),
                      "ずれた控えを次の照合に使わない(プロセス内の控えも永続控えも)")
    }
}
