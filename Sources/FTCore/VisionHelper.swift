// Vision の特徴量を長寿命の補助プロセス(`fleetest api vision-serve`)に計算させる救済の、通信とクライアント側。
// 設計と実測の根拠は docs/maintainer-notes.md §67。
//
// 使うのは**異常を検知した走査のやり直しの1回だけ**(`FindImage.retryingTransientAnomalies` の rescueSource)。
// 平常時の走査はこのファイルに一切触れない。**門(isDegenerate / isConsistent)は補助プロセスの値にもそのまま掛かる**
// (`FindImage.match` が特徴量の出どころを問わず通す)。補助が無い・答えない・unhealthy なら例外 = 既存の待ち直しへ落ちる。
//
// 同期相手: サーバは VisionHelperServer.swift・起動は VisionHelperHost.swift・コマンドは Sources/fleetest/ApiVisionServeCommand.swift。

import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum VisionHelperWire {
    /// シナリオのプロセスへソケットのパスを渡す環境変数(`ScenarioHost.childEnvironment` が載せる)
    public static let socketEnvironmentKey = "FT_VISION_HELPER_SOCKET"

    /// 1 フレームの上限[バイト]。要求は PNG 1 枚(a11y の枠の切り出しか見本。全画面でも数 MB)・応答は特徴量 1 つ(約 10 KB 台)。
    /// 32 MiB はそのどちらよりも桁で大きい = 正常な要求は弾かず、壊れた長さ(読み違い)でメモリを食い尽くさない
    public static let maxFrameBytes = 32 * 1024 * 1024

    /// 1 要求(接続から応答まで)の期限[秒]。**実測した値ではない**: 健全な特徴量は 2〜3 枚で約 20ms(`FindImage.prewarmBudget` の doc)、
    /// 補助は要求を 1 件ずつ処理し 10 本のシナリオが並行して撃つので最悪待ち 10 件 ≒ 数百 ms〜1 秒、その約 5 倍の余裕を取る。
    /// **尽きたら補助を諦めて既存の待ち直し(計 15.5 秒)へ落ちる** = 最悪でも走査につき 1 回しか払わない(最初の失敗で救済を打ち切る)。
    /// 補助が刺さっていても 5 秒 + 15.5 秒を超えない
    public static let requestDeadlineSeconds: Double = 5

    public struct Request: Codable, Equatable {
        public var png: Data
        public init(png: Data) { self.png = png }
    }

    public struct Response: Codable {
        public enum Status: String, Codable {
            /// `print` が入っている
            case ok
            /// 補助プロセス自身の Vision が健全でない(暖機中・白紙との縮退・測り直しの不一致)。値は返さない
            case unhealthy
            /// 要求が壊れている・画像として読めない・Vision の例外(`detail` に文言)
            case failed
        }
        public var status: Status
        public var print: FeaturePrintObservation?
        public var detail: String?
        public init(status: Status, print: FeaturePrintObservation? = nil, detail: String? = nil) {
            self.status = status
            self.print = print
            self.detail = detail
        }
    }

    // MARK: - フレーミング(長さ前置き: 4 バイト big endian + JSON)

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    /// 先頭 4 バイトの長さ。上限を超える・4 バイトに満たなければ nil
    public static func payloadLength(header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard Int(length) <= maxFrameBytes else { return nil }
        return Int(length)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maxFrameBytes else { throw VisionHelperError.frameTooLarge }
        return frame(payload)
    }

    /// `encode` の逆(長さ前置きごと)。長さが実際の本体と食い違えば投げる
    public static func decode<T: Decodable>(_ type: T.Type, fromFrame data: Data) throws -> T {
        guard let length = payloadLength(header: data.prefix(4)), data.count == 4 + length else {
            throw VisionHelperError.malformedFrame
        }
        return try JSONDecoder().decode(type, from: data.dropFirst(4))
    }

    // MARK: - ソケット(POSIX の薄い包み。クライアントとサーバで共有)

    /// 置き場: `~/.fleetest/vision-<親 pid>.sock`(`MachineStateDirectory`)。sun_path は 104 バイト上限なので
    /// 短い名前にし、収まらなければ nil(補助を起こさない = 既存の経路のまま)
    public static func socketPath(parentPID: pid_t, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = MachineStateDirectory.url(home: home).appendingPathComponent("vision-\(parentPID).sock").path
        return path.utf8.count < sunPathCapacity ? path : nil
    }

    static var sunPathCapacity: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) }

    static func withAddress<R>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < sunPathCapacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func setTimeouts(_ fd: Int32, seconds: Double) {
        let whole = Int(seconds)
        var timeout = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// ちょうど `count` バイト読む。EOF・タイムアウト・`deadline` 超過は nil
    static func readExactly(_ fd: Int32, count: Int, deadline: Date) -> Data? {
        var data = Data(count: count)
        var received = 0
        while received < count {
            guard Date() < deadline else { return nil }
            let n = data.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: received), count - received)
            }
            if n > 0 { received += n; continue }
            if n < 0, errno == EINTR { continue }
            return nil
        }
        return data
    }

    /// 長さ前置きの 1 フレームの本体を読む。長さが上限を超えれば nil
    static func readPayload(_ fd: Int32, deadline: Date) -> Data? {
        guard let header = readExactly(fd, count: 4, deadline: deadline),
              let length = payloadLength(header: header) else { return nil }
        if length == 0 { return Data() }
        return readExactly(fd, count: length, deadline: deadline)
    }

    static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
        var sent = 0
        while sent < data.count {
            guard Date() < deadline else { return false }
            let n = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
}

