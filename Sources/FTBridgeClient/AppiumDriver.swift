// PoC: Appium(WDA/UiAutomator2)経由の AppDriver 実装。既存の BridgeClient(iOS)/AndroidDriver との
// ベンチマーク比較用。W3C WebDriver セッション+Actions API のみで駆動する(Appium 拡張コマンドは
// mobile: execute script 経由)。

import Foundation
import FTCore

public final class AppiumDriver: AppDriver {

    public static let defaultServerURL = "http://127.0.0.1:4723"

    public static func resolveServerURL(override: String? = nil) -> String {
        override ?? ProcessInfo.processInfo.environment["FT_APPIUM_URL"] ?? defaultServerURL
    }

    private let platform: String
    private let udid: String?
    private let serial: String?
    private let bundleID: String
    private let serverURL: String
    private let appPath: String?
    private let repoRoot: URL
    private let session: URLSession

    private enum Timeout {
        static let normal: TimeInterval = 30
        /// WDA/UiAutomator2 の初回起動(セッション作成)は数十秒〜3分かかりうる
        static let sessionCreate: TimeInterval = 180
        static let probe: TimeInterval = 8
    }

    private var cachedSessionId: String?
    private var refCenters: [Int: (x: Double, y: Double, identifier: String?, label: String?)] = [:]
    private var lastScreen: FTRect?

    public init(platform: String, udid: String? = nil, serial: String? = nil, bundleID: String,
                serverURL: String = AppiumDriver.defaultServerURL, appPath: String? = nil,
                repoRoot: URL) {
        self.platform = platform
        self.udid = udid
        self.serial = serial
        self.bundleID = bundleID
        self.serverURL = serverURL
        self.appPath = appPath
        self.repoRoot = repoRoot
        let config = URLSessionConfiguration.ephemeral
        self.session = URLSession(configuration: config)
    }

    // MARK: - セッション永続化

    private struct PersistedSession: Codable {
        var sessionId: String
    }

    private var sessionFileURL: URL {
        let suffix = udid ?? serial ?? "default"
        return repoRoot.appendingPathComponent(".ftester/appium/session-\(suffix).json")
    }

