// `SnapshotResponse.webViewPath` の値の定義元。
//
// **BridgeDTO.swift には置かない**: あちらはブリッジのソース集合(BridgeSourceSet)に入っており、
// 触ると3ブリッジの指紋が動く。この列挙はホスト側だけの語彙(値を入れるのは in-app ブリッジと
// ホストの WebViewDelegatingDriver、読むのは StepExecutor と MCP)なので FTCore に置く。
//
// 文字列を各所に散らさないのは、**書く側と読む側がズレても何も落ちない**ため ——
// 綴りを変えた瞬間に注記と失敗文言が静かに出なくなる(検知として最悪の壊れ方)。

import Foundation

public enum WebViewPath {
    /// in-app が DOM を JS で走査して埋めた
    public static let dom = "dom"
    /// DOM は読めたが interop(Compose/Flutter)ホスト配下 = 操作だけ XCUITest の実タッチへ回す
    public static let domInterop = "dom-interop"
    /// 画面ごと XCUITest へ委譲した
    public static let delegated = "delegated"
    /// 委譲したが、**Web コンテンツが1つも現れないまま待ちの上限に達した**。
    /// `delegated` との差は「木が空である理由が分からない」こと —— AX がまだ活性化していない
    /// だけかもしれず、**空の木を不在の証拠にしてはいけない**
    public static let delegatedEmpty = "delegated-empty"
}
