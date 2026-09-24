// AndroidRunner/.../BridgeRouter.java の gesture 上限(本数・1本あたりの点数・秒数の天井)が
// BridgeAPI(Swift・ホストと MCP の唯一の門)と一致するかの同期検証。
//
// TouchGesture.swift はこのターゲット(Java)の入力集合に無い(Foundation 依存を増やしたくない)ため、
// BridgeRouter.java は同じ値を**写して**最後の砦として持つ。片方だけ上げると、
// ホストが通した要求を古い上限のブリッジが 400 で断る(本数・点数)、あるいは
// 古いホストが上限超えの要求をそのまま送っても新しいブリッジが素通しする(秒数)という
// 食い違いが黙って起きる。ここは production の定数どうしを突き合わせるのが目的の同期テストなので、
// production の定数を期待値に使ってよい(通常のテストで避けるべき「期待値を productionの定数で
// 書く」規律の例外)。

import XCTest
import FTCore

final class GestureLimitsSyncTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    private var routerSource: String {
        get throws {
            let path = repoRoot.appendingPathComponent(
                "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    /// `private static final <型> <name> = <値>;` の `<値>` を読む。無ければ nil
    /// (呼び手が「定数が見つからない」と明確に失敗させる)
    private func javaConstant(_ name: String, in source: String) -> Double? {
        let pattern = "\(name)\\s*=\\s*([0-9.]+)\\s*;"
        guard let range = source.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = source[range]
        guard let equalsIndex = matched.firstIndex(of: "="),
              let semicolonIndex = matched.firstIndex(of: ";") else { return nil }
        let literal = matched[matched.index(after: equalsIndex)..<semicolonIndex]
            .trimmingCharacters(in: .whitespaces)
        return Double(literal)
    }

    func testMaxFingersMatchesHostConstant() throws {
        let source = try routerSource
        guard let value = javaConstant("MAX_GESTURE_FINGERS", in: source) else {
            return XCTFail("BridgeRouter.java に MAX_GESTURE_FINGERS が見つかりません")
        }
        XCTAssertEqual(value, Double(BridgeAPI.gestureMaxFingers),
                       "BridgeRouter.java の MAX_GESTURE_FINGERS と"
                           + " BridgeAPI.gestureMaxFingers は同時に上げること"
                           + "(片方だけだと本数の門がホストとブリッジで食い違う)")
    }

    func testMaxPointsPerFingerMatchesHostConstant() throws {
        let source = try routerSource
        guard let value = javaConstant("MAX_GESTURE_POINTS_PER_FINGER", in: source) else {
            return XCTFail("BridgeRouter.java に MAX_GESTURE_POINTS_PER_FINGER が見つかりません")
        }
        XCTAssertEqual(value, Double(BridgeAPI.gestureMaxPointsPerFinger),
                       "BridgeRouter.java の MAX_GESTURE_POINTS_PER_FINGER と"
                           + " BridgeAPI.gestureMaxPointsPerFinger は同時に上げること"
                           + "(片方だけだと1本あたりの点数の門がホストとブリッジで食い違う)")
    }

    func testSecondsCeilingMatchesHostConstant() throws {
        let source = try routerSource
        guard let value = javaConstant("GESTURE_SECONDS_CEILING", in: source) else {
            return XCTFail("BridgeRouter.java に GESTURE_SECONDS_CEILING が見つかりません")
        }
        XCTAssertEqual(value, BridgeAPI.gestureSecondsCeiling,
                       "BridgeRouter.java の GESTURE_SECONDS_CEILING と"
                           + " BridgeAPI.gestureSecondsCeiling は同時に上げること"
                           + "(片方だけだと testmanagerd/InputInjector を守る最後の砦の秒数が食い違う)")
    }
}
