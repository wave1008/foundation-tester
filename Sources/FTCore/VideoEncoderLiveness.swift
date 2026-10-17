// この機械のハードウェア動画エンコーダ(AppleAVE)が今**使える状態か**の、機械グローバルな台帳。
//
// 実測(M2 Ultra): run 完了時の切り出しの途中からハードウェアの書き出しが全部 -17691 で失敗するようになり、
// 合成映像の符号化も含めてマシン全体で戻らなかった(セッションを握るプロセスは無し・メモリは空いていた)。
// 切り出しはソフトウェアへのやり直しで取れるので run は気付かせない —— モニターに出すための台帳。
//
// 規律(FMLiveness と同じ向き。経路は1つなので FMLiveness の根拠・刻印の仕組みは持たない):
//  ① **生 / 死 / 不明の3値**。記録が無い・`freshSeconds` より古いは nil(不明)で、死と混ぜない
//  ② **書き手は根拠を名乗る**(`Source`)。実際の切り出しの1回の失敗は素材のせいかもしれないので
//     **死の根拠にしない** —— 失敗したら合成映像の確かめ(`HardwareEncoderProbe`)を撃ち、その結果を書く
//  ③ **新しい観測が勝つ**(書く前にディスクの checkedAt と比べる。読み→比較→rename は flock の内側)
//
// 置き場は ~/.fleetest/video-encoder-liveness.json(`FT_VIDEO_ENCODER_LIVENESS_DIR` で差し替え。テスト用)。
// 読み手: `api host-metrics`(NDJSON の videoEncoderState/videoEncoderError/videoEncoderCheckedAt → モニターのバッジ)・
// VideoRecordingCoordinator(新しい死ならハードウェアを撃たずにソフトウェアで切り出す)。
// 書き手: VideoRecordingCoordinator(実際の切り出しの成功・期限超過・失敗後の確かめ)と `api host-metrics --video-encoder-probe`。

import Foundation
import Synchronization
import VideoToolbox

public enum VideoEncoderLiveness {
    public enum State: String, Codable, Sendable {
        case alive
        case dead
    }

    public enum Source: String, Codable, Sendable {
        /// 実際の切り出し(成功・期限超過)
        case call
        /// 合成映像の確かめ(HardwareEncoderProbe)
        case probe
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public var state: State
        /// 観測した時刻(epoch 秒)
        public var checkedAt: Double
        public var source: Source
        /// 死のときの理由。生のときは nil(直っても前のエラーが残る形を作らない)
        public var error: String?

        public init(state: State, checkedAt: Double, source: Source, error: String? = nil) {
            self.state = state
            self.checkedAt = checkedAt
            self.source = source
            self.error = state == .dead ? error : nil
        }

        public func isFresh(now: Date = Date(), maxAge: TimeInterval = VideoEncoderLiveness.freshSeconds) -> Bool {
            let age = now.timeIntervalSince1970 - checkedAt
            return age < maxAge && age > -maxAge
        }
    }

    /// 確かめの間隔(秒)。故障は再起動まで戻らない形しか観測していないので FM(60 秒)と同じ刻みで足りる。
    /// 1回の確かめは 256x256 を数フレーム = 実測 50ms 未満
    public static let probeIntervalSeconds: TimeInterval = 60
    /// これより古い観測は「不明」。確かめの間隔の2倍 = 1回取りこぼしただけで不明にしない
    public static let freshSeconds: TimeInterval = 120
    /// 1Hz の NDJSON に載せる理由の長さ(FM の deadReasonLimit と同じ)
    public static let errorLimit = 200

    // MARK: - 置き場

    static let fileName = "video-encoder-liveness.json"
    static let lockFileName = "video-encoder-liveness.lock"

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["FT_VIDEO_ENCODER_LIVENESS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent(fileName)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true).appendingPathComponent(fileName)
    }

    /// 書き込み先。nil = 書かない(LedgerWriteRole で opt-in した production の実行ファイルだけが書く。FMLiveness と同じ門)
    static var writeURL: URL? {
        if let override = ProcessInfo.processInfo.environment["FT_VIDEO_ENCODER_LIVENESS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent(fileName)
        }
        guard LedgerWriteRole.permitsProductionWrite else { return nil }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return fileURL
    }

    // MARK: - 書く・読む

    /// 観測1件を書く。ディスクの記録より古ければ書かない(③)。書き込み失敗は握りつぶす(台帳のために切り出しも監視も止めない)
    public static func record(_ verdict: Verdict) {
        guard let url = writeURL else { return }
        guard let previous = write(verdict, to: url) else { return }
        // 変わり目だけ残す。生は「死から戻った」ときだけ(記録が無い状態からの生は兆候ではない)
        switch verdict.state {
        case .dead where previous != .dead:
            VideoEncoderHistory.append(event: .becameDead, source: verdict.source, detail: verdict.error)
        case .alive where previous == .dead:
            VideoEncoderHistory.append(event: .becameAlive, source: verdict.source, detail: nil)
        default:
            break
        }
    }

