// 実機のブリッジが署名で建たないときの案内(XcodeSigningDiagnosis)。
//
// witness は **実際に踏んだビルドログ**(Tests/Fixtures/BuildLogs/xcodebuild-signing-failure.txt。
// 2026-08-29 に M1Ultra の iPhone 13 で採取。メールアドレスだけ伏せてある)。作り物のログで
// 固めると、Xcode の実際の文言と食い違ったまま緑になる。

import XCTest

import FTBridgeClient

final class XcodeSigningDiagnosisTests: XCTestCase {

    private func realFailureLog() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BuildLogs/xcodebuild-signing-failure.txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFindsEveryProblemInTheRealFailure() throws {
        XCTAssertEqual(
            XcodeSigningDiagnosis.problems(inBuildLog: try realFailureLog()),
            [.noAccount, .invalidCertificate, .deviceNotInProfile],
            "同じ問題が2ターゲット分出るが、案内は1回ずつ")
    }

    func testAnUnrelatedFailureIsLeftAlone() {
        // **当てはまらないログには触らない** —— 畳んで良いのは「何をすればいいか言える」ときだけ。
        // ここで生ログを捨てると、原因の分からない失敗になる
        let log = "error: Build input file cannot be found: '/…/Missing.swift'\n** TEST BUILD FAILED **"
        XCTAssertTrue(XcodeSigningDiagnosis.problems(inBuildLog: log).isEmpty)
        XCTAssertNil(XcodeSigningDiagnosis.guidance(problems: [], fullLogPath: "/tmp/x.log"))
    }

    /// 1行目だけで用が足りること(拡張のバナーは1行しか出さず、続きは OUTPUT へ回る)
    func testTheFirstLineStandsOnItsOwn() throws {
        let guidance = try XCTUnwrap(XcodeSigningDiagnosis.guidance(
            problems: XcodeSigningDiagnosis.problems(inBuildLog: try realFailureLog()),
            fullLogPath: "/tmp/bridge-build-8123.log"))
        let first = try XCTUnwrap(guidance.split(separator: "\n").first).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(first.contains("code-sign"), first)
        XCTAssertTrue(first.contains("physical device"), first)
        // 「なぜシミュレータは動くのに」を1行目で答える(この誤解が実際に起きた)
        XCTAssertTrue(first.contains("simulators need no signing"), first)
        XCTAssertFalse(first.contains("\n"))
    }

    func testStepsAreNumberedInTheOrderYouFixThem() throws {
        let guidance = try XCTUnwrap(XcodeSigningDiagnosis.guidance(
            problems: XcodeSigningDiagnosis.problems(inBuildLog: try realFailureLog()),
            fullLogPath: "/tmp/bridge-build-8123.log"))
        // アカウントを足すのが先(証明書もプロファイルもそこから作り直される)
        let account = try XCTUnwrap(guidance.range(of: "1. Xcode ▸ Settings ▸ Accounts: add your Apple ID"))
        let certificate = try XCTUnwrap(guidance.range(of: "2. Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates"))
        let profile = try XCTUnwrap(guidance.range(of: "3. The device is not in the provisioning profile"))
        XCTAssertTrue(account.lowerBound < certificate.lowerBound)
        XCTAssertTrue(certificate.lowerBound < profile.lowerBound)
        XCTAssertTrue(guidance.contains("Developer Mode"), "端末側の設定も要る")
        XCTAssertTrue(guidance.contains("Full xcodebuild output: /tmp/bridge-build-8123.log"),
                      "生ログの在り処を必ず示す")
    }

    func testOnlyTheDetectedStepsAreShown() {
        let guidance = XcodeSigningDiagnosis.guidance(problems: [.deviceNotInProfile], fullLogPath: nil)
        let text = guidance ?? ""
        XCTAssertTrue(text.contains("1. The device is not in the provisioning profile"))
        XCTAssertFalse(text.contains("add your Apple ID"), "起きていないことは言わない")
        XCTAssertFalse(text.contains("Full xcodebuild output"), "残せなかったログの在り処は書かない")
    }
}
