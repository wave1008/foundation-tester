// ハードウェア動画エンコーダの死活台帳(VideoEncoderLiveness)と、切り出しでの使い方(VideoRecordingCoordinator)。
// 台帳は一時フォルダへ書く(本番の ~/.fleetest には触れない)。

import AVFoundation
import VideoToolbox
import XCTest
@testable import FTCore

final class VideoEncoderLivenessTests: XCTestCase {
    func testConstantsArePinned() {
        XCTAssertEqual(VideoEncoderLiveness.probeIntervalSeconds, 60)
        XCTAssertEqual(VideoEncoderLiveness.freshSeconds, 120)
        XCTAssertEqual(VideoEncoderLiveness.errorLimit, 200)
        XCTAssertEqual(HardwareEncoderProbe.size, 256)
        XCTAssertEqual(HardwareEncoderProbe.frames, 3)
        XCTAssertEqual(HardwareEncoderProbe.deadlineSeconds, 10)
        XCTAssertEqual(VideoEncoderHistory.maxBytes, 5_242_880)
    }

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

    /// 並行の追記で1件も失われないはず(flock + O_APPEND。seekToEnd → write は同じ位置へ上書きし合っていた)
    func testConcurrentHistoryAppendsKeepEveryLine() throws {
        let url = try tempLedger().deletingLastPathComponent().appendingPathComponent(VideoEncoderHistory.fileName)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for n in 0..<100 {
                VideoEncoderHistory.append(event: .callFailed, source: .call, detail: "\(worker)-\(n)", to: url)
            }
        }
        XCTAssertEqual(VideoEncoderHistory.read(at: url).count, 800)
    }

    /// 末尾の静止画だけに収まる区間(ソースの終わりより後)でも、最後のフレームでクリップを書くはず(0 フレームの成功を作らない)
    func testExtractClipBeyondTheSourceEndHoldsTheLastFrame() async throws {
        let dir = try tempLedger().deletingLastPathComponent()
        let source = dir.appendingPathComponent("source.mp4")
        try await Self.writeVideo(to: source, frames: 2, frameSeconds: 0.5)
        let output = dir.appendingPathComponent("tail.mp4")
        let ok = await VideoRecordingFinalizer.extractClip(sourceFiles: [RecordingClipSource(url: source)], clipStartMs: 2000, clipEndMs: 3000,
                                                           bitrateKbps: 1000, fullResolution: false, hardware: false,
                                                           to: output)
        XCTAssertTrue(ok)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.1, "区間長ぶん最後のフレームを保持するはず")
    }

    func testExtractClipKeepsTheStillTailBeforeTheNextSource() async throws {
        let dir = try tempLedger().deletingLastPathComponent()
        let first = dir.appendingPathComponent("first.mp4")
        let second = dir.appendingPathComponent("second.mp4")
        try await Self.writeVideo(to: first, frames: 2, frameSeconds: 1, fill: 64)
        try await Self.writeVideo(to: second, frames: 2, frameSeconds: 1, fill: 255)
        let output = dir.appendingPathComponent("joined.mp4")
        let ok = await VideoRecordingFinalizer.extractClip(
            sourceFiles: [RecordingClipSource(url: first, durationMs: 5000), RecordingClipSource(url: second, durationMs: 2000)],
            clipStartMs: 3000, clipEndMs: 7000, bitrateKbps: 1000, fullResolution: false, hardware: false, to: output)
        XCTAssertTrue(ok)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4.0, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(frames)
        XCTAssertTrue(reader.startReading())
        var pixels: [(at: Double, brightness: UInt8)] = []
        while let sample = frames.copyNextSampleBuffer() {
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let brightness = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).load(as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            pixels.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, brightness))
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(Double(try XCTUnwrap(pixels.first).brightness), 64, accuracy: 15, "先頭は第1素材の静止末尾")
        let changed = try XCTUnwrap(pixels.first { $0.brightness > 200 })
        XCTAssertEqual(changed.at, 2.0, accuracy: 0.1, "第2素材は静止末尾2秒の後から始まる")
    }

    /// 単色のフレームを frames 枚、frameSeconds 間隔で書いた H.264 の mp4(ソフトウェアのエンコーダ)
    static func writeVideo(to url: URL, frames: Int, frameSeconds: Double, fill: UInt8 = 0) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let image = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(image, [])
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(image)), Int32(fill), CVPixelBufferGetDataSize(image))
            CVPixelBufferUnlockBaseAddress(image, [])
            XCTAssertTrue(adaptor.append(image, withPresentationTime: CMTime(seconds: Double(i) * frameSeconds,
                                                                           preferredTimescale: 600)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: Double(frames) * frameSeconds, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}

