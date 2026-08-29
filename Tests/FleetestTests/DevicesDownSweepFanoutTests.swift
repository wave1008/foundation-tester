import XCTest

@testable import fleetest

/// `fleetest devices down`(実行プロファイル無し = 全掃討)が**リモートの機械にも届く**ことを
/// ソース走査で固定する。
///
/// 実害 2026-08-30: モニターの「全て終了」はプロファイル未選択のとき従来の `devices down` を
/// 呼ぶ。これが手元しか掃討しないので、**タイルに出ているリモートの台が1枚も消えなかった**
/// (監視は登録簿の全マシンへ張るのに、停止は手元だけ = 集合が食い違っていた)。
/// `api devices-up` の同型は d678ae8f で直っており、これはその掃討漏れ。
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
}
