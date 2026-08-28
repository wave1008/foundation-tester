// **MCP と DSL の全呼び出し元が OverlayWindowOcclusion を通ること**の配線ゲート
// (`KeyboardOcclusionWiringTests` と同型)。判定そのものは OverlayWindowOcclusionTests が
// 見るが、「呼び出し側が申告を渡さず `.none` を作って握り潰す」変異はコンパイラでは止まらない
// ので、各ファイルのソースを読んで **そのスナップショットの overlayWindowFrames から**
// 作られていることまで見る。

import XCTest

final class OverlayWindowOcclusionWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FleetestMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/" + relativePath),
                    encoding: .utf8)
    }

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 申告から OverlayWindowOcclusion を組み立てる側。**ft_tap(MCPServer+Snapshot)・
    /// ft_double_tap(MCPServer+Dispatch)・DSL の tap/doubleTap(StepExecutor+Actions)の
    /// 3ファイルが同じ被覆でなければならない** —— どれかが黙ると同じ画面で言うことが割れる
    func testAllResolveSitesBuildFromTheSnapshotsDeclaredFrames() throws {
        let sites = [
            "FTCore/StepExecutor+Actions.swift",
            "fleetest-mcp/MCPServer+Snapshot.swift",
            "fleetest-mcp/MCPServer+Dispatch.swift",
        ]
        for site in sites {
            let text = compact(try source(site))
            XCTAssertTrue(text.contains("OverlayWindowOcclusion.resolve(reported:"),
                          "\(site) が OverlayWindowOcclusion.resolve から作っていない")
            XCTAssertTrue(text.contains("overlayWindowFrames"),
                          "\(site) がスナップショットの overlayWindowFrames を読んでいない"
                          + "(常に .none を渡す抜け殻になっていないか)")
        }
    }

    /// RefGuard 側は受け取って転送するだけ。**既定引数を置かない**(呼び忘れを
    /// コンパイルで止める規律。置くと新しい呼び出し元が黙って警告を失う)
    func testRefGuardTakesTheOcclusionWithoutADefault() throws {
        let text = compact(try source("fleetest-mcp/RefGuard.swift"))
        XCTAssertTrue(text.contains(compact("overlayWindowWarning(_ element: ElementInfo, overlayWindows: OverlayWindowOcclusion)")),
                      "RefGuard.overlayWindowWarning のシグネチャが違う")
        XCTAssertTrue(text.contains(compact("overlayWindows: OverlayWindowOcclusion)")),
                      "RefGuard.preTapWarnings が OverlayWindowOcclusion を受けていない")
        XCTAssertFalse(text.contains(compact("overlayWindows: OverlayWindowOcclusion = .none")),
                       "既定引数が置かれている(呼び忘れがコンパイルで止まらなくなる)")
    }

    /// **BridgeClient が写像を FTCore へ委ねていること**。`hittable` 欠落を素で
    /// `.unavailable` へ畳む実装に戻すと、木が画面を代表していないことを知る唯一の答えが
    /// 捨てられる —— その退化は FakeDriver 経由の MCP テストでは落ちない(2026-08-28 の
    /// 変異チェックで実際に生き残った)ので、配線をここで縛る
    func testBridgeClientMapsTheHitTestAnswerThroughFTCore() throws {
        let text = compact(try source("FTBridgeClient/BridgeClient.swift"))
        XCTAssertTrue(text.contains("HitTestAnswer.fromBridge(hittable:answer.hittable)"),
                      "BridgeClient が HitTestAnswer.fromBridge を通していない")
    }

    /// **ブリッジ側の申告が消えていないこと**。ホストだけ直しても、Android の
    /// SnapshotBuilder が overlayWindowFrames を出さなければ判定材料は永久に来ない
    /// (この配線は Java と Swift をまたぐのでコンパイラは何も言わない)
    func testAndroidBridgeStillDeclaresOverlayWindowFrames() throws {
        let bridge = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java"),
            encoding: .utf8)
        XCTAssertTrue(bridge.contains("\"overlayWindowFrames\""),
                      "SnapshotBuilder が overlayWindowFrames を申告していない")
        XCTAssertTrue(bridge.contains("TYPE_APPLICATION"),
                      "オーバーレイの種別判定(TYPE_APPLICATION)が消えている")
        // **アクティブより手前だけ**を数える条件。落とすと奥のウィンドウまで拾う
        XCTAssertTrue(compact(bridge).contains(compact("window.getLayer() <= activeLayer")),
                      "手前かどうかを layer で見る条件が消えている")
        // **IME は keyboardFrame の担当**。ここへ混ぜると同じ事実を2回言う
        XCTAssertTrue(bridge.contains("TYPE_INPUT_METHOD"),
                      "IME を overlayWindowFrames から外す分岐が消えている")
    }
}
