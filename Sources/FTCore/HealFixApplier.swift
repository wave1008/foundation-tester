// HealFixApplier.swift
// 自己修復(ロケータ指紋)の修正提案をソースへ確定反映するロジック。CLI(fleetest api apply-heal)が使う
// 副作用を持たない純粋ロジック。ファイル I/O は呼び出し側の責務とし、ここではソース文字列の変換だけを扱う
// (テスト容易性のため)。

import Foundation

/// 修復候補 1 件。id は指紋の鍵(FTDSL の `LocatorFingerprintCache.key`)と
/// 同一("scenarioID|file:line|oldSelector")
public struct HealFixInput: Sendable, Equatable {
    public let scenarioID: String
    /// ファイルパス(絶対 or 相対。解決・実際の読み書きは呼び出し側の責務。id にはそのまま使う)
    public let file: String
    public let line: Int
    public let oldSelector: String
    public let newSelector: String
    /// nil = 説明(行末コメント)は変更しない、空文字 = コメント削除、非空 = 差し替え/追記
    public let newComment: String?

    public init(scenarioID: String, file: String, line: Int, oldSelector: String,
                newSelector: String, newComment: String?) {
        self.scenarioID = scenarioID
        self.file = file
        self.line = line
        self.oldSelector = oldSelector
        self.newSelector = newSelector
        self.newComment = newComment
    }

    public var id: String { "\(scenarioID)|\(file):\(line)|\(oldSelector)" }
}

/// HealFixApplier.apply(fixes:toSource:) 1 件分の失敗
public struct HealFixFailure: Sendable, Equatable {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

public enum HealFixApplier {

    /// 同一ファイルの fix 群を行番号昇順でソースへ適用する
    /// (呼び出し側は事前に fix.file でグループ化してから、ファイル毎にこれを呼ぶこと)。
    /// セレクタ置換(replaceSelector)が成功した fix は続けて説明(setTrailingComment)の
    /// 更新も試みるが、説明の更新失敗はセレクタ置換の成功を無効にしない
    /// (置換結果は source / applied に残し、failures に追記するだけ)
    public static func apply(
        fixes: [HealFixInput], toSource source: String
    ) -> (source: String, applied: [HealFixInput], failures: [HealFixFailure]) {
        var source = source
        var applied: [HealFixInput] = []
        var failures: [HealFixFailure] = []

        for fix in fixes.sorted(by: { $0.line < $1.line }) {
            do {
                source = try ScenarioSourceEditor.replaceSelector(
                    inSource: source, line: fix.line,
                    oldSelector: fix.oldSelector, newSelector: fix.newSelector)
                applied.append(fix)
            } catch {
                failures.append(HealFixFailure(id: fix.id, message: error.localizedDescription))
                continue
            }
            guard let newComment = fix.newComment else { continue }
            do {
                source = try ScenarioSourceEditor.setTrailingComment(
                    inSource: source, line: fix.line, comment: newComment)
            } catch {
                failures.append(HealFixFailure(
                    id: fix.id,
                    message: "failed to update the description (\(error.localizedDescription))"))
            }
        }
        return (source, applied, failures)
    }
}
