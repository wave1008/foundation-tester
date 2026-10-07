// CommandsHTTP.swift
// httpRequest(同期の HTTP)。fleetest 独自(Shirates に無い)。テストデータを API で用意する等、シナリオから
// 外部へ通信する用途。サンドボックスの中では宛先が allowedDomains に無いと繋がらない
// (docs/user-docs/reference/writing/network_access_ja.md)。
// DSL スレッドはもともと同期なので、dataTask + セマフォで待つ(FTSync は通さない = 締切は waitSeconds だけ。
// 既定の RunTunables.httpRequestTimeout は commandTimeout より小さい)。

import Foundation
import FTCore

/// サンドボックスのプロキシ(環境変数 HTTPS_PROXY / HTTP_PROXY)を `connectionProxyDictionary` に設定済みの
/// `URLSession`。プロキシが無い Mac では普通の設定。シナリオから自前で通信するときはこれを使う
public let fleetestURLSession: URLSession = URLSessionProxy.makeSession()

public struct HTTPResponse: Sendable {
    public let status: Int
    /// ヘッダ名は**小文字**(HTTP のヘッダ名は大文字小文字を区別しない。同名が複数あれば CFNetwork が `, ` で連結したもの)
    public let headers: [String: String]
    public let data: Data
    /// 本文を UTF-8 として読んだもの(読めなければ "")
    public var text: String { String(data: data, encoding: .utf8) ?? "" }
    /// 本文を JSON として読んだもの(`JSONSerialization`。読めなければ nil。`Any` を持つので保持せず都度読む)
    public var json: Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

    static let empty = HTTPResponse(status: 0, headers: [:], data: Data())
}

enum HTTPOutcome: Sendable {
    case response(HTTPResponse)
    case failure(String)
}

/// 1回の送信と待ち。**4xx/5xx は失敗にしない**(`.response` で返す)。URL の不正・通信の失敗・時間切れが `.failure`
func performHTTP(session: URLSession, url: String, method: String, headers: [String: String],
                 body: String?, timeout: Double) -> HTTPOutcome {
    guard timeout > 0, timeout.isFinite else { return .failure("waitSeconds must be greater than 0") }
    guard let target = URL(string: url), let scheme = target.scheme?.lowercased(),
          scheme == "http" || scheme == "https", target.host != nil else {
        return .failure("invalid URL (expected http:// or https://): \(url)")
    }
    var request = URLRequest(url: target)
    request.httpMethod = method
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body.map { Data($0.utf8) }
    // URLSession 自身の時間切れ(固有の文言を返す)を先に鳴らし、セマフォは取りこぼしの網として少し長く待つ
    request.timeoutInterval = timeout

    let semaphore = DispatchSemaphore(value: 0)
    let outcome = LockedValue<HTTPOutcome?>(nil)
    let task = session.dataTask(with: request) { data, response, error in
        let result: HTTPOutcome
        if let http = response as? HTTPURLResponse {
            var received: [String: String] = [:]
            for (key, value) in http.allHeaderFields { received["\(key)".lowercased()] = "\(value)" }
            result = .response(HTTPResponse(status: http.statusCode, headers: received, data: data ?? Data()))
        } else if let error = error as NSError? {
            result = .failure(error.code == NSURLErrorTimedOut
                ? "no response within \(FTSeconds.format(timeout))s"
                : "\(error.localizedDescription) (\(error.domain) \(error.code))")
        } else {
            result = .failure("no HTTP response")
        }
        outcome.withLock { $0 = result }
        semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
        task.cancel()
        return .failure("no response within \(FTSeconds.format(timeout))s")
    }
    return outcome.withLock { $0 } ?? .failure("no HTTP response")
}

extension FTDriveCore {
    func httpRequest(url: String, method: String, headers: [String: String], body: String?,
                     waitSeconds: Double?, file: StaticString, line: UInt) -> HTTPResponse {
        let method = method.uppercased()
        let description = "httpRequest \(method) \(url)"
        let filePath = "\(file)"
        if scenarioAborted {
            recordStep(description: description, status: .skipped(skipReason),
                       file: filePath, line: Int(line), command: "httpRequest")
            return .empty
        }
        // dry-run は送らない(status 0 の空の応答。ステップは記録する)
        if dryRun {
            recordStep(description: description, status: .passed,
                       file: filePath, line: Int(line), command: "httpRequest")
            return .empty
        }
        let started = ContinuousClock().now
        let outcome = performHTTP(session: fleetestURLSession, url: url, method: method, headers: headers,
                                  body: body, timeout: waitSeconds ?? tunables.httpRequestTimeout)
        let elapsed = ContinuousClock().now - started
        let durationMs = continuousClockMilliseconds(elapsed)
        switch outcome {
        case .response(let response):
            // 本文は載せない(長く、秘密を含みうる)。説明の伏せ字化は recordStep が掛ける
            recordStep(description: "\(description) → \(response.status)", status: .passed,
                       file: filePath, line: Int(line), durationMs: durationMs, command: "httpRequest")
            return response
        case .failure(let message):
            var reason = "\(description): \(message)"
            if URLSessionProxy.isConfigured() {
                reason += ". The connection goes through the sandbox proxy; hosts not in allowedDomains are refused"
            }
            recordStep(description: description, status: .failed(reason),
                       file: filePath, line: Int(line), durationMs: durationMs, command: "httpRequest")
            handleFailure(stepDescription: description, reason: reason)
            return .empty
        }
    }
}

/// HTTP リクエストを送り、応答が返るまで待つ。**4xx/5xx は失敗にしない**(`status` を検証する)。
/// URL の不正・通信の失敗・`waitSeconds` 内に応答が無いときはステップを失敗にして中断し、status 0 の空の応答を返す。
/// `waitSeconds` 省略時は `RunTunables.httpRequestTimeout`。dry-run は送らず status 0 の空の応答を返す
@discardableResult
public func httpRequest(_ url: String, method: String = "GET", headers: [String: String] = [:],
                        body: String? = nil, waitSeconds: Double? = nil,
                        file: StaticString = #filePath, line: UInt = #line) -> HTTPResponse {
    FTRuntime.requireCore(command: "httpRequest")
        .httpRequest(url: url, method: method, headers: headers, body: body, waitSeconds: waitSeconds,
                     file: file, line: line)
}
