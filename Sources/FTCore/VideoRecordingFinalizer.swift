// VideoRecordingFinalizer.swift
// 録画のファイナライズは AVFoundation のみ(ffmpeg 等の外部プロセスは使わない契約)。
// ワーカー単位の生ソース(iOS: simctl の .mov 1本 / Android: screenrecord セグメント mp4 群)から、
// シナリオ(テスト関数)ごとの壁時計区間を 1 クリップとして切り出す。
// VFR ソース(simctl/screenrecord とも「画面が変化した時だけ」フレームを吐く)の罠:
// 区間の開始時刻ちょうどにフレームが無い場合、区間開始より前の最後のサンプルを
// 区間開始時刻に retime して先頭フレームとして追加する。writer の startSession/endSession で
// 出力を 0 起点・区間長ちょうどに揃える(末尾静止保持の理屈は旧 transcode 実装から継承)。
// 失敗はすべて false を返すのみ(呼び出し側が警告ログを出し、そのクリップを諦める。run は失敗させない)。

import AVFoundation
import CoreMedia
import Foundation

struct RecordingClipSource: Sendable {
    let url: URL
    /// 連結時の尺(ms)。録画終了までの静止末尾を含む。nil はファイルの尺を使う。
    let durationMs: Int?

    init(url: URL, durationMs: Int? = nil) {
        self.url = url
        self.durationMs = durationMs
    }
}

enum VideoRecordingFinalizer {

    /// この値(width/height の大きい方)を超えるソースだけ半分解像度にする(fullResolution:false 時)。
    /// Android の screenrecord ソースは wm size 由来で既に半分解像度で録っているため、無条件に
    /// 半分化すると二重縮小になる。実測: iOS simctl はフル解像度 1206x2622(→半分化する)、
    /// Android 半分済みソースは 540x1212(→そのまま)。縦長画面の縦辺で判定されるため両者の間の
    /// 1600 を閾値にする(900 だと Android の縦 1212 が超過して二重縮小になる実害があった)
    private static let shrinkThreshold: CGFloat = 1600

    /// sourceFiles(連結順。要素数 1 で単一ファイルのケースも含む)の [clipStartMs, clipEndMs) を
    /// 切り出し、bitrateKbps*1000 bps の H.264 .mp4 として書き出す。fullResolution:false(既定)なら
    /// shrinkThreshold より大きいソースだけ半分解像度にする(true なら常にソース解像度のまま)。
    /// clipStartMs/clipEndMs はソース内(gapless)の位置(RecordingWallClock.offsetMs 参照)。
    /// hardware: true = ハードウェアエンコーダ(AppleAVE)を**必須**にする(無ければ失敗 = 黙ってソフトウェアに落ちない)。
    /// ハードウェアは AVAssetWriter の内部でセッションを閉じる `VTCompressionSessionInvalidate` から戻らないことがある
    /// (実測: 12 秒クリップ 16 本×8 回で 2 回)ので、呼び手は短い期限を付けて固着したらソフトウェアへ切り替える
    /// (VideoRecordingCoordinator.hardwareDeadline)。ソフトウェアは別プロセス(VTEncoderXPCService)で動き、
    /// 総処理量が並列度でほぼ増えない(実測は VideoRecordingCoordinator.maxConcurrentExports)
    static func extractClip(sourceFiles: [RecordingClipSource], clipStartMs: Int, clipEndMs: Int,
                            bitrateKbps: Int, fullResolution: Bool, hardware: Bool,
                            to outputURL: URL) async -> Bool {
        guard clipEndMs > clipStartMs, !sourceFiles.isEmpty else { return false }
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        var cursor = CMTime.zero
        let lastFrameReach = CMTime(value: 1, timescale: 1000)
        for source in sourceFiles {
            let asset = AVURLAsset(url: source.url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0,
                  let track = try? await asset.loadTracks(withMediaType: .video).first else { return false }
            let range = CMTimeRange(start: .zero, duration: duration)
            do { try compositionTrack.insertTimeRange(range, of: track, at: cursor) }
            catch { return false }
            let covered = source.durationMs.map { CMTime(value: Int64($0), timescale: 1000) } ?? duration
            if covered > duration {
                // 次の素材を連結する前に、この素材の最後の1msを静止末尾の長さまで伸ばす。
                let reach = CMTimeMinimum(lastFrameReach, duration)
                let tailStart = CMTimeAdd(cursor, CMTimeSubtract(duration, reach))
                compositionTrack.scaleTimeRange(CMTimeRange(start: tailStart, duration: reach),
                                               toDuration: CMTimeAdd(reach, CMTimeSubtract(covered, duration)))
            }
            cursor = CMTimeAdd(cursor, CMTimeMaximum(duration, covered))
        }
        guard cursor.seconds > 0,
              let naturalSize = try? await compositionTrack.load(.naturalSize),
              naturalSize.width >= 4, naturalSize.height >= 4 else { return false }

        let scale: CGFloat = (!fullResolution && max(naturalSize.width, naturalSize.height) > shrinkThreshold)
            ? 0.5 : 1.0
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
        // 区間だけを読む。無いと毎回ソースの先頭から全フレームを復号して区間前を捨てるので、クリップ数 × 録画長の
        // 二乗になる(実測: 1台で56本の run = 元録画 13 分で、終盤は1本 40 秒・切り出しだけで 15 分前後)。
        // 区間頭を覆うフレームは PTS を区間開始に揃えて1枚目に来る(静止区間でもその1枚)= 下の
        // pendingBeforeClip の付け替えと同じ結果(実録画で確認: 300 秒地点 12.4s → 0.56s・静止区間 34s → 0.03s)
        // 区間の開始がソースの終わり以降(静止画の末尾だけに収まる区間 = 呼び手は clipStart/clipEnd をソースの外へ伸ばす)なら、
        // 最後のフレームを覆う位置から読む = 下の pendingBeforeClip の付け替えでその1枚が区間の頭に来る。ソースの中では区間から読む
        let readStart = clipStart < cursor ? clipStart : CMTimeMaximum(.zero, CMTimeSubtract(cursor, lastFrameReach))
        reader.timeRange = CMTimeRange(start: readStart, end: CMTimeMaximum(clipEnd, CMTimeAdd(readStart, lastFrameReach)))
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: scaledEven(naturalSize.width),
            AVVideoHeightKey: scaledEven(naturalSize.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrateKbps * 1000],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: hardware,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: hardware,
            ],
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)
        // 失敗した書きかけは index が参照しないまま結果ディレクトリに溜まるため、以降の失敗経路は
        // すべて outputURL を消してから return する
        guard reader.startReading() else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        writer.startSession(atSourceTime: clipStart)

