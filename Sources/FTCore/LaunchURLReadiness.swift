// `launchApp(url:)` が URL を配送する前に「アプリが受け取れる状態か」を木から決める規則(純粋関数)。
//
// in-app エンジンの launch は**ネイティブのブリッジが答えた時点**で返る。React Native は JS が
// 起動して `Linking.addEventListener('url')` を登録するまで warm な URL を捨てる(RCTLinkingManager は
// JS 側の listener が居るまで通知を購読しない)ので、その前に `simctl openurl` を撃つと届かず、
// ホームのまま = 誤った赤(E2E-RN ios-inapp が M1Max で 2/24。台帳 §19.26)。XCUITest エンジンの
// launch はアプリの静穏まで待つので同じ穴が無い。**待つ根拠は定数ではなく観測**:
// 「利用者が触れる要素が木に載った」= 最初の画面が描かれた。RN/Flutter/Compose では JS・Dart の
// 起動後にしか載らない。起動画面(ラベルだけ)では載らない

import Foundation

public enum LaunchURLReadiness {
    /// 利用者が触れる要素(タップを受ける型 + 入力欄)が1つでも載っているか。
    /// `other` だけの木・ラベルだけの起動画面は false
    public static func hasInteractiveElement(_ elements: [ElementInfo]) -> Bool {
        elements.contains { TapTargetGeometry.interactiveTypes.contains($0.type) || TypeReadback.isTextInput($0) }
    }
}
