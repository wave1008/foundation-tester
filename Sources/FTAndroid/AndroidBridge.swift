// AndroidBridge.swift
// デバイス常駐ブリッジ(AndroidRunner/、instrumentation APK 内蔵 HTTP サーバ)の起動管理。
// プロトコルは iOS ブリッジと完全互換なので、通信は FTBridgeClient.BridgeClient をそのまま使う。
// - 初回操作時に APK を自動インストールし `am instrument -w`(デバイス内バックグラウンド)で常駐させる
// - ホストへは `adb forward tcp:0 tcp:8123` (空きポート自動割当)で到達する
// - ブリッジに接続できない場合は DriverError.bridgeUnreachable を投げる(フォールバックなし)

import Foundation
import FTBridgeClient
import FTCore

extension AndroidDriver {

    public static let bridgePackage = "com.example.ftbridge"
    static let bridgeComponent = "com.example.ftbridge/.BridgeInstrumentation"
    /// デバイス側の listen ポート(全デバイス共通。デバイス毎に独立 loopback なので衝突しない)
    static let bridgeDevicePort: UInt16 = 8123
    /// AndroidRunner/build.sh の VERSION_CODE と同期(不一致なら自動で再インストール)
    public static let expectedBridgeVersionCode = 2

    enum BridgeState {
        case active(BridgeClient)
        case unavailable
    }

    /// serial → ブリッジ状態。呼び出し側(MCP 等)がドライバを都度生成してもプローブを繰り返さないための
    /// プロセス共有レジストリ。`.unavailable` はプロセス終了まで再試行しない(再試行の嵐防止)
    static let bridgeLock = NSLock()
    nonisolated(unsafe) static var bridgeRegistry: [String: BridgeState] = [:]

    var bridgeKey: String { serial ?? "default" }

    // MARK: - 状態機械

    /// 使えるブリッジの BridgeClient を返す。.active なら(操作毎の /status 往復はせず)そのまま返す。
    /// 初回・無効化後は forward 確認 → probe → 必要なら起動、を行う。全て失敗したらこのプロセスでは
    /// 以降 .unavailable にキャッシュし(再試行の嵐防止)、案内メッセージ付きで投げる
    func ensureBridge() async throws -> BridgeClient {
        switch Self.getRegistry(bridgeKey) {
        case .active(let client):
            return client
        case .unavailable:
            throw Self.unreachableError(detail: nil)
        case nil:
            break
        }

        do {
            let client = try await startBridge()
            Self.setRegistry(bridgeKey, .active(client))
            return client
        } catch {
            Self.setRegistry(bridgeKey, .unavailable)
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw Self.unreachableError(detail: message)
        }
    }

    private static func unreachableError(detail: String?) -> DriverError {
        let base = "Android ブリッジに接続できません。`ftester doctor` で環境を確認するか、"
            + "`ftester bridge up --platform android` を試してください"
        return .bridgeUnreachable(detail.map { "\(base)(\($0))" } ?? base)
    }

    /// ブリッジ操作の共通実行ヘルパ。接続拒否系エラー(リクエストがブリッジに届いていないことが
    /// 確実な場合)だけレジストリを無効化して1回だけ再プロビジョン+リトライする。
    /// それ以外のエラー(HTTP エラー応答等)はそのまま投げる
    func withBridge<T>(_ operation: (BridgeClient) async throws -> T) async throws -> T {
        let client = try await ensureBridge()
        do {
            return try await operation(client)
        } catch DriverError.bridgeConnectionRefused {
            Self.setRegistry(bridgeKey, nil)
            let retried = try await ensureBridge()
            return try await operation(retried)
        }
    }

    /// bridge up --platform android 用: `.unavailable` を破棄して強制再セットアップ
    public func resetAndEnsureBridge() async throws {
        Self.setRegistry(bridgeKey, nil)
        _ = try await ensureBridge()
    }

    private static func setRegistry(_ key: String, _ state: BridgeState?) {
        bridgeLock.lock()
        bridgeRegistry[key] = state
        bridgeLock.unlock()
    }

    private static func getRegistry(_ key: String) -> BridgeState? {
        bridgeLock.lock()
        defer { bridgeLock.unlock() }
        return bridgeRegistry[key]
    }

    // MARK: - セットアップ

