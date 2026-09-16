import XCTest

@testable import fleetest

/// `fleetest devices down`(実行プロファイル無し = 全掃討)が**リモートの機械にも届く**ことを
/// ソース走査で固定する。
///
/// 実害 2026-08-30: モニターの「全て終了」はプロファイル未選択のとき従来の `devices down` を
/// 呼ぶ。これが手元しか掃討しないので、**タイルに出ているリモートの台が1枚も消えなかった**
/// (監視は登録簿の全マシンへ張るのに、停止は手元だけ = 集合が食い違っていた)。
/// `api start-all-devices` の同型は d678ae8f で直っており、これはその掃討漏れ。
final class DevicesDownSweepFanoutTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **その掃討をリモートで撃つ側は自分の機械に閉じる** —— `remote clean` が投げる
    /// `devices down` に `--device-machine local` が無いと、ランナー自身の登録簿を辿って
    /// 入れ子のディスパッチになる(経路は1段、の規律)
    func testRemoteCleanPinsTheRunnerToItself() throws {
        let code = try source("Sources/fleetest/RemoteCommands.swift")
        XCTAssertTrue(
            code.contains(#"["devices", "down", "--device-machine", "local"]"#),
            "remote clean の devices down は --device-machine local で閉じる(でないと連鎖する)")
    }

    func testSweepDispatchesToTheRemoteMachines() throws {
        let code = try source("Sources/fleetest/DevicesCommand.swift")
        XCTAssertTrue(code.contains("RemoteDeviceFanout.dispatchSweep"),
                      "profile 無しの devices down は登録簿の全マシンへも同じ掃討を投げる"
                      + "(手元だけだと「全て終了」でリモートのタイルが消えない)")
        XCTAssertTrue(code.contains("await fanout"),
                      "リモート分の完走を待たずに抜けると、子を殺したまま「終わった」と言う")
    }

    /// **掃討は run-lease の門を先に通す**。判定の後に分散すると、手元で断ったのにリモートは
    /// 掃討してしまう。`force` を子へ運ぶことも固定する
    func testSweepChecksRunLeasesBeforeTouchingAnything() throws {
        let code = try source("Sources/fleetest/DevicesCommand.swift")
        let gate = try XCTUnwrap(code.range(of: "if let refusal = DeviceBooter.sweepRefusal("),
                                 "profile 無しの devices down は run-lease の門を通す(条件を足して無効化しない)")
        let fanout = try XCTUnwrap(code.range(of: "RemoteDeviceFanout.dispatchSweep("))
        let bridges = try XCTUnwrap(code.range(of: "BridgeLauncher.stopAll("))
        let simctl = try XCTUnwrap(code.range(of: #"["xcrun", "simctl", "shutdown", "all"]"#))
        XCTAssertLessThan(gate.lowerBound, fanout.lowerBound)
        XCTAssertLessThan(gate.lowerBound, bridges.lowerBound)
        XCTAssertLessThan(gate.lowerBound, simctl.lowerBound)
        XCTAssertTrue(code[gate.upperBound..<fanout.lowerBound].contains("throw ExitCode(1)"),
                      "断ったら掃討へ進まず exit 1 で抜ける")
        XCTAssertTrue(code[fanout.lowerBound...].prefix(200).contains("force: force"),
                      "リモートの子へ --force を運ぶ")
    }

    /// `remote clean --ignore-lock` は掃討へ `--force` として運ぶ(運ばないとランナー側の門で断られ、
    /// 押し切ったつもりでデバイスが止まらない)
    func testRemoteCleanCarriesIgnoreLockAsForce() {
        XCTAssertEqual(RemoteCommand.Clean.devicesDownArgs(ignoreLock: false),
                       ["devices", "down", "--device-machine", "local"])
        XCTAssertEqual(RemoteCommand.Clean.devicesDownArgs(ignoreLock: true),
                       ["devices", "down", "--device-machine", "local", "--force"])
    }
}
