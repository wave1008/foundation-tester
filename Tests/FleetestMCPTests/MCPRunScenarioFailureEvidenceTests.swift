// ft_run_scenario / ft_dry_run の不合格を isError で返し、失敗の証跡(要素一覧・スクショ)を
// 応答に添える経路。シナリオ実行は子プロセスなので、ここでは組み立ての2つの純粋関数を固定する。

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPRunScenarioFailureEvidenceTests: XCTestCase {

    // MARK: - tools/call の result

    /// 中身を持った失敗は、画像を含む中身のまま isError:true で返る(文1本に畳まない)
    func testToolFailureKeepsItsContentAndMarksIsError() throws {
        let content: [[String: Any]] = [
            ["type": "text", "text": "❌ failed"],
            ["type": "image", "data": "AAAA", "mimeType": "image/jpeg"],
        ]
        let result = MCPServer.toolCallResult(.failure(MCPToolFailure(content: content)))
        XCTAssertEqual(result["isError"] as? Bool, true)
        let returned = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(returned.map { $0["type"] as? String }, ["text", "image"])
        XCTAssertEqual(returned.first?["text"] as? String, "❌ failed", "Error: を前置してはいけない")
    }

    func testPlainErrorIsOneTextBlockWithIsError() throws {
        let result = MCPServer.toolCallResult(.failure(MCPError("boom")))
        XCTAssertEqual(result["isError"] as? Bool, true)
        let returned = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(returned.count, 1)
        XCTAssertEqual(returned.first?["text"] as? String, "Error: boom")
    }

    func testSuccessIsNotAnError() {
        let result = MCPServer.toolCallResult(.success([["type": "text", "text": "ok"]]))
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    // MARK: - 証跡の組み立て

    /// 要素一覧が画像より先(直すための一次情報は木)。スクショは ft_screenshot と同じ縮小で JPEG
    func testElementListComesBeforeTheDownscaledScreenshot() throws {
        let evidence = FailureEvidence(scenes: [
            .init(number: 3, title: "ログイン", elements: "[1] Button \"Sign in\" id=btn_signin",
                  screenshotFile: "shot.png", screenshotBlank: false,
                  foregroundWindows: [], appProcess: []),
        ])
        let png = Self.makePNG(width: 1200, height: 800)
        var requested: [String] = []
        let content = MCPServer.failureEvidenceContent(evidence: evidence) { name in
            requested.append(name)
            return png
        }
        XCTAssertEqual(requested, ["shot.png"])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "text", "image"])
        let elements = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(elements.contains("scene 3"), elements)
        XCTAssertTrue(elements.contains("id=btn_signin"), elements)
        XCTAssertEqual(content.last?["mimeType"] as? String, "image/jpeg")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(content.last?["data"] as? String)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 600,
                       "ft_screenshot の既定幅(600)に縮めていない")
    }

    /// 白フレームは証跡として無効 = 画像は載せずに一言だけ言う
    func testBlankScreenshotIsOmittedWithANote() throws {
        let evidence = FailureEvidence(scenes: [
            .init(number: 1, title: "", elements: "[1] Text \"x\"", screenshotFile: "blank.png",
                  screenshotBlank: true, foregroundWindows: [], appProcess: []),
        ])
        let content = MCPServer.failureEvidenceContent(evidence: evidence) { _ in Data([0x01]) }
        XCTAssertFalse(content.contains { $0["type"] as? String == "image" })
        let note = try XCTUnwrap(content.last?["text"] as? String)
        XCTAssertTrue(note.contains("blank frame"), note)
    }

    /// 手前の別ウィンドウ・消えたプロセスは要素一覧に出ない事実なので、木と一緒に言う
    func testForegroundWindowAndMissingProcessAreSaidWithTheElementList() throws {
        let evidence = FailureEvidence(scenes: [
            .init(number: 1, title: "", elements: "[1] Text \"x\"", screenshotFile: nil,
                  screenshotBlank: false, foregroundWindows: ["Photos permission"],
                  appProcess: ["pid gone"]),
        ])
        let content = MCPServer.failureEvidenceContent(evidence: evidence) { _ in nil }
        XCTAssertEqual(content.count, 1)
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("Photos permission"), text)
        XCTAssertTrue(text.contains("pid gone"), text)
    }

    /// 証跡が無い(古い子プロセス・書けなかった)ときは何も足さない
    func testNoEvidenceAddsNothing() {
        XCTAssertTrue(MCPServer.failureEvidenceContent(evidence: nil) { _ in Data() }.isEmpty)
    }

    /// 単色だと JPEG が極端に小さくなるので市松模様にする(MCPToolCallTests と同じ形)
    private static func makePNG(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) where (x / 16 + y / 16) % 2 == 0 {
                context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        let image = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
