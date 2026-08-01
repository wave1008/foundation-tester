// TypeReadback.swift
// XCUITest ランナー /type の読み返し判定(純粋ロジック)。
// 実行系は BridgeRouter.handleType(Runner は SPM ターゲットではなく単体テストできないため、
// 判定だけをここへ切り出して FTCoreTests でテストする)。
// Runner/project.yml の FTesterRunnerUITests.sources と BridgeSourceSet.xcuitest の
// 両方に載せること(片方だけ変えない)。Foundation のみに依存すること。

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
        /// どちらでもない = 入力が加工されている(自動修正・書式付け・マスク欄の伏せ字)。
        /// 追送でも delete でも直せないので検証を諦めて受理する
        case unverifiable
    }

    public static func plan(expected: String, actual: String) -> Plan {
        if actual == expected { return .done }
        if expected.hasPrefix(actual) { return .resend(String(expected.dropFirst(actual.count))) }
        if actual.hasPrefix(expected) { return .deleteExcess(actual.count - expected.count) }
        return .unverifiable
    }

    /// 読み返しの対象になる型(値がテキストとして読める要素)。ここに無い型は検証せず素通しする
    /// (**嘘の成功は潰したいが、値を持たない要素で必ず失敗する経路を作らない**)。
    /// 型は ElementInfo が先頭小文字に畳んだ後の名前
    public static func isTextInput(_ element: ElementInfo) -> Bool {
        ["textField", "secureTextField", "textView", "searchField"].contains(element.type)
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
