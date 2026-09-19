// DefaultClassifier(Shirates Vision の imageIs)の見本の読み方と、imageIs の判定。
// 学習は合成した画像(丸 / 四角)で実際に Create ML に掛ける。

import CoreGraphics
import ImageIO
import XCTest
@testable import FTCore

final class DefaultClassifierTests: XCTestCase {

    /// 丸か四角のアイコン。`shift` で位置と大きさを少しずらす
    static func iconPNG(circle: Bool, shift: Int, canvas: Int = 64) -> Data {
        let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        let box = CGRect(x: 10 + shift, y: 10 + shift, width: 40 - shift, height: 40 - shift)
        if circle { context.fillEllipse(in: box) } else { context.fill(box) }
        return CheckStateClassifierTests.png(context.makeImage()!)
    }

    /// `@i/Settings/[Circle Icon]` と `@i/Settings/[Square Icon]` に見本を置いたプロジェクト
    static func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-\(UUID().uuidString)", isDirectory: true)
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
        for (label, circle) in [("[Circle Icon]", true), ("[Square Icon]", false)] {
            let labelDir = dir.appendingPathComponent("@i/Settings/\(label)", isDirectory: true)
            try FileManager.default.createDirectory(at: labelDir, withIntermediateDirectories: true)
            for i in 0..<6 {
                try iconPNG(circle: circle, shift: i).write(to: labelDir.appendingPathComponent("s\(i).png"))
            }
        }
        return root
    }

    // MARK: - 見本の読み方(Shirates の LearningImageFileEntry / VisionClassifierShard)

    func testNestedFoldersBecomeCombinedLabels() throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
        // テキストの索引(# 始まり)と、分類器フォルダ直下の画像は学習に使わない
        try Self.iconPNG(circle: true, shift: 0).write(to: dir.appendingPathComponent("@i/Settings/[Circle Icon]/#text.png"))
        try Self.iconPNG(circle: true, shift: 0).write(to: dir.appendingPathComponent("loose.png"))
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir))
        XCTAssertEqual(set.labels.keys.sorted(), ["@i_Settings_[Circle Icon]", "@i_Settings_[Square Icon]"])
        XCTAssertEqual(set.labels["@i_Settings_[Circle Icon]"]?.count, 6)
    }

    func testTheSameShortLabelInTwoFoldersIsAnError() throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
        let other = dir.appendingPathComponent("@a/Settings/[Circle Icon]", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Self.iconPNG(circle: true, shift: 0).write(to: other.appendingPathComponent("a.png"))
        XCTAssertThrowsError(try VisionClassifier.trainingSet(at: dir)) { error in
            XCTAssertTrue(String(describing: error).contains("[Circle Icon]"), "\(error)")
        }
    }

    func testShortLabelAndMatchFollowShirates() {
        XCTAssertEqual(VisionClassifier.shortLabel("@i_Settings_[Camera Icon]"), "[Camera Icon]")
        XCTAssertEqual(VisionClassifier.shortLabel("plain"), "plain")
        XCTAssertTrue(DefaultClassifier.matches(label: "@i_Settings_[Camera Icon]", expected: "[Camera Icon]"))
        XCTAssertTrue(DefaultClassifier.matches(label: "@i_Settings_[Camera Icon]", expected: "Camera"), "含むかで判定")
        XCTAssertFalse(DefaultClassifier.matches(label: "@i_Camera_[General Icon]", expected: "Camera"),
                       "見るのは短いラベルだけ(フォルダ名は見ない)")
    }

    // MARK: - imageIs

    private final class ImageDriver: AppDriver {
        let screenPNG: Data
        init(screenPNG: Data) { self.screenPNG = screenPNG }
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
                             elements: [ElementInfo(ref: 1, type: "image", identifier: "icon", label: nil, value: nil,
                                                    placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 0, y: 0, width: 64, height: 64), depth: 1)],
                             truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { screenPNG }
        func terminate() async throws {}
    }

    private func imageIs(_ expected: String, screenIsCircle: Bool, projectRoot: URL?) async -> StepOutcome {
        let executor = StepExecutor(driver: ImageDriver(screenPNG: Self.iconPNG(circle: screenIsCircle, shift: 2)),
                                    isAndroid: false)
        executor.visionClassifierProjectRoot = projectRoot
        return await executor.execute(FlowStep(assert: "imageIs", locator: FlowLocator(id: "icon"),
                                               expected: expected, timeout: 0))
    }

    private func reason(_ outcome: StepOutcome) -> String? {
        if case .failed(let reason) = outcome.status { return reason }
        return nil
    }

    func testImageIsClassifiesTheElementImage() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let circle = await imageIs("[Circle Icon]", screenIsCircle: true, projectRoot: root)
        XCTAssertNil(reason(circle), reason(circle) ?? "")
        let wrong = await imageIs("[Circle Icon]", screenIsCircle: false, projectRoot: root)
        let message = try XCTUnwrap(reason(wrong))
        XCTAssertTrue(message.contains("classified as \"[Square Icon]\""), message)

        // 見本に無いラベルは待たずに落とす(待っても答えは変わらない)
        let unknown = await imageIs("[Camera Icon]", screenIsCircle: true, projectRoot: root)
        XCTAssertTrue(reason(unknown)?.contains("no sample images") == true, reason(unknown) ?? "")
    }

    /// 対照が外れた推論の答えは imageIs でも使わない(「切り出しに失敗」とは言い分ける)
    func testImageIsDoesNotUseAnAnswerWhenAControlIsMisclassified() async throws {
        let root = try Self.makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: dir))
        let model = try VisionClassifier.loadBlocking(
            set, cacheDirectory: VisionClassifier.cacheDirectory(projectRoot: root, name: DefaultClassifier.name))
        let circle = try XCTUnwrap(set.labels.keys.first { $0.hasSuffix("[Circle Icon]") })
        model.inferenceForTesting = { _ in VisionClassifier.Classification(label: circle, confidence: 1) }
        defer { model.inferenceForTesting = nil }   // 同じ見本のモデルはプロセス内で共有される

        let outcome = await imageIs("[Circle Icon]", screenIsCircle: true, projectRoot: root)
        let message = try XCTUnwrap(reason(outcome), "定数を答える推論で imageIs を通さない")
        XCTAssertTrue(message.contains("not answering reliably"), message)
        XCTAssertFalse(message.contains("crop failed"), message)
    }

    func testImageIsWithoutSamplesFailsAndSaysWhereToPutThem() async {
        let outcome = await imageIs("[Circle Icon]", screenIsCircle: true, projectRoot: nil)
        XCTAssertTrue(reason(outcome)?.contains("vision/classifiers/DefaultClassifier") == true, reason(outcome) ?? "")
    }
}
