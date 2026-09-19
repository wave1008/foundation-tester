// findImage / findImages の見本の特徴量の永続控え(TemplatePrintStore)。差分更新・OS の版・刈り込み・
// 門を通ったものだけ書くことを、実際に Vision の特徴量を作って確かめる。

import CoreGraphics
import Vision
import XCTest
@testable import FTCore

final class TemplatePrintStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tps-\(UUID().uuidString)")
        FindImage.forgetTemplatePrints()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        FindImage.forgetTemplatePrints()
    }

    private func sample(_ relative: String, circle: Bool) throws -> URL {
        let url = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DefaultClassifierTests.iconPNG(circle: circle, shift: 0).write(to: url)
        return url
    }

    private func print(of url: URL) async throws -> FeaturePrintObservation {
        try await FindImage.featurePrint(try XCTUnwrap(FindImage.loadImage(url)))
    }

    private var storeFile: URL { root.appendingPathComponent(".fleetest/vision/\(TemplatePrintStore.fileName)") }

    func testRecordedPrintIsReadBackUnchanged() async throws {
        let url = try sample("@i/Home/[Circle Icon]/circle.png", circle: true)
        let observation = try await print(of: url)
        TemplatePrintStore.record(url, print: observation)
        let stored = try XCTUnwrap(TemplatePrintStore.lookup(url))
        XCTAssertEqual(try stored.distance(to: observation), 0)
        XCTAssertEqual(Array(TemplatePrintStore.read(storeFile).entries.keys),
                       ["vision/classifiers/DefaultClassifier/@i/Home/[Circle Icon]/circle.png"])
    }

    /// 中身が変わった見本だけ外れ、他の行は残る(差分更新)
    func testOnlyTheChangedSampleIsInvalidated() async throws {
        let a = try sample("@i/Home/[A]/a.png", circle: true)
        let b = try sample("@i/Home/[B]/b.png", circle: true)
        TemplatePrintStore.record(a, print: try await print(of: a))
        TemplatePrintStore.record(b, print: try await print(of: b))
        try DefaultClassifierTests.iconPNG(circle: false, shift: 0).write(to: a)
        XCTAssertNil(TemplatePrintStore.lookup(a), "中身が変わったら控えを使わない")
        XCTAssertNotNil(TemplatePrintStore.lookup(b))
    }

    func testAnotherOSBuildIsNotReused() async throws {
        let url = try sample("@i/Home/[Circle Icon]/circle.png", circle: true)
        TemplatePrintStore.record(url, print: try await print(of: url), osBuild: "Version 1.0 (Build X)")
        XCTAssertNotNil(TemplatePrintStore.lookup(url, osBuild: "Version 1.0 (Build X)"))
        XCTAssertNil(TemplatePrintStore.lookup(url, osBuild: "Version 2.0 (Build Y)"))
    }

    func testRemovedSamplesArePrunedOnTheNextWrite() async throws {
        let a = try sample("@i/Home/[A]/a.png", circle: true)
        let b = try sample("@i/Home/[B]/b.png", circle: true)
        TemplatePrintStore.record(a, print: try await print(of: a))
        try FileManager.default.removeItem(at: a)
        TemplatePrintStore.record(b, print: try await print(of: b))
        XCTAssertEqual(Array(TemplatePrintStore.read(storeFile).entries.keys),
                       ["vision/classifiers/DefaultClassifier/@i/Home/[B]/b.png"])
    }

    func testImagesOutsideTheClassifiersAreNotPersisted() {
        XCTAssertNil(TemplatePrintStore.location(of: URL(fileURLWithPath: "/tmp/x/blank.png")))
    }

    /// match は門を通った見本だけを書き、門で落ちた見本(白紙 = 縮退と区別できない)は書かない
    func testMatchPersistsOnlyTemplatesThatPassedTheGates() async throws {
        let circle = try sample("@i/Home/[Circle Icon]/circle.png", circle: true)
        let blankURL = VisionClassifier.directory(projectRoot: root, name: DefaultClassifier.name)
            .appendingPathComponent("@i/Home/[Blank]/blank.png")
        try FileManager.default.createDirectory(at: blankURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CheckStateClassifierTests.png(FindImage.blankSentinel).write(to: blankURL)
        let screen = FTRect(x: 0, y: 0, width: 300, height: 100)
        let screenshot = try XCTUnwrap(VisionClassifier.crop(png: FindImageTests.screenPNG(), frame: screen, screen: screen))
        let elements = [ElementInfo(ref: 1, type: "image", identifier: "circle", label: nil, value: nil, placeholder: nil,
                                    enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 1)]
        _ = try await FindImage.match(template: circle, elements: elements, screen: screen, screenshot: screenshot,
                                      tolerance: 0.5, prints: FindImage.CandidatePrints())
        XCTAssertNotNil(TemplatePrintStore.lookup(circle), "門を通った見本は書く")
        // 前の run が書いた控えがあっても、門で落ちたら消す(壊れた状態の特徴量を持ち越さない)
        TemplatePrintStore.record(blankURL, print: try await print(of: blankURL))
        XCTAssertNotNil(TemplatePrintStore.lookup(blankURL))
        do {
            _ = try await FindImage.match(template: blankURL, elements: elements, screen: screen, screenshot: screenshot,
                                          tolerance: 0.5, prints: FindImage.CandidatePrints())
            XCTFail("白紙の見本で照合が通ってはいけない")
        } catch is FindImage.MatchError {}
        XCTAssertNil(TemplatePrintStore.lookup(blankURL), "門で落ちた見本は書かない・控えも消す")
    }
}
