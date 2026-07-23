// VideoRecordingFinalizer.swift
// 録画のファイナライズは AVFoundation のみ(ffmpeg 等の外部プロセスは使わない契約)。
// iOS: .mov(simctl は bitrate 指定不可・フル解像度で約 6.6Mbps を吐く)→ 半分解像度+低 bitrate の
//   H.264 .mp4 へ再エンコード(VideoToolbox HW。Android の screenrecord 撮影時圧縮と同水準に揃える)。
// Android: セグメント .mp4 群(撮影時に圧縮済み)を AVMutableComposition で連結 → passthrough で 1 本へ。
// 失敗はすべて nil を返すのみ(呼び出し側が警告ログを出し、録画を破棄する。run は失敗させない)。

import AVFoundation
import CoreMedia
import Foundation

enum VideoRecordingFinalizer {

    /// 上限 bitrate(bps)。Android 側 screenrecord の --bit-rate と同値。UI はほぼ静止画のため
    /// 実効レートはこれを大きく下回る(H.264 のレート制御が undershoot する)
    private static let targetBitRate = 1_500_000

    /// 半分解像度+targetBitRate の H.264 .mp4 へ再エンコード。戻り値: 実 duration(ミリ秒)
    static func transcode(from sourceURL: URL, to outputURL: URL) async -> Int? {
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let duration = try? await asset.load(.duration), duration.isNumeric,
              duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              naturalSize.width >= 4, naturalSize.height >= 4 else { return nil }
        func halveEven(_ v: CGFloat) -> Int {
            let half = Int(v) / 2
            return half % 2 == 0 ? half : half - 1
        }

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return nil }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        guard reader.canAdd(readerOutput) else { return nil }
        reader.add(readerOutput)
        // 入力バッファ(フル解像度)と出力サイズの差は AVVideoScalingModeKey で writer 側が縮小する
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: halveEven(naturalSize.width),
            AVVideoHeightKey: halveEven(naturalSize.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: targetBitRate],
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { return nil }
        writer.add(writerInput)
        guard reader.startReading() else { return nil }
        guard writer.startWriting() else {
            reader.cancelReading()
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "ftester.video.transcode")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // requestMediaDataWhenReady のブロックは markAsFinished 後も呼ばれうるため、
            // resume の一回性は finished フラグで守る(ブロックは queue 上で直列)
            var finished = false
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard !finished else { return }
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        finished = true
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            return nil
        }
        // simctl の VFR 録画は「最後に画面が変化した時点」以降のフレームを持たない。endSession で
        // ソース duration まで最終フレームを保持させないと、末尾の静止区間が出力から消える
        // (実測: 11.1s ソース → endSession 無しだと 8.7s に縮む)
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return Int((duration.seconds * 1000).rounded())
    }

    /// セグメント群(開始順)を 1 本の .mp4 に連結する。戻り値: 各セグメントの実 duration(ミリ秒)。
    /// startedAt(壁時計)は呼び出し側が別途保持している値をこの配列と zip して使う
    static func concatenate(segmentURLs: [URL], to outputURL: URL) async -> [Int]? {
        guard !segmentURLs.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var durationsMs: [Int] = []
        var cursor = CMTime.zero
        for url in segmentURLs {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric,
                  duration.seconds > 0 else {
                durationsMs.append(0)
                continue
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            if let videoAssetTrack = try? await asset.loadTracks(withMediaType: .video).first {
                try? videoTrack.insertTimeRange(range, of: videoAssetTrack, at: cursor)
            }
            if let audioTrack, let audioAssetTrack = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: audioAssetTrack, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
            durationsMs.append(Int((duration.seconds * 1000).rounded()))
        }
        guard cursor.seconds > 0 else { return nil }
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetPassthrough) else {
            return nil
        }
        do {
            try await export.export(to: outputURL, as: .mp4)
        } catch {
            return nil
        }
        return durationsMs
    }
}
