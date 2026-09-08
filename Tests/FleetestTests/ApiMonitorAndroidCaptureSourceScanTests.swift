import Foundation
import XCTest

/// `fleetest api monitor` の Android 撮影は `FTCore.AndroidScreencap`(adb 直叩き)だけを通すこと。
/// ブリッジ経由の `AndroidDriver(serial:).screenshot()` へ戻すと、ブリッジの無い実機でも観測
/// (ポーリング)のたびにブリッジを建ててしまう(利用者が「全て終了」した実機のブリッジが
/// 監視だけで復活する副作用があった)。
final class ApiMonitorAndroidCaptureSourceScanTests: XCTestCase {

    private static var apiMonitorCommandSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/fleetest/ApiMonitorCommand.swift")
    }

    /// コメント(`//` より右)を落とした本文全体。呼び出しが複数行へ折り返されても拾えるよう
    /// 行単位ではなく結合した全文へ正規表現をかける
    private static func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
    }

    private static let bridgeScreenshotPattern = try! NSRegularExpression(
        pattern: #"AndroidDriver\(\s*serial\s*:[^)]*\)\s*\.\s*screenshot\s*\("#,
        options: [.dotMatchesLineSeparators])

    func testAndroidCaptureDoesNotGoThroughTheBridgeScreenshot() throws {
        let code = try Self.codeOnly(Self.apiMonitorCommandSource)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        let matches = Self.bridgeScreenshotPattern.numberOfMatches(in: code, range: range)
        XCTAssertEqual(matches, 0,
                       "ApiMonitorCommand の Android 撮影がブリッジ経由へ戻っている。"
                       + "FTCore.AndroidScreencap.capturePNG(adb 直叩き)を使うこと")
    }

    /// 走査が空振りしていないことの確認(パス解決がズレて0件のまま緑になるのを防ぐ)
    func testTheSourceFileIsActuallyScanned() throws {
        let code = try Self.codeOnly(Self.apiMonitorCommandSource)
        XCTAssertTrue(code.contains("AndroidScreencap.capturePNG"),
                      "AndroidScreencap への委譲が見当たらない(走査対象のパス解決を疑う)")
    }
}
