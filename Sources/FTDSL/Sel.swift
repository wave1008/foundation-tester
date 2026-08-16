// Sel.swift
// 型付きセレクタ。文字列セレクタ式(記法の唯一の正は FTSelector.swift 冒頭)と**同じ FlowLocator**を
// 組み立てるだけの併設経路で、解決・実行・レポート・ヒールの経路は文字列版と完全に共通
// (実行エンジンを分岐させない)。記法との対応:
//   .id("x") / .id("x", .startsWith)   #x / #x*
//   .text("保存") / .text("保存", .contains)   保存 / *保存*
//   .type(.button).nth(2)              .button[2]
//   .id("a").or(.text("保存"))          #a||保存
//   .id("list").find(.type(.cell).nth(2))     #list >> .cell[2]
//   .text("通知").right(.switch)        通知:rightSwitch
//   .type(.button).not(.text("キャンセル"))     .button&&text!=キャンセル
//
// フィルタ系メソッド(text/type/nth 等)は常に「**現在の対象**」へ AND する: 相対ステップより前なら
// 基準(アンカー)、後ならその相対ステップの対象。nth も同様で、相対ステップ後は ordinal(近い順)に
// なる(文字列版の `:right(.button&&[2])` → `:rightButton(2)` 正規化と同じ意味)。
//
// 文字列版と違い綴り誤りはコンパイルエラーになるので、実行時の構文検証(FTSelector.validationError)は
// 通さない(FTSelector.structured。ラベルに `>>` 等を含めても壊れないのはこのため)。

import Foundation
import FTCore

/// 型セレクタの型名。OS を跨いで保証されるのは button / staticText / textField /
/// secureTextField / switch の5つだけ(E2EAppCMP/docs/ui-contract.md)。それ以外は SUT・OS 依存で、
/// 語彙に無い型は `.custom("...")`(先頭小文字へ正規化する。ElementInfo.normalizedType と同じ規約)
public struct SelType: Sendable, Equatable {
    public let name: String

    private init(_ name: String) { self.name = name }

    /// 語彙に無い型名。ブリッジが返す綴りをそのまま渡す(先頭大文字は自動で畳む)
    public static func custom(_ name: String) -> SelType {
        SelType(ElementInfo.normalizedType(name))
    }

    // OS 共通契約の5型
    public static let button = SelType("button")
    public static let staticText = SelType("staticText")
    public static let textField = SelType("textField")
    public static let secureTextField = SelType("secureTextField")
    public static let `switch` = SelType("switch")

    // エイリアス(FlowTypeAlias が実型へ展開する)
    public static let input = SelType("input")
    public static let widget = SelType("widget")

    // OS 非保証だが頻出(片方の SUT にしか出ない。ui-contract.md の型語彙表を確認してから使う)
    public static let cell = SelType("cell")
    public static let image = SelType("image")
    public static let clickable = SelType("clickable")
}

public struct Sel: Sendable, Equatable {
    var primary: FlowLocator
    var fallbacks: [FlowLocator]
    /// 組み立て時に見つかった誤り(1オリジンでない序数など)。**最初の1件だけ**保持し、
    /// 実行前に失敗ステップとして落とす(`FTRuntime.perform`)。**crash させない**のは
    /// 1プロセス=1シナリオでプロセスを落とすとレポートごと消えるため(design.md §10)。
    /// 文字列版が `[0]` を validationError で落とすのと同じ扱いに揃える
    var invalidReason: String?

    init(_ primary: FlowLocator, fallbacks: [FlowLocator] = [], invalidReason: String? = nil) {
        self.primary = primary
        self.fallbacks = fallbacks
        self.invalidReason = invalidReason
    }

    /// DSL コマンドへ渡す形。text は**文字列版の記法へ戻したもの**(FTSelector.serialize)で、
    /// レポート表示とヒールキャッシュのキーになる。ここで summary を使うと型が `.button` ではなく
    /// `button`(=ラベル)に化け、レポートからコピーしたセレクタが別物になる
    var ftSelector: FTSelector {
        FTSelector(text: FTSelector.serialize(primary: primary, fallbacks: fallbacks),
                   primary: primary, fallbacks: fallbacks, structured: true,
                   structuredError: invalidReason)
    }

    /// 誤りを1件だけ記録した複製(先勝ち: 最初に壊れた地点を報告する)
    private func invalidated(_ reason: String) -> Sel {
        var copy = self
        if copy.invalidReason == nil { copy.invalidReason = reason }
        return copy
    }

    // MARK: - 起点(static)

    public static func id(_ id: String, _ match: FlowMatchMode = .exact) -> Sel {
        Sel(FlowLocator()).id(id, match)
    }

    public static func text(_ text: String, _ match: FlowMatchMode = .exact) -> Sel {
        Sel(FlowLocator()).text(text, match)
    }

