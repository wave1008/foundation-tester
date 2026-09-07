// 欠陥③(2026-09-08): `Sources/fleetest/Fleetest.swift` は `runSummary.fmSettings!` で
// `RunOrchestrator.RunSummary.fmSettings`(Optional。ProfileRunner が「常に埋める」契約を型で
// 表せていなかった)を強制アンラップしていた。`ProfileRunner.run` の戻り値を
// `(summary: RunSummary, fmSettings: FMSettingsRecord)` に変え、`!` を使わずに済む形にした。
// ここでは 0 件早期リターン(デバイスに一切触れない経路)でも fmSettings が非 Optional のまま
// 実際の実効値を運ぶことを固定する。

import XCTest
import FTCore
@testable import fleetest

final class ProfileRunnerFMSettingsTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FleetestTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        for dir in [project.appsDir, project.machinesDir, project.runsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, to dir: URL, name: String) throws {
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
    }

    /// `items` に載っている唯一のシナリオが android 宣言で、machine のデバイスが ios だけなら
    /// `PlatformApplicability.partition` が全件を対象外へ落とし、`items.isEmpty` の
    /// 0件早期リターンに入る(デバイスにもアプリのインストールにも触れない経路)
    func testEarlyReturnWhenNoScenarioIsApplicableStillReturnsConcreteFMSettings() async throws {
        try write("""
        { "ios": { "app": "com.example.sampleapp" } }
        """, to: project.appsDir, name: "sampleapp")
        try write("""
        { "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro" } ] } }
        """, to: project.machinesDir, name: "M1")
        // "machine" を明示する(ambient な FT_MACHINE に左右されず決定的にするため。
        // determineMachine の優先順位: 実行プロファイルの明示 > FT_MACHINE > machines/ が1つ)
        try write("""
        { "app": "sampleapp", "machine": "M1", "devices": [ { "name": "メイン機" } ],
          "fm": false, "ocr": false }
        """, to: project.runsDir, name: "iosOnly")

        let androidOnly = ScenarioRunItem(info: ScenarioInfo(id: "A.S0010", title: "S0010", platform: "android"))
        let (summary, fmSettings) = try await ProfileRunner.run(
            project: project, profileName: "iosOnly", items: [androidOnly],
            reportDirOverride: nil)

        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.failed, 0)
        // fm:false/ocr:false が実際にプロファイルから読まれた値であることも確認する
        // (既定 true のまま素通りしていないか = ProfileResolver.resolve と同じ経路を通った証拠)
        XCTAssertFalse(fmSettings.fm)
        XCTAssertFalse(fmSettings.ocr)
    }
}
