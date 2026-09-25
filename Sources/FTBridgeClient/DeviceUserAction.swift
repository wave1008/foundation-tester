// 実機のブリッジ起動で「端末の前で人がやらないと進まないこと」。ツールからは代行できない
// (端末へ入力を撃つ手段がランナー自身なので、ランナーが上がる前には何もできない)。
// 知らせる先: `api start-device` / `start-all-devices` の NDJSON `deviceAction`
// (Sources/fleetest/ApiDeviceCommands.swift の ApiDeviceActionEvent)→ 拡張のタイルと通知
// (vscode-fleetest/src/monitorDeviceActionNotice.ts)。raw 値はワイヤに載る = 片方だけ変えない

import Foundation

public enum DeviceUserAction: String, Sendable, Equatable {
    /// 画面ロック中(`IOSPhysicalDeviceLock`)。ロック中はランナー自体が起動を拒否される
    case unlock
    /// UI 自動化の承認プロンプト(Touch ID / パスコード)が端末に出ている間
    /// (`IOSDeviceTransport.awaitingAutomationApproval`)。通さないと XCTest が
    /// `Timed out while enabling automation mode` で打ち切る
    case approveAutomation
}

/// 承認待ちの出入りを1回ずつ知らせる。ランナーのログを読む2つの待ち(LAN の宣言待ち
/// `IOSDeviceTransport.waitForAnnouncedAddress`・USB の ready 待ち `BridgeLauncher.waitUntilReady`)が
/// 同じ判定を通すために共有する。**待ちを抜けるときは `finish()` を必ず呼ぶ**(defer)——
/// 呼ばないと、失敗・中断で抜けたあともタイルと通知が「認証してください」のまま残る
final class AutomationApprovalTracker {
    /// 待ちの上限に達した時点でまだ承認待ちだったときの理由(総称の「時間内に上がらなかった」の代わり)。
    /// XCTest が自分で打ち切る(60 秒・`runnerFailureReason` が名指し)とは限らない ——
    /// 打ち切らずにツールの上限まで待つ形も実測した(iPhone SE3)
    static let notApprovedReason = "the UI-automation prompt on the iPhone (Touch ID / passcode) was not"
        + " approved. Start the bridge again and authenticate on the device while the prompt is shown"

    private(set) var pending = false
    private let notify: (Bool) -> Void
    private let log: (String) -> Void

    init(notify: @escaping (Bool) -> Void, log: @escaping (String) -> Void) {
        self.notify = notify
        self.log = log
    }

    func observe(log text: String) {
        let now = IOSDeviceTransport.awaitingAutomationApproval(inLog: text)
        guard now != pending else { return }
        pending = now
        if now {
            log("⏳ approve the UI-automation prompt on the iPhone (Touch ID / passcode)."
                + " The runner waits for it and gives up if it is not approved")
        }
        notify(now)
    }

    func finish() {
        guard pending else { return }
        pending = false
        notify(false)
    }
}
