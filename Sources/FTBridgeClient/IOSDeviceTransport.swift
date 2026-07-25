// iOS 実機のブリッジ到達手段。シミュレータはホストとネットワークスタックを共有するので
// 127.0.0.1 で届くが、実機のループバックはホストから見えない。
//
//   lan … ランナーを 0.0.0.0 に bind させ(FT_BIND_ALL=1 を xctestrun に注入)、ランナーが
//         自分の LAN IPv4 を "FT_BRIDGE_ADDR=<ip>:<port>" として標準出力に 1 行出す。
//         ホストは既存の .ftester/bridge-<port>.log を読んで宛先を得る(新しい探索機構を作らない)。
//         Mac と端末が同じネットワークに居ること。クライアント分離 WiFi では使えない。
//   usb … iproxy(brew install libimobiledevice)で USB トンネルを張り 127.0.0.1 を維持する。
//         LAN 不通の環境向け。iproxy は常駐プロセスなので pid を .ftester に置いて後始末する。
//
// 選択: FT_IOS_DEVICE_TRANSPORT=lan|usb で明示。未指定なら iproxy があれば usb、無ければ lan
// (LAN は追加依存が要らないぶん確実に動くので最後の砦にする)。
// Xcode 27 の devicectl にポート転送サブコマンドは無いため、この 2 択以外の選択肢は無い。

import FTCore
import Foundation

public enum IOSDeviceTransportKind: String, Sendable {
    case lan
    case usb
}

public enum IOSDeviceTransportError: Error, LocalizedError {
    /// blocker: 待っている間に検出した進行阻害要因(端末ロック等)。分かれば理由として出す
    case addressNotAnnounced(port: UInt16, logPath: String, blocker: String?)
    /// ランナーが起動前に死んだ(署名未信頼など)。180 秒待たずに理由ごと返す
    case runnerFailed(port: UInt16, reason: String, logPath: String)
    case iproxyMissing
    case iproxyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .addressNotAnnounced(let port, let logPath, let blocker):
            if let blocker {
                return "iOS 実機ブリッジ(port \(port))が起動しませんでした: \(blocker)"
                    + "\n(ログ: \(logPath))"
            }
            return "iOS 実機ブリッジ(port \(port))の LAN アドレスを取得できません。"
                + "ランナーの起動に失敗しているか、Mac と端末が同じネットワークに居ません"
                + "(ログ: \(logPath))"
        case .runnerFailed(let port, let reason, let logPath):
            return "iOS 実機ブリッジ(port \(port))のランナーが起動しませんでした: \(reason)"
                + "\n(ログ: \(logPath))"
        case .iproxyMissing:
            return "iproxy が見つかりません(USB トンネルに必要)。"
                + "`brew install libimobiledevice` で導入するか、"
                + "FT_IOS_DEVICE_TRANSPORT=lan で LAN 経由に切り替えてください"
        case .iproxyFailed(let detail):
            return "iproxy による USB トンネルの確立に失敗しました: \(detail)"
        }
    }
}

public enum IOSDeviceTransport {

    /// ランナーが LAN モードで 1 行だけ出す宣言。同期相手:
    /// Runner/FTesterRunnerUITests/BridgeHTTPServer.swift の announceAddress()
    public static let addressMarker = "FT_BRIDGE_ADDR="

    /// 選択された方式(環境変数 > iproxy の有無)
    public static func kind(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        wired: Bool = true
    ) -> IOSDeviceTransportKind {
        if let explicit = environment["FT_IOS_DEVICE_TRANSPORT"],
           let parsed = IOSDeviceTransportKind(rawValue: explicit) {
            return parsed
        }
        // **USB 接続でない端末に usb を選んではいけない**: iproxy はトンネルを張れず、
        // 「network connection was lost で 180 秒後にタイムアウト」としか出ない(2026-07-25 実害)。
        // wired は devicectl の transportType 由来(localNetwork = WiFi のみ)
        guard wired else { return .lan }
        return iproxyPath() == nil ? .lan : .usb
    }