public enum VisionHelperError: Error, CustomStringConvertible {
    /// 繋がらない・答えない・期限切れ(`detail` に事実)
    case unavailable(String)
    /// 補助プロセス自身の Vision が健全でない(暖機中を含む)
    case unhealthy
    /// 補助が要求を処理できなかった(`detail` は補助の文言)
    case failed(String)
    case frameTooLarge
    case malformedFrame

    public var description: String {
        switch self {
        case .unavailable(let detail): return "the Vision helper process is unavailable (\(detail))"
        case .unhealthy: return "the Vision helper process reported its own Vision as unhealthy"
        case .failed(let detail): return "the Vision helper process could not compute the print (\(detail))"
        case .frameTooLarge: return "the Vision helper frame is larger than the limit"
        case .malformedFrame: return "the Vision helper frame is malformed"
        }
    }
}

/// シナリオのプロセスから補助プロセスへ特徴量を計算させる(要求ごとに接続して使い切る)
public struct VisionHelperClient: Sendable {
    public let socketPath: String
    public var deadlineSeconds: Double

    public init(socketPath: String, deadlineSeconds: Double = VisionHelperWire.requestDeadlineSeconds) {
        self.socketPath = socketPath
        self.deadlineSeconds = deadlineSeconds
    }

    /// 環境変数が無い(= 補助を起こしていない run)なら nil
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> VisionHelperClient? {
        guard let path = environment[VisionHelperWire.socketEnvironmentKey], !path.isEmpty else { return nil }
        return VisionHelperClient(socketPath: path)
    }

    public func featurePrint(_ image: CGImage) async throws -> FeaturePrintObservation {
        guard let png = Self.pngData(image) else { throw VisionHelperError.failed("the image could not be encoded as PNG") }
        let frame = try VisionHelperWire.encode(VisionHelperWire.Request(png: png))
        let path = socketPath
        let seconds = deadlineSeconds
        // ブロッキングの I/O で協調スレッドプールを塞がない(最大 `deadlineSeconds` 秒待つ)
        let payload: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.exchange(path: path, frame: frame, seconds: seconds) })
            }
        }
        let response = try JSONDecoder().decode(VisionHelperWire.Response.self, from: payload)
        switch response.status {
        case .ok:
            guard let print = response.print else { throw VisionHelperError.malformedFrame }
            return print
        case .unhealthy: throw VisionHelperError.unhealthy
        case .failed: throw VisionHelperError.failed(response.detail ?? "no detail")
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func exchange(path: String, frame: Data, seconds: Double) throws -> Data {
        let deadline = Date().addingTimeInterval(seconds)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VisionHelperError.unavailable("socket: errno \(errno)") }
        defer { close(fd) }
        VisionHelperWire.setTimeouts(fd, seconds: seconds)
        // connect だけは SO_SNDTIMEO が効かないので、非ブロッキングで繋いで poll で期限を置く
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connected = VisionHelperWire.withAddress(path: path) { address, length in connect(fd, address, length) }
        guard let connected else { throw VisionHelperError.unavailable("socket path too long") }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else {
                throw VisionHelperError.unavailable("connect: errno \(errno)")
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, Int32(seconds * 1000)) == 1 else { throw VisionHelperError.unavailable("connect timed out") }
            var soError: Int32 = 0
            var soLength = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLength)
            guard soError == 0 else { throw VisionHelperError.unavailable("connect: errno \(soError)") }
        }
        _ = fcntl(fd, F_SETFL, flags)
        guard VisionHelperWire.writeAll(fd, frame, deadline: deadline) else {
            throw VisionHelperError.unavailable("the request could not be written")
        }
        guard let payload = VisionHelperWire.readPayload(fd, deadline: deadline) else {
            throw VisionHelperError.unavailable("no answer within \(seconds) seconds")
        }
        return payload
    }
}

extension FindImage {
    /// 特徴量の計算元。走査(`match`)は見本・白紙・候補の切り出しの特徴量をすべてここから得る
    /// (出どころが違っても門は同じに掛かる)
    public struct PrintSource: Sendable {
        /// 出どころの名前(テストが走査の計算元を見分ける)
        public let label: String
        let compute: @Sendable (CGImage) async throws -> FeaturePrintObservation
        public init(label: String, compute: @escaping @Sendable (CGImage) async throws -> FeaturePrintObservation) {
            self.label = label
            self.compute = compute
        }

        /// このプロセスの Vision(既定)
        public static let inProcess = PrintSource(label: "in-process") { image in
            if VisionAnomalyInjection.isActive() { return try await VisionAnomalyInjection.degeneratePrint() }
            return try await FindImage.featurePrint(image)
        }

        /// 長寿命の補助プロセスの Vision
        public static func helper(_ client: VisionHelperClient) -> PrintSource {
            PrintSource(label: "helper") { try await client.featurePrint($0) }
        }
    }
}

/// 陽性対照の注入: `FT_FAKE_VISION_ANOMALY=1` のとき、このプロセスの特徴量(`PrintSource.inProcess`)は
/// どの画像にも一色の画像の特徴量を返す = 壊れた Vision と同じ形(門の測り直しが控えと食い違う)。
/// 補助プロセスの値には効かせない(救済が本物の値で門を通ることを端から端まで確かめるため)。
/// デバイスには触らない。暖機(`FindImage+Prewarm`)は `featurePrint` を直接呼ぶので対象外
public enum VisionAnomalyInjection {
    public static let environmentKey = "FT_FAKE_VISION_ANOMALY"

    public static func isActive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    static func degeneratePrint() async throws -> FeaturePrintObservation {
        let side = 32
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VisionHelperError.unhealthy
        }
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = ctx.makeImage() else { throw VisionHelperError.unhealthy }
        return try await FindImage.featurePrint(image)
    }
}
