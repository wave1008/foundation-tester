// `sandbox` の配線をソース走査で固定する。包む経路は既定(false)の run では1度も通らないので、
// 「設定を読まなくなった」「包んだ結果を process に戻さなくなった」はどのデバイス実行でも緑のまま通る。

import XCTest
@testable import FTCore

final class ScenarioSandboxWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// シナリオ実行バイナリを起こす3経路(run・一覧取得・OCR の暖機)が全部 `sandboxedLaunch` を通り、
    /// 返ってきた起動の形を実際に使っていること。**バイナリは起こし方に関わらず利用者のコードを実行しうる**
    /// ので、1経路でも素で起こすとそこが抜け道になる
    func testEveryLaunchOfTheScenarioRunnerGoesThroughTheSandboxEntry() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertEqual(host.components(separatedBy: "try sandboxedLaunch(").count - 1, 3)
        // ランナーの場所を引く箇所 = 起こす経路の数(増えたら、その経路も入口を通すこと)
        XCTAssertEqual(host.components(separatedBy: "runnerURL(project: project)").count - 1, 4,
                       "runnerURL の呼び出しが増減した(build の存在確認1 + 起こす3経路)")

        let run = try XCTUnwrap(host.range(of: "request: settings.sandbox,"))
        let launch = try XCTUnwrap(host.range(of: "try process.run()", range: run.upperBound..<host.endIndex))
        let block = String(host[run.upperBound..<launch.lowerBound])
        XCTAssertTrue(block.contains("process.executableURL = launch.executable"))
        XCTAssertTrue(block.contains("process.arguments = launch.arguments"))
        XCTAssertTrue(block.contains("merging(launch.environment)"))
        XCTAssertTrue(block.contains("drivesDevice: !dryRun") || host.contains("drivesDevice: !dryRun"))
        // 枠を組めないときは枠なしで起こさない
        XCTAssertTrue(block.contains("return abortBeforeLaunch("))

        XCTAssertTrue(host.contains("+ [launch.executable.path] + launch.arguments"), "list が枠の形で起こしていない")
        XCTAssertTrue(host.contains("process.executableURL = launch?.executable ?? runner"), "warm-ocr が枠の形で起こしていない")

        let entry = try source("Sources/FTCore/ScenarioHost+Sandbox.swift")
        XCTAssertTrue(entry.contains("guard let plan = try ScenarioSandbox.plan(request, project: project) else { return nil }"))
        XCTAssertTrue(entry.contains("ScenarioSandbox.wrap("))
    }

    /// `list` の `sandbox:` に既定値が無いこと(あると、新しい呼び手が包み忘れてもコンパイルが通る)
    func testListTakesTheSandboxRequestWithoutADefault() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("static func list(project: TestProject, sandbox: ScenarioSandbox.Request) throws"))
        XCTAssertTrue(host.contains("sandbox: ScenarioSandbox.Request) async throws -> [ScenarioEvent]"))
        XCTAssertFalse(host.contains("sandbox: ScenarioSandbox.Request = "))
    }

    /// 枠を掛ける入口は `ScenarioSandbox` の1箇所だけ(別の場所が自前で `sandbox-exec` を組むと、
    /// 書ける場所の規則が2つに割れる)
    func testSandboxExecIsNamedOnlyInScenarioSandbox() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            guard url.lastPathComponent != "ScenarioSandbox.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            // コメントは対象外(説明として名前を出すのは構わない)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains("\"/usr/bin/sandbox-exec\"") || $0.contains("\"sandbox-exec\"") }) {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan did not reach Sources")
        XCTAssertEqual(offenders, [])
    }
}
