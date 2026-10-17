// ハードウェア動画エンコーダの死活台帳(VideoEncoderLiveness)と、切り出しでの使い方(VideoRecordingCoordinator)。
// 台帳は一時フォルダへ書く(本番の ~/.fleetest には触れない)。

import XCTest
@testable import FTCore

final class VideoEncoderLivenessTests: XCTestCase {
    private func tempLedger() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetest-encoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(VideoEncoderLiveness.fileName)
    }

    /// 生 / 死 / 不明の3値。記録が無い・古いは不明(死と混ぜない)
    func testUnknownWhenMissingOrStale() throws {
        let url = try tempLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(VideoEncoderLiveness.current(at: url, now: now))
        VideoEncoderLiveness.write(.init(state: .dead, checkedAt: now.timeIntervalSince1970 - 121, source: .probe,
                                         error: "x"), to: url)
        XCTAssertNil(VideoEncoderLiveness.current(at: url, now: now), "120 秒より古い観測は不明のはず")
        VideoEncoderLiveness.write(.init(state: .dead, checkedAt: now.timeIntervalSince1970 - 10, source: .probe,
                                         error: "x"), to: url)
        XCTAssertEqual(VideoEncoderLiveness.current(at: url, now: now)?.state, .dead)
    }

    /// 古い観測で新しい観測を上書きしない
    func testOlderObservationDoesNotOverwrite() throws {
        let url = try tempLedger()
        VideoEncoderLiveness.write(.init(state: .dead, checkedAt: 200, source: .probe, error: "broken"), to: url)
        VideoEncoderLiveness.write(.init(state: .alive, checkedAt: 100, source: .call), to: url)
        XCTAssertEqual(VideoEncoderLiveness.read(at: url)?.state, .dead)
        VideoEncoderLiveness.write(.init(state: .alive, checkedAt: 300, source: .call), to: url)
        XCTAssertEqual(VideoEncoderLiveness.read(at: url)?.state, .alive)
    }

    /// 生には理由を残さない・理由は NDJSON 用に切り詰める
    func testErrorIsDroppedWhenAliveAndTruncatedWhenDead() throws {
        let url = try tempLedger()
        XCTAssertNil(VideoEncoderLiveness.Verdict(state: .alive, checkedAt: 1, source: .call, error: "stale").error)
        VideoEncoderLiveness.write(.init(state: .dead, checkedAt: 1, source: .probe,
                                         error: String(repeating: "e", count: 500)), to: url)
        XCTAssertEqual(VideoEncoderLiveness.read(at: url)?.error?.count, VideoEncoderLiveness.errorLimit)
    }

    func testInjectionOnlyWithExactValue() {
        XCTAssertTrue(HardwareEncoderProbe.isInjectedDead(["FT_FAKE_VIDEO_ENCODER_DEAD": "1"]))
        XCTAssertFalse(HardwareEncoderProbe.isInjectedDead(["FT_FAKE_VIDEO_ENCODER_DEAD": "0"]))
        XCTAssertFalse(HardwareEncoderProbe.isInjectedDead([:]))
    }

    /// NDJSON の3欄は不明でも必ず出す(拡張は欠けた行を捨てる)
    func testHostMetricsSampleAlwaysCarriesEncoderKeys() throws {
        let unknown = try XCTUnwrap(HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil, fmCalls: nil, fmFailures: nil,
            fmTotalMs: nil, visionCalls: nil, visionFailures: nil, visionTotalMs: nil, ocrCompiling: 0).encodedLine())
        XCTAssertTrue(unknown.contains(#""videoEncoderState":null"#), unknown)
        XCTAssertTrue(unknown.contains(#""videoEncoderError":null"#), unknown)
        XCTAssertTrue(unknown.contains(#""videoEncoderCheckedAt":null"#), unknown)
        let dead = try XCTUnwrap(HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil, fmCalls: nil, fmFailures: nil,
            fmTotalMs: nil, visionCalls: nil, visionFailures: nil, visionTotalMs: nil, ocrCompiling: 0,
            videoEncoder: .init(state: .dead, checkedAt: 5, source: .probe, error: "OSStatus -17691")).encodedLine())
        XCTAssertTrue(dead.contains(#""videoEncoderState":"dead""#), dead)
        XCTAssertTrue(dead.contains(#""videoEncoderError":"OSStatus -17691""#), dead)
        XCTAssertTrue(dead.contains(#""videoEncoderCheckedAt":5"#), dead)
    }

    /// 書き込みは書く前の状態を返す(変わり目を履歴へ書く判断の材料)。古い観測は書かない = nil
    func testWriteReturnsThePreviousState() throws {
        let url = try tempLedger()
        let first = VideoEncoderLiveness.write(.init(state: .alive, checkedAt: 100, source: .probe), to: url)
        XCTAssertEqual(first, .some(nil), "記録が無ければ .some(nil)")
        let second = VideoEncoderLiveness.write(.init(state: .dead, checkedAt: 200, source: .probe, error: "x"), to: url)
        XCTAssertEqual(second, .some(.alive))
        let stale = VideoEncoderLiveness.write(.init(state: .alive, checkedAt: 150, source: .call), to: url)
        XCTAssertNil(stale, "古い観測は書かないはず")
    }

    /// 履歴は追記で、起動の識別子・起動からの経過・出来事・理由を持つ
    func testHistoryAppendsLines() throws {
        let url = try tempLedger().deletingLastPathComponent().appendingPathComponent(VideoEncoderHistory.fileName)
        VideoEncoderHistory.append(event: .callFailed, source: .call, detail: "S0010", to: url,
                                   now: Date(timeIntervalSince1970: 1_800_000_000), uptime: 1500)
        VideoEncoderHistory.append(event: .becameDead, source: .probe, detail: "OSStatus -17691", to: url,
                                   now: Date(timeIntervalSince1970: 1_800_000_010), uptime: 1510)
        let lines = VideoEncoderHistory.read(at: url)
        XCTAssertEqual(lines.map(\.event), [.callFailed, .becameDead])
        XCTAssertEqual(lines.map(\.uptimeSeconds), [1500, 1510])
        XCTAssertEqual(lines.last?.detail, "OSStatus -17691")
        XCTAssertFalse(lines.first?.boot.isEmpty ?? true)
    }

    /// 配信の数え方: h264 の Simulator 配信だけを数える(mjpeg・Android の配信・名前だけ似たものは数えない)
    func testLiveEncodeStreamsCountsOnlyH264SimulatorStreams() {
        let ps = """
        /repo/.build/out/Products/Debug/fleetest-simstream --udid A --fps 12 --max-width 960 --codec h264
        /repo/.build/out/Products/Debug/fleetest-simstream --udid B --fps 12 --max-width 960
        /repo/.build/out/Products/Debug/fleetest-simstream --udid D --codec mjpeg
        /repo/.build/out/Products/Debug/fleetest-androidstream --serial emulator-5554 --codec h264
        /bin/zsh -c grep fleetest-simstream --codec h264
        /repo/.build/out/Products/Debug/fleetest-simstream --udid C --codec h264
        """
        XCTAssertEqual(LiveEncodeStreams.count(psOutput: ps), 2)
    }
}

