// HealFixApplier.swift
// 自己修復(FM ロケータ自己修復)の確定反映ロジック。CLI(ftester api apply-heal)が使う
// 副作用を持たない純粋ロジック。
// ファイル I/O(ソースの読み書き・ヒールキャッシュファイルの読み書き)は呼び出し側の責務とし、
// ここではソース文字列の変換とヒールキャッシュ(JSONSerialization の辞書)のキー削除だけを扱う
// (テスト容易性のため)。

import Foundation

/// 修復候補 1 件。id はヒールキャッシュのキー形式(HealCache.key)と
/// 同一("scenarioID|file:line|oldSelector")
public struct HealFixInput: Sendable, Equatable {
    public let scenarioID: String
    /// ファイルパス(絶対または Package ルート相対。どちらであるかの解決・実際の読み書きは
    /// 呼び出し側の責務。id / キャッシュキーにはこの値をそのまま使う)
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

    /// ヒールキャッシュのキー形式(HealCache.key と同一)
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
    /// (置換結果は source / applied に残し、failures に追記するだけ。
    /// 置換成功分のみ確定させ、説明更新の失敗でセレクタ置換自体は無効にしない設計)
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
                    message: "説明の更新に失敗しました(\(error.localizedDescription))"))
            }
        }
        return (source, applied, failures)
    }

    /// ヒールキャッシュ(JSONSerialization で読み込んだ辞書)から、適用成功した fix の id を
    /// キーとして削除する(存在しないキーは黙って無視)。
    /// 戻り値: (削除後の辞書, 1 件でも削除したか。呼び出し側は changed のときだけ書き戻せばよい)
    public static func removingAppliedKeys(
        _ ids: [String], from dict: [String: Any]
    ) -> (dict: [String: Any], changed: Bool) {
        var dict = dict
        var changed = false
        for id in ids where dict.removeValue(forKey: id) != nil {
            changed = true
        }
        return (dict, changed)
    }
}
