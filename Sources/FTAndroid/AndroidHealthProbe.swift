// connected な Android エミュレータのゲスト OS 健全性を低頻度で確認する(ApiMonitorCommand.swift
// から呼ばれる)。adb 接続は生きているがゲスト側が不健全(Wi-Fi 無効・ゲスト時計が凍結)なまま
// テストが延々失敗し続けた実害(2026-07-16)への対策。

import CoreGraphics
import FTCore
import Foundation
import ImageIO

public enum AndroidHealthProbe {
    /// 検出する異常の識別子(VSCode 拡張側 monitorModel.ts の health 契約と同期)
    public static let issueWifiDisabled = "wifi-disabled"
    public static let issueClockSkew = "clock-skew"
    public static let issueBlankScreen = "blank-screen"

    /// clock-skew の既定閾値(秒)。エミュレータの正常な揺らぎは数秒以内、今回の実害は約2時間。
    public static let clockSkewThresholdSeconds: Double = 120

    /// blank-screen 判定の PNG サイズ閾値(バイト)。一様フレームは PNG 圧縮で極小になる
    /// (実測 @1080x2424: ウェッジ時の白/黒 10-16KB、正常画面 130KB 以上)。描画パイプラインの
    /// ウェッジは a11y は生きたまま画面だけ死ぬため、screencap のサイズでしか安価に検出できない
    public static let blankScreenMaxPNGBytes = 30_000

    /// `dumpsys SurfaceFlinger` の GLES 行から実描画モードを判定する(判定基準は
    /// docs/performance-tuning.md §7)。SwiftShader は文字列上 Metal と共起しうるため
    /// 安全側(cpu 判定)を優先して先にチェックする
    static func renderMode(fromSurfaceFlinger output: String) -> String? {
        guard let glesLine = output.split(separator: "\n").first(where: { $0.contains("GLES:") }) else {
            return nil
        }
        if glesLine.range(of: "SwiftShader", options: .caseInsensitive) != nil { return "cpu" }
        if glesLine.contains("Metal") { return "gpu" }
        return nil
    }

    /// ブート時固定の実描画モードを adb dumpsys で1回検出する(呼び出し側=ApiMonitorCommand.swift が
    /// 接続毎にキャッシュし、再検出しない)
    public static func detectRenderMode(serial: String) -> String? {
        guard let adbPath = try? AndroidDriver.findADB() else { return nil }
        guard let result = try? Shell.run([adbPath, "-s", serial, "shell", "dumpsys", "SurfaceFlinger"]) else {
            return nil
        }
        return renderMode(fromSurfaceFlinger: result.output)
    }

    /// serial のエミュレータにプローブを実行する。wifi/clock は adb shell(gRPC 代替なし)、
    /// screencap は gRPC 優先(EmulatorControl)。取得失敗(コマンドエラー・出力パース不能)は
    /// そのプローブの判定をスキップ(=異常扱いしない。誤検知よりプローブ欠測を優先)。
    public static func observeIssues(serial: String, hostNow: Date = Date()) async -> Set<String> {
        guard let adbPath = try? AndroidDriver.findADB() else { return [] }
        var issues: Set<String> = []
        if let wifi = try? Shell.run([adbPath, "-s", serial, "shell", "cmd", "wifi", "status"]),
           wifiDisabled(statusOutput: wifi.output) {
            issues.insert(issueWifiDisabled)
        }
        if let date = try? Shell.run([adbPath, "-s", serial, "shell", "date", "+%s"]),
           clockSkewed(dateOutput: date.output, hostNow: hostNow.timeIntervalSince1970,
                       thresholdSeconds: clockSkewThresholdSeconds) == true {
            issues.insert(issueClockSkew)
        }
        if await probeBlank(serial: serial) {
            issues.insert(issueBlankScreen)
        }
        return issues
    }

    /// screencap PNG のサイズだけでブランク(一様フレーム)を判定する。0 は取得失敗(判定しない)
    static func blankScreen(pngByteCount: Int) -> Bool {
        pngByteCount > 0 && pngByteCount < blankScreenMaxPNGBytes
    }

    /// 事前除外用: serial が「恒常的に」blank-screen かを短時間の連続 probe で確定する。
    /// 白化は約25秒周期でフラッピングする(実測)ため、1回の blank だけでは除外しない。
    /// 健全機は1サンプル目で即 false が返り待たない(全機健全ならディスパッチ前チェックは数秒で終わる)。
    public static func isPersistentlyBlank(serial: String, samples: Int = 5,
                                           intervalMs: UInt64 = 8_000) async -> Bool {
        var observed: [Bool] = []
        for i in 0..<max(samples, 1) {
            let blank = await probeBlank(serial: serial)
            observed.append(blank)
            if !blank { break }  // 非blank観測=フラッピングの回復側。即座に健全確定し以降は待たない
            if i < samples - 1 {
                try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            }
        }
        return decidePersistentBlank(samples: observed)
    }

