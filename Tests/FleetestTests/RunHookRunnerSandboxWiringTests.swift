import XCTest

/// スクリプトの枠の配線をソース走査で固定する。枠が外れてもスクリプトは走るので、デバイス実行では緑のまま通る
/// (壁が消えたことに誰も気づかない)。
final class RunHookRunnerSandboxWiringTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// setup / teardown / 孤児の teardown の3経路が `runScript` を通り、そこだけが `ScriptSandbox.launch` を呼ぶ
    func testEveryScriptGoesThroughTheSandboxEntry() throws {
        let runner = try source("Sources/fleetest/RunHookRunner.swift")
        XCTAssertEqual(runner.components(separatedBy: "try runScript(").count - 1, 2,
                       "run(hook:) と reapOrphans の2箇所だけが runScript を呼ぶ")
        XCTAssertEqual(runner.components(separatedBy: "ScriptSandbox.launch(").count - 1, 1)
        // 包むかどうかはマシン側の設定だけで決まる
        XCTAssertTrue(runner.contains("try ScenarioSandbox.plan(settings: try ScenarioSandbox.machineSettings())"))
        // 親の環境を丸ごと継がせない(基本の鍵 → 秘密 → 契約 → 制御変数の順)
        XCTAssertTrue(runner.contains("ScriptSandbox.baseEnvironment(ProcessInfo.processInfo.environment)"))
        XCTAssertFalse(runner.contains("var env = ProcessInfo.processInfo.environment"))
        XCTAssertFalse(runner.contains("process.environment = env\n"), "親の環境を継いだ変数を渡している")
        XCTAssertTrue(runner.contains("process.environment = environment\n"))
        // 終了は終了通知で待ち、EOF は猶予つきで回収し、残った子孫を掃除する
        XCTAssertTrue(runner.contains("while waitExit(.now() + 0.2) == .timedOut"))
        XCTAssertTrue(runner.contains("readDone.wait(timeout: .now() + Shell.outputDrainGraceSeconds)"))
        XCTAssertTrue(runner.contains("sweepProcessGroup(pid, what:"))
        // 中断の中継(SIGINT / SIGTERM をスクリプトへ)
        XCTAssertTrue(runner.contains("interrupt?.registerChildProcess(process)"))
        // 一時領域(gateway のソケットの置き場)は run の後に消し、死んだ run のものは回収が掃く
        XCTAssertTrue(runner.contains("defer { try? FileManager.default.removeItem(atPath: temp) }"))
        XCTAssertTrue(runner.contains("for stale in ScriptSandbox.staleTemporaryDirectories()"))
    }

    /// run の2経路がサービスと中断を渡し、`hooks reap` はスクリプトの孤児をサービスの孤児より先に片付ける
    func testBothRunPathsPassTheServicesSessionAndTheReapOrderIsScriptsFirst() throws {
        for path in ["Sources/fleetest/ProfileRunner+Supply.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("services: servicesSession, interrupt: interruptState"), path)
        }
        let hooks = try source("Sources/fleetest/HooksCommand.swift")
        let scripts = try XCTUnwrap(hooks.range(of: "RunHookRunner.reapOrphans("))
        let services = try XCTUnwrap(hooks.range(of: "ServicesReaper.reap("))
        XCTAssertLessThan(scripts.lowerBound, services.lowerBound)
    }

    /// 秘密は compose.yaml が参照している名前だけ・制御変数は秘密で上書きされない(merge の順序)
    func testSecretsAreMergedBeforeTheContractAndControlVariables() throws {
        let runner = try source("Sources/fleetest/RunHookRunner.swift")
        let secrets = try XCTUnwrap(runner.range(of: "environment.merge(inputs.secrets) { $1 }"))
        let contract = try XCTUnwrap(runner.range(of: "environment.merge(contract) { $1 }"))
        let gateway = try XCTUnwrap(runner.range(of: "environment[ServiceGatewayWire.environmentKey] = server.socketPath"))
        let tmpdir = try XCTUnwrap(runner.range(of: "environment[\"TMPDIR\"] = temp"))
        XCTAssertLessThan(secrets.lowerBound, contract.lowerBound)
        XCTAssertLessThan(contract.lowerBound, gateway.lowerBound)
        XCTAssertLessThan(contract.lowerBound, tmpdir.lowerBound)
        let session = try source("Sources/fleetest/ServicesSession.swift")
        XCTAssertTrue(session.contains("usedSecretNames.compactMap { name in dictionaries.secrets[name]"))
    }
}
