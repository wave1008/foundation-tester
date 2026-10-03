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

    // MARK: - iOS(最新ランタイム + 最新の iPhone <数字>)

    public struct IOSRuntimeInfo: Equatable {
        public let identifier: String
        /// simctl の version("27.0")
        public let version: String
        public let name: String
        /// simctl の supportedDeviceTypes[].identifier
        public let supportedDeviceTypeIdentifiers: [String]
        public init(identifier: String, version: String, name: String,
                    supportedDeviceTypeIdentifiers: [String]) {
            self.identifier = identifier
            self.version = version
            self.name = name
            self.supportedDeviceTypeIdentifiers = supportedDeviceTypeIdentifiers
        }
    }

    public enum IOSRuntimeChoice: Equatable {
        case installed(identifier: String)
        /// SDK の版(`xcodebuild -downloadPlatform iOS` が入れる版)。入った後の identifier は
        /// `predictedIOSRuntimeIdentifier(version:)`
        case needsDownload(version: String)
    }

    /// 「選択中の Xcode が入れられる最新」= `xcrun --sdk iphonesimulator --show-sdk-version` の版。
    /// インストール済みの最大がそれ以上ならそれを使い、未満なら要ダウンロード。
    /// sdkVersion が nil・数字として読めないときは導入済みの最大(無ければ nil)
    public static func newestIOSRuntime(
        installed: [(identifier: String, version: String, name: String)], sdkVersion: String?
    ) -> IOSRuntimeChoice? {
        var best: (identifier: String, version: String, name: String)?
        for runtime in installed where best == nil || isNewer(runtime.version, than: best!.version) {
            best = runtime
        }
        let sdk = sdkVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdk, !osVersionValue(sdk).isEmpty else {
            return best.map { .installed(identifier: $0.identifier) }
        }
        if let best, !isNewer(sdk, than: best.version) {
            return .installed(identifier: best.identifier)
        }
        return .needsDownload(version: sdk)
    }

    /// ダウンロード後に作られるランタイムの identifier("27.0" → "...SimRuntime.iOS-27-0")。
    /// 版が読めなければ nil。主・副の2要素に揃える("27" → iOS-27-0。3要素目以降は simctl の identifier に出ない)
    public static func predictedIOSRuntimeIdentifier(version: String) -> String? {
        let parts = osVersionValue(version)
        guard let major = parts.first else { return nil }
        return "com.apple.CoreSimulator.SimRuntime.iOS-\(major)-\(parts.count > 1 ? parts[1] : 0)"
    }

    /// `...SimDeviceType.iPhone-<数字>` にちょうど一致するもの(Pro・Pro Max・Plus・Air・Duo・e・mini・SE 等の
    /// 装飾つきは除く)のうち数字が最大のもの。supportedBy があればそれに含まれるものだけ
    /// (要ダウンロードのときは nil = 絞らない)
    public static func newestIPhoneDeviceType(
        identifiers: [String], supportedBy: Set<String>?
    ) -> String? {
        let prefix = "com.apple.CoreSimulator.SimDeviceType.iPhone-"
        var best: (number: Int, identifier: String)?
        for identifier in identifiers {
            guard identifier.hasPrefix(prefix) else { continue }
            let digits = identifier.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else { continue }
            if let supportedBy, !supportedBy.contains(identifier) { continue }
            if best == nil || number > best!.number { best = (number, identifier) }
        }
        return best?.identifier
    }

    public struct IOSAutoTarget: Equatable {
        public let runtime: IOSRuntimeChoice
        public let deviceTypeIdentifier: String
        public init(runtime: IOSRuntimeChoice, deviceTypeIdentifier: String) {
            self.runtime = runtime
            self.deviceTypeIdentifier = deviceTypeIdentifier
        }
    }

    /// iOS の自動選定の規則そのもの(CLI の profile setup と device-catalog の recommended が共有する)
    public static func iosAutoTarget(
        runtimes: [IOSRuntimeInfo], deviceTypeIdentifiers: [String], sdkVersion: String?
    ) -> IOSAutoTarget? {
        guard let choice = newestIOSRuntime(
            installed: runtimes.map { ($0.identifier, $0.version, $0.name) }, sdkVersion: sdkVersion)
        else { return nil }
        var supported: Set<String>?
        if case .installed(let identifier) = choice {
            supported = Set(runtimes.first { $0.identifier == identifier }?.supportedDeviceTypeIdentifiers ?? [])
        }
        guard let deviceType = newestIPhoneDeviceType(
            identifiers: deviceTypeIdentifiers, supportedBy: supported) else { return nil }
        return IOSAutoTarget(runtime: choice, deviceTypeIdentifier: deviceType)
    }

    // MARK: - Android(最新の Pixel + 最新の google_apis イメージ)

    /// Android の自動選定の規則そのもの(profile setup と device-catalog の recommended が共有する)。
    /// 機種か イメージのどちらかが無ければ nil
    public static func androidAutoTarget(
        models: [(id: String, name: String)],
        installed: [SystemImageCandidate], downloadable: [SystemImageCandidate],
        tag: String, abi: String
    ) -> (model: (id: String, name: String), image: SystemImageCandidate, isInstalled: Bool)? {
        guard let model = newestPixelPhone(models),
              let picked = newestSystemImage(installed: installed, downloadable: downloadable, tag: tag, abi: abi)
        else { return nil }
        return (model, picked.image, picked.isInstalled)
    }

    /// 機種定義(avdmanager list device の id と Name)から最新の Pixel スマートフォンを選ぶ。
    /// 対象は id が `pixel_<数字>` か `pixel_<数字>a` にちょうど一致するもの(pixel_9_pro・pixel_9_pro_xl・
    /// pixel_fold・pixel_tablet・pixel_c 等の装飾つき/数字なしは除く)。数字が最大のものを選び、
    /// 同じ数字なら無印(pixel_10)を a(pixel_10a)より優先する
    public static func newestPixelPhone(
        _ models: [(id: String, name: String)]
    ) -> (id: String, name: String)? {
        var best: (number: Int, isA: Bool, model: (id: String, name: String))?
        for model in models {
            guard model.id.hasPrefix("pixel_") else { continue }
            var digits = model.id.dropFirst("pixel_".count)
            let isA = digits.hasSuffix("a")
            if isA { digits = digits.dropLast() }
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(digits) else { continue }
            if let current = best, number < current.number || (number == current.number && (isA || !current.isA)) {
                continue
            }
            best = (number, isA, model)
        }
        return best?.model
    }

    public struct SystemImageCandidate: Equatable {
        public let package: String
        public let apiLevel: Int
        public let tag: String
        public let abi: String
        public init(package: String, apiLevel: Int, tag: String, abi: String) {
            self.package = package
            self.apiLevel = apiLevel
            self.tag = tag
            self.abi = abi
        }
    }

    /// tag と abi が一致する候補のうち apiLevel が最大のもの。同じ apiLevel ならインストール済みを優先する
    public static func newestSystemImage(
        installed: [SystemImageCandidate], downloadable: [SystemImageCandidate],
        tag: String, abi: String
    ) -> (image: SystemImageCandidate, isInstalled: Bool)? {
        let matches = { (list: [SystemImageCandidate]) in list.filter { $0.tag == tag && $0.abi == abi } }
        let installedBest = matches(installed).max { $0.apiLevel < $1.apiLevel }
        let downloadableBest = matches(downloadable).max { $0.apiLevel < $1.apiLevel }
        switch (installedBest, downloadableBest) {
        case let (local?, remote?):
            return remote.apiLevel > local.apiLevel ? (remote, false) : (local, true)
        case let (local?, nil): return (local, true)
        case let (nil, remote?): return (remote, false)
        case (nil, nil): return nil
        }
    }

    /// Android の serial が実機か。エミュレータは `emulator-5554` 形式で採番される
    /// (`kind: "physical"` を誤って付けると実機向けの準備処理が走り、run が壊れる)
    public static func isPhysicalAndroidSerial(_ serial: String) -> Bool {
        !serial.hasPrefix("emulator-")
    }
}
