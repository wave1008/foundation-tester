// VSCode拡張の「既存のデバイスから選択」UI 向け: マシンにインストール済みの iOS シミュレータと
// Android AVD、**および接続中の実機**を1回取得しJSONで stdout に出力する
// (ftester api installed-devices)。
// プロジェクト/マシンプロファイルに依存しないため引数は無い。
// stdout には結果 1 行の JSON だけを出す(診断は stderr のみ。ApiCommands.swift と同じ流儀)。
//
// iOS/Android いずれかの取得に失敗しても、そちら側だけ available:false + error を立てて
// もう一方は正常に返す(実機に片方の SDK しか無い環境でも使えるようにするため。
// ApiDeviceCatalogCommand と同方針)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiInstalledDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "installed-devices",
        abstract: "Collect the installed iOS simulators and Android AVDs and print them as JSON on stdout"
            + " (diagnostics on stderr only)")

    func run() async throws {
        let output = ApiInstalledDevicesOutput(
            android: Self.androidCatalog(), ios: Self.iosCatalog())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    // MARK: - iOS

    /// SimulatorCatalog.devices() は既に isAvailable のみを返す。並びは
    /// name 昇順 → os 降順(SimulatorCatalog 自体の既定の並び「起動中→OS降順→名前順」とは
    /// 用途が異なるため、この API 向けに明示的に並べ替える)
    private static func iosCatalog() -> ApiInstalledIOSCatalog {
        let devices: [SimDeviceInfo]
        do {
            devices = try SimulatorCatalog.devices()
        } catch {
            // シミュレータ列挙が壊れていても実機は devicectl 経由で独立に取れる
            return ApiInstalledIOSCatalog(
                available: false, error: error.localizedDescription, devices: [],
                physicalDevices: iosPhysicalDevices())
        }
        let sorted = devices.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.os > $1.os
        }
        let entries = sorted.map {
            ApiInstalledIOSDevice(name: $0.name, os: Self.normalizeOS($0.os), udid: $0.udid)
        }
        return ApiInstalledIOSCatalog(available: true, error: nil, devices: entries,
                                      physicalDevices: iosPhysicalDevices())
    }

    /// 接続中の iOS 実機(devicectl)。取得失敗・0 台は空配列で返す
    /// (シミュレータ側の available を巻き添えで false にしない)。
    /// udid は**ハードウェア UDID**(xcodebuild の -destination が受け付ける方。
    /// devicectl の Identifier 列とは別物。IOSPhysicalDeviceCatalog 参照)
    private static func iosPhysicalDevices() -> [ApiPhysicalIOSDevice] {
        let devices = (try? IOSPhysicalDeviceCatalog.devices()) ?? []
        return devices.filter(\.connected).map {
            ApiPhysicalIOSDevice(name: $0.name, os: Self.normalizeOS($0.os), udid: $0.udid,
                                 transport: $0.transport, model: $0.model)
        }
    }

    /// SimDeviceInfo.os は "iOS 27.0" 形式。出力の os はバージョン番号のみ("27.0")に正規化する
    /// FTesterTests から検証するため internal。
    static func normalizeOS(_ os: String) -> String {
        os.hasPrefix("iOS ") ? String(os.dropFirst("iOS ".count)) : os
    }

    // MARK: - Android

    /// AndroidDeviceCatalog.installedAVDs() は非 throwing(AVD ディレクトリが無ければ単に空配列)
    /// のため、この経路に失敗状態は無い
    private static func androidCatalog() -> ApiInstalledAndroidCatalog {
        let avds = AndroidDeviceCatalog.installedAVDs().map { avd in
            // 機種/OS は config.ini 由来の表示専用情報(実機の model/os と同じ扱い)
            let info = AndroidDeviceCatalog.avdModelAndOS(id: avd.id)
            return ApiInstalledAVD(displayName: avd.displayName ?? avd.id, id: avd.id,
                                   model: info.model, os: info.os)
        }
        return ApiInstalledAndroidCatalog(available: true, error: nil, avds: avds,
                                          physicalDevices: androidPhysicalDevices())
    }

    /// 接続中の Android 実機(adb devices の state=device のうち emulator- 前置でないもの)。
    /// 表示名は ro.product.model(取れなければ serial)
    private static func androidPhysicalDevices() -> [ApiPhysicalAndroidDevice] {
        let serials = ((try? AndroidDeviceCatalog.connectedSerials()) ?? [])
            .filter { !$0.hasPrefix("emulator-") }
        guard !serials.isEmpty, let adb = try? AndroidDriver.findADB() else { return [] }
        func getprop(_ serial: String, _ key: String) -> String {
            (try? Shell.run([adb, "-s", serial, "shell", "getprop", key], timeout: 10))?
                .output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return serials.map { serial in
            let model = getprop(serial, "ro.product.model")
            return ApiPhysicalAndroidDevice(
                model: model.isEmpty ? serial : model,
                os: getprop(serial, "ro.build.version.release"),
                serial: serial)
        }
    }
}

