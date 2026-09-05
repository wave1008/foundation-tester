// 同じ Mac の別ウィンドウが同じ台の配信を持っているかの判定(FTCore.LocalStreamHolder)。
// 判定は純粋関数なので ps の行を合成して両方向に固定する。

import XCTest
@testable import FTCore

final class LocalStreamHolderTests: XCTestCase {

    private typealias Row = LocalStreamHolder.ProcessRow

    private func row(_ pid: Int32, elapsed: Int, _ command: String, owner: Int32? = nil) -> Row {
        var tokens = command.split(separator: " ").map(String.init)
        if let owner { tokens += ["HOME=/Users/x", "FT_PARENT_PID=\(owner)", "LANG=C"] }
        return Row(pid: pid, elapsedSeconds: elapsed, tokens: tokens)
    }

    private let sim = LocalStreamHolder.DeviceIdentity.iosSimulator(udid: "AAAA-1111")
    private let simstream = "/repo/.build/debug/fleetest-simstream --udid AAAA-1111 --fps 12 --max-width 960 --codec h264"

    // MARK: - 台の識別

    func testMatchesEachHelperByItsIdentifyingArgument() {
        let rows = [
            row(1, elapsed: 10, simstream, owner: 7),
            row(2, elapsed: 10, "/repo/.build/debug/fleetest-simstream --udid BBBB-2222 --fps 12", owner: 7),
            row(3, elapsed: 10, "/repo/.build/debug/fleetest-androidstream --serial emulator-5554 --adb /adb", owner: 7),
            row(4, elapsed: 10, "/repo/.build/debug/fleetest-devicepoll --platform android --serial 14141J --adb /adb", owner: 7),
            row(5, elapsed: 10, "/repo/.build/debug/fleetest-devicepoll --platform ios --host 127.0.0.1 --port 8123", owner: 7),
            row(6, elapsed: 10, "/usr/bin/grep --udid AAAA-1111", owner: 7),  // ヘルパーではない
        ]
        XCTAssertEqual(LocalStreamHolder.helpers(for: sim, in: rows).map(\.pid), [1])
        XCTAssertEqual(LocalStreamHolder.helpers(for: .android(serial: "emulator-5554"), in: rows).map(\.pid), [3])
        XCTAssertEqual(LocalStreamHolder.helpers(for: .android(serial: "14141J"), in: rows).map(\.pid), [4])
        XCTAssertEqual(LocalStreamHolder.helpers(for: .iosPhysical(port: 8123), in: rows).map(\.pid), [5])
        XCTAssertEqual(LocalStreamHolder.helpers(for: .iosPhysical(port: 8124), in: rows), [])
    }

    /// 値の前方一致・部分一致で別の台を掴まない(`--serial 1414` が `14141J` に当たらない)
    func testIdentifyingValueMustMatchExactly() {
        let rows = [row(4, elapsed: 10, "/x/fleetest-devicepoll --platform android --serial 14141J --adb /adb")]
        XCTAssertEqual(LocalStreamHolder.helpers(for: .android(serial: "1414"), in: rows), [])
        XCTAssertEqual(LocalStreamHolder.helpers(for: .android(serial: "14141JX"), in: rows), [])
    }

    // MARK: - 保持者と所有

    /// 保持者は最も早く起動した1本(同点は pid が小さいほう)。両方のウィンドウが同じ答えになる
    func testHolderIsTheEarliestStartedHelperWithPidAsTieBreak() {
        let rows = [
            row(30, elapsed: 5, simstream, owner: 1),
            row(10, elapsed: 20, simstream, owner: 2),
            row(20, elapsed: 20, simstream, owner: 3),
        ]
        XCTAssertEqual(LocalStreamHolder.holder(for: sim, in: rows)?.pid, 10)
        XCTAssertNil(LocalStreamHolder.holder(for: sim, in: []))
    }

    func testHeldByOtherComparesTheHolderOwnerWithMine() {
        let mine = [row(10, elapsed: 20, simstream, owner: 42), row(11, elapsed: 5, simstream, owner: 99)]
        // 保持者(pid 10)は自分のもの → 後から来た別ウィンドウのヘルパーが居ても false
        XCTAssertFalse(LocalStreamHolder.heldByOther(identity: sim, rows: mine, myOwner: 42))
        // 相手から見ると保持者は別人 → true(こちらが畳む側)
        XCTAssertTrue(LocalStreamHolder.heldByOther(identity: sim, rows: mine, myOwner: 99))
        // 誰も張っていない
        XCTAssertFalse(LocalStreamHolder.heldByOther(identity: sim, rows: [], myOwner: 42))
    }

