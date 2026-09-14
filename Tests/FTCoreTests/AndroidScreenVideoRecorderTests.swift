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

    // MARK: - stop() と再 spawn の直列実行(§3 要調査「録画の再 spawn 中 stop」)
    //
    // actor は真の suspension でしか他ジョブに譲らないため、spawnNextSegment()/
    // handleSegmentExited() の中に await が無い限り、stop() はこの2つの間に割り込めない
    // (handleSegmentExited 直前のコメント参照)。デバイス無しで検証できるのはこの前提
    // (await が増えていないか)だけなので、実行時の振る舞いではなくソースを走査する

    private func recorderSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/AndroidScreenVideoRecorder.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// `signature` から始まり、同じ4スペース段の `}` で閉じるまでの行を返す(この実装は
    /// メソッド本体が常に4スペースインデントである前提。崩れたら空を返し呼び出し側で気付く)
    private func methodBody(signature: String, in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        guard let startIndex = lines.firstIndex(where: { $0.contains(signature) }) else { return [] }
        var body: [String] = []
        for line in lines[(startIndex + 1)...] {
            if line == "    }" { break }
            body.append(line)
        }
        return body
    }

    /// コメントを除いた「コード部分」だけ(`//` から行末を落とす)
    private func codeOnly(_ lines: [String]) -> [String] {
        lines.map { $0.components(separatedBy: "//")[0] }
    }

    /// spawnNextSegment() の `currentProcess = process`(nil の窓を閉じる代入)より**前**に
    /// await を足すと、その窓の間に stop() が割り込めてしまい孤児 screenrecord を残す
    /// (直前のコメント参照)。それより後ろ(`watchTask = Task { ... }` の中身)は別タスクとして
    /// 走るので、そこの await(exitStream 待ち等)は呼び出し元の suspend に無関係 —— 除外する
    func testSpawnNextSegmentHasNoSuspensionPointsBeforeReassigningCurrentProcess() throws {
        let body = methodBody(signature: "private func spawnNextSegment() async -> Bool {", in: try recorderSource())
        XCTAssertFalse(body.isEmpty, "spawnNextSegment() の本体を取れなかった(シグネチャ/インデントが変わった?)")
        guard let taskLineIndex = body.firstIndex(where: { $0.contains("watchTask = Task") }) else {
            XCTFail("`watchTask = Task` の行を見つけられなかった(構造が変わった?)")
            return
        }
        let synchronousPrefix = Array(body[..<taskLineIndex])
        let awaitLines = codeOnly(synchronousPrefix).filter { $0.contains("await") }
        XCTAssertEqual(awaitLines, [],
                       "currentProcess 再代入より前に await が増えた —— stop() とのレースが開く(直前のコメント参照)")
    }

    /// handleSegmentExited() の await は末尾の再 spawn 呼び出し1つだけのはず。
    /// 手前に await が挟まると、pull 完了後・再 spawn 前に stop() が割り込める窓ができる
    func testHandleSegmentExitedOnlyAwaitsTheFinalRespawn() throws {
        let body = methodBody(
            signature: "private func handleSegmentExited(remotePath: String, startedAt: Date) async {",
            in: try recorderSource())
        XCTAssertFalse(body.isEmpty, "handleSegmentExited() の本体を取れなかった(シグネチャ/インデントが変わった?)")
        let awaitLines = codeOnly(body).filter { $0.contains("await") }
        XCTAssertEqual(awaitLines.count, 1, "handleSegmentExited() の await の本数が変わった: \(awaitLines)")
        XCTAssertEqual(awaitLines.first?.trimmingCharacters(in: .whitespaces), "await spawnNextSegment()",
                       "handleSegmentExited() の唯一の await は末尾の再 spawn のはず")
    }
}
