// フリート内の WebView 版の混在を run 前に知らせる(2026-08-14)。
//
// **なぜ要るか**(実測)。同じ HTML・同じアプリでも版で表現が**入れ替わる**:
//
//   WebView 124 : textField ph="WebView 入力"        (placeholder あり / id なし)
//   WebView 150 : textField id=wv_input              (id あり / placeholder なし)
//
// トレードではなく入れ替えなので、**どちらの版に合わせて書いても他方で落ちる**。
// 混在したフリートでは**どの端末に載ったかで結果が割れ**、しかも失敗の形は
// 「セレクタが見つからない」で原因が版だとは読めない
// (2026-08-14 に1台だけ更新して実際に事故を起こした)。
//
// **落とさない・直さない**(警告だけ)。古い版を意図的に残す運用があり得る
// (古い端末で壊れないかの検証)。判断は人がする。
//
// **この入れ替えは DOM 経路が供給源で消す**(`AndroidWebViewDOM`。2026-08-15)。
// 警告が効くのは**その経路が使えないとき** —— アプリが debuggable でない・WebView 未生成・
// `FT_WEBVIEW_DOM=off`。どれも黙って a11y に落ちるので、混在は依然として知らせる価値がある。

import Foundation
import FTCore

public enum AndroidWebViewVersions {

    /// serial → WebView の versionName。取れない端末は落とす(判定材料が無いだけで異常ではない)
    public static func collect(serials: [String],
                               adb: (_ serial: String, _ args: [String]) -> String?) -> [String: String] {
        var out: [String: String] = [:]
        for serial in serials {
            guard let text = adb(serial, ["shell", "dumpsys", "package", "com.google.android.webview"]),
                  let version = versionName(inDumpsys: text) else { continue }
            out[serial] = version
        }
        return out
    }

    /// `versionName=124.0.6367.219` の**最初の1件**を採る(純粋)。
    /// dumpsys は同じ鍵を複数回出すことがあるので、先頭に固定して端末間で比較可能にする
    public static func versionName(inDumpsys text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "versionName=") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// 混在していれば警告文、揃っていれば nil(純粋)。
    /// **メジャー版だけで比べる** —— パッチ違いで毎回警告を出すと読み飛ばされる
    public static func mixedVersionWarning(_ versions: [String: String]) -> String? {
        let majors = Set(versions.values.map { $0.split(separator: ".").first.map(String.init) ?? $0 })
        guard majors.count > 1 else { return nil }
        let detail = versions.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " / ")
        return "⚠️ Android WebView versions differ across the fleet (\(majors.sorted().joined(separator: ", "))):"
            + " \(detail). Inside a WebView the same element is described differently — 124 exposes"
            + " a placeholder and no #id, 150 exposes an #id and no placeholder — so a selector that"
            + " works on one device fails on another. Level the fleet before trusting a run."
    }
}
