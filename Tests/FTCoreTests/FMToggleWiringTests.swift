// FM の個別トグル(heal / textVisualCheck / screenLooksLike)が
// **プロファイル → 子ランナー → 実行時**の3段でつながっていることを固定する。
//
// **1段でも欠けると、その機能だけが黙って効いたまま/効かないままになる**(利用者から見ると
// 「プロファイルのチェックを外したのに FM が呼ばれる」)。トグルを足したら ScenarioHost の
// 引数配線も足す(忘れると、切っても子は何も知らないまま走る)。

import XCTest
@testable import FTCore

final class FMToggleWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// FMConfig の各トグルは、無効のとき**子ランナーへフラグとして伝わる**こと。
    /// `heal`(FMConfig の外・`settings.heal`)だけは逆向き(有効のとき `--heal` を足す)なので別に見る
    func testEveryFMToggleIsForwardedToTheChildRunner() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        for (property, flag) in [("fm.enabled", "--no-fm"),
                                 ("fm.textVisualCheck", "--no-text-visual-check"),
                                 ("fm.screenLooksLike", "--no-screen-looks-like")] {
            XCTAssertTrue(host.contains("if !\(property) { args.append(\"\(flag)\") }"),
                          "\(property) が子へ伝わっていない(切っても子は知らないまま走る)")
        }
        XCTAssertTrue(host.contains("if settings.heal { args.append(\"--heal\") }"),
                      "heal は有効のときに渡す向き")
    }

    /// 子ランナーは受け取ったフラグを実行時の設定へ渡すこと
    func testTheChildRunnerWiresTheFlagsIntoTheRuntime() throws {
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("textVisualCheckEnabled: !noTextVisualCheck"))
        XCTAssertTrue(runner.contains("screenLooksLikeEnabled: !noScreenLooksLike"))
    }

    /// **既定値はリテラルで固定する**(production の定数を参照すると、既定を変える変異が素通りする)。
    /// 同じ既定が JSON スキーマと拡張のフォームにもあるので、3箇所で一致させること
    func testProfileDefaultsArePinned() {
        let document = RunProfileDocument(app: "a", devices: [])
        XCTAssertNil(document.textVisualCheck, "未指定はあくまで nil(解決時に既定へ倒す)")
        XCTAssertNil(document.screenLooksLike)
    }
}
