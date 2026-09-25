// G10(2026-09-25): リモートディスパッチの子が「供給フェーズ(ブリッジ起動・凍結triage・
// install)」の最中に SIGHUP/SIGTERM/SIGINT を受けると、InterruptRelay がまだ1つも登録
// されていなかった(runDirect/runWithProfile/runWithProfileParallel/runSequential/runParallel
// が自分で登録するのは供給が終わった後だった)。その間の signal は既定動作(即終了)のまま
// プロセスを落とし、run.json は RunRecorder.begin() が書いた start 欄だけの尻切れで残った
// (docs/results-json.md: finishedAt 無し = crash と誤分類される)。
//
// 直した形: `RunRecorder.begin()` の直後・供給フェーズより前に、ApiRunCommand.run()/
// Fleetest.run() が1回だけ InterruptRelay.observing を登録し、同じ RunInterruptState を
// runDirect/runWithProfile/runWithProfileParallel/runSequential/runParallel へ**パラメータで**
// 渡す(自分では作らない・自分では登録しない)。オーケストレータが立ってから合流する経路
// (runWithProfileParallel/ProfileRunner.run/runParallel)は `attachLateSubscriber` で繋ぐ ——
// 新しい InterruptRelay を立てない(CLAUDE.md「シグナルソースは1プロセスに1組」)。
//
// このテストはソース走査で「供給フェーズを含む関数の中で新しく RunInterruptState/
// InterruptRelay.observing を作る」形の再発を本数の等号で固定する。

import XCTest

final class InterruptRelayEarlyRegistrationWiringTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// `api run` の唯一の登録元は `ApiRunCommand.run()`(recorder 確定直後)。
    /// runDirect/runWithProfile/runWithProfileParallel が自分で作ると、そこに着くまでの
    /// 供給フェーズが無防備に戻る
    func testApiRunRegistersInterruptRelayExactlyOnce() throws {
        let text = try source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(count("RunInterruptState(recorder:", in: text), 1,
                       "RunInterruptState は run() の recorder 確定直後にだけ作る"
                       + "(runDirect/runWithProfile/runWithProfileParallel はパラメータで受け取る)")
        XCTAssertEqual(count("InterruptRelay.observing", in: text), 1,
                       "InterruptRelay の登録は1プロセス1組(CLAUDE.md)。"
                       + "供給を含む関数の中で2つ目を立てない")
    }

    /// `run`(プロファイル無し/あり共通)の唯一の登録元は `Fleetest.run()`(recorder 確定直後)。
    /// runSequential/runParallel が自分で作ると同じ穴が開く
    func testCliRunRegistersInterruptRelayExactlyOnce() throws {
        let text = try source("Sources/fleetest/Fleetest.swift")
        XCTAssertEqual(count("RunInterruptState(recorder:", in: text), 1,
                       "RunInterruptState は run() の recorder 確定直後にだけ作る"
                       + "(runSequential/runParallel はパラメータで受け取る)")
        XCTAssertEqual(count("InterruptRelay.observing", in: text), 1,
                       "InterruptRelay の登録は1プロセス1組(CLAUDE.md)。"
                       + "供給を含む関数の中で2つ目を立てない")
    }

    /// オーケストレータ構築後に合流する3経路(ApiRunCommand.runWithProfileParallel /
    /// ProfileRunner.run / Fleetest.runParallel)は、供給より前に立てた interruptState へ
    /// `attachLateSubscriber` で合流するだけで、新しい InterruptRelay を立てない
    func testOrchestratorPathsAttachRatherThanReregister() throws {
        // `.attachLateSubscriber`(先頭のドット込み)で数える —— ドット無しは解説コメント中にも
        // 出るので、実呼び出し(`interruptState.attachLateSubscriber { ... }`)だけを数える
        XCTAssertEqual(count(".attachLateSubscriber",
                             in: try source("Sources/fleetest/ApiRunCommand.swift")), 1)
        XCTAssertEqual(count(".attachLateSubscriber",
                             in: try source("Sources/fleetest/ProfileRunner.swift")), 1)
        XCTAssertEqual(count(".attachLateSubscriber",
                             in: try source("Sources/fleetest/Fleetest.swift")), 1)
    }
}