// MARK: - 出力モデル

/// ftester api installed-devices の出力全体
private struct ApiInstalledDevicesOutput: Encodable {
    let android: ApiInstalledAndroidCatalog
    let ios: ApiInstalledIOSCatalog
}

/// iOS カタログ。error は省略可能フィールドとして明示的に null を encode する
/// (ApiDeviceCatalogCommand の ApiIOSCatalog と同方針)
private struct ApiInstalledIOSCatalog: Encodable {
    let available: Bool
    let error: String?
    let devices: [ApiInstalledIOSDevice]
    /// 接続中の実機(kind=physical で登録する候補)。追加フィールド=後方互換
    let physicalDevices: [ApiPhysicalIOSDevice]

    private enum CodingKeys: String, CodingKey {
        case available, error, devices, physicalDevices
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(error, forKey: .error)
        try container.encode(devices, forKey: .devices)
        try container.encode(physicalDevices, forKey: .physicalDevices)
    }
}

private struct ApiPhysicalIOSDevice: Encodable {
    let name: String
    /// "26.5.2" のようなバージョン番号のみ
    let os: String
    /// マシンプロファイルの udid にそのまま書ける値
    let udid: String
    /// "wired" / "localNetwork" 等(devicectl の transportType 生値)
    let transport: String
    /// 機種名(marketingName。例 "iPhone 15 Pro")
    let model: String
}

private struct ApiInstalledIOSDevice: Encodable {
    let name: String
    /// "27.0" のようなバージョン番号のみ("iOS " prefix なし)
    let os: String
    let udid: String
}

/// Android カタログ。error は省略可能フィールドとして明示的に null を encode する
private struct ApiInstalledAndroidCatalog: Encodable {
    let available: Bool
    let error: String?
    let avds: [ApiInstalledAVD]
    /// 接続中の実機(kind=physical で登録する候補)。追加フィールド=後方互換
    let physicalDevices: [ApiPhysicalAndroidDevice]

    private enum CodingKeys: String, CodingKey {
        case available, error, avds, physicalDevices
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(error, forKey: .error)
        try container.encode(avds, forKey: .avds)
        try container.encode(physicalDevices, forKey: .physicalDevices)
    }
}

private struct ApiPhysicalAndroidDevice: Encodable {
    /// ro.product.model(取れなければ serial)
    let model: String
    /// ro.build.version.release(例 "13")
    let os: String
    /// マシンプロファイルの serial にそのまま書ける値
    let serial: String
}

private struct ApiInstalledAVD: Encodable {
    /// displayName が無い AVD は id をそのまま使う
    let displayName: String
    let id: String
    /// config.ini の hw.device.name(例 "pixel_9")。取れなければ null
    let model: String?
    /// image.sysdir.1 から導出した OS 表記(例 "Android 15")。取れなければ null
    let os: String?

    private enum CodingKeys: String, CodingKey { case displayName, id, model, os }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode(os, forKey: .os)
    }
}
