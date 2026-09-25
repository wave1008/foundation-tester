// RemoteDispatchTests+HostCompat.swift
// リモートホストの照合・診断: RemoteCompat.verdict(ツールチェーン適合判定)・RemoteProbe(セッション情報/
// ハードウェア UUID の解析)・ToolchainFingerprint・RemoteStatusProbe(remote status の1往復コマンドと出力パース)。

import Foundation
import XCTest
@testable import FTCore
import FTRemote

extension RemoteDispatchTests {

    // MARK: - RemoteCompat.verdict

    func testVerdictEmptyWhenAllMatch() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1",
            remoteToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(v.blocking, [])
        XCTAssertEqual(v.advisory, [])
        XCTAssertTrue(v.isCompatible)
    }

    func testVerdictRevisionMismatchIsAlwaysBlocking() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: "def",
            localToolchain: "Xcode 27.0 Build A", remoteToolchain: "Xcode 27.0 Build A")
        XCTAssertEqual(v.blocking.count, 1)
        XCTAssertTrue(v.blocking[0].contains("git revision"), v.blocking[0])
        XCTAssertTrue(v.blocking[0].contains("local=abc") && v.blocking[0].contains("remote=def"), v.blocking[0])
        XCTAssertEqual(v.advisory, [])
    }

    /// 製品版(27.0)が同じで build だけ違う = ベータ seed の差 → advisory(止めない)
    func testVerdictSameProductVersionDifferentBuildIsAdvisory() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0 Build version 27A5228h / iphonesimulator 24A434",
            remoteToolchain: "Xcode 27.0 Build version 27A5231e / iphonesimulator 24A5423a")
        XCTAssertEqual(v.blocking, [])
        XCTAssertEqual(v.advisory.count, 1, "\(v.advisory)")
        XCTAssertTrue(v.advisory[0].hasPrefix("toolchain"), v.advisory[0])
        XCTAssertTrue(v.advisory[0].contains("beta seed"), v.advisory[0])
        XCTAssertTrue(v.isCompatible, "advisory はディスパッチを止めない")
    }

    /// 製品版そのものが違う(26 vs 27)ときは build が違っても blocking のまま
    func testVerdictDifferentProductVersionIsBlocking() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 26.3 Build version 26C1 / iphonesimulator 26C1",
            remoteToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(v.blocking.count, 1, "\(v.blocking)")
        XCTAssertTrue(v.blocking[0].hasPrefix("toolchain mismatch"), v.blocking[0])
        XCTAssertEqual(v.advisory, [])
    }

    /// fail-closed: リモート値が取れない(nil)場合も blocking
    func testVerdictNilRemoteIsBlocking() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: nil,
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0")
        XCTAssertEqual(v.blocking.count, 1)
        XCTAssertTrue(v.blocking[0].contains("could not determine the remote value"), v.blocking[0])
        XCTAssertTrue(v.blocking[0].contains("local=abc"), v.blocking[0])
    }

    /// fail-closed: ローカル値が取れない場合も blocking
    func testVerdictNilLocalIsBlocking() {
        let v = RemoteCompat.verdict(
            localRevision: nil, remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0")
        XCTAssertEqual(v.blocking.count, 1)
        XCTAssertTrue(v.blocking[0].contains("could not determine the local value"), v.blocking[0])
        XCTAssertTrue(v.blocking[0].contains("remote=abc"), v.blocking[0])
    }

    /// fail-closed: toolchain の片方が nil でも blocking(製品版が切り出せても advisory へは倒さない)
    func testVerdictNilToolchainIsBlockingNotAdvisory() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0 Build A", remoteToolchain: nil)
        XCTAssertEqual(v.blocking.count, 1)
        XCTAssertTrue(v.blocking[0].hasPrefix("toolchain"), v.blocking[0])
        XCTAssertEqual(v.advisory, [])
    }

    // MARK: - RemoteCompat.verdict(ProbeOutcome)

    /// 照会が失敗したら**判定は fail-closed のまま**で、理由の行が1本増える
    /// (レーンが丸ごと落ちたときに「なぜ取れなかったか」が残る)
    func testProbeFailureKeepsFailClosedAndCarriesTheReason() {
        let v = RemoteCompat.verdict(
            localRevision: "abc",
            remoteRevision: .failed(detail: "ssh command failed (status 128): git -C /x rev-parse HEAD"),
            localToolchain: "Xcode 27.0", remoteToolchain: .value("Xcode 27.0"))
        XCTAssertEqual(v.blocking.count, 2, "\(v.blocking)")
        XCTAssertTrue(v.blocking[0].contains("could not determine the remote value"), v.blocking[0])
        XCTAssertTrue(v.blocking[1].contains("status 128"), v.blocking[1])
        XCTAssertTrue(v.blocking[1].contains("git revision"), v.blocking[1])
        XCTAssertEqual(v.advisory, [])
    }

    /// 失敗行は "git revision" で**始まらない** —— 呼び出し側は接頭辞で向きの案内を
    /// 分岐するので、照会の失敗がそこへ食い込むと「push していない」等の誤誘導になる
    func testProbeFailureDoesNotCollideWithTheAdvicePrefix() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: .failed(detail: "timed out"),
            localToolchain: "Xcode 27.0", remoteToolchain: .failed(detail: "timed out"))
        XCTAssertEqual(v.blocking.filter { $0.hasPrefix("git revision") }.count, 1, "\(v.blocking)")
        XCTAssertEqual(v.blocking.filter { $0.hasPrefix("toolchain") }.count, 1, "\(v.blocking)")
        XCTAssertEqual(v.blocking.count, 4, "\(v.blocking)")
    }

    /// 値が揃っていれば失敗行は出ない(照会が成功した回に余計な行を足さない)
    func testProbeValuesMatchingYieldNoReasons() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: .value("abc"),
            localToolchain: "Xcode 27.0", remoteToolchain: .value("Xcode 27.0"))
        XCTAssertEqual(v.blocking, [])
        XCTAssertEqual(v.advisory, [])
    }

    /// 照会が成功して製品版が同じ・build だけ違うなら ProbeOutcome 経由でも advisory になる
    func testProbeSameProductVersionDifferentBuildIsAdvisory() {
        let v = RemoteCompat.verdict(
            localRevision: "abc", remoteRevision: .value("abc"),
            localToolchain: "Xcode 27.0 Build version 27A5228h / iphonesimulator 24A434",
            remoteToolchain: .value("Xcode 27.0 Build version 27A5231e / iphonesimulator 24A5423a"))
        XCTAssertEqual(v.blocking, [])
        XCTAssertEqual(v.advisory.count, 1, "\(v.advisory)")
    }

    // MARK: - RemoteCompat.classifyRelation

    func testClassifyRelationLocalBehind() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: true, remoteIsAncestorOfLocal: false), .localBehind)
    }

    func testClassifyRelationRemoteBehind() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: false, remoteIsAncestorOfLocal: true), .remoteBehind)
    }

    func testClassifyRelationDiverged() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: false, remoteIsAncestorOfLocal: false), .diverged)
    }

    func testClassifyRelationUnknownWhenEitherSideNil() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: nil, remoteIsAncestorOfLocal: true), .unknown)
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: false, remoteIsAncestorOfLocal: nil), .unknown)
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: nil, remoteIsAncestorOfLocal: nil), .unknown)
    }

    /// 呼び手は rev が異なるときだけ呼ぶ契約なので本来起きないが、防御として unknown に落とす
    func testClassifyRelationBothTrueFallsBackToUnknown() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: true, remoteIsAncestorOfLocal: true), .unknown)
    }

    // MARK: - RemoteCompat.relationAdvice

    /// localBehind は自分を更新する経路(update.sh)だけを案内する ―― align を実行手順として出さない
    func testRelationAdviceLocalBehindPointsToUpdateNotAlign() {
        let advice = RemoteCompat.relationAdvice(.localBehind)
        XCTAssertTrue(advice.contains("update"), advice)
        XCTAssertTrue(advice.contains("Scripts/update.sh"), advice)
        XCTAssertFalse(advice.contains("fleetest remote align"), advice)
    }

    func testRelationAdviceRemoteBehindPointsToAlignWithCanary() {
        let advice = RemoteCompat.relationAdvice(.remoteBehind)
        XCTAssertTrue(advice.contains("fleetest remote align"), advice)
        XCTAssertTrue(advice.contains("canary"), advice)
    }

    func testRelationAdviceDivergedPointsToDedicatedMachine() {
        XCTAssertTrue(RemoteCompat.relationAdvice(.diverged).contains("dedicated machine"))
    }

    func testRelationAdviceUnknownPointsToGitFetch() {
        XCTAssertTrue(RemoteCompat.relationAdvice(.unknown).contains("git fetch"))
    }


    // MARK: - RemoteProbe.parseSessionInfo

    func testParseSessionInfoNormalThreeLines() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice")
        XCTAssertEqual(info, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice"))
        XCTAssertEqual(info?.isLoggedIn, true)
    }

    func testParseSessionInfoAcceptsTrailingNewline() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\n")
        XCTAssertEqual(info, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice"))
    }

    func testParseSessionInfoMissingLineReturnsNil() {
        XCTAssertNil(RemoteProbe.parseSessionInfo("/Users/ci\nalice"))
    }

    func testParseSessionInfoBlankLineReturnsNil() {
        XCTAssertNil(RemoteProbe.parseSessionInfo("/Users/ci\n\nalice"))
    }

    func testParseSessionInfoConsoleUserRootDiffersFromSshUser() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nroot\nalice")
        XCTAssertEqual(info?.isLoggedIn, false)
    }

    func testParseSessionInfoConsoleUserMatchesSshUser() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice")
        XCTAssertEqual(info?.isLoggedIn, true)
    }

    /// 5行形(4行目 = CPU モデル・5行目 = コア数)。先頭3行の妥当性判定は3行形と同一
    func testParseSessionInfoFiveLinesIncludesHardware() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\n10")
        XCTAssertEqual(info, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice",
                                               processorModel: "Apple M1 Max", coreCount: 10))
    }

    func testParseSessionInfoFiveLinesAcceptsTrailingNewline() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\n10\n")
        XCTAssertEqual(info?.processorModel, "Apple M1 Max")
        XCTAssertEqual(info?.coreCount, 10)
    }

    /// 4行目が空(トリム後)なら processorModel は nil。セッション情報自体は活かす
    func testParseSessionInfoFiveLinesEmptyProcessorModelBecomesNil() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\n \n10")
        XCTAssertNotNil(info)
        XCTAssertNil(info?.processorModel)
        XCTAssertEqual(info?.coreCount, 10)
    }

    /// 5行目が Int にパースできなければ coreCount は nil
    func testParseSessionInfoFiveLinesNonIntegerCoreCountBecomesNil() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\nnot-a-number")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.processorModel, "Apple M1 Max")
        XCTAssertNil(info?.coreCount)
    }

    /// 行数が3でも5でも6でもなければ従来どおり nil(4行・7行等)
    func testParseSessionInfoFourLinesReturnsNil() {
        XCTAssertNil(RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max"))
    }

    func testParseSessionInfoSevenLinesReturnsNil() {
        XCTAssertNil(RemoteProbe.parseSessionInfo(
            "/Users/ci\nalice\nalice\nApple M1 Max\n10\n\"IOPlatformUUID\" = \"x\"\nextra"))
    }

    /// 3行形は5行形・6行形の追加ロジックの影響を受けない(hardware は nil のまま)
    func testParseSessionInfoThreeLinesHasNilHardware() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice")
        XCTAssertNil(info?.processorModel)
        XCTAssertNil(info?.coreCount)
        XCTAssertNil(info?.hardwareUUID)
    }

    /// 5行形(ハードウェア UUID の行が無い形)でも $HOME と
    /// コンソールユーザーを返す —— 行が1つ増えても既存の判定は変わらない
    func testParseSessionInfoFiveLinesStillHasNilHardwareUUID() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\n10")
        XCTAssertEqual(info?.home, "/Users/ci")
        XCTAssertEqual(info?.consoleUser, "alice")
        XCTAssertNil(info?.hardwareUUID)
    }

    // MARK: - 6行形(ハードウェア UUID)

    func testParseSessionInfoSixLinesIncludesHardwareUUID() {
        let info = RemoteProbe.parseSessionInfo(
            "/Users/ci\nalice\nalice\nApple M1 Max\n10\n"
            + "      \"IOPlatformUUID\" = \"0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9\"")
        XCTAssertEqual(info, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice",
                                               processorModel: "Apple M1 Max", coreCount: 10,
                                               hardwareUUID: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    }

    func testParseSessionInfoSixLinesAcceptsTrailingNewline() {
        let info = RemoteProbe.parseSessionInfo(
            "/Users/ci\nalice\nalice\nApple M1 Max\n10\n"
            + "      \"IOPlatformUUID\" = \"0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9\"\n")
        XCTAssertEqual(info?.hardwareUUID, "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
    }

    /// UUID の行が空(ioreg が読めなかった = `echo "$(…)"` が空行を返す)でも、
    /// **セッション情報とハードウェア情報は従来どおり生きる**(hardwareUUID だけ nil)
    func testParseSessionInfoSixLinesEmptyUUIDLineKeepsTheRest() {
        // 末尾の改行1個は許容規則で落ちるので、6行目が空であることを表すには "\n\n" が要る
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\n10\n\n")
        XCTAssertEqual(info?.home, "/Users/ci")
        XCTAssertEqual(info?.consoleUser, "alice")
        XCTAssertEqual(info?.processorModel, "Apple M1 Max")
        XCTAssertEqual(info?.coreCount, 10)
        XCTAssertNil(info?.hardwareUUID)
    }

    // MARK: - RemoteProbe.parseHardwareUUID

    func testParseHardwareUUIDNormalLine() {
        XCTAssertEqual(
            RemoteProbe.parseHardwareUUID("      \"IOPlatformUUID\" = \"0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9\""),
            "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
    }

    /// 前後の空白・末尾の改行が付いていても同じ値
    func testParseHardwareUUIDToleratesSurroundingWhitespace() {
        XCTAssertEqual(
            RemoteProbe.parseHardwareUUID("  \t \"IOPlatformUUID\" =   \"0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9\"  \n"),
            "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
    }

    /// 表記が揺れても正準形(大文字)へ畳む —— 「同じ機械なら誰が見ても同じ文字列」が要件
    func testParseHardwareUUIDCanonicalisesToUppercase() {
        XCTAssertEqual(
            RemoteProbe.parseHardwareUUID("\"IOPlatformUUID\" = \"0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9\""),
            "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
    }

    func testParseHardwareUUIDEmptyLineIsNil() {
        XCTAssertNil(RemoteProbe.parseHardwareUUID(""))
        XCTAssertNil(RemoteProbe.parseHardwareUUID("   \n"))
    }

    /// キーを含まない出力(ioreg が別の形を返した・grep が何も拾わなかった)は nil = 不明
    func testParseHardwareUUIDWithoutTheKeyIsNil() {
        XCTAssertNil(RemoteProbe.parseHardwareUUID("      \"IOPlatformSerialNumber\" = \"C02ABC\""))
        XCTAssertNil(RemoteProbe.parseHardwareUUID("ioreg: not found"))
    }

    /// UUID として読めない値は nil(既定値で埋めない)。`=` が無い形も同じ
    func testParseHardwareUUIDMalformedValueIsNil() {
        XCTAssertNil(RemoteProbe.parseHardwareUUID("\"IOPlatformUUID\" = \"not-a-uuid\""))
        XCTAssertNil(RemoteProbe.parseHardwareUUID("\"IOPlatformUUID\" = \"\""))
        XCTAssertNil(RemoteProbe.parseHardwareUUID("\"IOPlatformUUID\""))
    }


    // MARK: - ToolchainFingerprint.compose

    func testComposeFoldsTwoLineXcodeVersionIntoOneLine() {
        XCTAssertEqual(
            ToolchainFingerprint.compose(
                xcodeVersionOutput: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h"),
            "Xcode 27.0 Build version 27A5228h / iphonesimulator 27A5228h")
    }


    // MARK: - RemoteStatusProbe.command

    func testStatusProbeCommand() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let tool = "\"/Users/ci/fleetest-runner/foundation-tester\""
        let binary = "\"/Users/ci/fleetest-runner/foundation-tester/.build/debug/fleetest\""
        let base = "\"/Users/ci/fleetest-runner\""
        XCTAssertEqual(
            RemoteStatusProbe.command(layout: layout, simulatorRuntime: true),
            "echo $HOME; if launchctl print gui/$(id -u) >/dev/null 2>&1; then id -un;"
            + " else stat -f%Su /dev/console; fi; id -un; echo '---FT---'; "
            + "git -C \(tool) rev-parse HEAD 2>/dev/null || echo -; echo '---FT---'; "
            + "xcodebuild -version; echo '---FT---'; "
            + "xcrun --sdk iphonesimulator --show-sdk-build-version; echo '---FT---'; "
            + "test -x \(binary) && echo yes || echo no; echo '---FT---'; "
            + "df -k \(base) | tail -1; echo '---FT---'; "
            // **dispatch.lock は `<base>` の外**(機械グローバルな `<home>/.fleetest/`)——
            // 同じ Mac に base を2つ作っても1本にするため
            + "if [ -d \"/Users/ci/.fleetest/dispatch.lock\" ]; then echo held;"
            + " cat \"/Users/ci/.fleetest/dispatch.lock/info.json\" 2>/dev/null || true; echo;"
            + " else echo absent; fi; echo '---FT---'; "
            // FM の死活台帳。**レイアウトの外**(~/.fleetest)を読む —— FM はホストの資源で、
            // プロジェクトにも発行者にも属さない。**実呼び出しは混ぜない**(status がホストの
            // FM を消費し、ホスト数ぶん直列化の枠を奪うことになる)
            + "cat \"$HOME/.fleetest/fm-liveness.json\" 2>/dev/null || true; echo; echo '---FT---'; "
            // iOS シミュレータのランタイム(RUNTIME 欄)。手元と同じ2コマンド、simctl だけ期限付き
            + "xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true; echo '---FT---'; "
            + "perl -e 'alarm shift; exec @ARGV' 10 xcrun simctl list runtimes 2>/dev/null || true")
    }

    /// `developerDir` はブロックを増やさず、既存の joined 文字列の先頭に export を1つ足すだけ
    /// (`parse` は固定インデックスでブロックを読むので、新しいブロックを足すと後続がずれる)。
    /// export 以降は developerDir なしの版とバイト同一であること・ブロック数(separator の出現数)が
    /// 変わらないことの両方を固定する
    func testStatusProbeCommandPrefixesDeveloperDirExportWithoutShiftingBlocks() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let ambient = RemoteStatusProbe.command(layout: layout, simulatorRuntime: true)
        let pinned = RemoteStatusProbe.command(
            layout: layout, simulatorRuntime: true,
            developerDir: "/Applications/Xcode_27.app/Contents/Developer")
        XCTAssertEqual(pinned, "export DEVELOPER_DIR='/Applications/Xcode_27.app/Contents/Developer'; " + ambient)
        XCTAssertEqual(
            pinned.components(separatedBy: "echo '---FT---'").count,
            ambient.components(separatedBy: "echo '---FT---'").count)
    }

    /// nil(既定)は1バイトも足さない(呼び出し元を1つずつ opt-in させる。ambient のまま = 従来どおり)
    func testStatusProbeCommandOmitsDeveloperDirExportWhenNil() {
        let layout = RemoteLayout(base: "/b", issuer: "alice", home: "/h")
        XCTAssertFalse(RemoteStatusProbe.command(layout: layout, simulatorRuntime: true).contains("DEVELOPER_DIR"))
    }

    /// `api remote-compat`(拡張がリモート実行の前に毎回待つ)は RUNTIME を読まない ——
    /// simctl の往復を実行開始の前に払わせない。落とすのは FM の台帳までの8ブロック
    func testStatusProbeWithoutRuntimeOmitsSimctl() {
        let layout = RemoteLayout(base: "/b", issuer: "alice", home: "/h")
        let command = RemoteStatusProbe.command(layout: layout, simulatorRuntime: false)
        XCTAssertFalse(command.contains("simctl"), command)
        XCTAssertFalse(command.contains("--show-sdk-version"), command)
        XCTAssertTrue(command.hasSuffix("cat \"$HOME/.fleetest/fm-liveness.json\" 2>/dev/null || true; echo"), command)
        XCTAssertEqual(command.components(separatedBy: "echo '---FT---'").count, 8)
    }

    /// **ファイルを cat するブロックは必ず改行で閉じる**。改行で終わらないファイル(FM の台帳・
    /// `printf '%s'` で書くロックの info.json)の直後に区切りが来ると `}}---FT---` が1行になり、
    /// 区切りとして読まれず後ろのブロックが全部ずれる(2026-09-10 実データで RUNTIME が両機とも
    /// 読めなかった。単体テストの出力は区切りを自前で改行付きに組むので出ない)
    func testEveryCatInTheStatusProbeIsFollowedByANewline() {
        let command = RemoteStatusProbe.command(
            layout: RemoteLayout(base: "/b", issuer: "alice", home: "/h"), simulatorRuntime: true)
        let cats = command.components(separatedBy: " cat ").dropFirst()
        XCTAssertEqual(cats.count, 2, "cat の本数が変わった(ロックの info.json と FM の台帳)—— 検査を見直すこと")
        for rest in cats {
            let upToSeparator = rest.components(separatedBy: "echo '---FT---'")[0]
            XCTAssertTrue(upToSeparator.contains("; echo;"),
                          "cat の後に改行を足していない: cat \(upToSeparator)")
        }
    }

    /// RUNTIME 欄も同じ1往復に相乗りさせる。**実物の出力の形**(2026-09-10 の M1Max = ベータだけ /
    /// M1Ultra = ベータと正式版が同居)で、手元と比べられる指紋になること
    func testStatusProbeParsesTheSimulatorRuntimeBlocks() {
        let base = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A266a", sdkBuild: "24A430",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
            + "\n\(Self.statusSeparator)\nabsent\n\(Self.statusSeparator)\n"
        let betaOnly = base + "\(Self.statusSeparator)\n27.0\n\(Self.statusSeparator)\n== Runtimes ==\n"
            + "iOS 26.2 (26.2 - 23C54) - com.apple.CoreSimulator.SimRuntime.iOS-26-2\n"
            + "iOS 27.0 (27.0 - 24A5423a) - com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        XCTAssertEqual(RemoteStatusProbe.parse(betaOnly).simulatorRuntime, "iOS 27.0: 24A5423a (beta)")
        let mixed = base + "\(Self.statusSeparator)\n27.0\n\(Self.statusSeparator)\n== Runtimes ==\n"
            + "iOS 27.0 (27.0 - 24A5355p) - com.apple.CoreSimulator.SimRuntime.iOS-27-0\n"
            + "iOS 27.0 (27.0 - 24A434) - com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        XCTAssertEqual(RemoteStatusProbe.parse(mixed).simulatorRuntime, "iOS 27.0: 24A434")
        // 旧形(ブロックが足りない)・SDK が読めない(Xcode 無し)は nil = 不明
        XCTAssertNil(RemoteStatusProbe.parse(base).simulatorRuntime)
        XCTAssertNil(RemoteStatusProbe.parse(base + "\(Self.statusSeparator)\n\n\(Self.statusSeparator)\n").simulatorRuntime)
        // simctl が期限切れ(空のブロック)は不明。**「ランタイムが無い」= none に倒さない**
        XCTAssertNil(RemoteStatusProbe.parse(base + "\(Self.statusSeparator)\n27.0\n\(Self.statusSeparator)\n").simulatorRuntime)
    }

    /// 占有(誰が使っているか)を **remote status の1往復に相乗りさせる**(§18.1 #1)。
    /// 別の ssh を足すとホスト数ぶん往復が増える
    func testStatusProbeParsesTheDispatchLockBlock() {
        let info = RemoteDispatchLock.encode(RemoteDispatchLockInfo(
            issuerHost: "dev-mbp", pid: 7, acquiredAt: "2026-08-31T00:00:00Z", issuer: "bob")) ?? ""
        let free = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        XCTAssertEqual(RemoteStatusProbe.parse(free + "\n\(Self.statusSeparator)\nabsent").lock, .absent)
        let held = RemoteStatusProbe.parse(free + "\n\(Self.statusSeparator)\nheld\n\(info)").lock
        XCTAssertEqual(held, .held(RemoteDispatchLock.decode(info)))
        // **旧ランナー(ブロックが6個しか無い)は nil = 判定不能**。空きに倒すと、
        // 実際は走っている run を「空いている」と表示してしまう
        XCTAssertNil(RemoteStatusProbe.parse(free).lock)
    }

    /// $HOME を未解決のまま埋め込んだ layout(remote status の実運用形)でも
    /// 二重引用符で包むだけで壊れない(単一引用符と違い変数展開を妨げない)ことを確認
    func testStatusProbeCommandQuotesDoNotSuppressHomeExpansion() {
        let layout = RemoteLayout(base: RemoteLayout.resolveBase("~/fleetest-runner", home: "$HOME"),
                                  issuer: "alice", home: "$HOME")
        let command = RemoteStatusProbe.command(layout: layout, simulatorRuntime: true)
        XCTAssertTrue(command.contains("\"$HOME/fleetest-runner/foundation-tester\""), command)
        // **遅延展開してよいのはこの読み取り専用の1往復だけ**(1 ssh に収める設計)。
        // 取得・解放は手元で確定した絶対パスを使う(RemoteLayout.home の注記)
        XCTAssertTrue(command.contains("if [ -d \"$HOME/.fleetest/dispatch.lock\" ]"), command)
    }

    // MARK: - RemoteStatusProbe.dquote

    func testDquotePlainPathUnaffected() {
        XCTAssertEqual(RemoteStatusProbe.dquote("/Users/ci/fleetest-runner"), "\"/Users/ci/fleetest-runner\"")
    }

    /// $ はエスケープしない(remote status がここに $HOME を埋め込んで展開させるため)
    func testDquotePreservesDollarForHomeExpansion() {
        XCTAssertEqual(RemoteStatusProbe.dquote("$HOME/x"), "\"$HOME/x\"")
    }

    /// --remote-dir に紛れ込んだ埋め込み二重引用符・バックスラッシュが引用符から抜け出さない
    func testDquoteEscapesEmbeddedQuoteAndBackslash() {
        XCTAssertEqual(RemoteStatusProbe.dquote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    // MARK: - RemoteStatusProbe.parse

    private static let statusSeparator = "---FT---"

    private func statusOutput(session: String, revision: String, xcodeVersion: String,
                              sdkBuild: String, binary: String, df: String?) -> String {
        var blocks = [session, revision, xcodeVersion, sdkBuild, binary]
        if let df { blocks.append(df) }
        return blocks.joined(separator: "\n\(Self.statusSeparator)\n")
    }

    func testStatusProbeParseNormalOutput() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        let status = RemoteStatusProbe.parse(output)
        XCTAssertEqual(status.session, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice"))
        XCTAssertEqual(status.revision, "abc123")
        XCTAssertEqual(status.toolchain, "Xcode 27.0 Build version 27A5228h / iphonesimulator 27A5228h")
        XCTAssertTrue(status.binaryPresent)
        XCTAssertEqual(status.freeKB, 400_000_000)
    }

    func testStatusProbeParseDashRevisionBecomesNil() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "-",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        XCTAssertNil(RemoteStatusProbe.parse(output).revision)
    }

    func testStatusProbeParseBinaryNoBecomesFalse() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "no", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        XCTAssertFalse(RemoteStatusProbe.parse(output).binaryPresent)
    }

    func testStatusProbeParseMissingDfLineLeavesFreeKBNil() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: nil)
        XCTAssertNil(RemoteStatusProbe.parse(output).freeKB)
    }

    func testStatusProbeParseBrokenSessionLeavesOtherFieldsIntact() {
        // セッションが2行しかない(壊れている)が、後続のブロックは正常
        let output = statusOutput(
            session: "/Users/ci\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        let status = RemoteStatusProbe.parse(output)
        XCTAssertNil(status.session)
        XCTAssertEqual(status.revision, "abc123")
        XCTAssertEqual(status.toolchain, "Xcode 27.0 Build version 27A5228h / iphonesimulator 27A5228h")
        XCTAssertTrue(status.binaryPresent)
        XCTAssertEqual(status.freeKB, 400_000_000)
    }

}
