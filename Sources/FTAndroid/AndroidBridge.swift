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
    public static let expectedBridgeVersionCode = 9

    enum BridgeState {
        case active(BridgeClient)
        /// retryAfter まで再試行しない(嵐防止)。期限後の ensureBridge が自動で再試行するため、
        /// 長寿命プロセス(ftester-mcp / api monitor)でもデバイス復旧後に自動回復する。
        /// detail は初回失敗の原因(期限内の再 throw に引き継ぐ)
        case unavailable(retryAfter: Date, detail: String?)
    }

    /// 失敗キャッシュの保持時間。startBridge の失敗は probe 2s+起動待ち最大 10s 級のコストなので
    /// この間隔で十分嵐を防げる
    static let unavailableRetryInterval: TimeInterval = 60

    /// serial → ブリッジ状態。ドライバを都度生成してもプローブを繰り返さないプロセス共有レジストリ
    static let bridgeLock = NSLock()
    nonisolated(unsafe) static var bridgeRegistry: [String: BridgeState] = [:]
    /// serial → 進行中の startBridge タスク。同一 serial の並行初回操作を1本に集約する
    /// (未集約だと両者が nil を観測し adb forward / am instrument が二重実行される)。
    nonisolated(unsafe) static var bridgeSetup: [String: Task<BridgeClient, Error>] = [:]

    var bridgeKey: String { serial ?? "default" }

    // MARK: - 状態機械

    /// .active なら(/status 往復せず)即返す。初回・無効化後は forward確認→probe→必要なら起動。
    /// 全て失敗したら .unavailable にキャッシュ(再試行の嵐防止)し案内メッセージ付きで投げる
    func ensureBridge() async throws -> BridgeClient {
        switch Self.getRegistry(bridgeKey) {
        case .active(let client):
            return client
        case .unavailable(let retryAfter, let detail):
            guard Date() >= retryAfter else { throw Self.unreachableError(detail: detail) }
            // 期限切れ → 下の再セットアップへ
        case nil:
            break
        }

        // 同一 serial の並行初回操作は1本の startBridge に集約する(進行中があれば相乗り)。
        let key = bridgeKey
        let setup = Self.beginSetup(key: key) { [self] in
            do {
                let client = try await startBridge()
                Self.setRegistry(key, .active(client))
                return client
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Self.setRegistry(key, .unavailable(
                    retryAfter: Date().addingTimeInterval(Self.unavailableRetryInterval),
                    detail: message))
                throw error
            }
        }
        do {
            return try await setup.value
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw Self.unreachableError(detail: message)
        }
    }

    /// 同一 key の setup を1本に集約する。進行中の Task があればそれを返し、無ければ起動して登録。
    /// 完了(成功/失敗いずれも)で自動的に登録解除し、次回の再セットアップを妨げない。
    static func beginSetup(key: String,
                           _ body: @escaping @Sendable () async throws -> BridgeClient)
        -> Task<BridgeClient, Error> {
        bridgeLock.lock()
        if let existing = bridgeSetup[key] {
            bridgeLock.unlock()
            return existing
        }
        let task = Task { () async throws -> BridgeClient in
            defer { clearSetup(key: key) }
            return try await body()
        }
        bridgeSetup[key] = task
        bridgeLock.unlock()
        return task
    }

    private static func clearSetup(key: String) {
        bridgeLock.lock(); bridgeSetup[key] = nil; bridgeLock.unlock()
    }

    private static func unreachableError(detail: String?) -> DriverError {
        let base = "Android ブリッジに接続できません。`ftester doctor` で環境を確認するか、"
            + "`ftester bridge up --platform android` を試してください"
        return .bridgeUnreachable(detail.map { "\(base)(\($0))" } ?? base)
    }

    /// bridgeConnectionRefused(リクエストが届いていないと確実な場合)だけレジストリを無効化して
    /// 1回だけ再プロビジョン+リトライする。それ以外のエラー(HTTPエラー応答等)はそのまま投げる
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
        // 既に稼働中で版一致ならそのまま使う(CLI の別プロセスが起動済みのケース)。
        // 版不一致(旧ブリッジプロセスが常駐したまま)は素通しせず、下の再インストール+
        // force-stop+再起動で更新する(APK 差し替えだけでは稼働中プロセスは旧版のまま)
        if let (client, version) = await probeBridge(hostPort: hostPort),
           version == Self.expectedBridgeVersionCode {
            return client
        }

        disableAnimations()
        allowHiddenAPIReflection()
        try installBridgeIfNeeded()
        _ = try? adb(["shell", "am", "force-stop", Self.bridgePackage])
        // -w 必須(UiAutomationConnection は am プロセス側に生成される)。
        // デバイス内でバックグラウンド化するので adb 切断後も常駐する
        _ = try adb(["shell",
                     "am instrument -w -e port \(Self.bridgeDevicePort) \(Self.bridgeComponent) "
                     + "</dev/null >/dev/null 2>&1 &"])

        // ready 待ち(200ms 間隔・最大 10 秒)。起動直後は導入したての APK なので版照合は不要
        for _ in 0..<50 {
            if let (client, _) = await probeBridge(hostPort: hostPort) { return client }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw DriverError.bridgeUnreachable(
            "Android ブリッジが起動しません(adb logcat -s FTBridge を確認してください)")
    }

    /// アニメーションは a11y イベントを発しないため、QuietWaiter の静穏判定後もアニメが表示を
    /// 動かし続け screenshot が古い/遷移途中の絵を掴むことがある(a11y要素はFRESHだが画像だけSTALE)。
    /// ブリッジのコールド起動時のみ実行(毎操作ではないため3回のadb spawnは許容)。失敗は非致命。
    private func disableAnimations() {
        let keys = ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]
        let failed = keys.filter { (try? adb(["shell", "settings", "put", "global", $0, "0"]))?.status != 0 }
        guard !failed.isEmpty else { return }
        let message = "⚠️ Android アニメーション設定の無効化に失敗しました(\(failed.joined(separator: ", ")))。"
            + "有効なままだと静穏判定後に screenshot が古い絵を掴むことがあります\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// ブリッジの /locale(BridgeRouter.java handleLocale)が使う隠し API 反射の許可。
    /// 未設定だとロケール変更だけが 500 になる。失敗は非致命(disableAnimations と同方針)
    private func allowHiddenAPIReflection() {
        guard (try? adb(["shell", "settings", "put", "global", "hidden_api_policy", "1"]))?.status == 0
        else {
            FileHandle.standardError.write(Data(
                "⚠️ hidden_api_policy の設定に失敗しました(ロケール変更 /locale が使えません)\n".utf8))
            return
        }
    }

    /// 生存確認+稼働中プロセスの版(旧ブリッジは bridgeVersionCode を返さない → nil)
    private func probeBridge(hostPort: UInt16) async -> (client: BridgeClient, version: Int?)? {
        let probe = BridgeClient(port: hostPort, timeoutSeconds: 2)
        guard let status = try? await probe.status(), status.ready else { return nil }
        // 操作用は通常タイムアウト(snapshot 等は余裕を持つ)
        return (BridgeClient(port: hostPort), status.bridgeVersionCode)
    }

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
        var unscopedMatches: [UInt16] = []
        for line in list.output.split(separator: "\n") {
            // 形式: "<serial> tcp:<hostPort> tcp:<devicePort>"
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[2] == "tcp:\(Self.bridgeDevicePort)",
                  let hostPort = UInt16(parts[1].dropFirst(4)) else { continue }
            if let serial {
                if parts[0] == serial { return hostPort }
            } else {
                unscopedMatches.append(hostPort)
            }
        }
        // serial 未指定(デフォルトドライバ)は、bridge ポートへの forward が唯一のときだけ再利用する。
        // 複数あると別デバイスの forward を掴み得るため、曖昧回避で nil を返す(呼び出し側が新規 forward)。
        return unscopedMatches.count == 1 ? unscopedMatches[0] : nil
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

    /// doctor 用: window/transition/animator の *_scale のいずれかが 0 でなければ注意文言を返す(全て0ならnil)。
    /// 未設定(get が "null" を返す)は Android の既定値である 1.0 相当として扱い、警告対象に含める
    public func animationScaleWarning() -> String? {
        let keys = ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]
        let nonZero = keys.filter { key in
            let value = (try? adb(["shell", "settings", "get", "global", key]))?
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(Double(value ?? "") == 0)
        }
        guard !nonZero.isEmpty else { return nil }
        return "アニメーション設定が有効です(\(nonZero.joined(separator: ", ")))。"
            + "screenshot が静穏判定後も古い絵を掴むことがあります(次回ブリッジ起動時に自動で0になります)"
    }

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
