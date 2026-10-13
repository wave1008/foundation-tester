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

    /// 1 フレームの上限[バイト](`FramedUnixSocket.maxFrameBytes` と同じ値。根拠はそちら)
    public static let maxFrameBytes = FramedUnixSocket.maxFrameBytes

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

    // MARK: - フレーミング(FramedUnixSocket へ転送。テストと既存の呼び手がこの名前で使う)

    public static func frame(_ payload: Data) -> Data { FramedUnixSocket.frame(payload) }
    public static func payloadLength(header: Data) -> Int? { FramedUnixSocket.payloadLength(header: header) }
    public static func encode<T: Encodable>(_ value: T) throws -> Data { try FramedUnixSocket.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, fromFrame data: Data) throws -> T {
        try FramedUnixSocket.decode(type, fromFrame: data)
    }

    /// 置き場: `~/.fleetest/vision-<親 pid>.sock`(`MachineStateDirectory`)。sun_path は 104 バイト上限なので
    /// 短い名前にし、収まらなければ nil(補助を起こさない = 既存の経路のまま)
    public static func socketPath(parentPID: pid_t, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = MachineStateDirectory.url(home: home).appendingPathComponent("vision-\(parentPID).sock").path
        return FramedUnixSocket.fitsSunPath(path) ? path : nil
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
        let payload: Data
        do {
            let frame = try VisionHelperWire.encode(VisionHelperWire.Request(png: png))
            // ブロッキングの I/O で協調スレッドプールを塞がない(最大 `deadlineSeconds` 秒待つ)
            payload = try await FramedUnixSocket.exchangeAsync(path: socketPath, frame: frame, seconds: deadlineSeconds)
        } catch let failure as FramedUnixSocketError {
            // FindImage は VisionHelperError だけを救済の失敗として扱う(素通りさせると走査ごと例外で落ちる)
            switch failure {
            case .unavailable(let detail): throw VisionHelperError.unavailable(detail)
            case .frameTooLarge: throw VisionHelperError.frameTooLarge
            case .malformedFrame: throw VisionHelperError.malformedFrame
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
