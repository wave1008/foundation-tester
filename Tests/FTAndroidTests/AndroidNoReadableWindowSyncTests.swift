// BridgeRouter.java の NO_ACTIVE_WINDOW_ROOT 接頭辞が Sources/FTCore/AppDriver.swift の
// AndroidBridgeErrorPrefix.noActiveWindowRoot と一致するか(DriverError.isNoReadableWindow の
// 読み手はこの文字列でだけ判定する)。片方だけ変えると 500 の生 Java 例外へ静かに戻る。

import XCTest
import FTCore

final class AndroidNoReadableWindowSyncTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    private var routerSource: String {
        get throws {
            try String(contentsOf: repoRoot.appendingPathComponent(
                "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java"), encoding: .utf8)
        }
    }

    /// ワイヤの値そのものを固定する。**2つの定義元の一致だけでは足りない** ——
    /// 両方を同時に書き換えると、古いブリッジ(版ガードを通した他機・手元の既設)と
    /// 食い違ったまま緑になる
    func testThePrefixIsTheWireValue() {
        XCTAssertEqual(AndroidBridgeErrorPrefix.noActiveWindowRoot, "no-active-window-root:")
    }

    func testJavaConstantMatchesHostPrefix() throws {
        let source = try routerSource
        let expectedLiteral = "\"\(AndroidBridgeErrorPrefix.noActiveWindowRoot)\""
        XCTAssertTrue(source.contains("static final String NO_ACTIVE_WINDOW_ROOT = \(expectedLiteral);"),
                      "BridgeRouter.NO_ACTIVE_WINDOW_ROOT は "
                      + "AndroidBridgeErrorPrefix.noActiveWindowRoot (\(expectedLiteral)) と同じ文字列にすること")
    }

    /// handleSnapshot の再試行も root=null なら 422 + NO_ACTIVE_WINDOW_ROOT を投げる
    /// (生の IllegalStateException を BridgeRouter.handle の総括 catch へ落とさない)
    func testSnapshotRetryFailureIsWrappedAs422() throws {
        let source = try routerSource
        guard let start = source.range(of: "private BridgeHttpServer.Response handleSnapshot("),
              let end = source[start.upperBound...].range(of: "\n    private ") else {
            return XCTFail("handleSnapshot が見つからない(改名したら走査も直す)")
        }
        let body = source[start.upperBound..<end.lowerBound]
        XCTAssertEqual(body.components(separatedBy: "catch (IllegalStateException").count - 1, 2,
                       "初回・再試行の両方を catch すること(片方だけだと再試行の失敗が生の Java 例外のまま 500 になる)")
        XCTAssertTrue(body.contains("throw new BridgeException(422, NO_ACTIVE_WINDOW_ROOT"),
                      "再試行の失敗は 422 + NO_ACTIVE_WINDOW_ROOT で申告すること")
    }
}
