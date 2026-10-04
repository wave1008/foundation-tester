// CLI(Sources/fleetest)から任意の bundle ID で launch / activate を撃つ経路は、
// 撃つ前に `InstalledAppCheck.launchGuard` の門を通すこと。未インストールのまま
// `XCUIApplication.launch()` を撃つと XCUITest ランナーが約60秒ハングして自壊する ——
// MCP(ft_launch)とライブ操作には門があったのに `fleetest launch` だけ素通しで、
// 実地でランナーを落とした。シナリオ実行の経路は
// `LaunchPreflightDriver` が守るのでここでは見ない。
//
// 走査はソース全文(門を通す関数と撃つ行が別関数でも、同じファイルに門があれば通す)。

import XCTest

final class LaunchInstallGateScanTests: XCTestCase {

    private static var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FleetestTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
            .appendingPathComponent("Sources/fleetest")
    }

    /// 門が要らない呼び出し(理由つき)。キーは「ファイル名: 呼び出し行(前後空白を除く)」
    private static let exempt: [String: String] = [
        "ApiLiveCommand.swift: try await driver.launch(bundleID: LiveSessionTarget.springboard)":
            "springboard は常に在る(launchGuard も素通しにする)",
        "LiveSessionFollower.swift: try await driver.launch(bundleID: target)":
            "今まさに前面にあるアプリへ向け直すだけ(入っていることが観測で確定している)",
        "LiveSessionFollower.swift: try await driver.activate(bundleID: bundleID)":
            "pointAtApp。呼び手が門を通す(clearAppData = testLiveClearAppDataChecksBeforePointing・"
            + "terminate = 駆動中のアプリなので入っている)",
    ]

    func testEveryLaunchOrActivateFromTheCLIGoesThroughTheInstallGate() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.sourcesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "走査が Sources/fleetest に届いていない")
        var offenders: [String] = []
        var seenExempt: Set<String> = []
        var sawLaunchCLI = false
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hasGate = text.contains("InstalledAppCheck.launchGuard(")
            for line in text.components(separatedBy: "\n") {
                let code = line.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
                guard code.contains(".launch(bundleID:") || code.contains(".activate(bundleID:") else { continue }
                let key = "\(file.lastPathComponent): \(code)"
                if file.lastPathComponent == "ManualDriveCommands.swift" { sawLaunchCLI = true }
                if Self.exempt[key] != nil { seenExempt.insert(key); continue }
                if !hasGate { offenders.append(key) }
            }
        }
        XCTAssertTrue(sawLaunchCLI, "`fleetest launch` の呼び出しが見つからない(走査の前提が崩れた)")
        XCTAssertEqual(offenders, [],
                       "門(InstalledAppCheck.launchGuard)を通さずに launch / activate を撃つ CLI 経路がある")
        XCTAssertEqual(seenExempt, Set(Self.exempt.keys),
                       "免除が当たらなくなった(直したなら免除から外す)")
    }

    /// `fleetest launch` は門を **driver.launch より前に** 撃つこと
    func testLaunchCommandChecksBeforeLaunching() throws {
        let text = try String(contentsOf: Self.sourcesDir.appendingPathComponent("ManualDriveCommands.swift"),
                              encoding: .utf8)
        let gate = try XCTUnwrap(text.range(of: "try await Self.refuseIfNotInstalled(bundleID: bundleID"))
        let launch = try XCTUnwrap(text.range(of: "try await driver.launch(bundleID: bundleID)"))
        XCTAssertLessThan(gate.lowerBound, launch.lowerBound)
    }

    /// ライブ操作の clearAppData は名指しの bundle へセッションを寄せる(= activate)ので、
    /// **寄せる前に** launch と同じ門を通すこと(未インストールの bundle でランナーが落ちた)
    func testLiveClearAppDataChecksBeforePointing() throws {
        let text = try String(contentsOf: Self.sourcesDir.appendingPathComponent("ApiLiveCommand.swift"),
                              encoding: .utf8)
        let caseStart = try XCTUnwrap(text.range(of: "case \"clearAppData\":"))
        let caseEnd = try XCTUnwrap(text.range(of: "case \"install\":", range: caseStart.upperBound..<text.endIndex))
        let body = text[caseStart.upperBound..<caseEnd.lowerBound]
        let gate = try XCTUnwrap(body.range(of: "try await launchGuard(bundle: bundle"),
                                 "clearAppData が門を通していない")
        let point = try XCTUnwrap(body.range(of: "pointAtApp(bundle"))
        XCTAssertLessThan(gate.lowerBound, point.lowerBound, "門は pointAtApp(activate)より前に撃つこと")
    }
}
