// CommandsMemo.swift
// メモ(デバイスセッションの共有値)。名前・挙動は Shirates の Memo と同じ(writeMemo は履歴に追記・
// readMemo は最後の値か ""・clearMemo は全消去)。スコープは「1回の run × 1デバイス」で、
// 別デバイスで書いた値は見えない。親への通知とハンドオフの契約は FTCore/DeviceSessionHandoff.swift。

import Foundation
import FTCore

extension FTDriveCore {
    /// 追記してから親へ片道通知する(応答なし)。呼び出し側が scenarioAborted を先に見る
    func memoAppend(_ key: String, _ text: String) {
        deviceMemo[key, default: []].append(text)
        var event = ScenarioEvent(kind: "memoWrite")
        event.memoKey = key
        event.memoValue = text
        emit(event)
    }

    func memoRemoveAll() {
        deviceMemo.removeAll()
        emit(ScenarioEvent(kind: "memoClear"))
    }
}

/// メモにキーの値を追記する(履歴を持ち、readMemo は最後の値を返す)
public func writeMemo(_ key: String, _ text: String,
                      file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "writeMemo")
    let description = "writeMemo \"\(key)\" = \"\(text)\""
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "writeMemo")
        return
    }
    core.memoAppend(key, text)
    core.recordStep(description: description, status: .passed,
                    file: "\(file)", line: Int(line), command: "writeMemo")
}

/// キーの最後の値を返す。**無ければ ""**(失敗にしない。Shirates と同じ)で、注記 `memo-key-not-found` を残す
@discardableResult
public func readMemo(_ key: String,
                     file: StaticString = #filePath, line: UInt = #line) -> String {
    let core = FTRuntime.requireCore(command: "readMemo")
    if core.scenarioAborted {
        core.recordStep(description: "readMemo \"\(key)\"", status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "readMemo")
        return ""
    }
    guard let value = core.deviceMemo[key]?.last else {
        core.recordStep(description: "readMemo \"\(key)\" → \"\"", status: .passed,
                        file: "\(file)", line: Int(line), notes: [.memoKeyNotFound], command: "readMemo")
        return ""
    }
    core.recordStep(description: "readMemo \"\(key)\" → \"\(value)\"", status: .passed,
                    file: "\(file)", line: Int(line), command: "readMemo")
    return value
}

/// このデバイスのメモを全部消す
public func clearMemo(file: StaticString = #filePath, line: UInt = #line) {
    let core = FTRuntime.requireCore(command: "clearMemo")
    if core.scenarioAborted {
        core.recordStep(description: "clearMemo", status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "clearMemo")
        return
    }
    core.memoRemoveAll()
    core.recordStep(description: "clearMemo", status: .passed,
                    file: "\(file)", line: Int(line), command: "clearMemo")
}

extension FTElement {
    /// 掴んだ要素のテキスト(ラベル → 値のうち**空でない最初のもの**。Shirates の textOrLabel と同じく空文字は
    /// 「無い」扱い = 入力欄はラベルが "" で値に文字を持つ)をメモに書き、要素を返す。
    /// 要素を掴めていない(`isEmpty`)ときは失敗にする(空文字を黙って書かない)。dry-run は "" を書く
    @discardableResult
    public func memoTextAs(_ key: String,
                           file: StaticString = #filePath, line: UInt = #line) -> FTElement {
        let core = FTRuntime.requireCore(command: "memoTextAs")
        let filePath = "\(file)"
        if core.scenarioAborted {
            core.recordStep(description: "memoTextAs \"\(key)\"", status: .skipped(core.skipReason),
                            file: filePath, line: Int(line), command: "memoTextAs")
            return self
        }
        let text = matched.map { m in [m.label, m.value].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
        if text == nil && !core.dryRun {
            let reason = "no element to read the text from (the previous select/exist grabbed nothing)"
            core.recordStep(description: "memoTextAs \"\(key)\"", status: .failed(reason),
                            file: filePath, line: Int(line), command: "memoTextAs")
            core.handleFailure(stepDescription: "memoTextAs \"\(key)\"", reason: reason)
            return self
        }
        let value = text ?? ""
        core.memoAppend(key, value)
        core.recordStep(description: "memoTextAs \"\(key)\" = \"\(value)\"", status: .passed,
                        file: filePath, line: Int(line), command: "memoTextAs")
        return self
    }
}

extension String {
    /// 文字列をメモに書き、その文字列を返す(`readText` 等の戻り値をそのまま繋げられる)
    @discardableResult
    public func memoTextAs(_ key: String,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        let core = FTRuntime.requireCore(command: "memoTextAs")
        if core.scenarioAborted {
            core.recordStep(description: "memoTextAs \"\(key)\"", status: .skipped(core.skipReason),
                            file: "\(file)", line: Int(line), command: "memoTextAs")
            return self
        }
        core.memoAppend(key, self)
        core.recordStep(description: "memoTextAs \"\(key)\" = \"\(self)\"", status: .passed,
                        file: "\(file)", line: Int(line), command: "memoTextAs")
        return self
    }
}
