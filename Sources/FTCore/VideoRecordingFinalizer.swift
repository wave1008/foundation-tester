// VideoRecordingFinalizer.swift
// 録画のファイナライズは AVFoundation のみ(ffmpeg 等の外部プロセスは使わない契約)。
// ワーカー単位の生ソース(iOS: simctl の .mov 1本 / Android: screenrecord セグメント mp4 群)から、
// シナリオ(テスト関数)ごとの壁時計区間を 1 クリップとして切り出す。
// VFR ソース(simctl/screenrecord とも「画面が変化した時だけ」フレームを吐く)の罠:
// 区間の開始時刻ちょうどにフレームが無いことがほとんどのため、reader は毎回ソース全域を
// 読み直し(使い捨て。全域読みなおしのコストは許容)、区間開始より前の最後のサンプルを
// 区間開始時刻に retime して先頭フレームとして追加する。writer の startSession/endSession で
// 出力を 0 起点・区間長ちょうどに揃える(末尾静止保持の理屈は旧 transcode 実装から継承)。
// 失敗はすべて false を返すのみ(呼び出し側が警告ログを出し、そのクリップを諦める。run は失敗させない)。

import AVFoundation
import CoreMedia
import Foundation

enum VideoRecordingFinalizer {

    /// 上限 bitrate(bps)。Android 側 screenrecord の --bit-rate と同値。UI はほぼ静止画のため
    /// 実効レートはこれを大きく下回る(H.264 のレート制御が undershoot する)
    private static let targetBitRate = 1_500_000
    /// この値(width/height の大きい方)を超えるソースだけ半分解像度にする。Android の screenrecord
    /// ソースは wm size 由来で既に半分解像度で録っているため、無条件に半分化すると二重縮小になる。
    /// 実測: iOS simctl はフル解像度 1206x2622(→半分化する)、Android 半分済みソースは
    /// 540x1212(→そのまま)。縦長画面の縦辺で判定されるため両者の間の 1600 を閾値にする
    /// (900 だと Android の縦 1212 が超過して二重縮小になる実害があった)
    private static let shrinkThreshold: CGFloat = 1600

    /// sourceFiles(連結順。要素数 1 で単一ファイルのケースも含む)の [clipStartMs, clipEndMs) を
    /// 切り出し、半分解像度(既定より大きい場合のみ)+targetBitRate の H.264 .mp4 として書き出す。
    /// clipStartMs/clipEndMs はソース内(gapless)の位置(RecordingWallClock.offsetMs 参照)
    static func extractClip(sourceFiles: [URL], clipStartMs: Int, clipEndMs: Int,
                            to outputURL: URL) async -> Bool {
        guard clipEndMs > clipStartMs, !sourceFiles.isEmpty else { return false }
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        var cursor = CMTime.zero
        for url in sourceFiles {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0,
                  let track = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try? compositionTrack.insertTimeRange(range, of: track, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }
        guard cursor.seconds > 0,
              let naturalSize = try? await compositionTrack.load(.naturalSize),
              naturalSize.width >= 4, naturalSize.height >= 4 else { return false }

        let scale: CGFloat = max(naturalSize.width, naturalSize.height) > shrinkThreshold ? 0.5 : 1.0
        func scaledEven(_ v: CGFloat) -> Int {
            let scaled = Int(v * scale)
            return scaled % 2 == 0 ? scaled : scaled - 1
        }

        let clipStart = CMTime(value: CMTimeValue(clipStartMs), timescale: 1000)
        let clipEnd = CMTime(value: CMTimeValue(clipEndMs), timescale: 1000)

        guard let reader = try? AVAssetReader(asset: composition),
              let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return false }
        let readerOutput = AVAssetReaderTrackOutput(track: compositionTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: scaledEven(naturalSize.width),
            AVVideoHeightKey: scaledEven(naturalSize.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: targetBitRate],
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)
        guard reader.startReading() else { return false }
        guard writer.startWriting() else {
            reader.cancelReading()
            return false
        }
        writer.startSession(atSourceTime: clipStart)

        let queue = DispatchQueue(label: "ftester.video.extractClip")
        // 区間開始より前の最後のサンプル(pendingBeforeClip)を区間開始時刻に retime して先頭へ、
        // 以降は区間内サンプルをそのまま append する(VFR で区間頭にフレームが無い罠への対処)。
        var finished = false
        var enteredClip = false
        var reachedClipEnd = false
        var pendingBeforeClip: CMSampleBuffer?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // requestMediaDataWhenReady のブロックは markAsFinished 後も呼ばれうるため、
            // resume の一回性は finished フラグで守る(ブロックは queue 上で直列)
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard !finished else { return }
                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        // 区間内に 1 サンプルも無い(区間中ずっと画面静止)場合、区間前の最後の
                        // フレームで静止クリップを作る(何も append しないと writer が失敗する)
                        if !enteredClip, let pending = pendingBeforeClip,
                           let retimed = retimed(pending, to: clipStart) {
                            writerInput.append(retimed)
                        }
                        finished = true
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if pts < clipStart {
                        pendingBeforeClip = sample
                        continue
                    }
                    if !enteredClip {
                        enteredClip = true
                        if let pending = pendingBeforeClip, let retimed = retimed(pending, to: clipStart) {
                            writerInput.append(retimed)
                        }
                    }
                    if pts >= clipEnd {
                        finished = true
                        reachedClipEnd = true
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    writerInput.append(sample)
                }
            }
        }
        if reachedClipEnd {
            reader.cancelReading()
        } else if reader.status != .completed {
            writer.cancelWriting()
            return false
        }
        // simctl/screenrecord の VFR ソースは「最後に画面が変化した時点」以降のフレームを持たない。
        // endSession で区間終了時刻まで最終フレームを保持させないと末尾の静止区間が出力から消える
        // (実測: 11.1s ソース → endSession 無しだと 8.7s に縮む。旧 transcode 実装からの継承)
        writer.endSession(atSourceTime: clipEnd)
        await writer.finishWriting()
        return writer.status == .completed
    }

    private static func retimed(_ sample: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: newPTS, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}