    private func loadPersistedSessionId() -> String? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let persisted = try? JSONDecoder().decode(PersistedSession.self, from: data) else { return nil }
        return persisted.sessionId
    }

    private func persistSessionId(_ id: String) {
        let dir = sessionFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(PersistedSession(sessionId: id)) {
            try? data.write(to: sessionFileURL)
        }
    }

    private func discardSession() async {
        // サーバ側にも DELETE を投げる: サーバ上のセッション記録だけ生きて WDA/UiAutomator2 が
        // 死んでいる状態(掃除等でランナーだけ落とされた場合)を放置すると、同一 udid への
        // 新規セッション作成が古い残骸と衝突しうる。失敗しても続行(best effort)。
        // 罠: 生きているセッションを DELETE した直後の CREATE は appium-ios-simulator が
        // シミュレータを Shutdown しようとして 15s タイムアウトすることがある(iOS 27 beta 実測。
        // createSession 側の1回リトライが受け皿)
        if let sessionId = cachedSessionId ?? loadPersistedSessionId() {
            _ = try? await rawRequest(path: "/session/\(sessionId)", method: "DELETE",
                                      jsonBody: nil, timeout: Timeout.normal)
        }
        cachedSessionId = nil
        tunedSettingsApplied = false  // 新セッションには設定が引き継がれないため再適用が必要
        try? FileManager.default.removeItem(at: sessionFileURL)
    }

    /// メモリキャッシュがあれば即返す(ネットワーク往復ゼロ)。ProfileWorkerFactory が status() を
    /// デッドラインなしで1回呼んでコールドスタート(セッション作成、最大180秒)を先に済ませておき、
    /// RunOrchestrator.runWorker はその後 status() を10秒デッドラインで呼ぶ(Sources/FTCore/RunOrchestrator.swift)。
    /// この2段構えが成立するのはキャッシュ済みなら ensureSession() が実質ノーオペになるからで、
    /// status() が本メソッドをスキップすると2回目の呼び出しでもコールドスタート待ちが起きうる。
    private func ensureSession() async throws -> String {
        if let cachedSessionId { return cachedSessionId }

        if let persistedId = loadPersistedSessionId() {
            if await isSessionAlive(persistedId) {
                cachedSessionId = persistedId
                await applyTunedSettingsIfNeeded(sessionId: persistedId)
                return persistedId
            }
            await discardSession()  // ゾンビセッションをサーバごと破棄してから作り直す
        }

        let newId = try await createSession()
        cachedSessionId = newId
        persistSessionId(newId)
        await applyTunedSettingsIfNeeded(sessionId: newId)
        return newId
    }

    /// FT_APPIUM_TUNED=1(ベンチの appium-tuned 変種)のとき、XCUITest の整定待ちを無効化する
    /// 設定をセッションへ適用する。採用(再利用)と新規作成のどちらの経路でも1回だけ適用。
    /// 失敗しても続行(ベストエフォート)。discardSession がフラグを戻し、再作成セッションにも再適用される
    private var tunedSettingsApplied = false

    private func applyTunedSettingsIfNeeded(sessionId: String) async {
        guard !tunedSettingsApplied, platform == "ios",
              ProcessInfo.processInfo.environment["FT_APPIUM_TUNED"] == "1" else { return }
        let settings: [String: Any] = ["waitForIdleTimeout": 0, "animationCoolOffTimeout": 0]
        _ = try? await rawRequest(path: "/session/\(sessionId)/appium/settings", method: "POST",
                                  jsonBody: ["settings": settings], timeout: Timeout.normal)
        tunedSettingsApplied = true
    }

    /// /appium/settings はサーバ内で完結し WDA/UiAutomator2 の死を検知できない(実害あり:
    /// ランナーだけ死んだセッションを「生存」と誤判定して全コマンドが proxy エラーになった)。
    /// /window/rect はデバイス側サーバまで往復するのでプローブはこちらを使う
    private func isSessionAlive(_ sessionId: String) async -> Bool {
        guard let url = URL(string: "\(serverURL)/session/\(sessionId)/window/rect") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = Timeout.probe
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private func createSession(isRetry: Bool = false) async throws -> String {
        var alwaysMatch: [String: Any] = [
            "appium:noReset": true,
            "appium:newCommandTimeout": 0,  // 常駐再利用のためアイドル切断を無効化
        ]
        // Dictionary<String, Any> の subscript に String? を直接代入すると nil が
        // Optional<String>.none として Any に包まれたまま残り JSONSerialization が失敗する。
        // 必ず if let で有無を分けてから代入すること
        if platform == "ios" {
            alwaysMatch["platformName"] = "iOS"
            alwaysMatch["appium:automationName"] = "XCUITest"
            if let udid { alwaysMatch["appium:udid"] = udid }
            alwaysMatch["appium:bundleId"] = bundleID
            alwaysMatch["appium:wdaLaunchTimeout"] = 180000
            // WDA チューニング比較用(ベンチの appium-tuned 変種が環境変数で注入):
            // usePrebuiltWDA=ビルド済み WDA を再利用(build-for-testing をスキップ)、
            // wdaLocalPort=ポート固定、webDriverAgentUrl=事前起動した常駐 WDA へ直結(xcodebuild 全回避)
            let env = ProcessInfo.processInfo.environment
            if env["FT_APPIUM_USE_PREBUILT_WDA"] == "1" {
                alwaysMatch["appium:usePrebuiltWDA"] = true
            }
            if let port = env["FT_APPIUM_WDA_LOCAL_PORT"].flatMap({ Int($0) }) {
                alwaysMatch["appium:wdaLocalPort"] = port
            }
            if let wdaURL = env["FT_APPIUM_WDA_URL"], !wdaURL.isEmpty {
                alwaysMatch["appium:webDriverAgentUrl"] = wdaURL
            }
        } else {
            alwaysMatch["platformName"] = "Android"
            alwaysMatch["appium:automationName"] = "UiAutomator2"
            if let serial { alwaysMatch["appium:udid"] = serial }
        }
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": alwaysMatch,
                "firstMatch": [[String: Any]()],
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        guard let url = URL(string: "\(serverURL)/session") else {
            throw DriverError.bridgeUnreachable("Appium サーバ(\(serverURL))が起動しているか確認してください(不正なURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // WDA/UiAutomator2 の初回起動待ち。normal(30s)だと安定して打ち切られる
        req.timeoutInterval = Timeout.sessionCreate

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapConnectionError(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            // appium-ios-simulator がセッション終了直後の作成でシミュレータ状態を誤認し
            // shutdown 15s タイムアウトで 500 を返すことがある(実測)。少し待って1回だけ再試行
            if !isRetry, body.contains("Simulator is not in 'Shutdown' state") {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return try await createSession(isRetry: true)
            }
            throw DriverError.badResponse(status: status, body: body)
        }

        if let w3c = try? JSONDecoder().decode(W3CSessionResponse.self, from: data), !w3c.value.sessionId.isEmpty {
            return w3c.value.sessionId
        }
        if let legacy = try? JSONDecoder().decode(LegacySessionResponse.self, from: data), !legacy.sessionId.isEmpty {
            return legacy.sessionId
        }
        throw DriverError.badResponse(status: http.statusCode,
            body: "セッション作成応答を解釈できません: \(String(data: data, encoding: .utf8) ?? "<binary>")")
    }

    private struct W3CSessionResponse: Decodable {
        struct Value: Decodable { let sessionId: String }
        let value: Value
    }

    private struct LegacySessionResponse: Decodable {
        let sessionId: String
    }

    // MARK: - HTTP 基盤

    private func mapConnectionError(_ error: Error) -> DriverError {
        if DriverError.isDefiniteDeliveryFailure(error) {
            return .bridgeConnectionRefused(error.localizedDescription)
        }
        return .bridgeUnreachable("Appium サーバ(\(serverURL))が起動しているか確認してください: \(error.localizedDescription)")
    }

    /// セッションスコープのリクエストを1回だけ発行する下位ヘルパー。呼び出し側は sessionScopedRequest 経由で
    /// リトライ込みで呼ぶこと(直接は呼ばない)。
    private func rawRequest(path: String, method: String, jsonBody: [String: Any]?,
                            timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "\(serverURL)\(path)") else {
            throw DriverError.bridgeUnreachable("Appium サーバ(\(serverURL))が起動しているか確認してください(不正なURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapConnectionError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriverError.bridgeUnreachable("Appium サーバ(\(serverURL))が起動しているか確認してください(不正な応答)")
        }
        return (data, http)
    }

    /// session/:id を含むパスを組み立て、404 または本文に "invalid session id" を含む応答を
    /// 「セッション失効」とみなしてセッションを1回だけ作り直し、同一リクエストを1回だけ再試行する
    /// (無限ループ防止のためリトライは最大1回)。全 session-scoped 呼び出しはここを経由すること。
    private func sessionScopedRequest(pathSuffix: (String) -> String, method: String,
                                      jsonBody: [String: Any]?,
                                      timeout: TimeInterval = Timeout.normal) async throws -> (Data, HTTPURLResponse) {
        let sessionId = try await ensureSession()
        let (data, http) = try await rawRequest(path: pathSuffix(sessionId), method: method,
                                                 jsonBody: jsonBody, timeout: timeout)
        if isInvalidSessionResponse(status: http.statusCode, data: data) {
            await discardSession()
            let retrySessionId = try await ensureSession()
            let (retryData, retryHttp) = try await rawRequest(path: pathSuffix(retrySessionId), method: method,
                                                               jsonBody: jsonBody, timeout: timeout)
            try checkOK(status: retryHttp.statusCode, data: retryData)
            return (retryData, retryHttp)
        }
        try checkOK(status: http.statusCode, data: data)
        return (data, http)
    }

    /// 404 だけでは失効と断定しない: findElement の no such element も 404 を返すため、
    /// 本文の error 文字列で判定する(失効時の実測応答は {"value":{"error":"invalid session id",...}})。
    /// "could not proxy command" は WDA/UiAutomator2 だけが死んだ状態(実測: 500 + ECONNREFUSED 8100)
    /// で、セッション作り直しでランナーごと復旧させる
    private func isInvalidSessionResponse(status: Int, data: Data) -> Bool {
        guard (200..<300).contains(status) == false else { return false }
        let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        return body.contains("invalid session id") || body.contains("could not proxy command")
    }

    private func checkOK(status: Int, data: Data) throws {
        guard (200..<300).contains(status) else {
            throw DriverError.badResponse(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
    }

    // MARK: - AppDriver: ライフサイクル

    public func status() async throws -> StatusResponse {
        guard let statusURL = URL(string: "\(serverURL)/status") else {
            throw DriverError.bridgeUnreachable("Appium サーバ(\(serverURL))が起動しているか確認してください(不正なURL)")
        }
        var req = URLRequest(url: statusURL)
        req.httpMethod = "GET"
        req.timeoutInterval = Timeout.probe
        do {
            _ = try await session.data(for: req)
        } catch {
            throw DriverError.bridgeUnreachable("Appium サーバ(\(serverURL))が起動しているか確認してください: \(error.localizedDescription)")
        }

        // 意図的にデッドラインなしで呼ぶ(コメント冒頭の ensureSession() 参照)。
        _ = try await ensureSession()

        return StatusResponse(ready: true, device: udid ?? serial ?? "-", osVersion: "-",
                              sessionBundleID: bundleID, engine: "appium")
    }

    public func install(packagePath: String) async throws {
        _ = try await ensureSession()
        let args: [String: Any] = ["app": packagePath]
        _ = try await executeScript("mobile: installApp", args: args)
    }

    /// 既存エンジン(inapp=simctl 再起動 / xcuitest=XCUIApplication.launch)と同じ「再起動」意味論。
    /// activateApp 単独(前面化)だと直前シナリオの画面・キーボードが残って snapshot の可視要素が
    /// 変わり、タブ等のセレクタが解決不能になる実害があった(terminate は未起動時に失敗してよい)
    public func launch(bundleID: String) async throws {
        _ = try await ensureSession()
        _ = try? await executeScript("mobile: terminateApp", args: activateArgs(bundleID))
        _ = try await executeScript("mobile: activateApp", args: activateArgs(bundleID))
    }

    public func activate(bundleID: String) async throws {
        _ = try await ensureSession()
        _ = try await executeScript("mobile: activateApp", args: activateArgs(bundleID))
    }

    public func terminate() async throws {
        _ = try await ensureSession()
        _ = try await executeScript("mobile: terminateApp", args: activateArgs(bundleID))
    }

    private func activateArgs(_ bundleID: String) -> [String: Any] {
        platform == "ios" ? ["bundleId": bundleID] : ["appId": bundleID]
    }

    public func home() async throws {
        _ = try await ensureSession()
        if platform == "ios" {
            _ = try await executeScript("mobile: pressButton", args: ["name": "home"])
        } else {
            _ = try await executeScript("mobile: pressKey", args: ["keycode": 3])
        }
    }

    @discardableResult
    private func executeScript(_ script: String, args: [String: Any]) async throws -> Data {
        let body: [String: Any] = ["script": script, "args": [args]]
        let (data, _) = try await sessionScopedRequest(
            pathSuffix: { "/session/\($0)/execute/sync" }, method: "POST", jsonBody: body)
        return data
    }

    public func screenshot() async throws -> Data {
        let (data, _) = try await sessionScopedRequest(
            pathSuffix: { "/session/\($0)/screenshot" }, method: "GET", jsonBody: nil)
        struct ScreenshotResponse: Decodable { let value: String }
        guard let decoded = try? JSONDecoder().decode(ScreenshotResponse.self, from: data),
              let imageData = Data(base64Encoded: decoded.value) else {
            throw DriverError.badResponse(status: 500, body: "スクリーンショット応答を解釈できません")
        }
        return imageData
    }

    // MARK: - AppDriver: スナップショット

    public func snapshot() async throws -> SnapshotResponse {
        let (data, _) = try await sessionScopedRequest(
            pathSuffix: { "/session/\($0)/source" }, method: "GET", jsonBody: nil)
        // 応答は生 XML ではなく W3C の JSON ラップ({"value":"<?xml ..."})
        struct SourceResponse: Decodable { let value: String }
        guard let xml = (try? JSONDecoder().decode(SourceResponse.self, from: data))?.value else {
            throw DriverError.badResponse(status: 500,
                body: "source 応答を解釈できません: \(String(data: data.prefix(200), encoding: .utf8) ?? "<binary>")")
        }
        let parsed = platform == "ios" ? AppiumSourceParser.parseIOS(xml: xml) : AppiumSourceParser.parseAndroid(xml: xml)

        var centers: [Int: (x: Double, y: Double, identifier: String?, label: String?)] = [:]
        for element in parsed.elements {
            centers[element.ref] = (x: element.frame.centerX, y: element.frame.centerY,
                                    identifier: element.identifier, label: element.label)
        }
        refCenters = centers
        lastScreen = parsed.screen

        return SnapshotResponse(sessionBundleID: bundleID, screen: parsed.screen,
                                elements: parsed.elements, truncatedCount: parsed.truncatedCount)
    }

    // MARK: - AppDriver: 操作(W3C Actions)

    public func tap(ref: Int) async throws {
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "参照番号 [\(ref)] は未知です。先に snapshot を実行してください")
        }
        try await tap(x: center.x, y: center.y)
    }

    public func tap(x: Double, y: Double) async throws {
        let actions = Self.pointerActions(steps: [
            .move(x: x, y: y, durationMs: 0),
            .down,
            .pause(ms: 100),
            .up,
        ])
        try await sendActions(actions)
    }

    public func press(ref: Int, duration: Double) async throws {
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "参照番号 [\(ref)] は未知です。先に snapshot を実行してください")
        }
        try await press(x: center.x, y: center.y, duration: duration)
    }

    public func press(x: Double, y: Double, duration: Double) async throws {
        let actions = Self.pointerActions(steps: [
            .move(x: x, y: y, durationMs: 0),
            .down,
            .pause(ms: Int(duration * 1000)),
            .up,
        ])
        try await sendActions(actions)
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        let actions = Self.pointerActions(steps: [
            .move(x: fromX, y: fromY, durationMs: 0),
            .down,
            .pause(ms: Int(pressSeconds * 1000)),
            .move(x: toX, y: toY, durationMs: Int(durationSeconds * 1000)),
            .up,
        ])
        try await sendActions(actions)
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        let screen: FTRect
        if let lastScreen {
            screen = lastScreen
        } else {
            screen = try await snapshot().screen
        }
        let (fromX, fromY, toX, toY) = Self.swipePoints(direction: direction, screen: screen)
        let actions = Self.pointerActions(steps: [
            .move(x: fromX, y: fromY, durationMs: 0),
            .down,
            .move(x: toX, y: toY, durationMs: 300),
            .up,
        ])
        try await sendActions(actions)
    }

    static func swipePoints(direction: FTSwipeDirection, screen: FTRect) -> (Double, Double, Double, Double) {
        let cx = screen.centerX
        let cy = screen.centerY
        let top = screen.y + screen.height * 0.2
        let bottom = screen.y + screen.height * 0.8
        let left = screen.x + screen.width * 0.2
        let right = screen.x + screen.width * 0.8
        switch direction {
        case .up: return (cx, bottom, cx, top)
        case .down: return (cx, top, cx, bottom)
        case .left: return (right, cy, left, cy)
        case .right: return (left, cy, right, cy)
        }
    }

    /// xcuitest ドライバに "mobile: type" は無い(実測で unknown method)。identifier があれば
    /// findElement→Element Send Keys、無ければ tap でフォーカスしてから focused 要素へ入力する
    /// (iOS: "mobile: keys" / Android: "mobile: type")。
    public func type(ref: Int?, text: String) async throws {
        if let ref {
            if let identifier = refCenters[ref]?.identifier, !identifier.isEmpty {
                let using = platform == "ios" ? "accessibility id" : "id"
                if let elementId = try? await findElementId(using: using, value: identifier) {
                    _ = try await sessionScopedRequest(
                        pathSuffix: { "/session/\($0)/element/\(elementId)/value" },
                        method: "POST", jsonBody: ["text": text])
                    return
                }
            }
            try await tap(ref: ref)
        }
        if platform == "ios" {
            let keys: [[String: Any]] = text.map { ["key": String($0)] }
            _ = try await executeScript("mobile: keys", args: ["keys": keys])
        } else {
            _ = try await executeScript("mobile: type", args: ["text": text])
        }
    }

    private func findElementId(using: String, value: String) async throws -> String {
        let (data, _) = try await sessionScopedRequest(
            pathSuffix: { "/session/\($0)/element" }, method: "POST",
            jsonBody: ["using": using, "value": value])
        struct FindResponse: Decodable {
            let value: [String: String]
        }
        guard let decoded = try? JSONDecoder().decode(FindResponse.self, from: data),
              let elementId = decoded.value.values.first else {
            throw DriverError.badResponse(status: 500, body: "findElement 応答を解釈できません")
        }
        return elementId
    }

    // MARK: - W3C Actions 組み立て

    private enum PointerStep {
        case move(x: Double, y: Double, durationMs: Int)
        case down
        case up
        case pause(ms: Int)
    }

    /// W3C /session/:id/actions 用の単一ポインタ("touch")アクション列を組み立てる。id は固定文字列
    /// でよい(このドライバは同時に複数指を扱わない)。アクション解放(DELETE .../actions)は呼ばない
    /// (PoC: 次の actions 送信が前回の状態を上書きするため省略しても正しさに影響しない)。
    private static func pointerActions(steps: [PointerStep]) -> [String: Any] {
        var actionItems: [[String: Any]] = []
        for step in steps {
            switch step {
            case .move(let x, let y, let durationMs):
                actionItems.append([
                    "type": "pointerMove", "duration": durationMs,
                    "x": Int(x.rounded()), "y": Int(y.rounded()), "origin": "viewport",
                ])
            case .down:
                actionItems.append(["type": "pointerDown", "button": 0])
            case .up:
                actionItems.append(["type": "pointerUp", "button": 0])
            case .pause(let ms):
                actionItems.append(["type": "pause", "duration": max(ms, 0)])
            }
        }
        let action: [String: Any] = [
            "type": "pointer",
            "id": "finger1",
            "parameters": ["pointerType": "touch"],
            "actions": actionItems,
        ]
        return ["actions": [action]]
    }

    private func sendActions(_ body: [String: Any]) async throws {
        _ = try await sessionScopedRequest(
            pathSuffix: { "/session/\($0)/actions" }, method: "POST", jsonBody: body)
    }
}
