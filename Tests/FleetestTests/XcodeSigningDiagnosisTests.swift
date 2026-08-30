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
        XCTAssertNotNil(XcodeSigningDiagnosis.guidance(problems: [.keychainLocked], fullLogPath: nil, overSSH: true))
    }

    func testAnUnrelatedFailureIsLeftAlone() {
        // **当てはまらないログには触らない** —— 畳んで良いのは「何をすればいいか言える」ときだけ。
        // ここで生ログを捨てると、原因の分からない失敗になる
        let log = "error: Build input file cannot be found: '/…/Missing.swift'\n** TEST BUILD FAILED **"
        XCTAssertTrue(XcodeSigningDiagnosis.problems(inBuildLog: log).isEmpty)
        XCTAssertNil(XcodeSigningDiagnosis.guidance(problems: [], fullLogPath: "/tmp/x.log", overSSH: true))
    }

    /// チーム切替時に実際に出る3種も拾う。行は M1Ultra の bridge-build-8127/8129.log から
    /// 逐語で採ったもの(作り物のログで固めない、の file header の規律)
    func testFindsTheProblemsFromTheTeamSwitchIncident() {
        let log = """
        error: No Account for Team "GF42S2868Q". Add a new account in Accounts settings \
        or verify that your accounts have valid credentials. (in target 'FleetestRunnerApp')
        error: Device "iPhone snb" isn't registered in your developer account. \
        (in target 'FleetestRunnerUITests')
        error: Provisioning profile "iOS Team Provisioning Profile: com.example.ftrunner" \
        doesn't include signing certificate "Apple Development: …". (in target 'FleetestRunnerApp')
        """
        XCTAssertEqual(
            XcodeSigningDiagnosis.problems(inBuildLog: log),
            [.noAccountForTeam, .deviceNotRegistered, .certificateNotInProfile])
    }

    /// 1行目だけで用が足りること(何が起きたか + どこを直すか)
    func testTheFirstLineStandsOnItsOwn() throws {
        let guidance = try XCTUnwrap(XcodeSigningDiagnosis.guidance(
            problems: XcodeSigningDiagnosis.problems(inBuildLog: try realFailureLog()),
            fullLogPath: "/tmp/bridge-build-8123.log", overSSH: true))
        let first = try XCTUnwrap(guidance.split(separator: "\n").first).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(first.contains("code-sign"), first)
        XCTAssertTrue(first.contains("physical device"), first)
        XCTAssertFalse(first.contains("\n"))
    }

    /// **事実は言い、手順は書かない**。案内は最大4行:
    /// 見出し / Detected(事実の列挙)/ ポータル通信の制約(要るときだけ)/ ログの在り処。
    /// **Xcode の画面の道順は引き続き出さない**(版ごとに変わり、必ず古くなる)
    func testTheGuidanceStatesFactsButTellsNoSteps() throws {
        let guidance = try XCTUnwrap(XcodeSigningDiagnosis.guidance(
            problems: XcodeSigningProblem.allCases, fullLogPath: "/tmp/bridge-build-8123.log", overSSH: true))
        let lines = guidance.split(separator: "\n")
        XCTAssertEqual(lines.count, 4, guidance)
        XCTAssertTrue(String(lines[1]).hasPrefix("Detected: "), guidance)
        XCTAssertEqual(String(lines[3]), "Full xcodebuild output: /tmp/bridge-build-8123.log")
        // 手順・画面の道順は出さない(事実の名詞 — 証明書・チーム・プロファイル — は出してよい)
        for forbidden in ["1.", "▸", "Manage Certificates", "Accounts settings", "Settings →",
                          "Developer Mode", "simulators need no signing"] {
            XCTAssertFalse(guidance.contains(forbidden), forbidden)
        }
    }

    /// ポータル通信が要らない問題だけなら「GUI セッションで」の行は出さない
    /// (毎回書くとアカウント忘れのような手元で直る話まで GUI へ誘導してしまう)
    func testThePortalLineAppearsOnlyWhenProvisioningIsNeeded() throws {
        let without = try XCTUnwrap(
            XcodeSigningDiagnosis.guidance(problems: [.noAccountForTeam], fullLogPath: nil, overSSH: true))
        XCTAssertFalse(without.contains("GUI session"), without)
        let with = try XCTUnwrap(
            XcodeSigningDiagnosis.guidance(problems: [.deviceNotRegistered], fullLogPath: nil, overSSH: true))
        XCTAssertTrue(with.contains("GUI session"), with)
    }

    /// GUI セッションで走っているなら「GUI で」とは言わない(行き止まりの案内になる)。
    /// 代わりに登録直後の1回目が落ちる事実だけ
    func testInAGUISessionThePortalLineOnlySaysToRunItAgain() throws {
        let gui = try XCTUnwrap(
            XcodeSigningDiagnosis.guidance(problems: [.deviceNotRegistered], fullLogPath: nil, overSSH: false))
        XCTAssertFalse(gui.contains("GUI session"), gui)
        XCTAssertFalse(gui.contains("ssh"), gui)
        XCTAssertTrue(gui.contains("run it again"), gui)
    }

    /// ssh 判定は sshd が立てる環境変数だけを見る
    func testSSHSessionIsDetectedFromTheEnvironment() {
        XCTAssertTrue(XcodeSigningDiagnosis.isSSHSession(environment: ["SSH_CONNECTION": "10.0.0.2 1 10.0.0.1 22"]))
        XCTAssertTrue(XcodeSigningDiagnosis.isSSHSession(environment: ["SSH_TTY": "/dev/ttys001"]))
        XCTAssertFalse(XcodeSigningDiagnosis.isSSHSession(environment: ["TERM_PROGRAM": "Apple_Terminal"]))
    }

    /// 生ログを残せなかったときは在り処を書かない
    func testWithoutALogPathThePathLineIsOmitted() throws {
        let guidance = try XCTUnwrap(
            XcodeSigningDiagnosis.guidance(problems: [.noAccount], fullLogPath: nil, overSSH: true))
        XCTAssertFalse(guidance.contains("Full xcodebuild output"))
    }

    /// **事実の行は種別ごとに違う**(どれかすら言わないと切り分けのたびに生ログを読むことになる)
    func testDifferentProblemsProduceDifferentFacts() {
        let one = XcodeSigningDiagnosis.guidance(problems: [.noAccount], fullLogPath: nil, overSSH: true)
        let another = XcodeSigningDiagnosis.guidance(problems: [.keychainLocked], fullLogPath: nil, overSSH: true)
        XCTAssertNotEqual(one, another)
    }

    /// **機械可読の raw 値は拡張との契約**(NDJSON の signingProblems → 拡張の signingGuidance)。
    /// 改名すると拡張は「知らない種別」として飛ばし、その種別の事実行が黙って消える
    func testRawValuesAreTheWireContractWithTheExtension() {
        XCTAssertEqual(XcodeSigningProblem.allCases.map(\.rawValue),
                       ["noAccount", "noAccountForTeam", "invalidCertificate", "deviceNotRegistered",
                        "certificateNotInProfile", "deviceNotInProfile", "keychainLocked"])
    }
}
