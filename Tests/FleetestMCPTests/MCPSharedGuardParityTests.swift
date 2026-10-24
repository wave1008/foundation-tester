// **MCP のツールが、同じ種類の操作の共有の門を通っていること**をソース走査で固定する(2026-10-11 の掃討の再発防止)。
// 実害: ft_double_tap だけが ft_tap と同じ被覆(キーボードの下を断る・遮蔽の警告)を通り、ft_drag の fromRef・ft_pinch の ref は
// 無警告だった / 座標の ft_drag・ft_pinch・ft_gesture はキーボードの上でも何も言わなかった / ft_capture_element は一色の絵を
// 分類器の見本に保存した(DSL の分類は断っている)。どれもビルドもテストも緑のまま。
// 新しいツールを足して門を通さなければここで落ちる。**通さないのが正しいなら、理由を書いて表へ載せる**。

import XCTest

final class MCPSharedGuardParityTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `func 名前(` から次の同じ深さの func までの本文(コメント行は落とす = doc に名前が出ても数えない)
    private func functions(in relativeDirectory: String) throws -> [(name: String, body: String)] {
        let dir = Self.root.appendingPathComponent(relativeDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "走査が \(relativeDirectory) に届いていない")
        var result: [(String, String)] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            var name: String?
            var body: [Substring] = []
            for line in lines {
                if let match = line.firstMatch(of: /^    (?:public |static |private )*func (\w+)\(/) {
                    if let name { result.append((name, body.joined(separator: "\n"))) }
                    name = String(match.1)
                    body = []
                }
                body.append(line)
            }
            if let name { result.append((name, body.joined(separator: "\n"))) }
        }
        return result
    }

    /// **ref で始点を指すジェスチャは ft_tap と同じ被覆**(verifiedRef は中で通すので対象外。verifiedElement は通さない)
    func testEveryHandlerThatResolvesAnElementPassesTheRefGestureGuard() throws {
        let handlers = try functions(in: "Sources/fleetest-mcp").filter {
            $0.name.hasPrefix("ft") && $0.body.contains("verifiedElement(")
        }
        XCTAssertGreaterThanOrEqual(handlers.count, 3, "ft_double_tap / ft_drag / ft_pinch を拾えていない")
        let missing = handlers.filter { !$0.body.contains("refGestureGuard(") }.map(\.name)
        XCTAssertEqual(missing, [], "verifiedElement で要素を引いたのに refGestureGuard を通していない")
    }

    /// **座標で撃つツールは、キーボードの上の警告と前面のアプリの警告を通す**(ft_tap / ft_long_press と同じ)。
    /// 座標を受けるかは画面内の門(offscreenCoordinateError)か、指の経路の検査(TouchGesture.resolve)で見分ける
    func testEveryCoordinateHandlerWarnsAboutTheKeyboardAndTheFrontApp() throws {
        let handlers = try functions(in: "Sources/fleetest-mcp").filter {
            $0.name.hasPrefix("ft")
                && ($0.body.contains("offscreenCoordinateError(") || $0.body.contains("TouchGesture.resolve("))
        }
        XCTAssertGreaterThanOrEqual(handlers.count, 6, "座標を受けるツールを拾えていない: \(handlers.map(\.name))")
        let missing = handlers.filter {
            !$0.body.contains("keyboardCoordinateWarning(") || !$0.body.contains("coordinateFrontAppWarning(")
        }.map(\.name)
        XCTAssertEqual(missing, [], "座標で撃つのに、キーボードか前面のアプリの警告を通していない")
    }

    /// **ref で要素を押すツールは、Android の下端のジェスチャ帯を避ける**(DSL の tap・長押し・doubleTap と同じ
    /// `BottomGestureBandTap` を `bottomBandPoint` 経由で通す。DSL にだけ入れていた = 同じ画面で MCP だけホームへ抜けた)
    func testEveryRefTouchHandlerClearsTheBottomGestureBand() throws {
        let handlers = Dictionary(try functions(in: "Sources/fleetest-mcp").map { ($0.name, $0.body) },
                                  uniquingKeysWith: { a, _ in a })
        for name in ["ftTap", "ftLongPress", "ftDoubleTap"] {
            let body = try XCTUnwrap(handlers[name], "\(name) を拾えていない")
            XCTAssertTrue(body.contains("bottomBandPoint("), "\(name) が下端のジェスチャ帯を避けていない")
        }
    }

    /// **分類器の見本を保存する経路は、一色の絵を断る**(DSL の分類と同じ BlankFrameDetector.isUnjudgeable)。MCP と CLI の両方
    func testEveryVisionSampleSaverRefusesABlankFrame() throws {
        let savers = try (functions(in: "Sources/fleetest-mcp") + functions(in: "Sources/fleetest"))
            .filter { $0.body.contains("VisionSample.save(") }
        XCTAssertGreaterThanOrEqual(savers.count, 2, "ft_capture_element / fleetest vision capture を拾えていない")
        let missing = savers.filter { !$0.body.contains("BlankFrameDetector.isUnjudgeable") }.map(\.name)
        XCTAssertEqual(missing, [], "一色の絵を見本に保存しうる")
    }
}