    public static func value(_ value: String, _ match: FlowMatchMode = .exact) -> Sel {
        Sel(FlowLocator()).value(value, match)
    }

    public static func placeholder(_ placeholder: String, _ match: FlowMatchMode = .exact) -> Sel {
        Sel(FlowLocator()).placeholder(placeholder, match)
    }

    public static func type(_ type: SelType) -> Sel { Sel(FlowLocator()).type(type) }

    public static func checked(_ checked: Bool = true) -> Sel { Sel(FlowLocator()).checked(checked) }

    public static func enabled(_ enabled: Bool = true) -> Sel { Sel(FlowLocator()).enabled(enabled) }

    // MARK: - フィルタ(現在の対象へ AND)

    public func id(_ id: String, _ match: FlowMatchMode = .exact) -> Sel {
        updatingTarget { $0.id = id; $0.idMatch = Self.stored(match) }
    }

    public func text(_ text: String, _ match: FlowMatchMode = .exact) -> Sel {
        updatingTarget { $0.label = text; $0.labelMatch = Self.stored(match) }
    }

    public func value(_ value: String, _ match: FlowMatchMode = .exact) -> Sel {
        updatingTarget { $0.value = value; $0.valueMatch = Self.stored(match) }
    }

    public func placeholder(_ placeholder: String, _ match: FlowMatchMode = .exact) -> Sel {
        updatingTarget { $0.placeholder = placeholder; $0.placeholderMatch = Self.stored(match) }
    }

    /// exact は mode を持たせない(文字列版の parseNamedFilter と同じ正規化。
    /// 揃えないと同じ意味のセレクタが型付き版だけ別構造になり、比較・往復・キャッシュが割れる)
    private static func stored(_ match: FlowMatchMode) -> FlowMatchMode? {
        match == .exact ? nil : match
    }

    public func type(_ type: SelType) -> Sel { updatingTarget { $0.type = type.name } }

    public func checked(_ checked: Bool = true) -> Sel { updatingTarget { $0.checked = checked } }

    public func enabled(_ enabled: Bool = true) -> Sel { updatingTarget { $0.enabled = enabled } }

    /// 除外条件(記法の `text!=キャンセル`)。引数に設定された属性を持つ要素を候補から取り除く。
    /// **肯定条件と併用する**(否定だけでは容器やレイアウトノードまで掴むため、文字列版では
    /// 検証エラーになる形。型付き版も同じ意味で使う)。
    /// 引数が `or` を含むなら**全節を除外する**(`not` の各要素は「どれかに当たれば除く」)
    public func not(_ other: Sel) -> Sel {
        let exclusions = [other.primary] + other.fallbacks
        return updatingTarget { $0.not = ($0.not ?? []) + exclusions }
    }

    /// 候補内の順番(**1 オリジン**。記法の `[n]` と同じ)。相対ステップの後なら近い順の ordinal。
    /// **`updatingTarget` は使えない** — あちらは相対ステップがあると filter 節へ潜るので、
    /// 「対象の何番目か」ではなく「filter 節の index」になってしまう(2026-08-02 に踏んだ)
    public func nth(_ n: Int) -> Sel {
        guard n >= 1 else { return invalidated("nth is 1-origin: \(n)") }
        func numbered(_ locator: FlowLocator) -> FlowLocator {
            var copy = locator
            if var steps = copy.relative, !steps.isEmpty {
                steps[steps.count - 1].ordinal = n > 1 ? n : nil
                copy.relative = steps
                return copy
            }
            copy.index = n > 1 ? n - 1 : nil
            return copy
        }
        var copy = self
        copy.primary = numbered(primary)
        copy.fallbacks = fallbacks.map(numbered)
        return copy
    }

    // MARK: - 合成

    /// 候補集合の和(記法の `||`)。要素を1つ選ぶときは**この順**に先に見つかった方が使われるので、
    /// `#id` → ラベルのヒール連鎖としても書ける。countIs は和集合の総数を数える
    public func or(_ other: Sel) -> Sel {
        Sel(primary, fallbacks: fallbacks + [other.primary] + other.fallbacks,
            invalidReason: invalidReason ?? other.invalidReason)
    }

    /// スコープ(記法の `>>`)。**レシーバが祖先**で、引数がその子孫。
    /// **どちらの側の `or` も落とさない** — 祖先 × 子孫の全組み合わせを候補集合の和にする
    /// (`Sel.id("a").or(.id("b")).find(.text("x"))` = `#a >> x || #b >> x`)。
    /// 祖先を先に回すのは、祖先の方が識別子として重い = ヒール連鎖の優先順位だから
    public func find(_ target: Sel) -> Sel {
        func ancestry(of locator: FlowLocator) -> [FlowLocator] {
            var chain = locator.scope ?? []
            var me = locator
            me.scope = nil
            chain.append(me)
            return chain
        }
        var scopedAll: [FlowLocator] = []
        for ancestors in ([primary] + fallbacks).map(ancestry) {
            for locator in [target.primary] + target.fallbacks {
                var copy = locator
                copy.scope = ancestors + (locator.scope ?? [])
                scopedAll.append(copy)
            }
        }
        // 空にはならない(必ず primary × target.primary が1件できる)
        return Sel(scopedAll[0], fallbacks: Array(scopedAll.dropFirst()),
                   invalidReason: invalidReason ?? target.invalidReason)
    }