    /// シナリオ失敗直後の事後判定用: サンプリング窓の中で**一度でも** blank を観測したら true。
    /// isPersistentlyBlank(全サンプル blank で確定・非 blank で即健全)と逆の判定で、白フレームが
    /// 約25秒周期でフラッピングする凍結個体の「回復側の瞬間」を引いて見逃すのを防ぐ。
    /// 健全機は全サンプル非 blank のため窓ぶん(既定 4×2s≈8s)待つ — 失敗シナリオでのみ呼ぶこと。
    public static func isBlankObserved(serial: String, samples: Int = 4,
                                       intervalMs: UInt64 = 2_000) async -> Bool {
        for i in 0..<max(samples, 1) {
            if await probeBlank(serial: serial) { return true }
            if i < samples - 1 {
                try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            }
        }
        return false
    }

    /// 固着した表示凍結(blank)を画面 sleep→wake で修復する。凍結は複数エミュレータ同時描画時の
    /// ホスト GPU(-gpu host)側の合成バッファ固着で、表示パイプラインの無効化→再合成が唯一の
    /// 軽量修復(readback = screencap/screenrecord では回復しない。adb reboot ~60s は不要。
    /// 対照実験 2026-07-25、docs/performance-tuning.md §7)。
    /// 1サイクル(dwell 1.5s ≈4s)で直らない抵抗性の変種が実在し(wake 後 6s 待っても blank)、
    /// dwell 3s の2サイクル目で回復する(実測)。成功時 ~4s・抵抗変種のみ ~11s。
    /// 注入は gRPC 優先(sleep/wake ≈1.2ms×2・adb 死亡個体にも届く)・adb フォールバック
    /// (adb 経路は KEYCODE_SLEEP/WAKEUP、gRPC 経路は evdev 142/116。KEY_WAKEUP=143 は
    /// emulator の変換欠落で不発のため使わない。EmulatorGrpcSession.sleepWake 参照)。
    /// 戻り値: 修復後の再プローブで非 blank になったら true。注入経路が両方ない場合のみ false。
    /// プローブ取得失敗は probeBlank の「非 blank」扱いに倒れ true になる(誤除外しない安全側)。
    public static func repairBlankDisplay(serial: String) async -> Bool {
        let adbPath = try? AndroidDriver.findADB()
        for dwellNs: UInt64 in [1_500_000_000, 3_000_000_000] {
            if await EmulatorControl.sleepWake(serial: serial, dwellNs: dwellNs) {
                // gRPC 経路は dwell 済み(sleep→dwell→wake)。wake 後の整定だけ待つ
            } else if let adbPath {
                _ = try? Shell.run([adbPath, "-s", serial, "shell", "input", "keyevent", "KEYCODE_SLEEP"])
                try? await Task.sleep(nanoseconds: dwellNs)
                _ = try? Shell.run([adbPath, "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            } else {
                return false
            }
            try? await Task.sleep(nanoseconds: dwellNs)
            if await !probeBlank(serial: serial) { return true }
        }
        return false
    }

    /// 実行中の凍結起因失敗の事後判定+その場修復: isBlankObserved が true なら sleep/wake 修復を
    /// 試みてから true を返す。判定結果(このシナリオ失敗が凍結起因か)は修復成否で変えない=
    /// 振り直し・ワーカー離脱は従来どおりで、修復は「次のシナリオ/ワーカー復帰が健全画面に当たる」
    /// ための処置。RunOrchestrator.isDeviceFrozen への注入用(ProfileRunner / ApiRunCommand で共用)。
    public static func observeBlankAndRepair(serial: String,
                                             log: (String) -> Void) async -> Bool {
        guard await isBlankObserved(serial: serial) else { return false }
        if await repairBlankDisplay(serial: serial) {
            log("🔧 実行中の画面凍結を sleep/wake で修復しました(\(serial))")
        } else {
            log("⚠️ 実行中の画面凍結を修復できませんでした(\(serial))")
        }
        return true
    }

    /// serial に1回スクリーンショットを取り blank 判定する。取得失敗(gRPC/adb 両方不可)・
    /// デコード失敗は「blank ではない」扱い(誤って健全機を除外しない安全側)。
    /// 経路で判定方法が違う(重要):
    /// - gRPC: PNG をホスト側でデコードし画素の一様判定(uniformFrame)。凍結フレームは経路により
    ///   白/黒どちらもあり、emulator の PNG エンコーダは一様黒でも 51KB を出すため
    ///   **PNG サイズ閾値は使えない**(30KB 閾値は adb screencap のエンコーダ較正。
    ///   2026-07-25 証跡 PNG の画素解析で確認)
    /// - adb フォールバック: 従来どおり PNG サイズ閾値(blankScreen)
    private static func probeBlank(serial: String) async -> Bool {
        if let png = await EmulatorControl.screenshotPNG(serial: serial),
           let rgba = decodeRGBA(png: png) {
            return uniformFrame(rgba: rgba)
        }
        guard let adbPath = try? AndroidDriver.findADB(),
              let cap = try? Shell.runData([adbPath, "-s", serial, "exec-out", "screencap", "-p"]),
              cap.status == 0 else {
            return false
        }
        return blankScreen(pngByteCount: cap.data.count)
    }

    /// PNG → RGBA8888 生画素(ImageIO/CoreGraphics。フル解像度・補間なしで uniformFrame 用)
    static func decodeRGBA(png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return nil }
        return Data(bytes: buffer, count: width * height * 4)
    }

    /// RGBA 生画素バッファが一様フレーム(=blank)か。RGB 各チャネルの min/max 差が
    /// tolerance 以下なら一様(alpha は無視。実凍結フレームは spread 0 だがノイズ耐性を持たせる)。
    /// 4バイト未満(空含む)は判定不能= false(誤検知しない安全側)
    static func uniformFrame(rgba: Data, tolerance: UInt8 = 8, sampleCount: Int = 4096) -> Bool {
        let pixelCount = rgba.count / 4
        guard pixelCount > 0 else { return false }
        let stride = max(1, pixelCount / sampleCount)
        var minC: [UInt8] = [255, 255, 255]
        var maxC: [UInt8] = [0, 0, 0]
        return rgba.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            var p = 0
            while p < pixelCount {
                let base = p * 4
                for c in 0..<3 {
                    let v = buf[base + c]
                    if v < minC[c] { minC[c] = v }
                    if v > maxC[c] { maxC[c] = v }
                }
                p += stride
            }
            for c in 0..<3 where maxC[c] &- minC[c] > tolerance { return false }
            return true
        }
    }

