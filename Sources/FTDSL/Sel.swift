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
/// secureTextField / switch の5つだけ(E2EApp/docs/ui-contract.md)。それ以外は SUT・OS 依存で、
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

    init(_ primary: FlowLocator, fallbacks: [FlowLocator] = []) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    /// DSL コマンドへ渡す形。text は**文字列版の記法へ戻したもの**(FTSelector.serialize)で、
    /// レポート表示とヒールキャッシュのキーになる。ここで summary を使うと型が `.button` ではなく
    /// `button`(=ラベル)に化け、レポートからコピーしたセレクタが別物になる
    var ftSelector: FTSelector {
        FTSelector(text: FTSelector.serialize(primary: primary, fallbacks: fallbacks),
                   primary: primary, fallbacks: fallbacks, structured: true)
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
    /// 検証エラーになる形。型付き版も同じ意味で使う)
    public func not(_ other: Sel) -> Sel {
        updatingTarget { $0.not = ($0.not ?? []) + [other.primary] }
    }

    /// 候補内の順番(**1 オリジン**。記法の `[n]` と同じ)。相対ステップの後なら近い順の ordinal
    public func nth(_ n: Int) -> Sel {
        precondition(n >= 1, "nth は 1 オリジンです: \(n)")
        var copy = self
        if var steps = copy.primary.relative, !steps.isEmpty {
            steps[steps.count - 1].ordinal = n > 1 ? n : nil
            copy.primary.relative = steps
            return copy
        }
        copy.primary.index = n > 1 ? n - 1 : nil
        return copy
    }

    // MARK: - 合成

    /// 候補集合の和(記法の `||`)。要素を1つ選ぶときは**この順**に先に見つかった方が使われるので、
    /// `#id` → ラベルのヒール連鎖としても書ける。countIs は和集合の総数を数える
    public func or(_ other: Sel) -> Sel {
        Sel(primary, fallbacks: fallbacks + [other.primary] + other.fallbacks)
    }

    /// スコープ(記法の `>>`)。**レシーバが祖先**で、引数がその子孫。引数側に or があれば全節に効く
    /// (文字列版では書けない形。`#list >> (a||b)` 相当)
    public func find(_ target: Sel) -> Sel {
        var ancestors = primary.scope ?? []
        var me = primary
        me.scope = nil
        ancestors.append(me)
        func scoped(_ locator: FlowLocator) -> FlowLocator {
            var copy = locator
            copy.scope = ancestors + (locator.scope ?? [])
            return copy
        }
        return Sel(scoped(target.primary), fallbacks: target.fallbacks.map(scoped))
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
    /// filter が複数節(`||`)のときは全部に AND する(文字列版 `:rightSwitch(保存)` の merged と同じ)
    private func updatingTarget(_ transform: (inout FlowLocator) -> Void) -> Sel {
        var copy = self
        if var steps = copy.primary.relative, !steps.isEmpty {
            var last = steps[steps.count - 1]
            var filter = last.filter ?? []
            if filter.isEmpty { filter = [FlowLocator()] }
            last.filter = filter.map { locator in
                var updated = locator
                transform(&updated)
                return updated
            }
            steps[steps.count - 1] = last
            copy.primary.relative = steps
            return copy
        }
        transform(&copy.primary)
        return copy
    }

    private func appendingRelative(_ direction: FlowDirection, type: SelType?, nth: Int) -> Sel {
        appendingStep(FlowRelativeStep(direction: direction,
                                       filter: type.map { [FlowLocator(type: $0.name)] },
                                       ordinal: nth > 1 ? nth : nil))
    }

    private func appendingRelative(_ direction: FlowDirection, matching: Sel, nth: Int) -> Sel {
        appendingStep(FlowRelativeStep(direction: direction,
                                       filter: [matching.primary] + matching.fallbacks,
                                       ordinal: nth > 1 ? nth : nil))
    }

    private func appendingStep(_ step: FlowRelativeStep) -> Sel {
        precondition((step.ordinal ?? 1) >= 1, "nth は 1 オリジンです")
        var copy = self
        copy.primary.relative = (copy.primary.relative ?? []) + [step]
        return copy
    }
}
