// connected な Android エミュレータのゲスト OS 健全性を低頻度で確認する(ApiMonitorCommand.swift
// から呼ばれる)。adb 接続は生きているがゲスト側が不健全(Wi-Fi 無効・ゲスト時計が凍結)なまま
// テストが延々失敗し続けた実害(2026-07-16)への対策。

import FTCore
import Foundation

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

    /// serial のエミュレータに adb で2プローブを実行する。adb 失敗(コマンドエラー・出力パース
    /// 不能)はそのプローブの判定をスキップ(=異常扱いしない。誤検知よりプローブ欠測を優先)。
    public static func observeIssues(serial: String, hostNow: Date = Date()) -> Set<String> {
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
        if let cap = try? Shell.runData([adbPath, "-s", serial, "exec-out", "screencap", "-p"]),
           cap.status == 0, blankScreen(pngByteCount: cap.data.count) {
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
            let blank = probeBlank(serial: serial)
            observed.append(blank)
            if !blank { break }  // 非blank観測=フラッピングの回復側。即座に健全確定し以降は待たない
            if i < samples - 1 {
                try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            }
        }
        return decidePersistentBlank(samples: observed)
    }

    /// serial に1回 screencap して blank 判定する。adb 取得失敗(コマンドエラー・status != 0)は
    /// 「blank ではない」扱い(誤って健全機を除外しない安全側)
    private static func probeBlank(serial: String) -> Bool {
        guard let adbPath = try? AndroidDriver.findADB(),
              let cap = try? Shell.runData([adbPath, "-s", serial, "exec-out", "screencap", "-p"]),
              cap.status == 0 else {
            return false
        }
        return blankScreen(pngByteCount: cap.data.count)
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
