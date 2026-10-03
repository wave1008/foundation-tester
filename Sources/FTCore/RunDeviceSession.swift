// RunDeviceSession.swift
// 1回の run(または1回の呼び出し)× 1デバイスで共有する状態の親側の持ち主。
// 受け渡しの契約は DeviceSessionHandoff.swift。ScenarioHost.run が子の memoWrite / memoClear /
// deviceSetUp を横取りしてここへ反映し、次のシナリオの起動時に handoff(className:) を stdin へ書く。

import Foundation

public final class RunDeviceSession: @unchecked Sendable {
    private enum SetUpState { case began, passed, failed }

    private let lock = NSLock()
    private var memo: [String: [String]] = [:]
    /// 試行済みのクラスだけを持つ(キー無し = 未試行)
    private var setUpStates: [String: SetUpState] = [:]
    /// tearDownDevice を持つと子が申告したクラス(申告順 = 片付けの順。決定的にするため配列)
    private var tearDownDeclared: [String] = []
    private var tornDown: Set<String> = []

    public init() {}

    /// シナリオ ID(`Class.method`)のクラス部。Swift の識別子は "." を含められないので最初の "." で切る。
    /// "." が無い ID(クラスだけの指定)は丸ごと返す
    public static func className(ofScenarioID id: String) -> String {
        guard let dot = id.firstIndex(of: ".") else { return id }
        return String(id[id.startIndex..<dot])
    }

    /// nil = このクラスの setUpDevice がこのデバイスで失敗済み(呼び出し側はシナリオを走らせない)。
    /// setUpDevice を持たないクラスは deviceSetUp を出さず未試行のままなので、毎回 runSetUpDevice = true
    /// になる(子が無視する。クラスごとの有無は追跡しない)
    public func handoff(className: String) -> DeviceSessionHandoff? {
        lock.lock()
        defer { lock.unlock() }
        let state = setUpStates[className]
        if state == .failed { return nil }
        return DeviceSessionHandoff(memo: memo, runSetUpDevice: state == nil)
    }

    /// 子の memoWrite / memoClear / deviceSetUp を反映する。戻り値 true = 横取りした(emit しない)
    @discardableResult
    public func apply(_ event: ScenarioEvent, className: String) -> Bool {
        switch event.kind {
        case "memoWrite":
            if let key = event.memoKey, let value = event.memoValue {
                lock.lock()
                memo[key, default: []].append(value)
                lock.unlock()
            }
            return true
        case "memoClear":
            lock.lock()
            memo.removeAll()
            lock.unlock()
            return true
        case "deviceTearDown":
            // status "declared" だけ(子がシナリオの開始時に、クラスが tearDownDevice を持つときに出す)
            if event.status == "declared" {
                lock.lock()
                if !tearDownDeclared.contains(className) { tearDownDeclared.append(className) }
                lock.unlock()
            }
            return true
        case "deviceSetUp":
            let next: SetUpState?
            switch event.status {
            case "began": next = .began
            case "passed": next = .passed
            case "failed": next = .failed
            default: next = nil
            }
            if let next {
                lock.lock()
                setUpStates[className] = next
                lock.unlock()
            }
            return true
        default:
            return false
        }
    }

    /// tearDownDevice 専用の子へ渡す写し(setUpDevice は走らせない・失敗済みでも片付けは走らせる)
    public func tearDownHandoff() -> DeviceSessionHandoff {
        lock.lock()
        defer { lock.unlock() }
        return DeviceSessionHandoff(memo: memo, runSetUpDevice: false)
    }

    /// まだ片付けていない申告済みクラス(申告順)を返し、**返した時点で済み印を付ける** = 1デバイスで最大1回
    /// (結果が不明でも撃ち直さない。setUpDevice と同じ at-most-once)
    public func takePendingTearDowns() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let pending = tearDownDeclared.filter { !tornDown.contains($0) }
        tornDown.formUnion(pending)
        return pending
    }

    /// 子の終了後に呼ぶ。began のまま終わった(setUpDevice の途中で死んだ・kill された)クラスは failed にする。
    /// 途中まで走った setUpDevice(アカウント作成等)を再実行すると二重実行になるので、at-most-once
    public func scenarioEnded(className: String) {
        lock.lock()
        if setUpStates[className] == .began { setUpStates[className] = .failed }
        lock.unlock()
    }
}

/// レーン鍵(`BroadcastPlan.laneKey(of:)`)→ RunDeviceSession。初回に作る
public final class RunDeviceSessionBook: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: RunDeviceSession] = [:]

    public init() {}

    public func session(for laneKey: String) -> RunDeviceSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[laneKey] { return existing }
        let created = RunDeviceSession()
        sessions[laneKey] = created
        return created
    }
}

/// tearDownDevice 1本の結果(呼び手が自分の文脈の行へ写す)
public struct DeviceTearDownOutcome: Sendable {
    public let className: String
    public let passed: Bool
    public let reportPath: String?
    /// 最初に落ちたステップの説明と理由(passed なら nil)
    public let failure: String?
}

extension ScenarioHost {
    /// **デバイスの仕事が終わった時点で**、そのデバイスで tearDownDevice を申告したクラスを1本ずつ片付ける。
    /// 共有キューでは「このデバイスでのクラス最後のシナリオ」が取り出し時点で決まらない(残りを別デバイスが取りうる)
    /// ので、シナリオの子の中では走らせず、ここで専用の子を起こす。中断時・離脱したデバイスでは呼ばない(呼び手の責務)。
    /// 結果は results に載せない(シナリオではない)。レポート(.md)は子が書く
    public static func runDeviceTearDowns(project: TestProject, connection: DriverConnection,
                                          deviceSession: RunDeviceSession,
                                          settings: ScenarioExecutionSettings, reportDir: String,
                                          dryRun: Bool,
                                          appPath: String?, appName: String?, appBundleID: String?,
                                          registerChildProcess: (@Sendable (Process) -> @Sendable () -> Void)?)
        async -> [DeviceTearDownOutcome] {
        var outcomes: [DeviceTearDownOutcome] = []
        for className in deviceSession.takePendingTearDowns() {
            var reportPath: String?
            var failure: String?
            let passed = await run(project: project, scenarioID: "\(className).tearDownDevice",
                                   connection: connection, deviceSession: deviceSession,
                                   settings: settings, reportDir: reportDir, dryRun: dryRun,
                                   appPath: appPath, appName: appName, appBundleID: appBundleID,
                                   registerChildProcess: registerChildProcess,
                                   deviceTearDownOnly: true) { event in
                if event.kind == "scenarioFinished" { reportPath = event.reportPath }
                if failure == nil, event.kind == "step", event.status == "failed" {
                    failure = [event.description, event.detail].compactMap { $0 }.joined(separator: ": ")
                }
            }
            outcomes.append(DeviceTearDownOutcome(className: className, passed: passed,
                                                  reportPath: reportPath, failure: failure))
        }
        return outcomes
    }

    /// 呼び手の log 行(英語。CLI の文言は英語だけ)
    public static func describe(_ outcome: DeviceTearDownOutcome) -> String {
        if outcome.passed { return "tearDownDevice of \(outcome.className): passed" }
        return "⚠️ tearDownDevice of \(outcome.className) failed"
            + (outcome.failure.map { " — \($0)" } ?? "")
            + (outcome.reportPath.map { " (report: \($0))" } ?? "")
    }
}
