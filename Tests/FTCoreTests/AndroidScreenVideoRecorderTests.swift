// Android 録画が止める screenrecord は**自分のぶんだけ**(AndroidScreenVideoRecorder.killOwnScreenrecordCommand)。
// `kill -2 $(pidof screenrecord)` の無差別形はモニターのライブ配信(fleetest-androidstream の
// `screenrecord --output-format=h264`)まで落とし、録画の開始/停止のたびに映像が切れていた。

import XCTest
@testable import FTCore

final class AndroidScreenVideoRecorderTests: XCTestCase {

    private static let blanketKill = "$(pidof screenrecord)"

    func testKillCommandSelectsByOwnOutputPrefix() {
        let prefix = AndroidScreenVideoRecorder.ownOutputPrefix(fileStem: "src-abc")
        let command = AndroidScreenVideoRecorder.killOwnScreenrecordCommand(outputPathPrefix: prefix)

        XCTAssertTrue(command.contains("'/sdcard/ftrec-src-abc-'"), "接頭辞をクォートして grep に渡す: \(command)")
        XCTAssertTrue(command.contains("pidof screenrecord"), "候補は pidof で列挙する: \(command)")
        XCTAssertTrue(command.contains("/proc/$p/cmdline"), "選別は /proc/<pid>/cmdline: \(command)")
        XCTAssertTrue(command.contains("grep -qF"), "接頭辞は固定文字列として照合する: \(command)")
        XCTAssertTrue(command.contains("&& kill -2 $p"), "一致した pid だけに SIGINT: \(command)")
        XCTAssertFalse(command.contains(Self.blanketKill), "無差別 kill に戻っている: \(command)")
        XCTAssertFalse(command.contains("kill -2 $(pidof"), "無差別 kill に戻っている: \(command)")
        XCTAssertFalse(command.contains("--output-format"), "配信の印で選んではいけない: \(command)")
    }

    func testKillCommandEscapesSingleQuotesInPrefix() {
        let command = AndroidScreenVideoRecorder.killOwnScreenrecordCommand(outputPathPrefix: "/sdcard/ftrec-it's-")
        XCTAssertTrue(command.contains("'/sdcard/ftrec-it'\\''s-'"), "シングルクォートは '\\'' で閉じて開く: \(command)")
    }

    /// stop が使う接頭辞は spawn が使うセグメントパスの接頭辞と一致していないと、自分の録画が止まらない
    func testSegmentPathStartsWithOwnPrefixAndRecorderRoot() {
        let stem = "src-android-1"
        let path = AndroidScreenVideoRecorder.remoteSegmentPath(fileStem: stem, index: 3)
        XCTAssertEqual(path, "/sdcard/ftrec-src-android-1-3.mp4")
        XCTAssertTrue(path.hasPrefix(AndroidScreenVideoRecorder.ownOutputPrefix(fileStem: stem)))
        XCTAssertTrue(path.hasPrefix(AndroidScreenVideoRecorder.remoteOutputPrefix),
                      "stale 掃除(killStaleScreenrecord)は remoteOutputPrefix で選ぶので、セグメントもその下に置く")
        XCTAssertFalse(AndroidScreenVideoRecorder.remoteOutputPrefix.isEmpty)
        XCTAssertTrue(AndroidScreenVideoRecorder.remoteOutputPrefix.hasPrefix("/"),
                      "空や相対の接頭辞は cmdline のどこにでも一致してしまう")
    }

    /// 無差別形をソースから締め出す(コメントは除く)
    func testNoBlanketPidofKillRemainsInRecorderSource() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/AndroidScreenVideoRecorder.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        var offenders: [Int] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let code = line.components(separatedBy: "//")[0]
            if code.contains(Self.blanketKill) { offenders.append(index + 1) }
        }
        XCTAssertEqual(offenders, [], "AndroidScreenVideoRecorder.swift に無差別の pidof kill が残っている(行: \(offenders))")
    }
}