    /// 実機ブリッジへの到達点を確立する。lan はランナーの宣言を待ち、usb は iproxy を常駐させる。
    /// deviceUDID は usb のトンネル先指定に使う(lan では未使用)
    /// wired: USB 接続か(devicectl の transportType == "wired")。false なら usb は選べない
    public static func establish(port: UInt16, deviceUDID: String, repoRoot: URL,
                                 wired: Bool = true,
                                 timeoutSeconds: TimeInterval = 180,
                                 log: @escaping (String) -> Void = { _ in }) async throws -> BridgeEndpoint {
        let endpoint: BridgeEndpoint
        switch kind(wired: wired) {
        case .lan:
            // LAN は WiFi の省電力で 1 往復 ~48ms(標準偏差 27ms)かかる。USB の ~5ms に比べ
            // 1 シナリオあたり約 25% 遅い(実測 2026-07-25)。iproxy があれば usb が既定
            log(wired
                ? "経路 lan(WiFi 経由。`brew install libimobiledevice` で USB トンネルの方が速い)"
                : "経路 lan(端末が USB 接続ではないため。USB で繋ぐと 1 往復 48ms → 5ms になる)")
            endpoint = BridgeEndpoint(
                host: try await waitForAnnouncedAddress(
                    port: port, repoRoot: repoRoot, timeoutSeconds: timeoutSeconds, log: log),
                port: port)
        case .usb:
            log("経路 usb(iproxy の USB トンネル)")
            try startIproxy(hostPort: port, devicePort: port,
                            deviceUDID: deviceUDID, repoRoot: repoRoot)
            endpoint = BridgeEndpoint(port: port)
        }
        endpoint.persist(repoRoot: repoRoot)
        return endpoint
    }

    /// 実機ブリッジの後始末(usb のトンネル停止+endpoint 記録の破棄)。lan は何も残さない
    public static func teardown(port: UInt16, repoRoot: URL) {
        stopIproxy(hostPort: port, repoRoot: repoRoot)
        BridgeEndpoint.forget(port: port, repoRoot: repoRoot)
    }

    // MARK: - LAN

