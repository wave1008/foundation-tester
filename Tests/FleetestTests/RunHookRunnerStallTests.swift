// 開始/終了スクリプトが出力せずに戻らないとき、RunHookRunner が打ち切らずに警告を出し続けることを
// 実プロセスで固定する(判定は FTCore.RunHookStall。ここは配線 = 無音の計時と出力での数え直し)。

import XCTest
import FTCore
@testable import fleetest

final class RunHookRunnerStallTests: XCTestCase {

    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-hook-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("setup.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 無音のまま 1.3 秒 → 閾値 0.4 秒なら 2 回以上警告し(0.4 / 0.8 / 1.2 秒。終了の reap が遅れれば
    /// もう 1 回)、終了は待つ(打ち切らない = status 0)
    func testSilentScriptGetsRepeatedWarningsButIsNotKilled() throws {
        let url = try script("sleep 1.3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var lines: [String] = []
        let status = RunHookRunner.execute(
            script: url, kind: .setup, workingDirectory: url.deletingLastPathComponent(),
            environment: [:], stallThreshold: 0.4) { lines.append($0) }
        XCTAssertEqual(status, 0, "打ち切らない(スクリプトは自分で終わる)")
        let warnings = lines.filter { $0.contains("has produced no output") }
        XCTAssertGreaterThanOrEqual(warnings.count, 2, lines.description)
        XCTAssertLessThanOrEqual(warnings.count, 5, "閾値ごとに 1 行を超えて鳴っている: " + lines.description)
        XCTAssertTrue(warnings[0].contains(url.path), warnings[0])
    }

    /// 出力があれば数え直す: `echo` → 1.0 秒無音 → `echo` → 1.0 秒無音 → `echo`。
    ///
    /// **証拠は回数ではなく「報告された無音秒数」**。数え直していれば各区間は独立に測られるので
    /// どの警告も 1 秒前後までしか言わないが、数え直さなければ最後の警告は経過時間の合計を名乗る。
    /// 実測(2026-09-07): `lastOutputAt` の更新を落とす変異を殺すのは**秒数の表明のほうで、
    /// 回数の表明は素通しする**。回数を厳密一致で見ていた版は、機械が混んでいるだけで落ちる
    /// 一方この性質を守れていなかった。回数の範囲は姉妹テスト
    /// (testSilentScriptGetsRepeatedWarningsButIsNotKilled)と同じ規律。
    func testOutputResetsTheSilenceClock() throws {
        let url = try script("echo a; sleep 1.0; echo b; sleep 1.0; echo c")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var lines: [String] = []
        let status = RunHookRunner.execute(
            script: url, kind: .teardown, workingDirectory: url.deletingLastPathComponent(),
            environment: [:], stallThreshold: 0.4) { lines.append($0) }
        XCTAssertEqual(status, 0)

        let warnings = lines.filter { $0.contains("has produced no output") }
        XCTAssertGreaterThanOrEqual(warnings.count, 2, lines.description)
        XCTAssertLessThanOrEqual(warnings.count, 8, "閾値ごとに 1 行を超えて鳴っている: " + lines.description)

        // "…has produced no output for <N>s and is…" の N。累積していないことを見る
        let reported = warnings.compactMap { line -> Int? in
            guard let r = line.range(of: "no output for "),
                  let end = line[r.upperBound...].firstIndex(of: "s") else { return nil }
            return Int(line[r.upperBound..<end])
        }
        XCTAssertEqual(reported.count, warnings.count, "無音秒数を読み取れない警告がある: " + lines.description)
        XCTAssertLessThanOrEqual(reported.max() ?? 0, 1,
                                 "無音が累積している(出力で数え直していない): " + lines.description)

        for marker in ["│ a", "│ b", "│ c"] {
            XCTAssertTrue(lines.contains { $0.hasSuffix(marker) }, marker + " が無い: " + lines.description)
        }
    }

    /// 閾値の手前で終わるスクリプトは警告 0
    func testFastScriptIsNotWarned() throws {
        let url = try script("echo done")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var lines: [String] = []
        _ = RunHookRunner.execute(
            script: url, kind: .setup, workingDirectory: url.deletingLastPathComponent(),
            environment: [:], stallThreshold: 5) { lines.append($0) }
        XCTAssertEqual(lines.filter { $0.contains("has produced no output") }.count, 0, lines.description)
    }
}
