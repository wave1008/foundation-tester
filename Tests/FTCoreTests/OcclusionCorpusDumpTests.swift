import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

final class OcclusionCorpusDumpTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("occlusion-corpus-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func whitePNG() -> Data {
        guard let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        guard let image = ctx.makeImage() else { fatalError("テスト用 CGImage 生成に失敗") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("テスト用 PNG 書き出しに失敗") }
        return output as Data
    }

    func testWritesPngAndJsonWhenModeIsMeasure() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = OcclusionCorpusDump.Entry(
            expectedText: "ログイン", tier: "ink", inkStdDev: 4.2, ocrLines: ["ログイソ"],
            ocrReadable: false, ocrMs: 33.1, fmVisible: false, fmState: "covered", fmObserved: "")

        OcclusionCorpusDump.write(
            pngData: whitePNG(), frame: FTRect(x: 0, y: 0, width: 40, height: 40),
            screen: FTRect(x: 0, y: 0, width: 40, height: 40), entry: entry,
            environment: ["FT_OCCLUSION_OCR": "measure", "FT_OCCLUSION_CORPUS_DIR": dir.path])

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.filter { $0.pathExtension == "png" }.count, 1)
        let jsonURL = try XCTUnwrap(entries.first { $0.pathExtension == "json" })

        let decoded = try JSONDecoder().decode(OcclusionCorpusDump.Entry.self, from: Data(contentsOf: jsonURL))
        XCTAssertEqual(decoded.expectedText, "ログイン")
        XCTAssertEqual(decoded.tier, "ink")
        XCTAssertEqual(decoded.inkStdDev, 4.2)
        XCTAssertEqual(decoded.ocrLines, ["ログイソ"])
        XCTAssertEqual(decoded.ocrReadable, false)
        XCTAssertEqual(decoded.ocrMs, 33.1, accuracy: 0.001)
        XCTAssertEqual(decoded.fmVisible, false)
        XCTAssertEqual(decoded.fmState, "covered")
        XCTAssertEqual(decoded.fmObserved, "")
    }

    /// FM が答えを返さなかった回(fmVisible=nil)も書ける
    func testFmVisibleNullWhenNoVerdict() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = OcclusionCorpusDump.Entry(
            expectedText: "ログイン", tier: "geo", inkStdDev: nil, ocrLines: [],
            ocrReadable: false, ocrMs: 0, fmVisible: nil, fmState: nil, fmObserved: nil)

        OcclusionCorpusDump.write(
            pngData: whitePNG(), frame: FTRect(x: 0, y: 0, width: 40, height: 40),
            screen: FTRect(x: 0, y: 0, width: 40, height: 40), entry: entry,
            environment: ["FT_OCCLUSION_OCR": "measure", "FT_OCCLUSION_CORPUS_DIR": dir.path])

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let jsonURL = try XCTUnwrap(entries.first { $0.pathExtension == "json" })
        let decoded = try JSONDecoder().decode(OcclusionCorpusDump.Entry.self, from: Data(contentsOf: jsonURL))
        XCTAssertNil(decoded.fmVisible)
        XCTAssertNil(decoded.inkStdDev)
    }

    /// 書くのは measure のときだけ(既定 on でも off でも書かない)
    func testWritesNothingOutsideMeasureMode() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = OcclusionCorpusDump.Entry(
            expectedText: "ログイン", tier: "geo", inkStdDev: nil, ocrLines: [],
            ocrReadable: false, ocrMs: 0, fmVisible: nil, fmState: nil, fmObserved: nil)

        OcclusionCorpusDump.write(
            pngData: whitePNG(), frame: FTRect(x: 0, y: 0, width: 40, height: 40),
            screen: FTRect(x: 0, y: 0, width: 40, height: 40), entry: entry,
            environment: ["FT_OCCLUSION_CORPUS_DIR": dir.path])
        OcclusionCorpusDump.write(
            pngData: whitePNG(), frame: FTRect(x: 0, y: 0, width: 40, height: 40),
            screen: FTRect(x: 0, y: 0, width: 40, height: 40), entry: entry,
            environment: ["FT_OCCLUSION_OCR": "off", "FT_OCCLUSION_CORPUS_DIR": dir.path])

        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(entries.isEmpty, "measure 以外では何も書かないはず")
    }
}
