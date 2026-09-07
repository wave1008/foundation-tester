// occlusion-guard Tier-2(RegionText)の固定コーパス照合。実 run で FM の段に届いた crop を
// Tests/Fixtures/OcclusionCrops/ に置き、**拡大の段ごとに読めるかを等号で固定**する。
// 合成画像では拡大の効きが再現しない(実測: 6pt の合成文字は ×2 で悪化する)ので、
// はしごが要ることを示せるのは実 crop だけ。

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FTCore

final class RegionTextCorpusTests: XCTestCase {

    private struct Manifest: Decodable {
        struct Crop: Decodable {
            let file: String
            let expectedText: String
            /// 本番の規則(言語は期待文字列から決める)で読めるか
            let readableWithLanguageRule: Bool
            /// はしごが実際に撃つ回数(読めたら止まる / 1行も読めなければ段を上げない)
            let ladderAttemptsWithRule: Int
            /// 日本語モデルを載せたときの段ごとの読み取り(言語規則の効き目と、はしごの安全網としての値)
            let readableAtWithJapanese: [String: Bool]
        }
        let crops: [Crop]
    }

    /// `Tests/FTCoreTests/このファイル` から相対に `Tests/Fixtures/OcclusionCrops` を指す
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OcclusionCrops")
    }

    private func manifest() throws -> Manifest {
        let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// crop はすでに切り出し済みなので frame = screen = 画像全体を渡す(OcclusionCrop.rect が
    /// 画像内にクランプするので、余白の付け直しは起きない)
    private func png(_ name: String) throws -> (data: Data, rect: FTRect) {
        let url = fixtureDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (data, FTRect(x: 0, y: 0, width: Double(image.width), height: Double(image.height)))
    }

    /// **言語規則の効き目**を等号で固定する —— 日本語モデルを載せると ASCII の期待文字列を
    /// 誤読する(`swipe=down`→`swipe=aown`)。段ごとの表はその誤読と、はしごが安全網として
    /// どこで効くかを示す。ここが動いたら言語規則・拡大の段・一致規則・Vision の版のどれかが変わっている
    func testJapaneseModelMisreadsAsciiAndTheLadderRescuesIt() async throws {
        for crop in try manifest().crops {
            let (data, rect) = try png(crop.file)
            for (step, expected) in crop.readableAtWithJapanese {
                let factor = try XCTUnwrap(Int(step))
                let readingRaw = await RegionText.read(pngData: data, frame: rect, screen: rect,
                                                       languages: RegionText.defaultLanguages,
                                                       upscale: factor)
                let reading = try XCTUnwrap(readingRaw)
                XCTAssertEqual(RegionText.readable(expected: crop.expectedText, lines: reading.lines),
                               expected,
                               "\(crop.file) ja+en ×\(factor): 読めた行 \(reading.lines)")
            }
        }
    }

    /// 本番の経路(言語は期待文字列から決める)。**ASCII の期待文字列は等倍で読める**ので段は上がらず、
    /// **描かれていない crop は読めないまま FM へ回る** —— ここが逆転すると見逃し(誤った緑)になる
    func testResolveFollowsTheLanguageRule() async throws {
        for crop in try manifest().crops {
            let (data, rect) = try png(crop.file)
            let resolvedRaw = await RegionText.resolve(expected: crop.expectedText, pngData: data,
                                                       frame: rect, screen: rect)
            let resolved = try XCTUnwrap(resolvedRaw)
            XCTAssertEqual(resolved.readable, crop.readableWithLanguageRule,
                           "\(crop.file): はしごの結果 \(resolved.reading.lines)")
            XCTAssertEqual(resolved.reading.attempts, crop.ladderAttemptsWithRule, "\(crop.file)")
        }
    }

    /// 呼び手が言語を明示したらそれを使う。日本語モデル込みだと `swipe=down` は等倍で誤読するので、
    /// **はしごが 2 段目で拾う**(安全網として効いていることの witness)
    func testResolveUsesTheLanguagesGivenByTheCaller() async throws {
        let crop = try XCTUnwrap(try manifest().crops.first { $0.file == "swipe-down.png" })
        let (data, rect) = try png(crop.file)
        let resolvedRaw = await RegionText.resolve(expected: crop.expectedText, pngData: data,
                                                   frame: rect, screen: rect,
                                                   languages: RegionText.defaultLanguages)
        let resolved = try XCTUnwrap(resolvedRaw)
        XCTAssertTrue(resolved.readable, "読めた行 \(resolved.reading.lines)")
        XCTAssertEqual(resolved.reading.attempts, 2)
    }
}
