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

    /// **ssh 越しのビルドで出る**。証明書も端末も揃っていてもここで止まるので、
    /// 拾えないと「原因の分からない失敗」に戻る(2026-08-29 に M1Ultra で実測)
    func testTheLockedKeychainIsPickedUp() {
        let log = "error: User interaction is not allowed. (in target 'FleetestRunnerApp')"
        XCTAssertEqual(XcodeSigningDiagnosis.problems(inBuildLog: log), [.keychainLocked])
        XCTAssertNotNil(XcodeSigningDiagnosis.guidance(problems: [.keychainLocked], fullLogPath: nil))
    }

    func testAnUnrelatedFailureIsLeftAlone() {
        // **当てはまらないログには触らない** —— 畳んで良いのは「何をすればいいか言える」ときだけ。
        // ここで生ログを捨てると、原因の分からない失敗になる
        let log = "error: Build input file cannot be found: '/…/Missing.swift'\n** TEST BUILD FAILED **"
        XCTAssertTrue(XcodeSigningDiagnosis.problems(inBuildLog: log).isEmpty)
        XCTAssertNil(XcodeSigningDiagnosis.guidance(problems: [], fullLogPath: "/tmp/x.log"))
    }

    /// 1行目だけで用が足りること(何が起きたか + どこを直すか)
    func testTheFirstLineStandsOnItsOwn() throws {
        let guidance = try XCTUnwrap(XcodeSigningDiagnosis.guidance(
            problems: XcodeSigningDiagnosis.problems(inBuildLog: try realFailureLog()),
            fullLogPath: "/tmp/bridge-build-8123.log"))
        let first = try XCTUnwrap(guidance.split(separator: "\n").first).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(first.contains("code-sign"), first)
        XCTAssertTrue(first.contains("physical device"), first)
        XCTAssertFalse(first.contains("\n"))
    }

    /// **案内は2行だけ**(ユーザー決定 2026-08-29): どこを直すか + 生ログの在り処。
    /// **直し方は書かない** —— Xcode も macOS も版ごとに手順が変わり、書いた手順は必ず古くなる
    /// (実際「Manage Certificates… が見つからない」で詰まった)。放っておくと案内は手順と説明で
    /// 膨らむので、**行数と中身の両方**を機械で止める
    func testTheGuidanceIsTwoLinesAndTellsNoSteps() throws {
        let guidance = try XCTUnwrap(XcodeSigningDiagnosis.guidance(
            problems: XcodeSigningProblem.allCases, fullLogPath: "/tmp/bridge-build-8123.log"))
        let lines = guidance.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, guidance)
        XCTAssertEqual(String(lines[1]), "Full xcodebuild output: /tmp/bridge-build-8123.log")
        // 手順・画面の道順・状態の言い換えのどれも出さない
        for forbidden in ["1.", "▸", "Manage Certificates", "Apple ID", "keychain", "Developer Mode",
                         "developmentTeam", "revoked or expired", "simulators need no signing"] {
            XCTAssertFalse(guidance.contains(forbidden), forbidden)
        }
    }

    /// 生ログを残せなかったときは在り処を書かない(見出しだけ)
    func testWithoutALogPathOnlyTheHeadlineIsShown() throws {
        let guidance = try XCTUnwrap(
            XcodeSigningDiagnosis.guidance(problems: [.deviceNotInProfile], fullLogPath: nil))
        XCTAssertFalse(guidance.contains("\n"), guidance)
        XCTAssertFalse(guidance.contains("Full xcodebuild output"))
    }

    /// **どの種別でも案内は同じ** —— 種別は「署名で止まった」と言い切るためだけに使う
    func testEveryProblemProducesTheSameGuidance() {
        let one = XcodeSigningDiagnosis.guidance(problems: [.noAccount], fullLogPath: nil)
        let another = XcodeSigningDiagnosis.guidance(problems: [.keychainLocked], fullLogPath: nil)
        XCTAssertEqual(one, another)
    }

    /// **機械可読の raw 値は拡張との契約**(NDJSON の signingProblems → 拡張の signingGuidance)。
    /// 改名すると拡張は「知らない種別」として飛ばし、案内が黙って英語に戻る
    func testRawValuesAreTheWireContractWithTheExtension() {
        XCTAssertEqual(XcodeSigningProblem.allCases.map(\.rawValue),
                       ["noAccount", "invalidCertificate", "deviceNotInProfile", "keychainLocked"])
    }
}
