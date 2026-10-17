// Android の録画の撮り始めの確かめ(AndroidScreenVideoRecorder.confirmStarted / ensureRecording)を偽の adb で確かめる。
// 偽の adb は一時フォルダのシェルスクリプト: screenrecord は sleep で居座り、stat は mode に従って答える。

import XCTest
@testable import FTCore

final class AndroidScreenVideoRecorderConfirmTests: XCTestCase {
    private func fakeADB(mode: String) throws -> (dir: URL, adb: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetest-fake-adb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try mode.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let script = """
        #!/bin/bash
        D='\(dir.path)'
        mode=$(cat "$D/mode")
        if [ "$3" = shell ] && [ "$4" = screenrecord ]; then
          if [ "$mode" = generation ]; then
            remote="${!#}"; n="${remote##*-}"; n="${n%.mp4}"
          else
            n=$(( $(cat "$D/count" 2>/dev/null || echo 0) + 1 ))
          fi
          echo $n > "$D/count"; echo $$ > "$D/pid"; echo $$ > "$D/pid-$n"
          if [ "$mode" = generation ]; then
            if [ $n = 1 ]; then while [ ! -f "$D/exit1" ]; do sleep 0.01; done; exit 0; fi
            if [ $n = 2 ]; then sleep 0.05; exit 0; fi
          fi
          if [ "$mode" = rollover ] && [ $n = 1 ]; then sleep 1; exit 0; fi
          exec sleep 60
        elif [ "$3" = shell ] && [ "$4" = stat ]; then
          remote="${!#}"; n="${remote##*-}"; n="${n%.mp4}"
          case "$mode" in
            hang) exec sleep 5 ;;
            rollover) if [ "$n" = 1 ]; then echo 100; else echo 0; fi ;;
            generation)
              [ "$n" = 3 ] && touch "$D/stat3"
              if [ "$n" = 1 ] || { [ "$n" = 3 ] && [ -f "$D/ready3" ]; }; then echo 100; else echo 0; fi ;;
          esac
        elif [ "$3" = shell ]; then
          case "$4" in
            *pidof*)
              if [ "$mode" = generation ]; then
                case "$4" in
                  *ftrec-src-2.mp4*) [ -f "$D/pid-2" ] && kill "$(cat "$D/pid-2")" 2>/dev/null ;;
                  *) for file in "$D"/pid-*; do [ -f "$file" ] && kill "$(cat "$file")" 2>/dev/null; done ;;
                esac
              else
                [ -f "$D/pid" ] && kill "$(cat "$D/pid")" 2>/dev/null
              fi ;;
          esac
        elif [ "$3" = pull ]; then
          touch "$5"
        fi
        exit 0
        """
        let adb = dir.appendingPathComponent("adb")
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        addTeardownBlock {
            if let pid = try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), let value = Int32(pid) {
                kill(value, SIGKILL)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return (dir, adb.path)
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "fake adb did not reach \(url.lastPathComponent)")
    }

    /// adb の stat が応答しなくても、撮り始めの確かめは上限で終わるはず(stat に残り時間の期限を渡す)
    func testStartConfirmationIsBoundedEvenIfADBHangs() async throws {
        let (dir, adb) = try fakeADB(mode: "hang")
        let recorder = AndroidScreenVideoRecorder(serial: "fake", adbPath: adb, workDir: dir, fileStem: "src",
                                                  startConfirmLimit: 1)
        let started = Date()
        let ok = await recorder.start()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(ok, "撮り始めを確かめられなければ false のはず")
        XCTAssertLessThan(elapsed, 4, "stat が 5 秒応答しなくても上限 1 秒 + 後始末で戻るはず(\(elapsed)s)")
    }

    /// 3 分ごとの切り替えで撮り直したセグメントの確かめの途中に、ensureRecording は「撮れている」と言わないはず
    func testEnsureRecordingWaitsForTheConfirmationAfterARollover() async throws {
        let (dir, adb) = try fakeADB(mode: "rollover")
        let recorder = AndroidScreenVideoRecorder(serial: "fake", adbPath: adb, workDir: dir, fileStem: "src",
                                                  startConfirmLimit: 1.5)
        let started = await recorder.start()
        XCTAssertTrue(started, "1 本目は撮り始めを確かめられるはず")
        // 1 本目は 1 秒で終わり、撮り直した 2 本目は stat が 0 のまま(撮り始めない)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let recording = await recorder.ensureRecording()
        XCTAssertFalse(recording, "撮り始めを確かめられない録画を「撮れている」と言わないはず")
        _ = await recorder.stop()
    }

    func testOlderConfirmationCannotStrandTheNextSegmentsWaiter() async throws {
        let (dir, adb) = try fakeADB(mode: "generation")
        let recorder = AndroidScreenVideoRecorder(serial: "fake", adbPath: adb, workDir: dir, fileStem: "src",
                                                  fullResolution: true, startConfirmLimit: 3)
        addTeardownBlock { _ = await recorder.stop() }
        let started = await recorder.start()
        XCTAssertTrue(started)
        try Data().write(to: dir.appendingPathComponent("exit1"))
        try await waitForFile(dir.appendingPathComponent("stat3"))
        // 第2世代の確認が sleep から戻っても、第3世代はまだファイルを書き始めない。
        try await Task.sleep(nanoseconds: 400_000_000)
        let checking = Task { await recorder.ensureRecording() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try Data().write(to: dir.appendingPathComponent("ready3"))
        let result: Bool? = await raceWithDeadline(seconds: 2, onTimeout: nil) { await checking.value }
        _ = await recorder.stop()
        _ = await checking.value
        XCTAssertEqual(result, true, "第3世代の確認成功で戻り、その録画の終了までは待たない")
    }

    func testConfirmationWaitEndsWhenItsSegmentDies() async throws {
        let (dir, adb) = try fakeADB(mode: "generation")
        let recorder = AndroidScreenVideoRecorder(serial: "fake", adbPath: adb, workDir: dir, fileStem: "src",
                                                  fullResolution: true, startConfirmLimit: 5)
        addTeardownBlock { _ = await recorder.stop() }
        let started = await recorder.start()
        XCTAssertTrue(started)
        try Data().write(to: dir.appendingPathComponent("exit1"))
        try await waitForFile(dir.appendingPathComponent("stat3"))
        try await Task.sleep(nanoseconds: 400_000_000)
        let checking = Task { await recorder.ensureRecording() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let raw = try String(contentsOf: dir.appendingPathComponent("pid-3"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, SIGTERM), 0)
        let result: Bool? = await raceWithDeadline(seconds: 2, onTimeout: nil) { await checking.value }
        _ = await recorder.stop()
        _ = await checking.value
        XCTAssertEqual(result, false, "確認中の第3世代が死んだら、第4世代の確認を待たずに失敗する")
    }
}
