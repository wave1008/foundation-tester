// FTSelector.swift
// セレクタ式のパース。文字列 1 本を `||` で分割し、各節を FlowLocator に写像する。
//   #login_btn                       → id
//   ログイン                          → label(完全一致→部分一致は StepExecutor.match の挙動)
//   .Button / .Button[2]             → type(+順番)
//   .Switch#PHOTOS_UPLOAD_...        → type + id
//   .Switch=Resource Upload ...      → type + label
// [n] は 1 オリジン(.TextField[1] = 1番目の TextField。内部の FlowLocator.index は 0 オリジン)。
// パースは失敗しない(解釈できない節は label として扱う)。

import Foundation
import FTCore

public struct FTSelector {
    /// 元のセレクタ式(ログ・レポート・修正提案用)
    public let text: String
    public let primary: FlowLocator
    public let fallbacks: [FlowLocator]

    public static func parse(_ text: String) -> FTSelector {
        let clauses = text.components(separatedBy: "||")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let locators = clauses.map(parseClause)
        guard let first = locators.first else {
            return FTSelector(text: text, primary: FlowLocator(label: text), fallbacks: [])
        }
        return FTSelector(text: text, primary: first, fallbacks: Array(locators.dropFirst()))
    }

    /// 生ラベル(# や . で始まるテキスト)をそのまま label として使う場合
    public static func label(_ text: String) -> FTSelector {
        FTSelector(text: text, primary: FlowLocator(label: text), fallbacks: [])
    }

    static func parseClause(_ clause: String) -> FlowLocator {
        if clause.hasPrefix("=") {
            // 生ラベルのエスケープ(# や . で始まるラベルを label として扱う)
            return FlowLocator(label: String(clause.dropFirst()))
        }
        if clause.hasPrefix("#") {
            return FlowLocator(id: String(clause.dropFirst()))
        }
        if clause.hasPrefix("."), clause.count > 1 {
            let body = clause.dropFirst()
            if let hashIndex = body.firstIndex(of: "#") {
                let type = String(body[body.startIndex..<hashIndex])
                let id = String(body[body.index(after: hashIndex)...])
                return FlowLocator(id: id, type: type.isEmpty ? nil : type)
            }
            if let eqIndex = body.firstIndex(of: "=") {
                let type = String(body[body.startIndex..<eqIndex])
                let label = String(body[body.index(after: eqIndex)...])
                return FlowLocator(label: label, type: type.isEmpty ? nil : type)
            }
            if body.hasSuffix("]"), let bracketIndex = body.firstIndex(of: "[") {
                let type = String(body[body.startIndex..<bracketIndex])
                let indexText = String(body[body.index(after: bracketIndex)..<body.index(before: body.endIndex)])
                if let ordinal = Int(indexText) {
                    // 表記は 1 オリジン、内部 index は 0 オリジン
                    return FlowLocator(type: type, index: max(0, ordinal - 1))
                }
            }
            return FlowLocator(type: String(body))
        }
        return FlowLocator(label: clause)
    }

    /// FlowLocator をセレクタ式の 1 節に戻す(修正提案・コード生成用)
    public static func serialize(_ locator: FlowLocator) -> String {
        if let id = locator.id {
            if let type = locator.type { return ".\(type)#\(id)" }
            return "#\(id)"
        }
        if let label = locator.label {
            if let type = locator.type { return ".\(type)=\(label)" }
            // # や . で始まるラベルは = でエスケープして id/type 節と区別する
            if label.hasPrefix("#") || label.hasPrefix(".") || label.hasPrefix("=") {
                return "=\(label)"
            }
            return label
        }
        if let type = locator.type {
            // 内部 index(0 オリジン)→ 表記(1 オリジン)。1番目は [1] を省略して .Type とする
            if let index = locator.index, index > 0 { return ".\(type)[\(index + 1)]" }
            return ".\(type)"
        }
        return ""
    }

    /// ロケータ連鎖をセレクタ式に戻す
    public static func serialize(primary: FlowLocator, fallbacks: [FlowLocator]) -> String {
        ([primary] + fallbacks).map(serialize).filter { !$0.isEmpty }.joined(separator: "||")
    }
}
