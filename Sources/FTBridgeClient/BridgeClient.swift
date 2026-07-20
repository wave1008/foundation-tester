// XCUITestランナー内蔵HTTPサーバへのクライアント。AppDriver の iOS 実装。

import Foundation
import FTCore

public final class BridgeClient: AppDriver {
    let baseURL: URL
    let session: URLSession
    /// per-endpoint の壁時計上限(秒)。既定は Timeout.interaction/session。
    /// テスト seam(下の internal init)経由でのみ短縮注入できる
    let interactionTimeout: TimeInterval
    let sessionTimeout: TimeInterval

    /// per-endpoint の壁時計上限(秒)の既定値。init の 120 は未指定エンドポイントのフォールバック。
    /// URLRequest.timeoutInterval で config の既定を1リクエスト単位に上書きする
    enum Timeout {
        static let interaction: TimeInterval = 20  // tap/swipe/type/press/drag
        // snapshot は a11y ツリー直列化で並列飽和時に伸びるため session 側に置く(誤爆回避)
        static let session: TimeInterval = 45      // launch/activate/screenshot/status/terminate/snapshot/appswitcher/home
    }

    /// timeoutSeconds: 既定 120 秒(launch や snapshot は数秒かかることがある)。
    /// ポート範囲のスキャン(生存確認)には短い値を渡す
    public convenience init(port: UInt16 = BridgeAPI.defaultPort, timeoutSeconds: TimeInterval = 120) {
        self.init(port: port, timeoutSeconds: timeoutSeconds,
                  interactionTimeout: Timeout.interaction, sessionTimeout: Timeout.session)
    }

