import Foundation

/// 折りたたみ機(iOS Simulator の iPhone Duo / Android Emulator の折りたたみ AVD)の開閉。
/// **DSL の fold / unfold / hinge と MCP の ft_fold が共有する**(判定・手順はここだけ。文言は呼び手が持つ)。
/// 送るのはドライバの `setHingeAngle`(iOS = XCUITest ランナーの POST /hinge / Android = `adb emu`)、
/// 状態の観測は呼び手が渡す(iOS Simulator = `observeIOSSimulator` / Android = `AppDriver.foldObservation`)。
///
/// 実測(Xcode 27.2 beta 3・iPhone Duo の Simulator):
/// - 0° で外側(`LCD` 466x678pt)・180° で内側(`LCD-1` 669x951pt)。送ってから約 0.2 秒で切り替わる
/// - **途中の角度は履歴に依存する**(開く向きは 120°→150° の間、閉じる向きは 20°→10° の間で切り替わる)。
///   だから角度を指定した送り(`FoldTarget.angle`)は画面を決め打ちで確かめず、結果を報告するだけ
public enum FoldState: String, Sendable, Equatable {
    case folded, unfolded
}

public enum FoldObservation: Sendable, Equatable {
    /// 折りたたみ機ではない(内蔵画面が1枚 / 折りたたみの状態を持たない Emulator)
    case notFoldable
    case state(FoldState)
    /// 読めなかった(観測の失敗・表示中が1枚に決まらない)。中身は観測が言ったこと
    case unknown(String)
}

public enum FoldTarget: Sendable, Equatable {
    case fold
    case unfold
    /// 0(閉)〜180(開)。途中の角度は履歴で画面が変わるので確かめない
    case angle(Double)

    public var degrees: Double {
        switch self {
        case .fold: FoldControl.foldedDegrees
        case .unfold: FoldControl.unfoldedDegrees
        case .angle(let degrees): degrees
        }
    }

    /// 送った後に成っているはずの状態(角度指定は nil = 確かめない)
    public var expected: FoldState? {
        switch self {
        case .fold: .folded
        case .unfold: .unfolded
        case .angle: nil
        }
    }
}

public enum FoldControl {
    public static let degreesRange = HingeRequest.degreesRange
    public static let foldedDegrees = degreesRange.lowerBound
    public static let unfoldedDegrees = degreesRange.upperBound
    /// 切り替わりを待つ間の観測の刻み(秒)。観測1回(devicectl 約 0.14 秒・adb)より短く、
    /// 観測を休みなく撃ち続けない程度。切り替えの実測は約 0.2 秒
    static let pollIntervalSeconds: Double = 0.1

    public enum Failure: Error, Equatable {
        case outOfRange(Double)
        case notFoldable
        /// 送る前に状態を読めなかった(確かめられないので送らない)
        case unreadable(String)
        /// 送ったが期限内に期待の状態にならなかった。observed は最後に読めた観測
        case didNotSwitch(expected: FoldState, observed: FoldObservation, waitedSeconds: Double)
    }

    public struct Outcome: Sendable, Equatable {
        /// 送る前の状態(呼び手がシナリオの終わりに戻すために控える)
        public let before: FoldState
        /// 送った後に読めた状態(角度指定で読めなかったときは nil)
        public let after: FoldState?

        public init(before: FoldState, after: FoldState?) {
            self.before = before
            self.after = after
        }
    }

