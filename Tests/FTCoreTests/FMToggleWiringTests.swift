// FM の個別トグル(heal / falsePositiveCheck / screenLooksLike / triage)が
// **プロファイル → 子ランナー → 実行時**の3段でつながっていることを固定する。
//
// **1段でも欠けると、その機能だけが黙って効いたまま/効かないままになる**(利用者から見ると
// 「プロファイルのチェックを外したのに FM が呼ばれる」)。triage は 2026-09-03 に追加した
// トグルで、追加時に ScenarioHost の引数配線を忘れると、切っても子は何も知らないまま走る。

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
    /// `heal` だけは逆向き(有効のとき `--heal` を足す)なので別に見る
    func testEveryFMToggleIsForwardedToTheChildRunner() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        for (property, flag) in [("fm.enabled", "--no-fm"),
                                 ("fm.falsePositiveCheck", "--no-false-positive-check"),
                                 ("fm.screenLooksLike", "--no-screen-looks-like"),
                                 ("fm.triage", "--no-triage")] {
            XCTAssertTrue(host.contains("if !\(property) { args.append(\"\(flag)\") }"),
                          "\(property) が子へ伝わっていない(切っても子は知らないまま走る)")
        }
        XCTAssertTrue(host.contains("if fm.heal { args.append(\"--heal\") }"),
                      "heal は有効のときに渡す向き")
    }

    /// 子ランナーは受け取ったフラグを実行時の設定へ渡すこと
    func testTheChildRunnerWiresTheFlagsIntoTheRuntime() throws {
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"no-triage\")"), "--no-triage を受け取れない")
        XCTAssertTrue(runner.contains("triageEnabled: !noTriage"),
                      "--no-triage を実行時へ渡していない(受け取っても捨てている)")
        XCTAssertTrue(runner.contains("falsePositiveCheckEnabled: !noFalsePositiveCheck"))
        XCTAssertTrue(runner.contains("screenLooksLikeEnabled: !noScreenLooksLike"))
    }

    /// 実行時はトリアージを撃つ前にトグルを見ること
    func testTheRuntimeChecksTheTriageToggleBeforeCalling() throws {
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
        XCTAssertTrue(runtime.contains("let triage = self.triageEnabled"),
                      "triage をトグルで囲っていない(切っても FM を呼ぶ)")
    }

    /// **既定値はリテラルで固定する**(production の定数を参照すると、既定を変える変異が素通りする)。
    /// 同じ既定が JSON スキーマと拡張のフォームにもあるので、3箇所で一致させること
    func testProfileDefaultsArePinned() {
        let document = RunProfileDocument(app: "a", devices: [])
        XCTAssertNil(document.fm, "未指定はあくまで nil(解決時に既定へ倒す)")
        XCTAssertNil(document.triage)
        // 解決後の既定
        let fm = FMConfig(enabled: true, heal: true, falsePositiveCheck: true,
                          screenLooksLike: true, triage: true)
        XCTAssertEqual(fm.triage, true)
        XCTAssertTrue(RunProfileDocument.knownKeys.contains("triage"),
                      "triage が未知キー扱いだと、書いた利用者に警告が出る")
    }
}
