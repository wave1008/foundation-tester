// `tap(入力欄)` → `type("文字列")` を成立させるための救済(2026-08-21)。
//
// **これは Shirates(Classic)からの伝統的な書き方**で、利用者はこの形をそのまま移植してくる。
// ところが Android の入力欄は**容器**(Material の `TextInputLayout` 等)と**中身**
// (`TextInputEditText`)に分かれることがあり、**id は容器側に付くことが多い** ——
// `tap("#id")` は容器に解決し、a11y のクリックでは中身へ入力フォーカスが移らない。
// 結果、次の `type` が「フォーカスが無い」で落ちる(2026-08-21 の受け手報告)。
//
// **回避策を書かせない**(利用者の自然な書き方をツール側で吸収する)。ただし
// **推測はしない** —— 入れる先が一意に決まるときだけ救済し、決まらなければ従来どおり失敗させる。
//
// 判定はここ1箇所(`StepExecutor` が転送する)。**焦点が立っているかは木から読む**
// (`ElementInfo.focused` は iOS xcuitest=`hasKeyboardFocus` / iOS in-app=`isFirstResponder` /
// Android=`isFocused` の3エンジンとも申告する)。

import Foundation

public enum InputFocusRescue {

    /// 木の中で**入力フォーカスを持つ要素が1つも無い**か。
    /// **申告が無いこと**(全要素 nil)も「無い」に含める —— その場合に救済へ進んでも、
    /// 入れる先が一意に決まらなければ何もしないので、誤って別の欄へ入れることはない
    public static func nothingHasFocus(_ elements: [ElementInfo]) -> Bool {
        !elements.contains { $0.focused == true }
    }

    /// 直前に叩いた要素から「入れるべき欄」を決める。**一意に決まらなければ nil**。
    ///
    /// - 叩いた要素そのものが入力欄ならそれ(フォーカスだけが立たなかった形)
    /// - 叩いたのが容器なら、その中にある**ただ1つ**の入力欄
    /// - 入力欄が0個、または2個以上あるなら nil(どれに入れるべきかツールには言えない)
    ///
    /// 突き合わせは**新しく撮り直した木**に対して行う(ref は木ごとに振り直されるので、
    /// 前の木の ref をそのまま使ってはいけない)。位置は**中心が容器の矩形に入るか**で見る ——
    /// 容器と中身は数 px ずれることがあり、厳密な包含だと落ちる
    public static func fieldToType(after tapped: ElementInfo,
                                   in elements: [ElementInfo]) -> ElementInfo? {
        let candidates = elements.filter {
            SnapshotRenderer.textInputTypes.contains($0.type) && $0.enabled
                && contains(tapped.frame, centreOf: $0.frame)
        }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    private static func contains(_ rect: FTRect, centreOf inner: FTRect) -> Bool {
        let x = inner.x + inner.width / 2
        let y = inner.y + inner.height / 2
        return x >= rect.x && x <= rect.x + rect.width
            && y >= rect.y && y <= rect.y + rect.height
    }
}