    /// 送って、期待の状態になるまで待つ。**送る前に状態を読む** —— 折りたたみ機でない・読めないなら送らない。
    /// `sent` は送る直前に送る前の状態で呼ばれる(確かめで落ちても呼び手が元へ戻せるように控える口)
    public static func apply(_ target: FoldTarget, waitSeconds: Double,
                             send: (Double) async throws -> Void,
                             observe: () async -> FoldObservation,
                             sent: (FoldState) -> Void) async throws -> Outcome {
        let degrees = target.degrees
        guard degreesRange.contains(degrees) else { throw Failure.outOfRange(degrees) }
        let before: FoldState
        switch await observe() {
        case .notFoldable: throw Failure.notFoldable
        case .unknown(let detail): throw Failure.unreadable(detail)
        case .state(let state): before = state
        }
        sent(before)
        try await send(degrees)
        guard let expected = target.expected else {
            if case .state(let after) = await observe() { return Outcome(before: before, after: after) }
            return Outcome(before: before, after: nil)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(max(0, waitSeconds) * 1000))
        var last = await observe()
        while last != .state(expected), clock.now < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            last = await observe()
        }
        guard last == .state(expected) else {
            throw Failure.didNotSwitch(expected: expected, observed: last, waitedSeconds: waitSeconds)
        }
        return Outcome(before: before, after: expected)
    }

    /// 元の状態へ戻す送り先(シナリオの終わり)。戻す必要が無ければ nil
    public static func restoreTarget(original: FoldState?, current: FoldState?) -> FoldTarget? {
        guard let original, original != current else { return nil }
        return original == .folded ? .fold : .unfold
    }

    // MARK: - Android の観測

    /// Android の `cmd device_state print-states; echo <区切り>; cmd device_state print-state` の出力 → 観測(純粋)。
    /// 状態の一覧に `CLOSED` が無ければ折りたたみ機ではない。今の状態の名前が CLOSED = 閉 /
    /// HALF_OPENED・OPENED = 開(内側の画面)。それ以外(REAR_DISPLAY_MODE 等)は unknown
    /// (Pixel 9 Pro Fold の Emulator・API 36 の実測: 0 CLOSED / 1 HALF_OPENED / 2 OPENED / 3 REAR_DISPLAY_MODE)
    public static let androidStateSeparator = "--ft-fold--"
    public static func observe(androidDeviceState output: String) -> FoldObservation {
        let parts = output.components(separatedBy: androidStateSeparator)
        guard parts.count == 2 else { return .unknown("unexpected device_state output") }
        var names: [Int: String] = [:]
        let pattern = /DeviceState\{identifier=(\d+), name='([A-Z_]+)'/
        for match in parts[0].matches(of: pattern) {
            if let id = Int(match.1) { names[id] = String(match.2) }
        }
        guard names.values.contains("CLOSED") else { return .notFoldable }
        guard let current = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              let name = names[current] else {
            return .unknown("device_state reported an unknown current state")
        }
        switch name {
        case "CLOSED": return .state(.folded)
        case "HALF_OPENED", "OPENED": return .state(.unfolded)
        default: return .unknown("device_state is \(name)")
        }
    }

    // MARK: - iOS Simulator の観測

    /// `devicectl device info displays --json-output -` の全体 → 観測(純粋)。
    /// 内蔵画面が1枚 = 折りたたみ機ではない。表示中(`active`)が**面積の小さい側 = 閉じている**
    /// (Duo は外側 1398x2034px < 内側 2007x2853px)。表示中が1枚に決まらなければ unknown
    /// (`simctl io screenConfig power` で画面の電源を触ると `active` 欄ごと消える = 実測)
    public static func observe(fromDevicectlJSON data: Data) -> FoldObservation {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]] else {
            return .unknown("devicectl did not return a display list")
        }
        let integrated = displays.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
        guard integrated.count > 1 else { return .notFoldable }
        func area(_ display: [String: Any]) -> Int {
            guard let size = display["nativeSize"] as? [Int], size.count == 2 else { return 0 }
            return size[0] * size[1]
        }
        let active = integrated.filter { ($0["active"] as? Bool) == true }
        guard active.count == 1, let shown = active.first else {
            return .unknown("devicectl reports \(active.count) active built-in displays")
        }
        let smallest = integrated.map(area).min() ?? 0
        return .state(area(shown) == smallest ? .folded : .unfolded)
    }

    /// iOS Simulator の観測(devicectl 1回・実測 0.14 秒)
    public static func observeIOSSimulator(udid: String) -> FoldObservation {
        guard let out = try? Shell.runData(
            ["xcrun", "devicectl", "device", "info", "displays", "--device", udid, "--quiet", "--json-output", "-"],
            timeout: 15) else {
            return .unknown("devicectl device info displays did not finish")
        }
        guard out.status == 0 else {
            return .unknown("devicectl device info displays exited with status \(out.status)")
        }
        return observe(fromDevicectlJSON: out.data)
    }
}
