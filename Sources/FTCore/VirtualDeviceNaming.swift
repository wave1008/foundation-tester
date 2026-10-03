// 仮想デバイスの命名「<機種>(<OS ラベル>)-NN」の純粋ロジック。
// 同期相手: vscode-fleetest/src/webview/monitor/deviceNaming.js(拡張の「デバイスを追加」)。
// 正解表は Tests/Fixtures/VirtualDeviceNaming/cases.json(Swift/JS 両方のテストが読む)。片方だけ変えない

import Foundation

public enum VirtualDeviceNaming {

    /// 連番の上限(2桁)
    public static let maxSerial = 99

    /// "iPhone 17 Pro(iOS 27.0)"。括弧は ASCII・空白なし
    public static func baseName(model: String, osLabel: String) -> String {
        "\(model)(\(osLabel))"
    }

    /// "Android 16, API 36, APIs"。サービス名は tag に "playstore" を含めば "Play"、
    /// "google_apis" で始まれば "APIs"、他は tag のまま(拡張の #dlg-service の表示「Google …」とは別の短縮形)。
    /// API 21 未満は版名が無い(androidVersionName が "API n" を返す)ので API を二重に書かない
    public static func androidOSLabel(apiLevel: Int, tag: String) -> String {
        let service = tag.contains("playstore") ? "Play"
            : tag.hasPrefix("google_apis") ? "APIs" : tag
        let version = RunProfileDeviceEditor.androidVersionName(apiLevel: apiLevel)
        let head = version.hasPrefix("API ") ? version : "\(version), API \(apiLevel)"
        return "\(head), \(service)"
    }

    /// `<base>-NN`(NN はちょうど2桁の ASCII 数字)なら NN。base に括弧・ドットが入るので
    /// 正規表現でなく接頭辞+接尾辞で判定する("<base> Max(...)-01" のような前方一致だけの別機種は除外される)
    public static func serialNumber(of name: String, base: String) -> Int? {
        let prefix = base + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count == 2,
              suffix.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return nil }
        return Int(suffix)
    }

    /// `<base>-NN` かつ matches(name) の名前のうち番号が最小のもの
    public static func lowestMatching(base: String, names: [String],
                                      matches: (String) -> Bool) -> String? {
        var best: (number: Int, name: String)?
        for name in names {
            guard let number = serialNumber(of: name, base: base), matches(name) else { continue }
            if best == nil || number < best!.number { best = (number, name) }
        }
        return best?.name
    }

    /// existing に無い `<base>-NN` を小さい順に count 個(01〜99。足りなければ count 未満)
    public static func nextUnusedNames(base: String, existing: [String], count: Int) -> [String] {
        let used = Set(existing.compactMap { serialNumber(of: $0, base: base) })
        var result: [String] = []
        var number = 1
        while result.count < count, number <= maxSerial {
            if !used.contains(number) {
                result.append("\(base)-\(number < 10 ? "0" : "")\(number)")
            }
            number += 1
        }
        return result
    }

    /// config.ini の image.sysdir.1("system-images/android-35/google_apis/arm64-v8a/")→
    /// avdmanager の package・API レベル・tag。"android-36.1" の API は先頭の数字(36)。形が違えば nil
    public static func androidImage(fromSysdir sysdir: String) -> (package: String, apiLevel: Int, tag: String)? {
        let parts = sysdir.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, parts[0] == "system-images", parts[1].hasPrefix("android-") else { return nil }
        let digits = parts[1].dropFirst("android-".count).prefix { $0.isASCII && $0.isNumber }
        guard let apiLevel = Int(digits) else { return nil }
        return (parts.prefix(4).joined(separator: ";"), apiLevel, parts[2])
    }
}
