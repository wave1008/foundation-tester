import XCTest
import FTRemote
import FTCore

/// ハードウェア UUID(`IOPlatformUUID`)を持ち帰るシェル片の不変条件。
/// **出力はちょうど1行**でなければ `RemoteProbe.parseSessionInfo` の行数判定(3行 / 5行 / 6行)が
/// 崩れ、$HOME もコンソールユーザーも道連れで判定不能に落ちる(= ログインチェックが黙って無効になる)。
/// 実際にローカルの sh で撃って確かめる
final class RemoteHardwareUUIDProbeTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FleetestTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// この Mac では読めるので、1行返り・UUID として解釈できる
    func testTheProbeEmitsExactlyOneParsableLine() throws {
        let lines = try runShell(RemoteProbe.hardwareUUIDCommand)
        XCTAssertEqual(lines.count, 1, "1行でない: \(lines)")
        XCTAssertNotNil(RemoteProbe.parseHardwareUUID(lines[0]),
                        "この機械の ioreg の1行が読めない: \(lines[0])")
    }

    /// 同じ機械なら何度撃っても同じ値(順序付けの鍵に使える条件そのもの)
    func testTheValueIsStableAcrossInvocations() throws {
        let first = RemoteProbe.parseHardwareUUID(try runShell(RemoteProbe.hardwareUUIDCommand)[0])
        let second = RemoteProbe.parseHardwareUUID(try runShell(RemoteProbe.hardwareUUIDCommand)[0])
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    /// **負の対照**: 1件も拾えないときも行は消えない(`echo "$(…)"` が空行を1行返す)。
    /// パーサはその空行を nil = 不明にする(「常に値を返す検出器」ではない)
    func testTheProbeStillEmitsOneLineWhenNothingMatches() throws {
        let probe = RemoteProbe.hardwareUUIDCommand
            .replacingOccurrences(of: "grep IOPlatformUUID", with: "grep IOPlatformNOSUCHKEY")
        XCTAssertNotEqual(probe, RemoteProbe.hardwareUUIDCommand,
                          "grep の綴りが変わった —— この写しは負の対照になっていない")
        let lines = try runShell(probe)
        XCTAssertEqual(lines.count, 1, "1行でない: \(lines)")
        XCTAssertEqual(lines[0].trimmingCharacters(in: .whitespaces), "")
        XCTAssertNil(RemoteProbe.parseHardwareUUID(lines[0]))
    }

    /// 採取は接続の入口の1往復に相乗りする = ssh を1本も増やさない。
    /// 生の `ioreg` へ戻る(= 別の往復を足す)とここで落ちる
    func testTheDispatcherRidesAlongOnTheExistingProbe() throws {
        let relative = "Sources/fleetest/RemoteRunDispatcher.swift"
        let text = try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
        XCTAssertTrue(text.contains("RemoteProbe.hardwareUUIDCommand"),
                      "\(relative) が採取の定義元を参照していない")
        XCTAssertFalse(text.contains("ioreg -rd1"), "\(relative) が生の ioreg を撃っている")
    }

    /// 親が**順序を決める前に**採る経路(キャッシュに無い機械だけ)も同じ口を通る ——
    /// ssh の組み立ても facts への書き込みも、2つ目の実装を持たない
    func testTheParentSideProbeGoesThroughTheDispatcher() throws {
        let relative = "Sources/fleetest/DispatchPrelock.swift"
        let text = try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
        XCTAssertTrue(text.contains("probeHardwareUUIDAsParent"),
                      "\(relative) が既存の採取の口を呼んでいない")
        for own in ["ioreg", "Shell.run", "RemoteProbe.hardwareUUIDCommand",
                    "RemoteHostFactsStore.save"] {
            XCTAssertFalse(text.contains(own), "\(relative) が2つ目の採取実装を持っている: \(own)")
        }
    }

    /// 改行を落とさずに行へ割る(空行も1行として数える)
    private func runShell(_ command: String) throws -> [String] {
        let output = String(data: try Shell.runData(["/bin/sh", "-c", command], timeout: 30).data,
                            encoding: .utf8) ?? ""
        var lines = output.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
