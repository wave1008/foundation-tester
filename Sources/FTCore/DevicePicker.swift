// DevicePicker.swift
// `fleetest profile setup --auto-device` のデバイス選定規則(純粋ロジック)。
// 実機・シミュレータを用意しないと確かめられない部分と切り離し、規則だけを単体テストで固める。
//
// 呼び出し側(ProfileSetupCommand)が simctl / emulator から一覧を取り、ここが「どれを選ぶか」を決める。

import Foundation

public enum DevicePicker {

    /// "iOS 27.0" / "27.0" / "iOS 26.10" → [27, 0] のような比較可能な数値列。
    /// **文字列比較で代用してはいけない**("26.10" < "26.9" になる)
    public static func osVersionValue(_ os: String) -> [Int] {
        let digitsAndDots = os.filter { $0.isNumber || $0 == "." }
        return digitsAndDots.split(separator: ".").compactMap { Int($0) }
    }

    /// 新しい方が大きい順序(同値は false)
    public static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let (l, r) = (osVersionValue(lhs), osVersionValue(rhs))
        for index in 0..<max(l.count, r.count) {
            let lv = index < l.count ? l[index] : 0
            let rv = index < r.count ? r[index] : 0
            if lv != rv { return lv > rv }
        }
        return false
    }

    /// iPad か(シミュレータ名は既定で機種名そのもの: "iPad Pro 13-inch (M4)")
    public static func isIPad(name: String) -> Bool {
        name.lowercased().contains("ipad")
    }

    /// シミュレータを1台選ぶ: **iPad を除外**した上で(除外しないと下の "Pro" 優先が iPad Pro を
    /// 掴む)、**最新 OS** の中で名前に "Pro" を含むものを優先し、無ければ先頭。iPhone が
    /// 無ければ nil。入力の並び順に依存しない(SimulatorCatalog は「起動中」を先頭に寄せるため、
    /// 先頭を最新 OS とみなすと**古い OS の起動中デバイス**を掴む)。
    /// 同点のときは入力順を保つ(呼び出し側の並び = 起動中優先 を尊重する)
    public static func pickSimulatorIndex(_ devices: [(name: String, os: String)]) -> Int? {
        let phones = devices.enumerated().filter { !isIPad(name: $0.element.name) }
        guard !phones.isEmpty else { return nil }
        guard let newestOS = phones.map(\.element.os).max(by: { isNewer($1, than: $0) })
        else { return nil }
        let candidates = phones.filter { $0.element.os == newestOS }
        return (candidates.first { $0.element.name.contains("Pro") } ?? candidates[0]).offset
    }

    /// AVD を1台選ぶ: API レベルが最大のもの。同点・不明(-1)は名前順で決定的に
    public static func pickAVD(_ candidates: [(name: String, apiLevel: Int)]) -> String? {
        candidates.sorted {
            $0.apiLevel == $1.apiLevel ? $0.name < $1.name : $0.apiLevel > $1.apiLevel
        }.first?.name
    }

    /// AVD の config.ini から API レベルを読む(`image.sysdir.1=system-images/android-36/...`)。
    /// 読めない・書式が違うときは -1(= 不明。pickAVD で最後尾に回る)
    public static func apiLevel(fromConfigINI text: String) -> Int {
        for line in text.split(separator: "\n") where line.hasPrefix("image.sysdir.1") {
            guard let range = line.range(of: "android-") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let level = Int(digits) { return level }
        }
        return -1
    }

    /// Android の serial が実機か。エミュレータは `emulator-5554` 形式で採番される
    /// (`kind: "physical"` を誤って付けると実機向けの準備処理が走り、run が壊れる)
    public static func isPhysicalAndroidSerial(_ serial: String) -> Bool {
        !serial.hasPrefix("emulator-")
    }
}
