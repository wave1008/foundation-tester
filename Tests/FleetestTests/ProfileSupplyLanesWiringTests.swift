import XCTest

/// デバイス供給の手順は `ProfileSupplyLanes` の1箇所だけに置く。`fleetest run`(ProfileRunner)と
/// `fleetest api run` が別々に持っていた間に、api run の並列経路だけ WebView の更新・実機の画面の観測・
/// Android のホームへ戻す処理が抜けていた(呼び出しの有無だけを見る配線テストは、同じファイルの別経路にある
/// 1本で緑になって見逃した)。呼び手が手順を直に呼んでいないこと・共有の関数を通っていることを固定する
final class ProfileSupplyLanesWiringTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func code(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// 供給の手順(レーンの中身)。どれも呼び手に書かず、レーンの中にある
    private static let steps = [
        "AndroidDataWiper.wipeBloatedAVDs(", "AndroidGpuRecovery.recoverCpuFallbackDevices(",
        "AndroidLaneRecovery.bootMissingDevices(", "preparePhysicalAndroidDevices(",
        "buildAndroidWorkers(", "buildIOSWorkers(", "AndroidWebViewUpdate.run(",
        "excludeOrRepairBlankScreenWorkers(", "excludeBlankScreenWorkers(", "observePhysicalScreens(",
        "installIfNeeded(", "recoverStaleRecordingIOSWorkers(", "prepareDevicesOnStart(",
    ]

    func testTheLanesHoldEveryStep() throws {
        let lanes = try code("Sources/fleetest/ProfileSupplyLanes.swift")
        for step in Self.steps {
            XCTAssertGreaterThan(count(step, in: lanes), 0, "レーンに手順が無い: \(step)")
        }
    }

    /// 呼び手は手順を直に呼ばない。**例外は api run の `--port` 直指定の経路(runDirect)の
    /// prepareDevicesOnStart 1本だけ**(プロファイルが無いのでレーンを通らない)
    func testCallersDoNotCallTheStepsDirectly() throws {
        let runner = try code("Sources/fleetest/ProfileRunner.swift") + code("Sources/fleetest/ProfileRunner+Supply.swift")
        let api = try code("Sources/fleetest/ApiRunCommand.swift")
        for step in Self.steps {
            XCTAssertEqual(count(step, in: runner), 0, "ProfileRunner(+Supply).swift が供給の手順を直に呼んでいる: \(step)")
            XCTAssertEqual(count(step, in: api), step == "prepareDevicesOnStart(" ? 1 : 0,
                           "ApiRunCommand.swift が供給の手順を直に呼んでいる: \(step)")
        }
    }

    /// run は準備の段(ProfileRunner+Supply.swift)で Android・iOS のレーンを各1本のタスクで起こす(iOS の eager と
    /// 遅延参加はどちらもそのタスクを待つ)。api run は並列経路と --debug の逐次経路で各2本
    func testBothEntryPointsGoThroughTheLanes() throws {
        let runner = try code("Sources/fleetest/ProfileRunner+Supply.swift")
        XCTAssertEqual(count("ProfileSupplyLanes.android(", in: runner), 1)
        XCTAssertEqual(count("ProfileSupplyLanes.ios(", in: runner), 1)
        XCTAssertEqual(count("ProfileSupplyLanes.", in: try code("Sources/fleetest/ProfileRunner.swift")), 0,
                       "実行の段が供給のレーンを自分で起こしている(準備の段のタスクを待つ)")
        let api = try code("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(count("ProfileSupplyLanes.android(", in: api), 2)
        XCTAssertEqual(count("ProfileSupplyLanes.ios(", in: api), 2)
    }
}
