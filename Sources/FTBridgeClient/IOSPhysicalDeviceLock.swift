// 実機が「今ロックされているか」をホストから読む。**ロックされた端末ではランナーを起動できない**
// (SpringBoard が `denied by SBMainWorkspace ... reason: Locked` で拒否する)ので、
// ビルドと起動の前にここで見て人に促す。起動後の再ロックはランナー側が防ぐ
// (Runner/FleetestRunnerUITests/KeepAwake.swift)。**自動解除は原理的にできない** ——
// 端末に入力を撃つ手段がランナー自身なので、ランナーが無い状態では起こしようがない。
//
// 信号は `xcrun devicectl device info lockState` の **`passcodeRequired`**。
// これは「今パスコードの入力が要るか」= 画面ロックの現況で、静的な「パスコードを設定して
// あるか」ではない(2026-08-27 実機実測 iPhone SE3: 消灯 true / 解除して点灯 false、
// 自動ロック 30 秒での false→true の遷移も観測)。実測 0.23 秒。
//
// **パスコード未設定の端末では常に false** になるため、その場合は locked を見落とす。
// 誤検知(解除済みなのにロックと言う)を出さない側に倒してあり、見落としても従来どおり
// xcodebuild のログからの検出(IOSDeviceTransport.blockingCondition)に落ちるだけ。
// **`devicectl device info displays` の `backlightState` は使えない** —— 消灯中でも
// `activeOn` を返した(同時刻の IORegistry は CurrentPowerState=0)。

import FTCore
import Foundation

public enum IOSPhysicalDeviceLock {

    public enum State: Equatable {
        case locked
        case unlocked
        /// 読めなかった(devicectl が無い・端末が居ない・形式が変わった)。**促さない**
        case unknown
    }

    /// 解除待ちのポーリング間隔(秒)。人が端末を手に取って解除する動作に対しての刻みで、
    /// 1 回 0.23 秒の devicectl を挟むので詰めても意味がない
    private static let pollIntervalSeconds: TimeInterval = 2

    /// devicectl の JSON から現況を読む(I/O 抜き。ここだけが形式を知っている)
    public static func parse(_ data: Data) -> State {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let required = result["passcodeRequired"] as? Bool else { return .unknown }
        return required ? .locked : .unlocked
    }

    public static func query(udid: String) -> State {
        guard let out = try? Shell.runData(
            ["xcrun", "devicectl", "device", "info", "lockState",
             "--device", udid, "--json-output", "-"], timeout: 20), out.status == 0 else {
            return .unknown
        }
        return parse(out.data)
    }

    /// 解除されるまで待つ。**促すのは 1 回だけ**(同じ行を刻み続けない)。
    /// 待ちきれなくても throw しない —— 起動を試みて既存の締切と診断に委ねる
    /// (ここで落とすと、解除が間に合った端末まで殺すことになる)
    @discardableResult
    public static func waitForUnlock(udid: String, deviceName: String, timeout: TimeInterval,
                                     log: (String) -> Void) async -> State {
        var state = query(udid: udid)
        guard state == .locked else { return state }
        log("⏳ \(deviceName) is locked — unlock it now. The runner cannot be launched on a locked "
            + "device (it keeps the device awake once it is up).")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            state = query(udid: udid)
            if state != .locked {
                log("✔ \(deviceName): unlocked")
                return state
            }
        }
        return state
    }
}
