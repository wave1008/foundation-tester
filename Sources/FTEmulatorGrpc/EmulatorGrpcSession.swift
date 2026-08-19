// EmulatorController への単発 RPC 群。呼び出し毎に接続を張って閉じる
// (loopback なので接続コストは ~ms。常駐接続の管理より確実さを優先)。
// 失敗は throw で返し、gRPC→adb のフォールバック判断は呼び出し側(FTAndroid.EmulatorControl)が行う。

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public enum EmulatorGrpcSession {

    public static let defaultTimeout: Duration = .seconds(10)

    /// PNG スクリーンショット(adb screencap -p の代替。実測 48ms vs 140〜250ms)。
    /// 注意: blank 判定に PNG バイト数を使わないこと(emulator 側エンコーダは一様黒でも
    /// 51KB を出す=adb 較正の 30KB 閾値をすり抜ける。判定はホスト側でデコードして画素一様性で
    /// 行う(AndroidHealthProbe.uniformFrame)。RGBA8888 直取りは約10MB の単一メッセージが
    /// grpc-swift トランスポートに切断され使えない(2026-07-25 実測。node の grpc-js は受かる))
    public static func screenshotPNG(endpoint: EmulatorEndpoint,
                                     timeout: Duration = defaultTimeout) async throws -> Data {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var format = Android_Emulation_Control_ImageFormat()
            format.format = .png
            let image = try await client.getScreenshot(format, metadata: metadata, options: options)
            return image.image
        }
    }

    /// evdev キーコードの keypress(down+up)。
    /// 罠: **届くのは guest に入力デバイスがあるキーだけ** — gpio-keys の KEY_POWER(116)/
    /// KEY_SLEEP(142) は届き、KEY_WAKEUP(143) は不発(2026-07-25 実測)。API 36 arm64 の AVD は
    /// キーボードデバイスを持たないので HOME/APP_SWITCH/ENTER 相当も届かない(2026-08-19 実測。
    /// docs/design.md §16.3)。wake には KEY_POWER を使うこと(sleepWake() が正しい並びを内蔵)
    public static func sendEvdevKeypress(endpoint: EmulatorEndpoint, keyCode: Int32,
                                         timeout: Duration = defaultTimeout) async throws {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var event = Android_Emulation_Control_KeyboardEvent()
            event.codeType = .evdev
            event.eventType = .keypress
            event.keyCode = keyCode
            _ = try await client.sendKey(event, metadata: metadata, options: options)
        }
    }

    /// sleep/wake 1サイクル(blank-screen 修復。KEY_SLEEP=142 → dwell → KEY_POWER=116。
    /// KEY_SLEEP は非トグルで確実に Asleep、直後の KEY_POWER トグルは確実に wake になる)
    public static func sleepWake(endpoint: EmulatorEndpoint, dwell: Duration) async throws {
        try await sendEvdevKeypress(endpoint: endpoint, keyCode: 142)
        try await Task.sleep(for: dwell)
        try await sendEvdevKeypress(endpoint: endpoint, keyCode: 116)
    }

    // 名前付きキー(KeyboardEvent.key = "GoHome"/"AppSwitch"/"Enter")の keypress は置かない —
    // proto は Android 固有動作を明記しているが guest には届かず、RPC だけ成功する
    // (2026-08-19 実測。FTAndroid.AndroidDriver.home() と docs/design.md §16.3)

    /// 2点間ドラッグ(`input swipe` の代替)。down → ~16ms 刻みの補間 move → up を
    /// 1接続内で送る(pressure 0 の up を必ず送らないと identifier が残留する。proto 契約)。
    /// 座標は screencap と同じ物理ピクセル
    public static func drag(endpoint: EmulatorEndpoint,
                            fromX: Int32, fromY: Int32, toX: Int32, toY: Int32,
                            durationMs: Int) async throws {
        try await withController(endpoint: endpoint,
                                 timeout: .milliseconds(durationMs + 10_000)) { client, metadata, options in
            func touch(_ x: Int32, _ y: Int32, pressure: Int32) async throws {
                var t = Android_Emulation_Control_Touch()
                t.x = x
                t.y = y
                t.identifier = 0
                t.pressure = pressure
                var event = Android_Emulation_Control_TouchEvent()
                event.touches = [t]
                _ = try await client.sendTouch(event, metadata: metadata, options: options)
            }
            let steps = max(2, durationMs / 16)
            try await touch(fromX, fromY, pressure: 1)
            for i in 1...steps {
                let progress = Double(i) / Double(steps)
                try await touch(Int32((Double(fromX) + Double(toX - fromX) * progress).rounded()),
                                Int32((Double(fromY) + Double(toY - fromY) * progress).rounded()),
                                pressure: 1)
                try await Task.sleep(for: .milliseconds(durationMs / steps))
            }
            try await touch(toX, toY, pressure: 0)
        }
    }

    /// 座標ロングプレス(同一点 `input swipe` の代替): down → duration 保持 → up
    public static func longPress(endpoint: EmulatorEndpoint, x: Int32, y: Int32,
                                 durationMs: Int) async throws {
        try await withController(endpoint: endpoint,
                                 timeout: .milliseconds(durationMs + 10_000)) { client, metadata, options in
            var t = Android_Emulation_Control_Touch()
            t.x = x
            t.y = y
            t.identifier = 0
            t.pressure = 1
            var down = Android_Emulation_Control_TouchEvent()
            down.touches = [t]
            _ = try await client.sendTouch(down, metadata: metadata, options: options)
            try await Task.sleep(for: .milliseconds(durationMs))
            t.pressure = 0
            var up = Android_Emulation_Control_TouchEvent()
            up.touches = [t]
            _ = try await client.sendTouch(up, metadata: metadata, options: options)
        }
    }

    /// getStatus.booted(sys.boot_completed の代替候補。semantics 差があるため
    /// 呼び出し側は false を「未ブート」でなく「不明」として扱い getprop に落とすこと)
    public static func statusBooted(endpoint: EmulatorEndpoint,
                                    timeout: Duration = defaultTimeout) async throws -> Bool {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            let status = try await client.getStatus(.init(), metadata: metadata, options: options)
            return status.booted
        }
    }

    /// 正規シャットダウン(UI の X と同じ)。`adb emu kill` と違い adb 経路死亡でも届く
    public static func shutdown(endpoint: EmulatorEndpoint,
                                timeout: Duration = defaultTimeout) async throws {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var state = Android_Emulation_Control_VmRunState()
            state.state = .shutdown
            _ = try await client.setVmState(state, metadata: metadata, options: options)
        }
    }

    /// VM リセット(guest reboot 相当。emulator プロセスは維持)。`adb reboot` 不達時の代替
    public static func reset(endpoint: EmulatorEndpoint,
                             timeout: Duration = defaultTimeout) async throws {
        try await withController(endpoint: endpoint, timeout: timeout) { client, metadata, options in
            var state = Android_Emulation_Control_VmRunState()
            state.state = .reset
            _ = try await client.setVmState(state, metadata: metadata, options: options)
        }
    }

    // MARK: - 内部

    private static func withController<T: Sendable>(
        endpoint: EmulatorEndpoint,
        timeout: Duration,
        _ body: @Sendable @escaping (
            Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>,
            Metadata,
            CallOptions
        ) async throws -> T
    ) async throws -> T {
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: endpoint.grpcPort),
            transportSecurity: .plaintext)
        var metadata: Metadata = [:]
        metadata.addString("Bearer \(endpoint.token)", forKey: "authorization")
        // RPC 全体のデッドライン(ハング中のエミュレータで永久待ちしない)
        var options = CallOptions.defaults
        options.timeout = timeout
        let capturedMetadata = metadata
        let capturedOptions = options
        return try await withGRPCClient(transport: transport) { grpcClient in
            let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: grpcClient)
            return try await body(controller, capturedMetadata, capturedOptions)
        }
    }
}