    /// 純粋な確定ロジック: 全サンプルが blank なら true、1つでも非blankがあれば false、
    /// 空配列(観測なし)は false
    static func decidePersistentBlank(samples: [Bool]) -> Bool {
        guard !samples.isEmpty else { return false }
        return samples.allSatisfy { $0 }
    }

    /// `adb shell cmd wifi status` の出力に "Wifi is disabled" が含まれるかで判定
    /// (正常時は "Wifi is enabled" / "Wifi is connected to ..." が出る)
    static func wifiDisabled(statusOutput: String) -> Bool {
        statusOutput.contains("Wifi is disabled")
    }

    /// `adb shell date +%s` の出力とホスト時刻の差が threshold 秒を超えるか。
    /// 出力がパース不能(空・非数値)なら nil(判定不能)
    static func clockSkewed(dateOutput: String, hostNow: TimeInterval, thresholdSeconds: Double) -> Bool? {
        let trimmed = dateOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guestEpoch = Double(trimmed) else { return nil }
        return abs(guestEpoch - hostNow) > thresholdSeconds
    }
}

/// プローブ結果の確定判定: 同じ異常が confirmThreshold 回連続で観測されたら確定、
/// 異常なしのプローブ1回で即クリア(過渡的なプローブ揺らぎで修復を誤発動させないため)。
public struct AndroidHealthDebounce {
    private struct SerialState {
        var streaks: [String: Int] = [:]
        var confirmed: Set<String> = []
    }

    private let confirmThreshold: Int
    private var states: [String: SerialState] = [:]

    public init(confirmThreshold: Int = 2) {
        self.confirmThreshold = confirmThreshold
    }

    /// serial の最新プローブ結果を記録し、確定済み異常(ソート済み)を返す
    public mutating func record(_ observed: Set<String>, serial: String) -> [String] {
        var state = states[serial] ?? SerialState()
        // observed に無い異常はカウンタ・確定の両方から即座に消す
        for issue in Set(state.streaks.keys).subtracting(observed) {
            state.streaks.removeValue(forKey: issue)
            state.confirmed.remove(issue)
        }
        for issue in observed {
            let streak = (state.streaks[issue] ?? 0) + 1
            state.streaks[issue] = streak
            if streak >= confirmThreshold {
                state.confirmed.insert(issue)
            }
        }
        states[serial] = state
        return state.confirmed.sorted()
    }

    /// 現在の確定済み異常(record を経ていない serial は空)
    public func confirmed(serial: String) -> [String] {
        (states[serial]?.confirmed ?? []).sorted()
    }

    /// serial の記憶を破棄(デバイス消滅・接続断のとき呼ぶ)
    public mutating func forget(serial: String) {
        states.removeValue(forKey: serial)
    }
}
