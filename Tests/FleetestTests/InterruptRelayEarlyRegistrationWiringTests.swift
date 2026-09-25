// maintainer-notes §51.4: リモートディスパッチの子が「供給フェーズ(ブリッジ起動・凍結triage・
// install)」の最中に SIGHUP/SIGTERM/SIGINT を受けると、InterruptRelay がまだ1つも登録
// されていなかった(runDirect/runWithProfile/runWithProfileParallel/runSequential/runParallel
// が自分で登録するのは供給が終わった後だった)。その直しは「recorder 確定直後」に登録したが、
// `api run` はそこに至るまでに setup.sh(`RunHookRunner.begin`)・供給タスクの起動
// (`androidWorkersTask`)・ビルド(`ScenarioHost.build`)がまだ残っており、同じ穴が
// (`fleetest run` はロック取得〜ビルドの間だけ)再発していた。
//
// 直した形: `LocalDispatchLock(...).acquire()` の**直前**(recorder がまだ無い段階)に
// `ApiRunCommand.run()`/`Fleetest.run()` が1回だけ `InterruptRelay.observing` を登録し、
// 同じ `RunInterruptState` を runDirect/runWithProfile/runWithProfileParallel/runSequential/
// runParallel へ**パラメータで**渡す(自分では作らない・自分では登録しない)。recorder は
// ビルド後にしか作れないので、後から `attachRecorder` で繋ぐ。オーケストレータが立ってから
// 合流する経路(runWithProfileParallel/ProfileRunner.run/runParallel)は `attachLateSubscriber`
// で繋ぐ ——新しい InterruptRelay を立てない(CLAUDE.md「シグナルソースは1プロセスに1組」)。
// `LocalDispatchLock.acquire` は待機中の中断もこの同じ interruptState を見る
// (`interruptCheck:` 引数。自前で2つ目の relay を立てない)。
//
// このテストはソース走査で「供給フェーズを含む関数の中で新しく RunInterruptState/
// InterruptRelay.observing を作る」形の再発を本数の等号で固定し、加えて登録の**位置**
// (ロック取得・setup.sh・供給タスクの起動・ビルドより前)を文字列の出現位置の大小で固定する
// (順序を元に戻す変異 = 登録をこれらの後へ動かす変異で必ず落ちる)。

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

    /// `api run` の唯一の登録元は `ApiRunCommand.run()`(ロック取得の直前)。
    /// runDirect/runWithProfile/runWithProfileParallel が自分で作ると、そこに着くまでの
    /// setup.sh・供給フェーズ・ビルドが無防備に戻る
    func testApiRunRegistersInterruptRelayExactlyOnce() throws {
        let text = try source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(count("RunInterruptState(recorder:", in: text), 1,
                       "RunInterruptState は run() の中で1回だけ作る"
                       + "(runDirect/runWithProfile/runWithProfileParallel はパラメータで受け取る)")
        XCTAssertEqual(count("InterruptRelay.observing", in: text), 1,
                       "InterruptRelay の登録は1プロセス1組(CLAUDE.md)。"
                       + "setup/供給/ビルドを含む関数の中で2つ目を立てない")
    }

    /// `run`(プロファイル無し/あり共通)の唯一の登録元は `Fleetest.run()`(ロック取得の直前)。
    /// runSequential/runParallel が自分で作ると同じ穴が開く
    func testCliRunRegistersInterruptRelayExactlyOnce() throws {
        let text = try source("Sources/fleetest/Fleetest.swift")
        XCTAssertEqual(count("RunInterruptState(recorder:", in: text), 1,
                       "RunInterruptState は run() の中で1回だけ作る"
                       + "(runSequential/runParallel はパラメータで受け取る)")
        XCTAssertEqual(count("InterruptRelay.observing", in: text), 1,
                       "InterruptRelay の登録は1プロセス1組(CLAUDE.md)。"
                       + "ビルドを含む関数の中で2つ目を立てない")
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

    /// recorder はビルド後にしか作れない(`RunRecorder.begin` は listForRun/selection の後)ので、
    /// 早く登録した interruptState には後から繋ぐしかない。`attachRecorder` を経由すること自体を
    /// 固定する(recorder を渡さずに markInterrupted が一生呼ばれない形の再発を防ぐ)
    func testBothEntryPointsAttachTheRecorderAfterItExists() throws {
        for path in ["Sources/fleetest/ApiRunCommand.swift", "Sources/fleetest/Fleetest.swift"] {
            let text = try source(path)
            XCTAssertEqual(count(".attachRecorder(recorder)", in: text), 1,
                           "\(path): recorder の後付けが無い(RunInterruptState(recorder: nil) の"
                           + " ままでは中断で始まらなかった記録に interrupted が付かない)")
        }
    }

    /// **`api run` の登録位置**: `RunInterruptState`/`InterruptRelay.observing` は
    /// `LocalDispatchLock(...).acquire()` より前、かつ setup.sh(`RunHookRunner.begin`)・
    /// 供給タスクの起動(`androidWorkersTask`)・ビルド(`ScenarioHost.build`)より前。
    /// 登録をこれらの後ろへ戻す変異はこの大小関係のどれかを崩すので必ず落ちる
    func testApiRunRegistersBeforeLockSetupSupplyAndBuild() throws {
        let text = try source("Sources/fleetest/ApiRunCommand.swift")
        let registration = try XCTUnwrap(text.range(of: "RunInterruptState(recorder:"))
        let lock = try XCTUnwrap(text.range(of: "LocalDispatchLock("))
        let setup = try XCTUnwrap(text.range(of: "RunHookRunner.begin("))
        let supply = try XCTUnwrap(text.range(of: "androidWorkersTask = Task"))
        let build = try XCTUnwrap(text.range(of: "try ScenarioHost.build(project: testProject)"))
        XCTAssertLessThan(registration.lowerBound, lock.lowerBound,
                          "登録が dispatch.lock の取得より後(acquire の待機中の中断を拾えない)")
        XCTAssertLessThan(lock.lowerBound, setup.lowerBound,
                          "dispatch.lock の取得が setup.sh より後")
        XCTAssertLessThan(setup.lowerBound, supply.lowerBound,
                          "setup.sh が供給タスクの起動より後")
        XCTAssertLessThan(supply.lowerBound, build.lowerBound,
                          "供給タスクの起動がビルドより後")
    }

    /// **`run` の登録位置**: `fleetest run` は setup.sh/供給が `ProfileRunner.run` 等の内側
    /// (登録より後で問題ない)なので、ここで確かめるのは登録がロック取得・ビルドより前であること
    func testCliRunRegistersBeforeLockAndBuild() throws {
        let text = try source("Sources/fleetest/Fleetest.swift")
        let registration = try XCTUnwrap(text.range(of: "RunInterruptState(recorder:"))
        let lock = try XCTUnwrap(text.range(of: "LocalDispatchLock("))
        let build = try XCTUnwrap(text.range(of: "try ScenarioHost.build(project: testProject)"))
        XCTAssertLessThan(registration.lowerBound, lock.lowerBound,
                          "登録が dispatch.lock の取得より後(acquire の待機中の中断を拾えない)")
        XCTAssertLessThan(lock.lowerBound, build.lowerBound,
                          "dispatch.lock の取得がビルドより後")
    }

    /// `LocalDispatchLock.acquire` は呼び出し側が既に登録した interruptState を渡し、
    /// 自前で2つ目の `InterruptRelay.observing` を立てない(`interruptCheck:` 引数)
    func testAcquireReceivesTheCallersInterruptStateRatherThanRegisteringItsOwn() throws {
        for path in ["Sources/fleetest/ApiRunCommand.swift", "Sources/fleetest/Fleetest.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains(".acquire(interruptCheck: { interruptState.isStopped })"),
                          "\(path): acquire() へ interruptCheck を渡していない"
                          + "(渡さないと待機中だけ別の relay が立ち、1プロセス1組が崩れる)")
        }
    }
}
