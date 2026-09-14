// TypeReadback.swift
// XCUITest ランナー /type の読み返し判定(純粋ロジック)。
// 実行系は BridgeRouter.handleType(Runner は SPM ターゲットではなく単体テストできないため、
// 判定だけをここへ切り出して FTCoreTests でテストする)。
// **両方のブリッジがコンパイルする**: XCUITest = Runner/project.yml の FleetestRunnerUITests.sources と
// BridgeSourceSet.xcuitest / in-app = InAppBridge/build.sh の SWIFT_SOURCES と BridgeSourceSet.inApp
// (`isTextInput` を焦点の確認に使う)。それぞれ2箇所ずつ、片方だけ変えない。
// Foundation と BridgeDTO(ElementInfo)のみに依存すること。ホスト専用の関数を足さない(両ブリッジの指紋が鳴る)

import Foundation

public enum TypeReadback {

    /// 読み返した実際値から次の一手を決める。
    /// 前提: expected = 入力前の値 + 送る本文(呼び出し側が構成する)
    public enum Plan: Equatable {
        /// 期待値に一致(完了)
        case done
        /// 打鍵の取りこぼし(実際値が期待値の前方一致で止まった)。この文字列を追送する
        case resend(String)
        /// 二重入力(実際値が期待値を含んで長い)。この文字数だけ delete を打つ
        case deleteExcess(Int)
        /// **中央の欠落**(実際値が期待値の順序を保った部分列で、落ちた文字に可視文字を含む)=
        /// 打鍵の落ち。追送では埋められない位置なので**全文を打ち直す**(ランナー = delete × 実際値の
        /// 文字数 + 期待値 / ホスト = clearInput + type)。実データ: `hello123`→`hllo123` / `persist99`→`prsist99`
        case retype
        /// どちらでもない = 入力が加工されている(自動修正・書式付け・マスク欄の伏せ字)。
        /// 追送でも delete でも直せないので検証を諦めて受理する
        case unverifiable

        /// 前方一致で説明できる(追送・削除・完了)。部分列の説明(`.retype`)より確度が高い
        public var explainsByPrefix: Bool {
            switch self {
            case .done, .resend, .deleteExcess: return true
            case .retype, .unverifiable: return false
            }
        }
    }