        let queue = DispatchQueue(label: "fleetest.video.extractClip")
        // 区間開始より前の最後のサンプル(pendingBeforeClip)を区間開始時刻に retime して先頭へ、
        // 以降は区間内サンプルをそのまま append する(VFR で区間頭にフレームが無い罠への対処)。
        let state = ClipExtractionState(writerInput: writerInput, readerOutput: readerOutput)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // requestMediaDataWhenReady のブロックは markAsFinished 後も呼ばれうるため、
            // resume の一回性は finished フラグで守る(ブロックは queue 上で直列に走るので lock は要らない)
            state.writerInput.requestMediaDataWhenReady(on: queue) { [state] in
                while state.writerInput.isReadyForMoreMediaData {
                    guard !state.finished else { return }
                    guard let sample = state.readerOutput.copyNextSampleBuffer() else {
                        // 区間内に 1 サンプルも無い(区間中ずっと画面静止)場合、区間前の最後の
                        // フレームで静止クリップを作る(何も append しないと writer が失敗する)
                        if !state.enteredClip, let pending = state.pendingBeforeClip,
                           let retimed = retimed(pending, to: clipStart) {
                            state.appended += state.writerInput.append(retimed) ? 1 : 0
                        }
                        state.finished = true
                        state.writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if pts < clipStart {
                        state.pendingBeforeClip = sample
                        continue
                    }
                    if !state.enteredClip {
                        state.enteredClip = true
                        if let pending = state.pendingBeforeClip, let retimed = retimed(pending, to: clipStart) {
                            state.appended += state.writerInput.append(retimed) ? 1 : 0
                        }
                    }
                    if pts >= clipEnd {
                        state.finished = true
                        state.reachedClipEnd = true
                        state.writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    state.appended += state.writerInput.append(sample) ? 1 : 0
                }
            }
        }
        if state.reachedClipEnd {
            reader.cancelReading()
        } else if reader.status != .completed {
            // 散発的な切り出し失敗の診断用(status/error が唯一の手掛かり)
            ConsoleOut.err(
                "⚠️ [recording] extractClip reader failed: status=\(reader.status.rawValue) "
                 + "error=\(String(describing: reader.error))")
            writer.cancelWriting()
            // cancelWriting はファイルの削除を保証しないため明示的に消す
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        // 1 フレームも書けなかった(区間に覆うフレームが無い)出力は 0 バイトの mp4 になるのに writer は completed を返す
        // = 成功と数えない(再生できないクリップを index に載せない)
        guard state.appended > 0 else {
            ConsoleOut.err("⚠️ [recording] extractClip wrote no frames for \(clipStartMs)..\(clipEndMs)ms")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        // simctl/screenrecord の VFR ソースは「最後に画面が変化した時点」以降のフレームを持たない。
        // endSession で区間終了時刻まで最終フレームを保持させないと末尾の静止区間が出力から消える
        // (実測: 11.1s ソース → endSession 無しだと 8.7s に縮む。旧 transcode 実装からの継承)
        writer.endSession(atSourceTime: clipEnd)
        await writer.finishWriting()
        if writer.status != .completed {
            ConsoleOut.err(
                "⚠️ [recording] extractClip writer failed: status=\(writer.status.rawValue) "
                 + "error=\(String(describing: writer.error))")
            try? FileManager.default.removeItem(at: outputURL)
        }
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

/// requestMediaDataWhenReady のブロックが捕捉する可変状態(finished/enteredClip/reachedClipEnd/
/// pendingBeforeClip)と AV オブジェクトを1つに束ねる。ブロックは queue 上で直列に走るので lock は要らない。
private final class ClipExtractionState: @unchecked Sendable {
    let writerInput: AVAssetWriterInput
    let readerOutput: AVAssetReaderTrackOutput
    var finished = false
    var enteredClip = false
    var reachedClipEnd = false
    var pendingBeforeClip: CMSampleBuffer?
    /// 書けたサンプル数(0 なら失敗 = 空の mp4 を成功にしない)
    var appended = 0

    init(writerInput: AVAssetWriterInput, readerOutput: AVAssetReaderTrackOutput) {
        self.writerInput = writerInput
        self.readerOutput = readerOutput
    }
}
