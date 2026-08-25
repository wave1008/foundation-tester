// VSCode拡張の新規デバイス作成UI向け: iOS機種/ランタイム一覧とAndroid AVD定義/システム
// イメージ一覧を1回取得しJSON1行で stdout に出す(fleetest api device-catalog。診断は stderr)。
// iOS/Androidいずれかの取得失敗はそちら側だけ available:false+error にしもう一方は正常に返す
// (片方のSDKしか無い環境でも使えるようにするため)。

import ArgumentParser
import Foundation
import FTAndroid
import FTCore

struct ApiDeviceCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-catalog",
        abstract: "Collect the catalog for creating new devices (iOS models/runtimes, Android AVD device"
            + " definitions/system images) and print it as JSON on stdout (diagnostics on stderr only)")

    func run() async throws {
        let output = ApiDeviceCatalogOutput(
            android: Self.androidCatalog(), ios: Self.iosCatalog())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    // MARK: - iOS

    private static func iosCatalog() -> ApiIOSCatalog {
        let deviceTypesResult: Shell.Result
        do {
            deviceTypesResult = try Shell.run(["xcrun", "simctl", "list", "-j", "devicetypes"])
        } catch {
            return ApiIOSCatalog(available: false, error: error.localizedDescription,
                                 deviceTypes: [], runtimes: [])
        }
        guard deviceTypesResult.status == 0 else {
            return ApiIOSCatalog(available: false, error: deviceTypesResult.tail,
                                 deviceTypes: [], runtimes: [])
        }
        let runtimesResult: Shell.Result
        do {
            runtimesResult = try Shell.run(["xcrun", "simctl", "list", "-j", "runtimes"])
        } catch {
            return ApiIOSCatalog(available: false, error: error.localizedDescription,
                                 deviceTypes: [], runtimes: [])
        }
        guard runtimesResult.status == 0 else {
            return ApiIOSCatalog(available: false, error: runtimesResult.tail,
                                 deviceTypes: [], runtimes: [])
        }

        guard let deviceTypesData = deviceTypesResult.output.data(using: .utf8),
              let deviceTypesJSON = (try? JSONSerialization.jsonObject(with: deviceTypesData))
                as? [String: Any],
              let rawDeviceTypes = deviceTypesJSON["devicetypes"] as? [[String: Any]] else {
            return ApiIOSCatalog(
                available: false, error: "cannot parse the simctl list devicetypes output",
                deviceTypes: [], runtimes: [])
        }
        guard let runtimesData = runtimesResult.output.data(using: .utf8),
              let runtimesJSON = (try? JSONSerialization.jsonObject(with: runtimesData))
                as? [String: Any],
              let rawRuntimes = runtimesJSON["runtimes"] as? [[String: Any]] else {
            return ApiIOSCatalog(
                available: false, error: "cannot parse the simctl list runtimes output",
                deviceTypes: [], runtimes: [])
        }

        // productFamily が iPhone/iPad のみ対象。devicetypes は実機確認済みで既に
        // 「新しい世代が先頭」順に返るため反転しない(runtimes とは出力順の向きが逆)
        let deviceTypes = rawDeviceTypes.compactMap { dict -> ApiIOSDeviceType? in
            guard let identifier = dict["identifier"] as? String,
                  let name = dict["name"] as? String,
                  let productFamily = dict["productFamily"] as? String,
                  productFamily == "iPhone" || productFamily == "iPad" else { return nil }
            return ApiIOSDeviceType(identifier: identifier, name: name, productFamily: productFamily)
        }

        // runtimes は platform "iOS" かつ isAvailable のみ。実機確認済みで出力順が
        // 「古いバージョンが先頭」の昇順のため反転して新しい順にする
        let runtimes = rawRuntimes.compactMap { dict -> ApiIOSRuntime? in
            guard let identifier = dict["identifier"] as? String,
                  let name = dict["name"] as? String,
                  let version = dict["version"] as? String,
                  (dict["platform"] as? String) == "iOS",
                  (dict["isAvailable"] as? Bool) == true else { return nil }
            return ApiIOSRuntime(identifier: identifier, name: name, version: version)
        }

        // beta更新を重ねた環境では simctl が同じ identifier を複数返すため重複排除する
        // (新しい順に並べた後の先勝ち。UI に同名項目が並ぶのを防ぐ)。deviceTypes も保険で同様
        return ApiIOSCatalog(
            available: true, error: nil,
            deviceTypes: uniqued(deviceTypes, by: \.identifier),
            runtimes: uniqued(Array(runtimes.reversed()), by: \.identifier))
    }

    /// 並び順を保ったまま key の重複を排除する(先勝ち)
    // 以降のパース/整列ヘルパーと ApiAndroidModel / ApiAndroidSystemImage は private ではなく
    // internal。FleetestTests から直接叩いて固めている(avdmanager の出力形式と整列規則は
    // 実機なしで壊れるとフリート一覧が静かに空になる)。private へ戻さないこと。
    private static func uniqued<T>(_ items: [T], by key: KeyPath<T, String>) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert($0[keyPath: key]).inserted }
    }

    // MARK: - Android

    private static func androidCatalog() -> ApiAndroidCatalog {
        guard let sdkRoot = AndroidSDKLocator.findSDKRoot() else {
            return ApiAndroidCatalog(
                available: false,
                error: "Android SDK not found (check ANDROID_HOME / ANDROID_SDK_ROOT)",
                errorCode: "sdk-missing",
                models: [], systemImages: [])
        }

        // システムイメージはディレクトリ走査のみで済むため avdmanager の有無に関わらず取得する
        let systemImages = Self.systemImages(sdkRoot: sdkRoot)

        guard let avdmanagerURL = AndroidSDKLocator.findAVDManager() else {
            return ApiAndroidCatalog(
                available: true,
                // **理由だけを返す**(解決手段は呼び手が足す)。カタログはリモートのホストからも
                // 取るので、ここで "fleetest api install-cmdline-tools" と書くと**読み手の手元へ
                // 入れる案内**になり、欠けている機械とは別のマシンを直させることになる
                // (拡張はローカルなら導入ボタン、リモートなら remote exec の案内を出す)
                error: AndroidSDKLocator.avdManagerMissingMessage,
                errorCode: "avdmanager-missing",
                models: [], systemImages: systemImages)
        }

        let result: Shell.Result
        do {
            result = try Shell.run([avdmanagerURL.path, "list", "device"])
        } catch {
            return ApiAndroidCatalog(available: true, error: error.localizedDescription,
                                     errorCode: "avdmanager-failed",
                                     models: [], systemImages: systemImages)
        }
        guard result.status == 0 else {
            return ApiAndroidCatalog(available: true, error: result.tail,
                                     errorCode: "avdmanager-failed",
                                     models: [], systemImages: systemImages)
        }

        let models = Self.parseDeviceDefinitions(result.output)
        return ApiAndroidCatalog(available: true, error: nil, errorCode: nil, models: models,
                                 systemImages: systemImages)
    }

    /// avdmanager list device の出力(ブロック形式)をパースする:
    /// `id: NN or "id_string"` 行の後、次の id 行が現れるまでの間にある最初の `Name: 表示名` 行と対にする
    static func parseDeviceDefinitions(_ output: String) -> [ApiAndroidModel] {
        var models: [(id: String, name: String)] = []
        var pendingID: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let id = Self.extractDeviceID(from: line) {
                pendingID = id
                continue
            }
            guard let id = pendingID else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Name:") else { continue }
            let name = trimmed.dropFirst("Name:".count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            models.append((id: id, name: name))
            pendingID = nil  // この id は Name を確定したので、以降の行(OEM/Tag等)は無視
        }
        return models
            .map { ApiAndroidModel(id: $0.id, name: $0.name) }
            .sorted(by: Self.modelSortsBefore)
    }

    /// `    id: 26 or "pixel_9_pro"` から id_string("pixel_9_pro")を取り出す
    static func extractDeviceID(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("id:") else { return nil }
        guard let firstQuote = trimmed.firstIndex(of: "\""),
              let lastQuote = trimmed.lastIndex(of: "\""), firstQuote != lastQuote else {
            return nil
        }
        return String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
    }

    /// models の並び順: Pixel系(id が "pixel" で始まる)を先頭に、id 中の数値の降順
    /// (同数値内は名前昇順)。その後にその他を名前昇順
    static func modelSortsBefore(_ lhs: ApiAndroidModel, _ rhs: ApiAndroidModel) -> Bool {
        let lhsPixel = lhs.id.hasPrefix("pixel")
        let rhsPixel = rhs.id.hasPrefix("pixel")
        if lhsPixel != rhsPixel { return lhsPixel }
        if lhsPixel {
            let lhsNumber = Self.firstNumber(in: lhs.id)
            let rhsNumber = Self.firstNumber(in: rhs.id)
            if lhsNumber != rhsNumber { return lhsNumber > rhsNumber }
        }
        return lhs.name < rhs.name
    }

    /// 文字列中の最初の連続数字を Int にする(無ければ 0。"pixel"/"pixel_c" 等の無番機種を
    /// 同グループの末尾へ寄せるための sentinel として使う)
    static func firstNumber(in text: String) -> Int {
        var digits = ""
        var started = false
        for ch in text {
            if ch.isNumber {
                digits.append(ch)
                started = true
            } else if started {
                break
            }
        }
        return Int(digits) ?? 0
    }

    /// SDK ルートの system-images/android-<N>/<tag>/<abi>/ をディレクトリ走査してシステムイメージ
    /// 一覧を作る(avdmanager 不要・高速。android-<N> の N が整数でないもの(コードネーム版等)は
    /// スキップする)
    private static func systemImages(sdkRoot: URL) -> [ApiAndroidSystemImage] {
        let fm = FileManager.default
        let systemImagesDir = sdkRoot.appendingPathComponent("system-images")
        guard let apiDirs = try? fm.contentsOfDirectory(
            at: systemImagesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var images: [ApiAndroidSystemImage] = []
        for apiDir in apiDirs {
            let dirName = apiDir.lastPathComponent
            guard dirName.hasPrefix("android-") else { continue }
            guard let apiLevel = Int(dirName.dropFirst("android-".count)) else { continue }
            guard let tagDirs = try? fm.contentsOfDirectory(
                at: apiDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for tagDir in tagDirs {
                let tag = tagDir.lastPathComponent
                guard let abiDirs = try? fm.contentsOfDirectory(
                    at: tagDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }
                for abiDir in abiDirs {
                    let abi = abiDir.lastPathComponent
                    images.append(ApiAndroidSystemImage(
                        abi: abi, apiLevel: apiLevel,
                        package: "system-images;android-\(apiLevel);\(tag);\(abi)",
                        tag: tag,
                        versionName: MachineProfileEditor.androidVersionName(apiLevel: apiLevel)))
                }
            }
        }
        return images.sorted(by: Self.systemImageSortsBefore)
    }

    /// systemImages の並び順: apiLevel 降順 → tag 優先順(google_apis > google_apis_playstore >
    /// default > その他名前順)→ 同一 tag 内は abi(arm64-v8a 優先)
    static func systemImageSortsBefore(
        _ lhs: ApiAndroidSystemImage, _ rhs: ApiAndroidSystemImage
    ) -> Bool {
        if lhs.apiLevel != rhs.apiLevel { return lhs.apiLevel > rhs.apiLevel }
        let lhsRank = Self.tagRank(lhs.tag)
        let rhsRank = Self.tagRank(rhs.tag)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.tag != rhs.tag { return lhs.tag < rhs.tag }
        let lhsIsArm64 = lhs.abi == "arm64-v8a"
        let rhsIsArm64 = rhs.abi == "arm64-v8a"
        if lhsIsArm64 != rhsIsArm64 { return lhsIsArm64 }
        return lhs.abi < rhs.abi
    }

    static func tagRank(_ tag: String) -> Int {
        switch tag {
        case "google_apis": return 0
        case "google_apis_playstore": return 1
        case "default": return 2
        default: return 3
        }
    }
}

// MARK: - 出力モデル

/// fleetest api device-catalog の出力全体
private struct ApiDeviceCatalogOutput: Encodable {
    let android: ApiAndroidCatalog
    let ios: ApiIOSCatalog
}

/// iOS カタログ。error は省略可能フィールドとして明示的に null を encode する
/// (ApiScenarioInfo と同方針)
private struct ApiIOSCatalog: Encodable {
    let available: Bool
    let error: String?
    let deviceTypes: [ApiIOSDeviceType]
    let runtimes: [ApiIOSRuntime]

    private enum CodingKeys: String, CodingKey {
        case available, error, deviceTypes, runtimes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(error, forKey: .error)
        try container.encode(deviceTypes, forKey: .deviceTypes)
        try container.encode(runtimes, forKey: .runtimes)
    }
}

private struct ApiIOSDeviceType: Encodable {
    let identifier: String
    let name: String
    let productFamily: String
}

private struct ApiIOSRuntime: Encodable {
    let identifier: String
    let name: String
    /// simctl の "version" フィールドそのまま(例 "27.0")
    let version: String
}

/// Android カタログ。error は省略可能フィールドとして明示的に null を encode する。
/// errorCode は error の機械可読版(拡張が「導入ボタンを出すか」を判断する。文言では分岐させない)
private struct ApiAndroidCatalog: Encodable {
    let available: Bool
    let error: String?
    /// "sdk-missing" / "avdmanager-missing" / "avdmanager-failed" / 正常時 nil。
    /// vscode-fleetest/src/monitorModel.ts の AndroidCatalogErrorCode と対。片方だけ変えない
    let errorCode: String?
    let models: [ApiAndroidModel]
    let systemImages: [ApiAndroidSystemImage]

    private enum CodingKeys: String, CodingKey {
        case available, error, errorCode, models, systemImages
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(error, forKey: .error)
        try container.encode(errorCode, forKey: .errorCode)
        try container.encode(models, forKey: .models)
        try container.encode(systemImages, forKey: .systemImages)
    }
}

struct ApiAndroidModel: Encodable {
    let id: String
    let name: String
}

struct ApiAndroidSystemImage: Encodable {
    let abi: String
    let apiLevel: Int
    let package: String
    let tag: String
    let versionName: String
}