    /// 所有の印がどちらかに無ければ別人(手で nohup したヘルパーの台に拡張は重ねない /
    /// CLI の監視から見たヘルパーは全部他人)
    func testMissingOwnerOnEitherSideCountsAsSomeoneElse() {
        let manual = [row(10, elapsed: 20, simstream)]
        XCTAssertTrue(LocalStreamHolder.heldByOther(identity: sim, rows: manual, myOwner: 42))
        let extensionOwned = [row(10, elapsed: 20, simstream, owner: 42)]
        XCTAssertTrue(LocalStreamHolder.heldByOther(identity: sim, rows: extensionOwned, myOwner: nil))
    }

    // MARK: - ps の読み

    func testParsesPsRowsIncludingEnvironmentTokens() {
        let output = """
            11380       09:51 /repo/.build/debug/fleetest-simstream --udid AAAA-1111 --fps 12 HOME=/Users/x FT_PARENT_PID=59440 LANG=C
              346 01-10:42:20 /sbin/launchd
            garbage line without numbers
            """
        let rows = LocalStreamHolder.parse(psOutput: output)
        XCTAssertEqual(rows.map(\.pid), [11380, 346])
        XCTAssertEqual(rows[0].elapsedSeconds, 9 * 60 + 51)
        XCTAssertEqual(rows[0].owner, 59440)
        XCTAssertEqual(rows[1].elapsedSeconds, ((1 * 24 + 10) * 60 + 42) * 60 + 20)
        XCTAssertNil(rows[1].owner)
        XCTAssertTrue(LocalStreamHolder.heldByOther(identity: sim, rows: rows, myOwner: 1))
        XCTAssertFalse(LocalStreamHolder.heldByOther(identity: sim, rows: rows, myOwner: 59440))
    }

    func testElapsedSecondsCoversEveryEtimeShape() {
        XCTAssertEqual(LocalStreamHolder.elapsedSeconds(etime: "00:05"), 5)
        XCTAssertEqual(LocalStreamHolder.elapsedSeconds(etime: "12:34:56"), 12 * 3600 + 34 * 60 + 56)
        XCTAssertEqual(LocalStreamHolder.elapsedSeconds(etime: "02-00:00:01"), 2 * 86400 + 1)
        XCTAssertNil(LocalStreamHolder.elapsedSeconds(etime: "abc"))
        XCTAssertNil(LocalStreamHolder.elapsedSeconds(etime: "1:2:3:4"))
    }

    func testMyOwnerReadsTheParentPidMark() {
        XCTAssertEqual(LocalStreamHolder.myOwner(environment: ["FT_PARENT_PID": "77"]), 77)
        XCTAssertNil(LocalStreamHolder.myOwner(environment: [:]))
        XCTAssertNil(LocalStreamHolder.myOwner(environment: ["FT_PARENT_PID": "x"]))
    }

    /// 実プロセスで1回: 本物のヘルパー(fleetest-devicepoll。自前のバイナリなので `ps -E` に env が載る。
    /// システムのバイナリは env を隠すのでシェルスクリプトや sleep では代用できない)を所有の印付きで
    /// 起こし、snapshot → 判定まで通す。宛先はブリッジの無いポート 1(実在の台と衝突しない。
    /// 接続失敗を 10 回数えるまで生きる = fps 0.1 で 100 秒)
    func testSnapshotSeesARealHelperWithItsOwnerMark() throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/fleetest-devicepoll")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("fleetest-devicepoll が .build/debug に無い(swift test が建てる product)")
            throw XCTSkip("binary missing")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--platform", "ios", "--host", "127.0.0.1", "--port", "1", "--fps", "0.1"]
        process.environment = ["FT_PARENT_PID": "424242", "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()  // 開いたまま = 終了指示を出さない
        process.standardInput = stdin
        try process.run()
        defer { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }

        let identity = LocalStreamHolder.DeviceIdentity.iosPhysical(port: 1)
        // ps に載るまで(起動直後)を短く待つ
        var rows: [Row] = []
        for _ in 0..<40 {
            rows = LocalStreamHolder.snapshot()
            if LocalStreamHolder.holder(for: identity, in: rows) != nil { break }
            usleep(100_000)
        }
        let holder = try XCTUnwrap(LocalStreamHolder.holder(for: identity, in: rows), "起こしたヘルパーが ps に見えない")
        XCTAssertEqual(holder.pid, process.processIdentifier)
        XCTAssertEqual(holder.owner, 424242, "env の FT_PARENT_PID が読めていない(自前バイナリなら ps -E に載る)")
        XCTAssertTrue(LocalStreamHolder.heldByOther(identity: identity, rows: rows, myOwner: 1))
        XCTAssertFalse(LocalStreamHolder.heldByOther(identity: identity, rows: rows, myOwner: 424242))
    }

    // MARK: - 配線

    /// 監視(`api monitor`)が LocalStreamHolder を通して streamedByOther を出している
    func testMonitorWiresTheLocalHolderIntoStreamedByOther() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiMonitorCommand.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("LocalStreamHolder.heldByOther("), "監視が手元の二重配信を判定していない")
        XCTAssertTrue(source.contains("LocalStreamHolder.snapshot()"), "ps の一覧を周期ごとに1回取っていない")
    }
}
