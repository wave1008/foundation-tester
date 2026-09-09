// fleetest-simstream の**生存 ping はアタッチより前に出る**ことを実バイナリで固定する。
//
// **実害 2026-09-09**: 消費側(vscode-fleetest の deviceStream.ts)は「15 秒 1 バイトも来なければ
// helper が固まった」と見て kill→再起動する。ところが CoreSimulator へのアタッチ
// (SimServiceContext / ioPorts / setPowerState)は dispatch_main より前の同期処理で、
// keepalive タイマーがまだ動いていない。起動ストームの最中はここが十数秒かかり、健全な helper が
// 繰り返し殺されていた(M1Ultra の6台で観測)。**デバイスを1台も要らずに**確かめられるよう、
// 実在しない UDID を渡して「アタッチに失敗する前に ping が出ているか」を見る。
//
// **リモートの台には手前にもう1段ある**: 拡張は `remote exec <host> -- api device-stream` を起こし、
// そのコマンドが向こうで宛先を解決してからヘルパーへ exec する。解決(determineStates)は起動
// ストームの最中に十数秒かかり、実測ではヘルパーが起きる前に 15 秒の期限が切れていた。
// よってその段でも ping を流す(`ApiDeviceStreamCommand` / `StreamResolvePing`)。

import XCTest
import FTCore

final class SimStreamAttachPingTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 実在しない UDID → helper はアタッチ段で終わる。それでも stdout には ping(KIND=3、10バイト、
    /// LEN=0)が1本出ていること。**これが無いと、遅いアタッチが「固まった」と誤判定される**
    func testEmitsAKeepalivePingBeforeAttachingEvenWhenTheDeviceIsMissing() throws {
        let binary = repoRoot().appendingPathComponent(".build/debug/fleetest-simstream")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            // 黙って skip にしない(素通りで緑になると、この砦が無いのと同じになる)
            XCTFail("fleetest-simstream が .build/debug に無い(swift build --product fleetest-simstream)")
            throw XCTSkip("binary missing")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--udid", "00000000-0000-0000-0000-0000DEADBEEF",
                             "--fps", "12", "--codec", "h264"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertGreaterThanOrEqual(data.count, 10,
                                    "アタッチ前に ping を出していない(stdout が \(data.count) バイト)")
        let header = [UInt8](data.prefix(10))
        XCTAssertEqual(header[0], 3, "KIND=3(ping)であること")
        XCTAssertEqual(Array(header[6...9]), [0, 0, 0, 0], "ping の LEN は 0")
    }

    /// mjpeg(v1)には ping レコードが無い。**h264 のときだけ出す**という条件を固定する
    /// (v1 に 10 バイトの謎レコードを流すとパーサが壊れる)
    func testMjpegDoesNotEmitAPing() throws {
        let binary = repoRoot().appendingPathComponent(".build/debug/fleetest-simstream")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("binary missing")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--udid", "00000000-0000-0000-0000-0000DEADBEEF",
                             "--fps", "12", "--codec", "mjpeg"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(data.count, 0, "v1(mjpeg)には ping レコードが無い")
    }
    /// リモート経路の手前の段(`api device-stream` の解決)でも ping が出る。
    /// **解決に失敗しても、失敗より前に 1 本出ている**ことを実バイナリで見る(デバイス不要)
    func testDeviceStreamEmitsAPingWhileResolvingTheTarget() throws {
        let binary = repoRoot().appendingPathComponent(".build/debug/fleetest")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("fleetest が .build/debug に無い(swift build --product fleetest)")
            throw XCTSkip("binary missing")
        }
        let out = try runDeviceStream(binary: binary, codec: "h264")
        XCTAssertGreaterThanOrEqual(out.count, 10, "解決の前に ping を出していない")
        XCTAssertEqual([UInt8](out.prefix(10)), [3, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                       "KIND=3・LEN=0 の ping レコードであること")
    }

    /// mjpeg(v1)には ping レコードが無いので、こちらでも出さない
    func testDeviceStreamDoesNotPingForMjpeg() throws {
        let binary = repoRoot().appendingPathComponent(".build/debug/fleetest")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("binary missing")
        }
        XCTAssertEqual(try runDeviceStream(binary: binary, codec: "mjpeg").count, 0)
    }

    /// 実在しないテストプロジェクトを指すので、解決は必ず失敗する(このホストの構成に依存しない)
    private func runDeviceStream(binary: URL, codec: String) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["api", "device-stream",
                             "--project", "no-such-project-\(UUID().uuidString)",
                             "--platform", "ios", "--name", "no-such-device", "--codec", codec]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0, "解決は失敗する前提のテスト")
        return data
    }
}