    // MARK: - 相対(基準が先・対象が後)

    /// 型省略時は記法の接尾辞なし `:right` と同じ(既定フィルタ = 役割が確定した要素)
    public func right(_ type: SelType? = nil, nth: Int = 1) -> Sel {
        appendingRelative(.right, type: type, nth: nth)
    }

    public func left(_ type: SelType? = nil, nth: Int = 1) -> Sel {
        appendingRelative(.left, type: type, nth: nth)
    }

    public func above(_ type: SelType? = nil, nth: Int = 1) -> Sel {
        appendingRelative(.above, type: type, nth: nth)
    }

    public func below(_ type: SelType? = nil, nth: Int = 1) -> Sel {
        appendingRelative(.below, type: type, nth: nth)
    }

    /// 対象を型だけでなくセレクタで絞る(記法の `:right(#a||保存)`)
    public func right(matching: Sel, nth: Int = 1) -> Sel {
        appendingRelative(.right, matching: matching, nth: nth)
    }

    public func left(matching: Sel, nth: Int = 1) -> Sel {
        appendingRelative(.left, matching: matching, nth: nth)
    }

    public func above(matching: Sel, nth: Int = 1) -> Sel {
        appendingRelative(.above, matching: matching, nth: nth)
    }

    public func below(matching: Sel, nth: Int = 1) -> Sel {
        appendingRelative(.below, matching: matching, nth: nth)
    }

    // MARK: - 内部

    /// 相対ステップがあれば**その対象**(最後のステップの filter 全節)、無ければ基準へ適用する。
    /// filter が複数節(`||`)のときは全部に AND する(文字列版 `:rightSwitch(保存)` の merged と同じ)。
    ///
    /// **`or` の全節へ配る**(primary だけに掛けない)。`Sel.text("a").or(.text("b")).type(.button)`
    /// は文字列版の `(a|b)&&.button` = `a&&.button || b&&.button` と同じ意味になる。
    /// primary だけに掛けると第2節が無条件のまま残り、**書いた条件が黙って効かない**
    private func updatingTarget(_ transform: (inout FlowLocator) -> Void) -> Sel {
        func applied(_ locator: FlowLocator) -> FlowLocator {
            var copy = locator
            if var steps = copy.relative, !steps.isEmpty {
                var last = steps[steps.count - 1]
                var filter = last.filter ?? []
                if filter.isEmpty { filter = [FlowLocator()] }
                last.filter = filter.map { clause in
                    var updated = clause
                    transform(&updated)
                    return updated
                }
                steps[steps.count - 1] = last
                copy.relative = steps
                return copy
            }
            transform(&copy)
            return copy
        }
        var copy = self
        copy.primary = applied(primary)
        copy.fallbacks = fallbacks.map(applied)
        return copy
    }

    private func appendingRelative(_ direction: FlowDirection, type: SelType?, nth: Int) -> Sel {
        guard nth >= 1 else { return invalidated("nth is 1-origin: \(nth)") }
        return appendingStep(FlowRelativeStep(direction: direction,
                                              filter: type.map { [FlowLocator(type: $0.name)] },
                                              ordinal: nth > 1 ? nth : nil))
    }

    private func appendingRelative(_ direction: FlowDirection, matching: Sel, nth: Int) -> Sel {
        guard nth >= 1 else { return invalidated("nth is 1-origin: \(nth)") }
        var result = appendingStep(FlowRelativeStep(direction: direction,
                                                    filter: [matching.primary] + matching.fallbacks,
                                                    ordinal: nth > 1 ? nth : nil))
        if result.invalidReason == nil { result.invalidReason = matching.invalidReason }
        return result
    }

    /// 相対ステップも**基準の全節へ配る**(`a||b` の右のスイッチ = `a:rightSwitch || b:rightSwitch`)。
    /// primary だけに足すと、第2節が「基準そのもの」のまま残って別の要素を掴む
    private func appendingStep(_ step: FlowRelativeStep) -> Sel {
        func appended(_ locator: FlowLocator) -> FlowLocator {
            var copy = locator
            copy.relative = (copy.relative ?? []) + [step]
            return copy
        }
        var copy = self
        copy.primary = appended(primary)
        copy.fallbacks = fallbacks.map(appended)
        return copy
    }
}
