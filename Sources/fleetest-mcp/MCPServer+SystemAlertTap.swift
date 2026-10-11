// ft_tap alertButton: — 前面のシステムアラート(SpringBoard)のボタンを、アプリへのセッションを保ったまま押す。
// 以前は ft_launch(springboard)→ ft_tap(ref)→ ft_launch(resume)の3回が要った。

import Foundation
import FTCore

extension MCPServer {

    /// **押すのはエージェントが名指ししたボタンだけ**(自動では押さない。ツールが自分で閉じる範囲 =
    /// 何も決めないボタンと権限の拒否側は広げない)。**xcuitest と hybrid**(hybrid は SpringBoard を XCUITest 側へ
    /// 寄せ、自アプリへの attach で委譲を解く)。in-app だけのときは SpringBoard を掴めない。順序: 照会(`/systemalert`)でボタンの実在を確かめる →
    /// SpringBoard へ向ける(ft_launch の springboard と同じ非破壊の経路)→ 同じラベルの button を押す →
    /// **元のアプリへ attach で向け直す**(activate は使わない = 前面確認だけ。CLAUDE.md の attach の規律)
    func tapSystemAlertButton(_ label: String, driver d: AppDriver,
                              args: [String: Any]) async throws -> [[String: Any]] {
        let key = Self.engineKey(args)
        guard engines[key] == "xcuitest" || engines[key] == "hybrid" else {
            throw MCPError("alertButton: this device is driven through an in-app bridge alone (no XCUITest"
                + " bridge could be prepared), which sees only its own app, not SpringBoard. Read the alert"
                + " with `ft_launch bundleId: com.apple.springboard` and tap its button by ref instead")
        }
        let probe: SystemAlertProbeResponse?
        do {
            probe = try await d.systemAlert()
        } catch {
            throw MCPError("alertButton: could not check for a system alert"
                + " (\(error.localizedDescription)) — nothing was tapped")
        }
        guard let alert = probe, alert.present else {
            throw MCPError("alertButton: no system alert is in front of the app — nothing was tapped")
        }
        let title = alert.title.map { "\"\($0)\"" } ?? "(untitled)"
        guard alert.buttons.contains(label) else {
            throw MCPError("alertButton: the system alert \(title) has no button \"\(label)\" — its"
                + " buttons are \(alert.buttons.map { "\"\($0)\"" }.joined(separator: " / ")). Nothing was tapped")
        }
        let returnTo = launchedBundleIDs[key].flatMap { $0 == Self.springboardBundleID ? nil : $0 }
            ?? lastSnapshots[key]?.sessionBundleID.flatMap { $0 == Self.springboardBundleID ? nil : $0 }
        try await d.launch(bundleID: Self.springboardBundleID)
        let board = try await d.snapshot()
        // **アラートの中の button だけ**を見る(ホーム画面にも同じ文字のアイコンがありうる)
        let inAlert = Self.systemAlertButtons(in: board)
        guard let button = inAlert.first(where: { $0.label == label }) else {
            if let app = returnTo { try? await d.attach(bundleID: app) }
            throw MCPError("alertButton: the alert \(title) listed \"\(label)\" but SpringBoard's tree has"
                + " no such button inside an alert (it may have just closed) — nothing was tapped")
        }
        try await d.tap(ref: button.ref)
        recordAction(InteractionLog.Entry(
            step: nil,
            unresolved: "pressed \"\(label)\" on the system alert \(title) — in a scenario, declare it with"
                + " iosAlertHandler instead",
            summary: "tap system alert button \"\(label)\""), args: args)
        var back = " The session is still pointed at SpringBoard (the app to return to is not known) —"
            + " ft_launch your app with resume: true to go back to it with its state kept."
        if let app = returnTo {
            do {
                try await d.attach(bundleID: app)
                back = " The session is back on \(app)."
            } catch {
                // **向け直せないことを伝えて止める**(activate へ倒さない: 前面でないアプリを前面化すると
                // 画面を動かす。押した結果、別のアラートや別のアプリが前に出ていることがある)
                back = " Could not re-attach to \(app) (\(error.localizedDescription)) — something other"
                    + " than the app may be in front (another alert?). Check with ft_snapshot."
            }
        }
        return text("Pressed \"\(label)\" on the system alert \(title).\(back)"
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
    }

    static let springboardBundleID = "com.apple.springboard"

    /// SpringBoard の木のうち、alert の部分木にある button(preorder + depth で alert の子孫を取る)
    static func systemAlertButtons(in board: SnapshotResponse) -> [ElementInfo] {
        var result: [ElementInfo] = []
        var alertDepth: Int?
        for element in board.elements {
            if let depth = alertDepth, element.depth <= depth { alertDepth = nil }
            if ElementInfo.normalizedType(element.type) == "alert" {
                alertDepth = element.depth
                continue
            }
            if alertDepth != nil, ElementInfo.normalizedType(element.type) == "button" {
                result.append(element)
            }
        }
        return result
    }
}
