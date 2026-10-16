import Foundation
import FTCore
import FTAndroid
import FTBridgeClient

// ft_fold(折りたたみ機の開閉)。判定・手順は FTCore.FoldControl(DSL の fold / unfold / hinge と共有)。
// ここは引数の検査・宛先の解決・文言だけ。シナリオの終わりが無いので元の状態へは戻さない。
extension MCPServer {
    /// state と degrees はちょうど1つ(純粋関数。ドライバに触る前に断る)
    static func foldTarget(_ args: [String: Any]) throws -> FoldTarget {
        let state = try stringArgument(args, "state")
        let degrees = try doubleArgument(args, "degrees")
        switch (state, degrees) {
        case (nil, nil):
            throw MCPError("give exactly one of state (\"fold\" or \"unfold\") or degrees (0-180)")
        case (.some, .some):
            throw MCPError("give either state or degrees, not both")
        case (let state?, nil):
            switch state {
            case "fold": return .fold
            case "unfold": return .unfold
            default: throw MCPError("state must be \"fold\" or \"unfold\" (got \"\(state)\")")
            }
        case (nil, let degrees?):
            return .angle(degrees)
        }
    }

    static func foldFailureMessage(_ failure: FoldControl.Failure) -> String {
        func format(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
        switch failure {
        case .outOfRange(let degrees):
            return "degrees must be between 0 (folded) and 180 (unfolded), got \(format(degrees))"
        case .notFoldable:
            return "this device is not foldable — ft_fold needs the iPhone Duo simulator or a foldable"
                + " Android Emulator. Nothing was sent"
        case .unreadable(let detail):
            return "could not read whether the device is folded (\(detail)), so nothing was sent"
        case .didNotSwitch(let expected, let observed, let waited):
            let last: String
            switch observed {
            case .state(let state): last = "it stayed \(state.rawValue)"
            case .notFoldable: last = "it no longer reports two built-in displays"
            case .unknown(let detail): last = "the fold state could not be read: \(detail)"
            }
            return "the device did not become \(expected.rawValue) within \(format(waited))s after the hinge"
                + " event (\(last)). On iOS the hinge event is an undocumented simulator interface, so this"
                + " Xcode may not accept it"
        }
    }

    func ftFold(_ args: [String: Any]) async throws -> [[String: Any]] {
        let target = try Self.foldTarget(args)
        let wait = try Self.doubleArgument(args, "waitSeconds") ?? Self.defaultWaitSeconds
        let foldDriver = try await driver(args)
        let observe: () async -> FoldObservation
        if Self.platformName(args) == "android" {
            observe = { await foldDriver.foldObservation() ?? .unknown("the driver does not report the fold state") }
        } else {
            let udid = try await foldSimulatorUDID(foldDriver, args: args)
            observe = { FoldControl.observeIOSSimulator(udid: udid) }
        }
        do {
            let outcome = try await FoldControl.apply(target, waitSeconds: wait,
                                                      send: { try await foldDriver.setHingeAngle(degrees: $0) },
                                                      observe: observe, sent: { _ in })
            // Android の折りたたみ機は閉じるとロック画面が出る(ドライバが外す。iOS は何もしない)
            await foldDriver.continueAfterFold()
            // 開閉で画面の大きさごと変わるので、覚えている木は捨てて撮り直す(ft_rotate と同じ理由)
            var head: String
            switch target {
            case .fold: head = "Folded."
            case .unfold: head = "Unfolded."
            case .angle(let degrees): head = "Hinge set to \(degrees == degrees.rounded() ? String(Int(degrees)) : String(degrees))°."
            }
            if case .angle = target {
                head += outcome.after.map { " The device now reports \($0.rawValue) (an in-between angle is not verified)." }
                    ?? " Which screen shows was not verified."
            }
            // **開閉は済んでいる**(取り消せない)。木が読めない(アプリのセッションが無い等)だけで失敗と返さない
            let settled: (snapshot: SnapshotResponse, fits: Bool)
            do {
                settled = try await settledTree(foldDriver, args: args)
            } catch {
                return text(head + " The screen tree could not be read afterwards (\(ErrorText.user(error)))"
                    + " — refs taken before this are gone; call ft_snapshot (after ft_launch if no app is running).")
            }
            recordSnapshot(settled.snapshot, foldDriver is AndroidDriver ? "android" : "ios", args)
            let relayoutCaveat = settled.fits ? ""
                : " note: the tree did not settle within the check budget — it may still be"
                    + " mid-relayout; take another ft_snapshot before relying on these frames."
            return text(head + " The frames below are in the new coordinate system — refs taken before"
                + " this are gone." + relayoutCaveat + "\n\n"
                + (await snapshotBody(settled.snapshot, driver: foldDriver, args: args, foldsSelectorTables: true)))
        } catch let failure as FoldControl.Failure {
            throw MCPError(Self.foldFailureMessage(failure))
        }
    }

    /// iOS の Simulator の udid。実機は断る(折りたためない)。
    /// 候補は ft_list_apps と同じ順(明示 → セッションの記憶 → ポートの実機記録 → /status の自己申告)
    private func foldSimulatorUDID(_ foldDriver: AppDriver, args: [String: Any]) async throws -> String {
        let key = Self.engineKey(args)
        let candidate = (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? udids[key].flatMap { $0 }
            ?? connectedPorts[key].flatMap { port in
                (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
            }
        let refusal = MCPError("ft_fold cannot fold a physical device (fold it by hand);"
            + " it works on the iPhone Duo simulator")
        // シミュレータの udid は UUID 形。UUID でなければ実機の可能性があるので台帳で確かめる
        if let candidate, UUID(uuidString: candidate) == nil {
            if let physical = try? IOSPhysicalDeviceCatalog.devices(),
               physical.contains(where: { $0.udid == candidate || $0.deviceCtlIdentifier == candidate }) {
                throw refusal
            }
        }
        if let candidate, UUID(uuidString: candidate) != nil { return candidate }
        if let reported = try? await foldDriver.status().udid { return reported }
        // /status がシミュレータの udid を名乗らない = 実機か、udid を知らせない旧ブリッジ
        if candidate != nil { throw refusal }
        throw MCPError("could not determine the simulator's udid — pass udid (see ft_list_devices)")
    }

    /// ft_rotate と同じ整定(`RotationSettle` の締め切りと間隔)。**cap が無いと一度も整定しないドライバで止まらない**
    private func settledTree(_ foldDriver: AppDriver, args: [String: Any]) async throws
        -> (snapshot: SnapshotResponse, fits: Bool) {
        var current = try await freshSnapshot(foldDriver, args: args)
        let interval = max(RotationSettle.pollIntervalSeconds, settleWaitSeconds)
        let maxRereads = Int(rotationSettleDeadlineSeconds / interval)
        for _ in 0..<maxRereads {
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            let reread = try await freshSnapshot(foldDriver, args: args)
            let fits = RotationSettle.framesFitScreen(reread)
            let unchanged = BackEffect.treesAreIdentical(before: current.elements, after: reread.elements)
            current = reread
            if fits, unchanged { return (current, true) }
        }
        return (current, false)
    }
}
