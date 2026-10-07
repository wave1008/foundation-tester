// URLSessionProxy.swift
// シナリオの子へ渡るプロキシの環境変数(`SandboxProxy.environment`)から `URLSession` の設定を作る。
// **`URLSession` は HTTP(S)_PROXY を読まない**ので、`connectionProxyDictionary` へ写す必要がある。
// プロキシが無い(サンドボックスを外した Mac)ときは普通の設定。DSL の `fleetestURLSession` が使う。

import Foundation

public enum URLSessionProxy {
    /// プロキシの URL を載せる環境変数(優先順)
    static let proxyVariables = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]

    /// 環境変数に(空でない)プロキシの指定があるか。失敗文の注記の出し分けに使う
    public static func isConfigured(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        proxyVariables.contains { !(environment[$0] ?? "").isEmpty }
    }

    /// `connectionProxyDictionary` の中身。指定が無い・読めない(host か port が無い)ときは nil。
    /// `NO_PROXY` は `ExceptionsList` へ(localhost へはプロキシを経由しない。サンドボックスは localhost への直接接続を許す)
    public static func connectionProxyDictionary(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any]? {
        for name in proxyVariables {
            guard let value = environment[name], !value.isEmpty,
                  let url = URLComponents(string: value), let host = url.host, let port = url.port else { continue }
            var dictionary: [String: Any] = [
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
            ]
            let exceptions = (environment["NO_PROXY"] ?? environment["no_proxy"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !exceptions.isEmpty { dictionary["ExceptionsList"] = exceptions }
            return dictionary
        }
        return nil
    }

    public static func makeSession(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if let dictionary = connectionProxyDictionary(environment: environment) {
            configuration.connectionProxyDictionary = dictionary
        }
        return URLSession(configuration: configuration)
    }
}
