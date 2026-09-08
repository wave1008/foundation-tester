import Foundation
import XCTest

import FTCore

final class AndroidScreencapTests: XCTestCase {

    /// `adb` の代わりに立てる実行可能な一時スクリプト。呼び出しごとに独立したディレクトリを返すので
    /// テストが並列実行されても衝突しない
    private func fakeADB(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-android-screencap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("adb")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testReturnsStdoutBytesOnSuccess() throws {
        let adb = try fakeADB("printf 'PNGDATA'")
        defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
        let data = AndroidScreencap.capturePNG(adb: adb.path, serial: "emulator-5554", timeout: 5)
        XCTAssertEqual(data, Data("PNGDATA".utf8))
    }

    /// **出力を出したうえで非0終了する**形で確かめる —— `exit 1` だけだと標準出力が空になり、
    /// 空データの検査だけで nil になるので `status` の検査を1度も通らない(変異が生き残る)。
    /// adb は端末が途中で消えると途中まで書いてから失敗するので、これが実際の危険な形
    func testNilOnNonZeroExitEvenWhenBytesWereWritten() throws {
        let adb = try fakeADB("printf 'PARTIAL'; exit 1")
        defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
        XCTAssertNil(AndroidScreencap.capturePNG(adb: adb.path, serial: "emulator-5554", timeout: 5))
    }

    /// status==0 でも出力が空なら成功と見なさない(すり抜けた空フレームをタイルへ配らない)
    func testNilOnEmptyOutputEvenWithSuccessStatus() throws {
        let adb = try fakeADB("exit 0")
        defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }
        XCTAssertNil(AndroidScreencap.capturePNG(adb: adb.path, serial: "emulator-5554", timeout: 5))
    }

    func testNilWhenTheExecutableDoesNotExist() {
        XCTAssertNil(AndroidScreencap.capturePNG(adb: "/no/such/adb", serial: "s", timeout: 5))
    }

    /// 引数の組み立てが `exec-out screencap -p` であることを固定する(実プロセスの起動有無に
    /// 依存せず、fake adb に自分へ渡された引数を記録させて確かめる)
    func testInvokesExecOutScreencapPWithTheGivenSerial() throws {
        let adb = try fakeADB(#"echo "$@" > "$(dirname "$0")/args.txt"; printf 'PNG'"#)
        let recorded = adb.deletingLastPathComponent().appendingPathComponent("args.txt")
        defer { try? FileManager.default.removeItem(at: adb.deletingLastPathComponent()) }

        _ = AndroidScreencap.capturePNG(adb: adb.path, serial: "R3CN123", timeout: 5)

        let args = try String(contentsOf: recorded, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(args, "-s R3CN123 exec-out screencap -p")
    }
}