    public static func plan(expected: String, actual: String) -> Plan {
        if actual == expected { return .done }
        // **空白は a11y から読み返せない**(2026-08-18 実測: 空白のみの値は「値なし」で返る/
        // 2026-08-31 実測: 可視文字と混在していても空白の有無自体は読み返しに現れない)。
        // 前後の空白を除いて一致するなら、残った差分は「読めない空白」でしかありえないので、
        // 追送も delete も打たず検証を諦める——誤って追送すると同じ空白が毎周積まれて欄を壊す
        // (2026-08-18 実測: 4周で12個の空白が入った)
        if expected.trimmingCharacters(in: .whitespacesAndNewlines)
            == actual.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .unverifiable
        }
        if expected.hasPrefix(actual) { return .resend(String(expected.dropFirst(actual.count))) }
        if actual.hasPrefix(expected) { return .deleteExcess(actual.count - expected.count) }
        // **前方一致の後にしか置けない**: `hel` は `hello123` の部分列でもあり、先に見ると
        // 今自己修復できている「末尾の欠落 → 追送」を全文打ち直しに変えてしまう。
        // 落ちた文字が空白だけなら読めない空白(上の規則)と区別できないので諦める
        if isSubsequenceDroppingVisibleCharacters(actual, of: expected) { return .retype }
        return .unverifiable
    }

    /// 1回の type で全文を打ち直す上限(ランナー・ホストの両消費者が共有)。
    /// **1 = 打ち直しても同じ形で欠けるなら、それは打鍵の落ちではなくアプリ側の加工**
    /// (数字だけ通す欄が英字を捨てる等)。2回目以降は v104 より前と同じく検証を諦めて受理する ——
    /// 上限が無いと加工する欄で「消す→打つ→同じ値」が停滞に達し、緑だった step が 422 になる
    public static let maxRetypes = 1

    /// 読み返しが目標にする値。**既定は `expected`(撃つ前の値 + 本文)**で、それが前方一致で説明できない
    /// ときだけ「撃った文字だけ」(`typedOnly`)を候補にする。ホスト(`StepExecutor.readbackTarget`)と
    /// XCUITest ランナー(`BridgeRouter.handleType`)が共有する = 同じ欄で判断が食い違わない。
    ///
    /// **なぜ要るか**: 空欄のヒント文字列を `value` に載せ `placeholder` を出さない欄では、撃つ前の値が
    /// 実在の内容ではないので `expected` が最初から偽になる(`単一行hello123`)。撃った文字だけの
    /// `actual` はヒント付きの `expected` の**部分列にもなる**ので、`expected` を目標に `.retype` へ
    /// 落とすと**ヒント文字列ごと欄へ打ち込む**。
    ///
    /// 順序(入れ替えないこと): ①`expected` が前方一致(.done/.resend/.deleteExcess)で説明できる →
    /// `expected`(撃つ前の値と本文が同じ欄で、追記が届かなかった失敗を `.done` に見せない)
    /// ②`typedOnly` が前方一致で説明できる → `typedOnly` ③`expected` が `.retype` → `expected`
    /// (撃つ前の値が実在で追記の途中が落ちた形 = `old`+`new` が `onew`)④`typedOnly` が `.retype` →
    /// `typedOnly` ⑤どちらでもない → `expected`(今までどおり諦める)。
    /// 呼び手が不可視文字を正規化してから渡す(このファイルは正規化を持たない)
    public static func readbackTarget(expected: String, typedOnly: String, actual: String) -> String {
        guard expected != typedOnly else { return expected }
        let byExpected = plan(expected: expected, actual: actual)
        if byExpected.explainsByPrefix { return expected }
        let byTypedOnly = plan(expected: typedOnly, actual: actual)
        if byTypedOnly.explainsByPrefix { return typedOnly }
        if case .retype = byExpected { return expected }
        if case .retype = byTypedOnly { return typedOnly }
        return expected
    }

    /// `actual` が `expected` の順序を保った真部分列で、落ちた文字に空白でないものが含まれるか
    public static func isSubsequenceDroppingVisibleCharacters(_ actual: String, of expected: String) -> Bool {
        guard actual.count < expected.count else { return false }
        var dropped: [Character] = []
        var index = actual.startIndex
        for ch in expected {
            if index < actual.endIndex, actual[index] == ch {
                index = actual.index(after: index)
            } else {
                dropped.append(ch)
            }
        }
        guard index == actual.endIndex else { return false }
        return dropped.contains { !$0.isWhitespace && !$0.isNewline }
    }

    /// 読み返しの対象になる型(値がテキストとして読める要素)。ここに無い型は検証せず素通しする
    /// (**嘘の成功は潰したいが、値を持たない要素で必ず失敗する経路を作らない**)。
    /// 型は ElementInfo が先頭小文字に畳んだ後の名前
    public static func isTextInput(_ element: ElementInfo) -> Bool {
        ["textField", "secureTextField", "textView", "searchField"].contains(element.type)
    }

    /// secure 欄(パスワード等)か。**この型だけは読み返しの材料に使ってはいけない** ——
    /// 中身は常に伏せ字(`•`)でしか読めず、`•` は本文とは無関係な記号なので、`expected`
    /// (= 入力前の値 + 送る本文)へ混ぜると `plan` が「•」を実際の1文字として resend し、
    /// 欄へ literal な bullet 文字を打ち込む(実害: `abc`→再フォーカス→`XY` が
    /// `XY••XY` になった。Android の `InputInjector.applied` はマスク欄を長さ一致だけで見て
    /// 同じ事故を避けている——`TypeReadbackReformatJavaSyncTests` 参照)。
    /// 呼び手は secure 欄では読み返しループそのものへ入らないこと(`app.typeText` を1回だけ送る)
    public static func isMaskedInput(_ element: ElementInfo) -> Bool {
        element.type == "secureTextField"
    }

    /// スナップショット中の対象要素の値(placeholder 表示・未入力は空文字)。
    /// nil = 検証不能。対象が見つからないだけでなく、**候補が複数あるときも nil**
    /// (別の空欄を「入っていない」と誤読して追送すると、本当のフォーカス欄へ二重入力する。
    /// 曖昧なら検証を諦める側に倒す)。
    /// **nil と空文字を混ぜないこと** —— 空文字として扱うと「1文字も入っていない」と読んで
    /// 全文を打ち直し、二重入力になる。
    /// 突き合わせは identifier 優先(キーボードの出現で frame は動く)、無ければ frame 一致
    public static func value(of target: ElementInfo, in elements: [ElementInfo]) -> String? {
        let matches = elements.filter { element in
            if let identifier = target.identifier, !identifier.isEmpty {
                return element.identifier == identifier
            }
            return element.frame == target.frame
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return normalizedValue(of: match)
    }

    /// 値の正規化(nil・placeholder と同値は「未入力」= 空文字)
    public static func normalizedValue(of element: ElementInfo) -> String {
        guard let value = element.value, !value.isEmpty else { return "" }
        if let placeholder = element.placeholder, value == placeholder { return "" }
        return value
    }
}