    /// テスト専用 seam: interaction/session の予算を短縮注入する(未応答ブリッジのタイムアウト
    /// 検証等)。公開 init(port:timeoutSeconds:) はこれを既定予算付きで呼ぶだけで公開 API は不変
    init(port: UInt16, timeoutSeconds: TimeInterval = 120,
        interactionTimeout: TimeInterval, sessionTimeout: TimeInterval) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        self.session = URLSession(configuration: config)
        self.interactionTimeout = interactionTimeout
        self.sessionTimeout = sessionTimeout
    }

    // MARK: - AppDriver

    public func status() async throws -> StatusResponse {
        try await get("/status", timeout: sessionTimeout)
    }

    /// 短いタイムアウトでの /status プローブ。バックグラウンドで iOS に suspend された in-app
    /// アプリは TCP 接続は受理するが応答しないため、既定 sessionTimeout(45s)では無限待ちになる。
    /// 呼び出し側は無応答を「不明」として扱う(engine=inapp/hybrid の注入先判定を参照)。
    /// 確実に短時間で切るため config 側も短くした BridgeClient から呼ぶこと。
    public func status(timeout: TimeInterval) async throws -> StatusResponse {
        try await get("/status", timeout: timeout)
    }

    /// install は HTTP エンドポイントを持たず simctl の役割。/status のデバイス名から対象シミュレータを
    /// 特定する。同名デバイス(Shutdown の複製等)があると名前指定 simctl は失敗するため、
    /// Booted かつ同名の UDID に解決してから実行する(解決不能時は名前のまま試す)。
    public func install(packagePath: String) async throws {
        let current = try await status()
        let target = (try? SimulatorCatalog.devices())?
            .first(where: { $0.booted && $0.name == current.device })?.udid ?? current.device
        let result = try Shell.run(["xcrun", "simctl", "install", target, packagePath])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl install に失敗しました: \(result.tail)")
        }
    }

    public func launch(bundleID: String) async throws {
        let _: OKResponse = try await post("/session", body: LaunchRequest(bundleID: bundleID),
                                           timeout: sessionTimeout)
    }

    public func activate(bundleID: String) async throws {
        let _: OKResponse = try await post("/session", body: LaunchRequest(bundleID: bundleID, activate: true),
                                           timeout: sessionTimeout)
    }

    public func openAppSwitcher() async throws {
        let _: OKResponse = try await post("/appswitcher", body: OKResponse(),
                                           timeout: sessionTimeout)
    }

    public func home() async throws {
        let _: OKResponse = try await post("/home", body: OKResponse(),
                                           timeout: sessionTimeout)
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await get("/snapshot", timeout: sessionTimeout)
    }

    public func tap(ref: Int) async throws {
        let _: OKResponse = try await post("/tap", body: TapRequest(ref: ref),
                                           timeout: interactionTimeout)
    }

    public func tap(x: Double, y: Double) async throws {
        let _: OKResponse = try await post("/tap", body: TapRequest(x: x, y: y),
                                           timeout: interactionTimeout)
    }

    public func type(ref: Int?, text: String) async throws {
        let _: OKResponse = try await post("/type", body: TypeRequest(ref: ref, text: text),
                                           timeout: interactionTimeout)
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        let _: OKResponse = try await post("/swipe", body: SwipeRequest(direction: direction),
                                           timeout: interactionTimeout)
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        let _: OKResponse = try await post("/drag", body: DragRequest(
            fromX: fromX, fromY: fromY, toX: toX, toY: toY,
            press: pressSeconds, duration: durationSeconds),
            timeout: interactionTimeout)
    }

    public func press(ref: Int, duration: Double) async throws {
        let _: OKResponse = try await post("/press", body: PressRequest(ref: ref, duration: duration),
                                           timeout: interactionTimeout)
    }

    public func press(x: Double, y: Double, duration: Double) async throws {
        let _: OKResponse = try await post("/press", body: PressRequest(x: x, y: y, duration: duration),
                                           timeout: interactionTimeout)
    }

    public func screenshot() async throws -> Data {
        let (data, response) = try await request(path: "/screenshot", method: "GET", body: nil,
                                                 timeout: sessionTimeout)
        try Self.check(response: response, data: data)
        return data
    }

    public func terminate() async throws {
        let _: OKResponse = try await post("/terminate", body: OKResponse(),
                                           timeout: sessionTimeout)
    }

    public struct DeviceLocaleResponse: Decodable, Sendable {
        public let changed: Bool
        public let locale: String
    }

    /// システムロケールの永続変更。Android ブリッジのみ対応(iOS ブリッジは 404。
    /// 同期相手: AndroidRunner/src/.../BridgeRouter.java handleLocale)
    public func setDeviceLocale(_ locale: String) async throws -> DeviceLocaleResponse {
        struct LocaleRequest: Encodable { let locale: String }
        return try await post("/locale", body: LocaleRequest(locale: locale),
                              timeout: sessionTimeout)
    }

    // MARK: - HTTP helpers

    func get<R: Decodable>(_ path: String, timeout: TimeInterval? = nil) async throws -> R {
        let (data, response) = try await request(path: path, method: "GET", body: nil, timeout: timeout)
        try Self.check(response: response, data: data)
        return try JSONDecoder().decode(R.self, from: data)
    }

    func post<B: Encodable, R: Decodable>(_ path: String, body: B,
                                          timeout: TimeInterval? = nil) async throws -> R {
        let bodyData = try JSONEncoder().encode(body)
        let (data, response) = try await request(path: path, method: "POST", body: bodyData,
                                                 timeout: timeout)
        try Self.check(response: response, data: data)
        return try JSONDecoder().decode(R.self, from: data)
    }

    func request(path: String, method: String, body: Data?,
                 timeout: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.httpBody = body
        if let timeout { req.timeoutInterval = timeout }
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            return try await session.data(for: req)
        } catch {
            if DriverError.isDefiniteDeliveryFailure(error) {
                throw DriverError.bridgeConnectionRefused(error.localizedDescription)
            }
            throw DriverError.bridgeUnreachable(error.localizedDescription)
        }
    }

    static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                message = err.error
            } else {
                message = String(data: data, encoding: .utf8) ?? "<binary>"
            }
            throw DriverError.badResponse(status: http.statusCode, body: message)
        }
    }
}
