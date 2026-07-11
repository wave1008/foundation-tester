// ApiInstalledDevicesCommand.swift
// VSCode拡張の「既存のデバイスから選択」UI 向け: マシンにインストール済みの iOS シミュレータと
// Android AVD を1回取得しJSONで stdout に出力する(ftester api installed-devices)。
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
        abstract: "インストール済みのiOSシミュレータとAndroid AVDを取得しJSONでstdoutに出力する"
            + "(診断は stderr のみ)")

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
            return ApiInstalledIOSCatalog(
                available: false, error: error.localizedDescription, devices: [])
        }
        let sorted = devices.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.os > $1.os
        }
        let entries = sorted.map {
            ApiInstalledIOSDevice(name: $0.name, os: Self.normalizeOS($0.os), udid: $0.udid)
        }
        return ApiInstalledIOSCatalog(available: true, error: nil, devices: entries)
    }

    /// SimDeviceInfo.os は "iOS 27.0" 形式。出力の os はバージョン番号のみ("27.0")に正規化する
    private static func normalizeOS(_ os: String) -> String {
        os.hasPrefix("iOS ") ? String(os.dropFirst("iOS ".count)) : os
    }

    // MARK: - Android

    /// AndroidDeviceCatalog.installedAVDs() は非 throwing(AVD ディレクトリが無ければ単に空配列)
    /// のため、この経路に失敗状態は無い
    private static func androidCatalog() -> ApiInstalledAndroidCatalog {
        let avds = AndroidDeviceCatalog.installedAVDs().map {
            ApiInstalledAVD(displayName: $0.displayName ?? $0.id, id: $0.id)
        }
        return ApiInstalledAndroidCatalog(available: true, error: nil, avds: avds)
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

    private enum CodingKeys: String, CodingKey {
        case available, error, devices
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(error, forKey: .error)
        try container.encode(devices, forKey: .devices)
    }
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

    private enum CodingKeys: String, CodingKey {
        case available, error, avds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(error, forKey: .error)
        try container.encode(avds, forKey: .avds)
    }
}

private struct ApiInstalledAVD: Encodable {
    /// displayName が無い AVD は id をそのまま使う
    let displayName: String
    let id: String
}
