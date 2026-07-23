// occlusion-guard が反転(不可視判定)したときに保存する crop ダンプの検証。
// このダンプが無いと「FM の誤判定」なのか「渡した crop が別物だった」のかを事後に切り分けられない
// (レポートの失敗時スクショは poll 終了後の別撮りで、FM の入力ではない)。

import CoreGraphics
import XCTest
@testable import FTAgent

final class OcclusionDumpTests: XCTestCase {

    private func makeImage(width: Int = 40, height: Int = 20) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testDumpWritesPNGAndExpectedText() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-occlusion-dump-\(UUID().uuidString)")
        setenv("FT_OCCLUSION_DUMP_DIR", dir.path, 1)
        defer { unsetenv("FT_OCCLUSION_DUMP_DIR"); try? FileManager.default.removeItem(at: dir) }

        let dumpedPath = try XCTUnwrap(OcclusionVerifier.dump(crop: makeImage(), expectedText: "E2E ホーム"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dumpedPath))
        // 期待テキストが隣に無いと再判定(Scripts/occlusion-repro.swift)に食わせられない
        let txt = URL(fileURLWithPath: dumpedPath).deletingPathExtension()
            .appendingPathExtension("txt")
        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8), "E2E ホーム")
    }

    func testDumpDisabledByOff() {
        setenv("FT_OCCLUSION_DUMP_DIR", "off", 1)
        defer { unsetenv("FT_OCCLUSION_DUMP_DIR") }
        XCTAssertNil(OcclusionVerifier.dump(crop: makeImage(), expectedText: "x"))
    }
}
