// XCUITestランナー内蔵HTTPサーバへのクライアント。AppDriver の iOS 実装。

import Foundation
import FTCore

public final class BridgeClient: AppDriver {
    let baseURL: URL
    let session: URLSession

    /// timeoutSeconds: 既定 120 秒(launch や snapshot は数秒かかることがある)。
    /// ポート範囲のスキャン(生存確認)には短い値を渡す
    public init(port: UInt16 = BridgeAPI.defaultPort, timeoutSeconds: TimeInterval = 120) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        self.session = URLSession(configuration: config)
    }

    // MARK: - AppDriver

    public func status() async throws -> StatusResponse {
        try await get("/status")
    }

    /// install は HTTP エンドポイントを持たず simctl の役割。/status のデバイス名から対象シミュレータを特定する
    public func install(packagePath: String) async throws {
        let current = try await status()
        let result = try Shell.run(["xcrun", "simctl", "install", current.device, packagePath])
        guard result.status == 0 else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "simctl install に失敗しました: \(result.tail)")
        }
    }

    public func launch(bundleID: String) async throws {
        let _: OKResponse = try await post("/session", body: LaunchRequest(bundleID: bundleID))
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await get("/snapshot")
    }

    public func tap(ref: Int) async throws {
        let _: OKResponse = try await post("/tap", body: TapRequest(ref: ref))
    }

    public func tap(x: Double, y: Double) async throws {
        let _: OKResponse = try await post("/tap", body: TapRequest(x: x, y: y))
    }

    public func type(ref: Int?, text: String) async throws {
        let _: OKResponse = try await post("/type", body: TypeRequest(ref: ref, text: text))
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        let _: OKResponse = try await post("/swipe", body: SwipeRequest(direction: direction))
    }

    public func press(ref: Int, duration: Double) async throws {
        let _: OKResponse = try await post("/press", body: PressRequest(ref: ref, duration: duration))
    }

    public func screenshot() async throws -> Data {
        let (data, response) = try await request(path: "/screenshot", method: "GET", body: nil)
        try Self.check(response: response, data: data)
        return data
    }

    public func terminate() async throws {
        let _: OKResponse = try await post("/terminate", body: OKResponse())
    }

    // MARK: - HTTP helpers

    func get<R: Decodable>(_ path: String) async throws -> R {
        let (data, response) = try await request(path: path, method: "GET", body: nil)
        try Self.check(response: response, data: data)
        return try JSONDecoder().decode(R.self, from: data)
    }

    func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        let bodyData = try JSONEncoder().encode(body)
        let (data, response) = try await request(path: path, method: "POST", body: bodyData)
        try Self.check(response: response, data: data)
        return try JSONDecoder().decode(R.self, from: data)
    }

    func request(path: String, method: String, body: Data?) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.httpBody = body
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
