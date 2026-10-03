// StillFrameMovieEncoder.swift
// 静止画方式の録画(物理 iPhone・動画を起動できなかったデバイス)で、別プロセスが `<epochMs>.png` で保存した静止画列を mp4 にする。
// AVFoundation のみ(外部プロセスなし)。各フレームは自分の時刻から次のフレームの時刻まで表示し、
// 最後のフレームは endAt まで保持する(endSession で尺を揃える。VideoRecordingFinalizer と同じ理屈)。
// 出力は VideoRecordingFinalizer.extractClip が後で利用者のビットレートで再エンコードする中間ソース。
// 失敗はすべて false を返すのみ(throw/crash しない)。

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

enum StillFrameMovieEncoder {

    /// 中間ソースのビットレート(bps)。静止画主体は圧縮が効き、後段 extractClip が利用者の
    /// ビットレートで再エンコードするため、画質を律する側ではなく十分に高い固定値でよい
    private static let sourceBitrate = 4_000 * 1000

    /// 1 回の append 待ちの上限(秒)。ソフトウェアエンコーダは大きい画面で 1 フレームに
    /// 数百 ms かかるが、秒単位の停止は異常。尽きたら writer を失敗扱いにして false を返す
    private static let readyTimeoutSeconds: Double = 30

    /// isReadyForMoreMediaData のポーリング間隔(ナノ秒)。10ms
    private static let readyPollNanos: UInt64 = 10_000_000

    /// endAt が最後のフレーム以前のとき、最後のフレームに与える表示時間(ms)
    private static let minLastFrameHoldMs = 1000

    /// dir 内の `<epochMs>.png` を時刻順に読む(名前が整数.png でないファイルは無視)
    static func frames(in dir: URL) -> [(at: Date, url: URL)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(ms: Int64, url: URL)] = []
        for url in urls where url.pathExtension.lowercased() == "png" {
            guard let ms = Int64(url.deletingPathExtension().lastPathComponent), ms >= 0 else { continue }
            out.append((ms, url))
        }
        out.sort { $0.ms < $1.ms }
        return out.map { (Date(timeIntervalSince1970: Double($0.ms) / 1000), $0.url) }
    }

    /// frames を [frames[0].at, endAt] の尺の mp4(H.264)として outputURL に書く。**原点は frames[0].at 固定**
    /// (先頭が復号できなくても動かさない —— 呼び手 StillFrameRecorder が segments の開始に frames[0].at を
    /// 使うので、ずらすと壁時計と動画内の位置が食い違う)。
    /// frame i は先頭からの相対時刻で表示を始め、最後のフレームは endAt まで保持する。
    /// 復号できないフレームと、時刻が前フレーム以前(同 ms・逆行)のフレームは読み飛ばす。
    /// **エンコーダはソフトウェア固定**: ハードウェアは writer 内部の VTCompressionSessionInvalidate から
    /// 戻らないことがある(理由と実測は VideoRecordingFinalizer.extractClip)
    static func encode(frames: [(at: Date, url: URL)], endAt: Date, to outputURL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: outputURL)

        func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

        // 先頭の復号できたフレームが出力サイズを決める
        var firstIndex = -1
        var firstImage: CGImage?
        for (i, f) in frames.enumerated() {
            if let img = autoreleasepool(invoking: { decode(f.url) }) {
                firstIndex = i
                firstImage = img
                break
            }
        }
        guard firstIndex >= 0, let first = firstImage else { return false }
        // H.264 は偶数サイズが必須
        let width = first.width - first.width % 2
        let height = first.height - first.height % 2
        guard width >= 2, height >= 2 else { return false }
        firstImage = nil

        let originMs = ms(frames[0].at)
        let lastMs = ms(frames[frames.count - 1].at) - originMs
        var endMs = ms(endAt) - originMs
        if endMs <= lastMs { endMs = lastMs + Int64(minLastFrameHoldMs) }

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: sourceBitrate],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        writer.startSession(atSourceTime: .zero)

        func fail() -> Bool {
            input.markAsFinished()
            writer.cancelWriting()
            // cancelWriting はファイルの削除を保証しない
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }

        var lastAppendedMs: Int64 = -1
        var appended = 0
        for f in frames[firstIndex...] {
            let t = ms(f.at) - originMs
            guard t > lastAppendedMs else { continue }
            // pool から取った buffer と復号画像を 1 フレームごとに解放する(長い run は数百枚)
            let buffer: CVPixelBuffer? = autoreleasepool {
                guard let img = decode(f.url) else { return nil }
                return render(img, width: width, height: height, adaptor: adaptor)
            }
            guard let pixelBuffer = buffer else { continue }

            var waited: Double = 0
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing || waited >= readyTimeoutSeconds { return fail() }
                try? await Task.sleep(nanoseconds: readyPollNanos)
                waited += Double(readyPollNanos) / 1_000_000_000
            }
            let pts = CMTime(value: CMTimeValue(t), timescale: 1000)
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else { return fail() }
            lastAppendedMs = t
            appended += 1
        }
        guard appended > 0 else { return fail() }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(endMs), timescale: 1000))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        return true
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// image を width x height の BGRA バッファへアスペクト維持・中央・黒背景で描く
    private static func render(_ image: CGImage, width: Int, height: Int,
                               adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        }
        if created == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        }
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * scale
        let h = Double(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2,
                                   width: w, height: h))
        return buffer
    }
}