    private func startBridge() async throws -> BridgeClient {
        let hostPort = try ensureForward()
        // 既に稼働中ならそのまま使う(CLI の別プロセスが起動済みのケース)
        if let client = await probeBridge(hostPort: hostPort) { return client }

        try installBridgeIfNeeded()
        _ = try? adb(["shell", "am", "force-stop", Self.bridgePackage])
        // -w 必須(UiAutomationConnection は am プロセス側に生成される)。
        // デバイス内でバックグラウンド化するので adb 切断後も常駐する
        _ = try adb(["shell",
                     "am instrument -w -e port \(Self.bridgeDevicePort) \(Self.bridgeComponent) "
                     + "</dev/null >/dev/null 2>&1 &"])

        // ready 待ち(200ms 間隔・最大 10 秒)
        for _ in 0..<50 {
            if let client = await probeBridge(hostPort: hostPort) { return client }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw DriverError.bridgeUnreachable(
            "Android ブリッジが起動しません(adb logcat -s FTBridge を確認してください)")
    }

    private func probeBridge(hostPort: UInt16) async -> BridgeClient? {
        let probe = BridgeClient(port: hostPort, timeoutSeconds: 2)
        guard (try? await probe.status())?.ready == true else { return nil }
        // 操作用は通常タイムアウト(snapshot 等は余裕を持つ)
        return BridgeClient(port: hostPort)
    }

    /// 既存の forward を再利用、無ければ tcp:0(空きポート自動割当)で張る
    private func ensureForward() throws -> UInt16 {
        if let existing = findExistingForward() { return existing }
        let created = try adb(["forward", "tcp:0", "tcp:\(Self.bridgeDevicePort)"])
        guard let hostPort = UInt16(created.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DriverError.bridgeUnreachable("adb forward に失敗: \(created.tail)")
        }
        return hostPort
    }

    private func findExistingForward() -> UInt16? {
        guard let list = try? adb(["forward", "--list"]) else { return nil }
        for line in list.output.split(separator: "\n") {
            // 形式: "<serial> tcp:<hostPort> tcp:<devicePort>"
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[2] == "tcp:\(Self.bridgeDevicePort)",
                  serial == nil || parts[0] == serial,
                  let hostPort = UInt16(parts[1].dropFirst(4)) else { continue }
            return hostPort
        }
        return nil
    }

    // MARK: - CLI(bridge down / status / doctor)用

    /// ブリッジ停止 + forward 解放(ftester bridge down --platform android)
    public func stopBridge() {
        _ = try? adb(["shell", "am", "force-stop", Self.bridgePackage])
        if let list = try? adb(["forward", "--list"]) {
            for line in list.output.split(separator: "\n") {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count == 3, parts[2] == "tcp:\(Self.bridgeDevicePort)",
                      serial == nil || parts[0] == serial else { continue }
                _ = try? adb(["forward", "--remove", parts[1]])
            }
        }
        Self.setRegistry(bridgeKey, nil)
    }

    /// doctor / bridge status 用の1行サマリ
    public func bridgeDoctorSummary() -> String {
        guard let version = installedBridgeVersionCode() else {
            return "ブリッジ未導入(初回操作時に自動導入)"
        }
        var summary = "ブリッジ v\(version)"
        if version != Self.expectedBridgeVersionCode {
            summary += "(要更新 → v\(Self.expectedBridgeVersionCode)、次回操作時に自動更新)"
        }
        let pid = (try? adb(["shell", "pidof", Self.bridgePackage]))?
            .output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if pid.isEmpty {
            summary += " 停止中(初回操作時に自動起動)"
        } else {
            summary += " 稼働中(pid \(pid)"
                + (findExistingForward().map { ", forward tcp:\($0)" } ?? "") + ")"
        }
        return summary
    }

    /// versionCode(dumpsys)を照合し、未導入・不一致なら prebuilt APK をインストール
    func installBridgeIfNeeded() throws {
        if installedBridgeVersionCode() == Self.expectedBridgeVersionCode { return }
        let apk = try Self.locateBridgeAPK()
        var result = try adb(["install", "-r", apk.path])
        if result.output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            // 別マシンの debug keystore で署名された旧 APK が居る場合
            _ = try? adb(["uninstall", Self.bridgePackage])
            result = try adb(["install", apk.path])
        }
        guard result.output.contains("Success") else {
            throw DriverError.badResponse(status: Int(result.status),
                body: "ブリッジ APK のインストールに失敗: \(result.tail)")
        }
    }

    public func installedBridgeVersionCode() -> Int? {
        guard let dump = try? adb(["shell", "dumpsys", "package", Self.bridgePackage]),
              let range = dump.output.range(of: #"versionCode=(\d+)"#, options: .regularExpression)
        else { return nil }
        return Int(dump.output[range].dropFirst("versionCode=".count))
    }

    /// 探索順: 環境変数 → リポジトリの prebuilt → ~/.ftester キャッシュ
    public static func locateBridgeAPK() throws -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FT_ANDROID_BRIDGE_APK"],
           fm.isReadableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ftester/ftbridge.apk")
        if let root = try? RepoRoot.find() {
            let repoAPK = root.appendingPathComponent("AndroidRunner/prebuilt/ftbridge.apk")
            if fm.isReadableFile(atPath: repoAPK.path) {
                // リポジトリ外 cwd からの将来の起動用にキャッシュしておく
                try? fm.createDirectory(at: cache.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: cache)
                try? fm.copyItem(at: repoAPK, to: cache)
                return repoAPK
            }
        }
        if fm.isReadableFile(atPath: cache.path) {
            return cache
        }
        throw DriverError.bridgeUnreachable("""
            ブリッジ APK(ftbridge.apk)が見つかりません。
            リポジトリの AndroidRunner/prebuilt/ftbridge.apk か、
            FT_ANDROID_BRIDGE_APK=<APKパス> を設定してください(再生成: AndroidRunner/build.sh)
            """)
    }
}