    /// ランナーのテストログから FT_BRIDGE_ADDR= の宣言を待つ。
    /// 実機は build/install/launch を挟むためシミュレータより遅い(既定 180s)
    static func waitForAnnouncedAddress(port: UInt16, repoRoot: URL,
                                        timeoutSeconds: TimeInterval,
                                        log: @escaping (String) -> Void = { _ in }) async throws -> String {
        let logURL = repoRoot.appendingPathComponent(".ftester/bridge-\(port).log")
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var blocker: String?
        while Date() < deadline {
            if let host = announcedHost(inLogAt: logURL, port: port) { return host }
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            // ランナーが死んでいたら待つだけ無駄。理由(端末側の証明書未信頼など)ごと即返す
            if let reason = runnerFailureReason(inLog: text) {
                throw IOSDeviceTransportError.runnerFailed(
                    port: port, reason: reason, logPath: logURL.path)
            }
            // 進行を止めているだけ(解消すれば xcodebuild は続行する)条件は throw せず 1 回だけ知らせる。
            // 端末ロックはここに来る = 黙って 180 秒待つのをやめ、その場で解除を促す
            if let detected = blockingCondition(inLog: text), detected != blocker {
                blocker = detected
                log("⏳ \(detected)")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw IOSDeviceTransportError.addressNotAnnounced(
            port: port, logPath: logURL.path, blocker: blocker)
    }

    /// 「失敗ではないが進まない」条件。解消されれば xcodebuild はそのまま続行するので throw しない。
    /// 検知文字列は xcodebuild / DVTDevice の出力依存(変わってもタイムアウトに落ちるだけ)
    static func blockingCondition(inLog text: String) -> String? {
        if text.contains("Unlock") && text.contains("to Continue") {
            return "iPhone がロックされています。端末のロックを解除してください"
                + "(テスト中に再ロックされないよう 設定 → 画面表示と明るさ → 自動ロック を"
                + "「なし」にしておくと安定します)"
        }
        return nil
    }

    /// xcodebuild のテストログから「ランナーが起動できなかった」ことと理由を読み取る。
    /// nil = まだ失敗と断定できない(起動途中)。
    /// 検知文字列は xcodebuild の出力に依存する(Xcode 更新で変わりうる。変わっても
    /// 180 秒タイムアウトに落ちるだけで誤検知はしない側に倒してある)
    static func runnerFailureReason(inLog text: String) -> String? {
        // **端末が起動を拒否した条件は終端マーカーを待たずに確定させる**:
        // xcodebuild は `** TEST EXECUTE FAILED **` も `Testing failed:` も出さないまま
        // 留まり続けることがある(実測 2026-07-26: 証明書未信頼のエラーは 20 秒時点でログに
        // 出ていたのに、マーカー待ちのせいで 181 秒の締切まで待たされ、
        // 「LAN アドレスを取得できません」という無関係な理由で失敗した)。
        // 端末が拒否した時点で結論は出ているので、下の 3 文字列だけは単独で終端扱いにする
        if text.contains("Developer App Certificate is not trusted")
            || text.contains("has not been explicitly trusted by the user") {
            return "端末で開発者証明書が信頼されていません。"
                + "iPhone の 設定 → 一般 → VPN とデバイス管理 から"
                + "デベロッパ App の証明書を「信頼」してください"
                + "(証明書を作り直すと再度必要になります)"
        }
        if text.contains("Developer Mode disabled") {
            return "端末の Developer Mode が無効です。"
                + "iPhone の 設定 → プライバシーとセキュリティ → デベロッパモード を ON にしてください"
        }
        // ここから先は理由を特定できないケース。誤検知を避けるため終端マーカーが出てから判定する
        guard text.contains("** TEST EXECUTE FAILED **")
            || text.contains("Testing failed:") else { return nil }
        if text.lowercased().contains("developer mode") {
            return "端末の Developer Mode が無効です。"
                + "iPhone の 設定 → プライバシーとセキュリティ → デベロッパモード を ON にしてください"
        }
        // 理由が特定できないときは xcodebuild の該当行をそのまま見せる(推測を書かない)。
        // 分割は isNewline(ログは CRLF。announcedHost のコメント参照)
        let line = text.split(whereSeparator: \.isNewline)
            .last { $0.contains("error:") || $0.contains("Underlying Error") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return line ?? "xcodebuild のテスト実行が失敗しました"
    }

    /// ログ本文から該当ポートの宣言を拾う(複数行あれば最後 = 最新の起動を採用)
    static func announcedHost(inLogAt url: URL, port: UInt16) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return announcedHost(inLog: text, port: port)
    }

    static func announcedHost(inLog text: String, port: UInt16) -> String? {
        var found: String?
        // **xcodebuild のテストログは CRLF**(実測 2026-07-25)。Swift では "\r\n" が 1 つの
        // Character なので `split(separator: "\n")` は CRLF を**一切分割しない**(ログ全体が
        // 1 行になり照合が必ず外れる。180 秒待って失敗した実害)。isNewline で分割すること
        for line in text.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: addressMarker) else { continue }
            let value = line[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = value.split(separator: ":")
            guard parts.count == 2, UInt16(parts[1]) == port else { continue }
            found = String(parts[0])
        }
        return found
    }

    // MARK: - USB(iproxy)

    static func iproxyPath() -> String? {
        for candidate in ["/opt/homebrew/bin/iproxy", "/usr/local/bin/iproxy"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func pidURL(hostPort: UInt16, repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".ftester/iproxy-\(hostPort).pid")
    }

    /// 既存トンネルが生きていれば再利用、無ければ起動して pid を残す
    static func startIproxy(hostPort: UInt16, devicePort: UInt16,
                            deviceUDID: String, repoRoot: URL) throws {
        if isIproxyRunning(hostPort: hostPort, repoRoot: repoRoot) { return }
        guard let iproxy = iproxyPath() else { throw IOSDeviceTransportError.iproxyMissing }
        let stateDir = repoRoot.appendingPathComponent(".ftester")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: iproxy)
        process.arguments = ["\(hostPort)", "\(devicePort)", "-u", deviceUDID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw IOSDeviceTransportError.iproxyFailed(error.localizedDescription)
        }
        // ポート使用中・デバイス未接続だと iproxy は即座に終了する。ここで気づかないと
        // 「トンネルは張れた」と誤って進み、waitUntilReady の接続拒否という遠い症状で出る
        usleep(300_000)
        guard process.isRunning else {
            throw IOSDeviceTransportError.iproxyFailed(
                "iproxy がすぐ終了しました(ポート \(hostPort) の使用中、"
                + "または UDID \(deviceUDID) の端末が USB 接続されていない可能性があります)")
        }
        try? String(process.processIdentifier)
            .write(to: pidURL(hostPort: hostPort, repoRoot: repoRoot),
                   atomically: true, encoding: .utf8)
    }

    /// pid ファイルの pid が**今も iproxy か**を見る。kill(pid,0) だけだと PID 再利用で
    /// 無関係プロセスを「トンネル生存」と誤認し、転送されていないポートへ繋ぎに行ってしまう
    static func isIproxyRunning(hostPort: UInt16, repoRoot: URL) -> Bool {
        guard let text = try? String(contentsOf: pidURL(hostPort: hostPort, repoRoot: repoRoot),
                                     encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0,
              let ps = try? Shell.run(["ps", "-p", String(pid), "-o", "command="]), ps.status == 0
        else {
            return false
        }
        return ps.output.contains("iproxy")
    }

    static func stopIproxy(hostPort: UInt16, repoRoot: URL) {
        let url = pidURL(hostPort: hostPort, repoRoot: repoRoot)
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
