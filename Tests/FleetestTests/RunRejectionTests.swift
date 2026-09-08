// `fleetest run`(RunScenarios)には「指定したのに黙って効かない」オプションの組み合わせが
// 4件あった(DriverOptions.platform/port が既定値付きの非Optional で「指定された」が判定できず、
// --profile 併用時に無視されていた)。CLAUDE.md の規律「効かせられないなら名指しでエラーにする」に
// 従い validate() で拒否する。ここは拒否が**実際に parse 時点で落ちる**ことと、正当な組み合わせが
// 誤検知しないことを固定する(陰性対照が無いと「常に throw する実装」と区別できない)。

import XCTest
import ArgumentParser
@testable import fleetest

final class RunRejectionTests: XCTestCase {

    // MARK: - fleetest run

    func testRunRejectsProfileWithPort() {
        XCTAssertThrowsError(
            try RunScenarios.parse(["--profile", "ios", "--port", "8200"])
        ) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("--profile cannot be combined with --platform/--port/--serial"), message)
        }
    }

    func testRunRejectsProfileWithPlatform() {
        XCTAssertThrowsError(
            try RunScenarios.parse(["--profile", "ios", "--platform", "android"])
        ) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("--profile cannot be combined with --platform/--port/--serial"), message)
        }
    }

    func testRunRejectsProfileWithApp() {
        XCTAssertThrowsError(
            try RunScenarios.parse(["--profile", "ios", "--app-id", "com.example"])
        ) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("--app-id cannot be combined with --profile"), message)
        }
    }

    func testRunRejectsPerformanceWithoutProfileOrFleet() {
        XCTAssertThrowsError(try RunScenarios.parse(["--performance"])) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("--performance requires --profile or --fleet"), message)
        }
    }

    /// 陰性対照: 正当な組み合わせは誤検知しない
    func testRunAllowsLegitimateCombinations() {
        XCTAssertNoThrow(try RunScenarios.parse(["--profile", "ios"]))
        XCTAssertNoThrow(try RunScenarios.parse(["--port", "8200"]))
        XCTAssertNoThrow(try RunScenarios.parse(["--performance", "--profile", "ios"]))
        XCTAssertNoThrow(try RunScenarios.parse(["--performance", "--fleet", "f"]))
    }

    /// `--set` の profile-only キー検査は build の前(validate() = parse 時点)へ移した。
    /// 以前は swift build の後(run() の途中)まで落ちなかった
    func testRunRejectsSetProfileOnlyKeyWithoutProfileAtParse() {
        XCTAssertThrowsError(
            try RunScenarios.parse(["--set", "iosInappEngine=false"])
        ) { error in
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("iosInappEngine"), message)
            XCTAssertTrue(message.contains("needs --profile"), message)
        }
    }

    // MARK: - fleetest api run

    func testApiRunRejectsProfileWithPort() {
        XCTAssertThrowsError(
            try ApiRunCommand.parse(["--scenario", "A.b", "--profile", "ios", "--port", "8200"])
        ) { error in
            let message = ApiRunCommand.message(for: error)
            XCTAssertTrue(message.contains("--profile cannot be combined with --platform/--port/--serial"), message)
        }
    }

    func testApiRunRejectsProfileWithApp() {
        XCTAssertThrowsError(
            try ApiRunCommand.parse(["--scenario", "A.b", "--profile", "ios", "--app-id", "com.example"])
        ) { error in
            let message = ApiRunCommand.message(for: error)
            XCTAssertTrue(message.contains("--app-id cannot be combined with --profile"), message)
        }
    }

    /// 陰性対照
    func testApiRunAllowsLegitimateCombination() {
        XCTAssertNoThrow(try ApiRunCommand.parse(["--scenario", "A.b", "--profile", "ios"]))
    }

    /// `--port` は `fleetest run` と同じ綴りで repeatable になったが、api run の --profile 無し経路
    /// (runDirect)には並列実行が無いため、2回以上渡すのは名指しで拒否する(work item 3)
    func testApiRunRejectsMultiplePorts() {
        XCTAssertThrowsError(
            try ApiRunCommand.parse(["--scenario", "A.b", "--port", "8200", "--port", "8201"])
        ) { error in
            let message = ApiRunCommand.message(for: error)
            XCTAssertTrue(message.contains("--port can only be given once here"), message)
        }
    }
}
