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

    /// **keychainLocked とは別の case で拾われる**(解錠済みだが ACL が非対話セッションを
    /// 拒む状態。2026-09-08 に ssh 越しの codesign を直接叩いて実測した文言)
    func testTheDeniedKeySigningAccessIsPickedUp() {
        let log = """
        Signing Identity:     "Apple Development: Nobuhiro Senba (73YMA2YH5T)"
        Provisioning Profile: "iOS Team Provisioning Profile: *"
        /usr/bin/codesign --force --sign 7BC760... FleetestRunnerApp.debug.dylib: errSecInternalComponent
        Command CodeSign failed with a nonzero exit code
        ** TEST BUILD FAILED **
        """
        XCTAssertEqual(XcodeSigningDiagnosis.problems(inBuildLog: log), [.keySigningAccessDenied])
        XCTAssertNotNil(XcodeSigningDiagnosis.guidance(
            problems: [.keySigningAccessDenied], fullLogPath: nil, overSSH: true))
    }

    /// **keychainLocked と keySigningAccessDenied を取り違えない** —— 片方だけのログでは
    /// もう片方が出ず、両方揃ったログでは両方出る(順序は宣言順)
    func testKeychainLockedAndKeySigningAccessDeniedAreNotConfused() {
        let onlyLocked = "error: User interaction is not allowed. (in target 'FleetestRunnerApp')"
        XCTAssertEqual(XcodeSigningDiagnosis.problems(inBuildLog: onlyLocked), [.keychainLocked])

        let onlyDenied = "FleetestRunnerApp.debug.dylib: errSecInternalComponent"
        XCTAssertEqual(XcodeSigningDiagnosis.problems(inBuildLog: onlyDenied), [.keySigningAccessDenied])

        let both = onlyLocked + "\n" + onlyDenied
        XCTAssertEqual(XcodeSigningDiagnosis.problems(inBuildLog: both), [.keychainLocked, .keySigningAccessDenied])
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
                        "certificateNotInProfile", "deviceNotInProfile", "keychainLocked",
                        "keySigningAccessDenied"])
    }
}

/// **実際に起きた失敗のログ**を食わせる(合成のログだけだと、実物の書式が違っても緑のままになる)。
/// 2026-09-08 に M1Ultra へ ssh で dispatch した iPhone 13 のブリッジ起動で出たもの。
/// 署名 ID とプロビジョニングプロファイルは解決できており、**署名の実行だけ**が落ちている点が要。
final class XcodeSigningDiagnosisRealLogTests: XCTestCase {

    private let realLog = """
        CodeSign /Users/wave1008/fleetest-runner/foundation-tester/.fleetest/DerivedData-device/Build/Products/Debug-iphoneos/FleetestRunnerApp.app/FleetestRunnerApp.debug.dylib (in target 'FleetestRunnerApp' from project 'FleetestRunner')
            cd /Users/wave1008/fleetest-runner/foundation-tester/Runner

            Signing Identity:     "Apple Development: Nobuhiro Senba (73YMA2YH5T)"
            Provisioning Profile: "iOS Team Provisioning Profile: *"
                                  (e3102005-61a1-4e96-96d9-d0cb684a1c68)

            /usr/bin/codesign --force --sign 7BC7602764D57D07304ED7FCE30BA7A6528EEE05 --timestamp\\=none --generate-entitlement-der /Users/wave1008/fleetest-runner/foundation-tester/.fleetest/DerivedData-device/Build/Products/Debug-iphoneos/FleetestRunnerApp.app/FleetestRunnerApp.debug.dylib
        /Users/wave1008/fleetest-runner/foundation-tester/.fleetest/DerivedData-device/Build/Products/Debug-iphoneos/FleetestRunnerApp.app/FleetestRunnerApp.debug.dylib: errSecInternalComponent
        Command CodeSign failed with a nonzero exit code
        ** TEST BUILD FAILED **
        """

    func testTheRealSshCodeSignFailureIsDiagnosed() {
        let problems = XcodeSigningDiagnosis.problems(inBuildLog: realLog)
        XCTAssertFalse(problems.isEmpty,
                       "実ログから署名問題を1つも拾えていない(拾えないと再試行が止まらずフルビルドを繰り返す)")
    }

    /// 解錠の問題(User interaction is not allowed)は**出ていない** —— 取り違えると
    /// 「解錠してください」という誤った対処を案内する
    func testTheRealLogIsNotReportedAsALockedKeychain() {
        let problems = XcodeSigningDiagnosis.problems(inBuildLog: realLog)
        XCTAssertFalse(problems.contains(.keychainLocked),
                       "解錠済みなのにロックと診断している(対処が set-key-partition-list ではなく解錠になる)")
    }
}
