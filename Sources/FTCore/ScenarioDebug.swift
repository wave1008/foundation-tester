// ScenarioDebug.swift
// シナリオ実行のデバッグ制御(ブレークポイント・ステップ実行)。
// ホスト(GUI/CLI)⇔ ランナー(ftester-scenarios --debug)の制御プロトコルと、
// ランナー側の一時停止機構をここに集約する。
//
// プロトコル(ホスト → ランナー stdin、NDJSON 1 行 1 コマンド):
//   {"cmd":"continue"}                                … 次の停止条件まで実行
//   {"cmd":"step"}                                    … 次のステップの手前まで実行して一時停止
//   {"cmd":"pause"}                                   … 次のステップの手前で一時停止
//   {"cmd":"stop"}                                    … シナリオを中断(残りは skipped)
//   {"cmd":"breakpoints","locations":["<file>:<line>", …]} … ブレークポイントを全置換
// ランナー → ホストは既存の NDJSON イベントに kind: "paused" を追加
// (index = 次に実行するステップ番号、file/line = そのステップのソース位置)。

import Foundation

// MARK: - ランナー側: 一時停止機構

/// ランナー側のデバッグ制御。DSL スレッドがステップ実行の手前で checkpoint() を呼び、
/// 停止条件に合致したらブロックする。stdin 読み取りスレッドが apply(line:) で再開させる。
/// DSL スレッドは専用スレッド(協調プールの外)なのでブロックしてよい
public final class ScenarioDebugControl: @unchecked Sendable {

    /// checkpoint() の結果: そのまま実行を続けるか、シナリオを中断するか
    public enum CheckpointResult: Sendable {
        case proceed
        case abort
    }

    private enum ResumeAction {
        case continueRun, stepOver, stop
    }

    private let condition = NSCondition()
    private var breakpoints: [(file: String, line: Int)]
    /// 次のステップの手前で必ず止まる(--pause-on-start / step / pause で立つ)
    private var pauseAtNextStep: Bool
    /// 停止中でないときに stop を受けた(次の checkpoint で即中断)
    private var stopRequested = false
    private var paused = false
    private var pendingAction: ResumeAction?

    public init(breakpoints: [String] = [], pauseOnStart: Bool = false) {
        self.breakpoints = breakpoints.compactMap(Self.parseLocation)
        self.pauseAtNextStep = pauseOnStart
    }

    /// "<file>:<line>" → (file, line)。最後の「:」で分割する(パスに「:」が含まれても壊れない)
    public static func parseLocation(_ text: String) -> (file: String, line: Int)? {
        guard let colon = text.lastIndex(of: ":"),
              let line = Int(text[text.index(after: colon)...]), line > 0 else { return nil }
        let file = String(text[..<colon])
        return file.isEmpty ? nil : (file, line)
    }

    /// ステップ実行の手前で呼ぶ。停止条件に合致したら onPause(paused イベントの emit)を
    /// 呼んでからブロックし、再開コマンドを待つ。合致しなければ即 .proceed
    public func checkpoint(file: String, line: Int, onPause: () -> Void) -> CheckpointResult {
        condition.lock()
        if stopRequested {
            condition.unlock()
            return .abort
        }
        guard pauseAtNextStep || hitsBreakpoint(file: file, line: line) else {
            condition.unlock()
            return .proceed
        }
        pauseAtNextStep = false
        paused = true
        condition.unlock()

        onPause()  // イベントの emit はロック外で(stdout への書き込みを拘束しない)

        condition.lock()
        while pendingAction == nil {
            condition.wait()
        }
        let action = pendingAction!
        pendingAction = nil
        paused = false
        if action == .stepOver { pauseAtNextStep = true }
        condition.unlock()
        return action == .stop ? .abort : .proceed
    }

    /// ホストからの制御コマンド 1 行を適用する(stdin 読み取りスレッドから呼ぶ)
    public func apply(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String else { return }
        condition.lock()
        defer { condition.unlock() }
        switch cmd {
        case "continue":
            resumeLocked(.continueRun)
        case "step":
            // 停止中なら 1 ステップ進めて再停止、実行中なら次のステップで停止
            if paused { resumeLocked(.stepOver) } else { pauseAtNextStep = true }
        case "pause":
            pauseAtNextStep = true
        case "stop":
            if paused { resumeLocked(.stop) } else { stopRequested = true }
        case "breakpoints":
            let locations = object["locations"] as? [String] ?? []
            breakpoints = locations.compactMap(Self.parseLocation)
        default:
            break
        }
    }

    private func resumeLocked(_ action: ResumeAction) {
        guard paused, pendingAction == nil else { return }
        pendingAction = action
        condition.signal()
    }

    /// 行が一致し、パスが一致(または一方が他方の末尾)ならヒット。
    /// ランナーの相対化とホストの dry-run 由来のパスは通常同一文字列だが、
    /// 絶対/相対の混在にも耐えるようにしておく
    private func hitsBreakpoint(file: String, line: Int) -> Bool {
        breakpoints.contains { bp in
            bp.line == line && (bp.file == file
                || file.hasSuffix("/" + bp.file) || bp.file.hasSuffix("/" + file))
        }
    }
}

// MARK: - ホスト側: 制御チャネルとデバッグ実行設定

/// ホスト → ランナーの制御チャネル(ランナー stdin への書き込み口)。
/// ScenarioHost.run(debug:) が起動直後に onControl で渡す
public final class ScenarioRunControl: @unchecked Sendable {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    public func continueRun() { send(["cmd": "continue"]) }
    public func stepOver() { send(["cmd": "step"]) }
    public func pause() { send(["cmd": "pause"]) }
    public func stop() { send(["cmd": "stop"]) }
    public func setBreakpoints(_ locations: [String]) {
        send(["cmd": "breakpoints", "locations": locations])
    }

    private func send(_ command: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: command) else { return }
        data.append(Data("\n".utf8))
        // プロセス終了直後の broken pipe は無視(実行終了は scenarioFinished で伝わる)
        try? handle.write(contentsOf: data)
    }
}

/// デバッグ実行の設定(ScenarioHost.run へ渡す)
public struct ScenarioDebugOptions: Sendable {
    /// 初期ブレークポイント("<file>:<line>"。file は dry-run の step イベントと同じ表記)
    public let breakpoints: [String]
    /// 最初のステップの手前で一時停止して開始する(ステップ実行の起点)
    public let pauseOnStart: Bool
    /// ランナー起動直後に制御チャネルを渡す(ホストはこれで続行・ステップ・停止を送る)
    public let onControl: @Sendable (ScenarioRunControl) -> Void

    public init(breakpoints: [String], pauseOnStart: Bool,
                onControl: @escaping @Sendable (ScenarioRunControl) -> Void) {
        self.breakpoints = breakpoints
        self.pauseOnStart = pauseOnStart
        self.onControl = onControl
    }
}