    /// 書いたら書く前の状態を返す(.some(nil) = 記録が無かった)。書かなかった(古い・失敗)なら nil
    @discardableResult
    static func write(_ verdict: Verdict, to url: URL) -> State?? {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(lockFileName).path, O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }  // close が flock も解放する
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { return nil }
        }
        let current = read(at: url)
        if let current, current.checkedAt > verdict.checkedAt { return nil }
        var stored = verdict
        stored.error = stored.error.map { String($0.prefix(errorLimit)) }
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        let tmp = dir.appendingPathComponent(".\(fileName).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        guard (try? data.write(to: tmp)) != nil else { return nil }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return .some(current?.state)
    }

    static func read(at url: URL) -> Verdict? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Verdict.self, from: data)
    }

    /// 鮮度を当てた読み。nil = 不明(死と混ぜない)
    public static func current(now: Date = Date()) -> Verdict? {
        current(at: fileURL, now: now)
    }

    static func current(at url: URL, now: Date) -> Verdict? {
        guard let verdict = read(at: url), verdict.isFresh(now: now) else { return nil }
        return verdict
    }

    /// 切り出しの前に読む門。**新しい死**のときだけ true(古い・不明・生はハードウェアで撃って確かめる)。
    /// 書き込み先を開けないプロセス(テスト)は本番の台帳を読まない(FMLiveness.isKnownDead と同じ理由)
    public static func isKnownDead(now: Date = Date()) -> Bool {
        guard let url = writeURL, let verdict = read(at: url), verdict.isFresh(now: now) else { return false }
        return verdict.state == .dead
    }

    /// host-metrics の確かめ(`--video-encoder-probe`)。台帳が `probeIntervalSeconds` より古いときだけ撃つ
    public static func refreshIfStale(now: Date = Date()) async {
        if let verdict = read(at: fileURL), now.timeIntervalSince1970 - verdict.checkedAt < probeIntervalSeconds,
           verdict.checkedAt <= now.timeIntervalSince1970 {
            return
        }
        guard let observed = await HardwareEncoderProbe.check() else { return }
        record(observed)
    }
}

/// 合成映像を数フレーム、ハードウェア必須の VTCompressionSession で符号化して確かめる。
/// **素材に依らない**(実際の切り出しの失敗が素材のせいかエンコーダのせいかを分ける)。
/// 注入: `FT_FAKE_VIDEO_ENCODER_DEAD=1` はハードウェアに触らずに死を返す(観測と公表の経路だけを通す)
public enum HardwareEncoderProbe {
    /// 符号化の大きさとフレーム数。小さすぎるとハードウェアが受けない形があるので 256 の正方形
    static let size = 256
    static let frames = 3
    /// 期限(秒)。ハードウェアは `VTCompressionSessionInvalidate` から戻らない固着がある(実測)。
    /// 正常時は 50ms 未満なので桁で余裕を見た値。超えたら死と書き、このプロセスでは以後撃たない
    /// (固着したセッションへ撃ち続けるとスレッドが積み上がる)
    public static let deadlineSeconds: Double = 10
    private static let hung = Mutex(false)

    /// 観測(生 / 死)。前回の確かめが固着したプロセスでは nil(撃たない = 不明。台帳は最後の死のまま古くなる)
    public static func check(now: @Sendable () -> Date = { Date() }) async -> VideoEncoderLiveness.Verdict? {
        if isInjectedDead(ProcessInfo.processInfo.environment) {
            return .init(state: .dead, checkedAt: now().timeIntervalSince1970, source: .probe,
                         error: "injected (FT_FAKE_VIDEO_ENCODER_DEAD=1)")
        }
        guard !hung.withLock({ $0 }) else { return nil }
        let result: String?? = await raceWithDeadline(seconds: deadlineSeconds, onTimeout: String??.none) {
            await Task.detached { encodeSynthetic() }.value
        }
        let checkedAt = now().timeIntervalSince1970
        guard let failure = result else {
            hung.withLock { $0 = true }
            return .init(state: .dead, checkedAt: checkedAt, source: .probe,
                         error: "the hardware encoder did not finish \(frames) synthetic frames within \(Int(deadlineSeconds))s")
        }
        return .init(state: failure == nil ? .alive : .dead, checkedAt: checkedAt, source: .probe, error: failure)
    }

    static func isInjectedDead(_ environment: [String: String]) -> Bool {
        environment["FT_FAKE_VIDEO_ENCODER_DEAD"] == "1"
    }

    /// nil = 全フレームが符号化できた。失敗は OSStatus を含む1文
    private static func encodeSynthetic() -> String? {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let created = VTCompressionSessionCreate(
            allocator: nil, width: Int32(size), height: Int32(size), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard created == noErr, let session else {
            return "could not create a hardware H.264 session (OSStatus \(created))"
        }
        defer { VTCompressionSessionInvalidate(session) }
        let failures = LockedValue<[OSStatus]>([])
        let encoded = LockedValue(0)
        for index in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { return "could not allocate a pixel buffer" }
            let submitted = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                    if status != noErr { failures.withLock { $0.append(status) } }
                    if status == noErr, sample != nil { encoded.withLock { $0 += 1 } }
                }
            if submitted != noErr { return "the hardware encoder refused a frame (OSStatus \(submitted))" }
        }
        let completed = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if let first = failures.withLock({ $0.first }) {
            return "the hardware encoder failed to encode synthetic frames (OSStatus \(first))"
        }
        if completed != noErr { return "the hardware encoder could not finish the frames (OSStatus \(completed))" }
        let count = encoded.withLock { $0 }
        return count == frames ? nil : "the hardware encoder produced \(count) of \(frames) frames"
    }
}
