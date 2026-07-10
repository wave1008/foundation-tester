// ApiLiveCommand.swift
// VSCode拡張のライブ操作パネル向け: 手動駆動コマンド(FTester.swift の Snapshot/Tap/
// TypeCommand/Swipe/Press/Install/Launch/Terminate)と同じ AppDriver 呼び出しを流用した
// 機械可読ワンショットCLI(ftester api live <sub>)。常駐しない(1回の呼び出しにつき1回の
// 操作を行い、結果を1行 JSON で出して終了する)。
//
// 座標契約: snapshot の screen / elements[].frame はポイント座標(ftester-gui/LiveView.swift の
// ScreenshotView と同じ)。スクリーンショット画像上のクリック位置→ポイント座標への比例変換は
// 呼び出し側(拡張)が行い、このコマンドへは変換済みのポイント座標をそのまま渡す契約。
//
// 出力方針: stdout には 1 行の JSON だけを出力する(診断は stderr のみ。ApiCommands.swift と
// 同じ流儀)。snapshot はスクリーンショットのダウンスケール+JPEG化に ApiMonitorCommand.swift の
// MonitorImage(private を外して共有)を再利用する。
//
// エラー方針: ドライバ操作(ブリッジ/adb 通信等)の失敗は throw で落とさず
// {"ok":false,"error":"<localizedDescription>"} を stdout に出して exit code 1 で終える
// (拡張がパースしてエラー表示する。ApiDeviceCommands.swift の ok:false 方針と同じ)。
// 一方、引数不正(--platform の値が不正、--ref/--x/--y の指定不足等)は ValidationError を
// そのまま throw し、従来どおり ArgumentParser にフォーマットさせる。

import ArgumentParser
import Foundation
import FTCore

struct ApiLiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live",
        abstract: "VSCode拡張のライブ操作パネル向け機械可読ワンショットCLI"
            + "(snapshot/tap/type/swipe/press/launch/terminate/install。"
            + "stdout に結果1行のJSON。診断は stderr のみ)",
        subcommands: [ApiLiveSnapshot.self, ApiLiveTap.self, ApiLiveType.self,
                      ApiLiveSwipe.self, ApiLivePress.self, ApiLiveLaunch.self,
                      ApiLiveTerminate.self, ApiLiveInstall.self])
}

// MARK: - api live snapshot

struct ApiLiveSnapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "スクリーンショット(ダウンスケール済み JPEG)とアクセシビリティツリーを"
            + "1行のJSONで出力する(失敗時: ok:false + exit code 1)")

    @Option(name: .customLong("max-width"), help: "スクリーンショットの長辺の最大幅(px。既定 640)")
    var maxWidth: Int = 640

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let driver = try driverOptions.makeDriver()
        do {
            let png = try await driver.screenshot()
            let jpeg = try MonitorImage.downscaledJPEG(pngData: png, maxWidth: maxWidth)
            let snap = try await driver.snapshot()
            let elements = snap.elements.map {
                ApiLiveElement(ref: $0.ref, type: $0.type, label: $0.label,
                               identifier: $0.identifier, value: $0.value, frame: $0.frame)
            }
            emitLiveJSON(ApiLiveSnapshotResult(
                platform: driverOptions.platform,
                screen: ApiLiveScreenSize(width: snap.screen.width, height: snap.screen.height),
                image: jpeg.data.base64EncodedString(),
                elements: elements))
        } catch {
            emitLiveJSON(ApiLiveErrorResult(error: error.localizedDescription))
            throw ExitCode(1)
        }
    }
}

// MARK: - api live tap

struct ApiLiveTap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "要素または座標(pt)をタップする(失敗時: ok:false + exit code 1)")

    @Option(help: "snapshot の参照番号")
    var ref: Int?

    @Option(help: "X座標(pt)")
    var x: Double?

    @Option(help: "Y座標(pt)")
    var y: Double?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let driver = try driverOptions.makeDriver()
        if let ref {
            try await runLiveAction { try await driver.tap(ref: ref) }
        } else if let x, let y {
            try await runLiveAction { try await driver.tap(x: x, y: y) }
        } else {
            throw ValidationError("--ref か --x/--y のどちらかを指定してください")
        }
    }
}

// MARK: - api live type

struct ApiLiveType: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "テキストを入力する(--ref 指定時はタップしてから入力。"
            + "失敗時: ok:false + exit code 1)")

    @Option(help: "入力する文字列")
    var text: String

    @Option(help: "入力先要素の参照番号(省略時はフォーカス中の要素)")
    var ref: Int?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let driver = try driverOptions.makeDriver()
        try await runLiveAction { try await driver.type(ref: ref, text: text) }
    }
}

// MARK: - api live swipe

struct ApiLiveSwipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "スワイプする(失敗時: ok:false + exit code 1)")

    @Option(help: "方向: up / down / left / right")
    var direction: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard let dir = FTSwipeDirection(rawValue: direction) else {
            throw ValidationError("方向は up / down / left / right のいずれかです")
        }
        let driver = try driverOptions.makeDriver()
        try await runLiveAction { try await driver.swipe(dir) }
    }
}

// MARK: - api live press

struct ApiLivePress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "要素を長押しする(失敗時: ok:false + exit code 1)")

    @Option(help: "snapshot の参照番号")
    var ref: Int

    @Option(help: "長押し秒数")
    var duration: Double = 1.0

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let driver = try driverOptions.makeDriver()
        try await runLiveAction { try await driver.press(ref: ref, duration: duration) }
    }
}

// MARK: - api live launch

struct ApiLiveLaunch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "対象アプリを起動する(失敗時: ok:false + exit code 1)")

    @Option(help: "アプリの bundle identifier(例: com.example.sampleapp)")
    var bundle: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let driver = try driverOptions.makeDriver()
        try await runLiveAction { try await driver.launch(bundleID: bundle) }
    }
}

// MARK: - api live terminate

struct ApiLiveTerminate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminate",
        abstract: "対象アプリを終了する(失敗時: ok:false + exit code 1)")

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let driver = try driverOptions.makeDriver()
        try await runLiveAction { try await driver.terminate() }
    }
}

// MARK: - api live install

struct ApiLiveInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "パッケージファイルからアプリをインストールする"
            + "(iOS: .app バンドル / Android: .apk。失敗時: ok:false + exit code 1)")

    @Option(help: "パッケージファイルのパス(iOS: .app バンドル / Android: .apk)")
    var path: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("パッケージファイルが見つかりません: \(path)")
        }
        let driver = try driverOptions.makeDriver()
        try await runLiveAction { try await driver.install(packagePath: path) }
    }
}

// MARK: - 共通ヘルパー

/// ドライバ操作を実行し、成功時は {"ok":true}、失敗時は {"ok":false,"error":...} を出力して
/// exit code 1 で終える。makeDriver() 自体の ValidationError(--platform 不正)はこのヘルパーの
/// 外側(呼び出し元の run() 冒頭)で発生させ、ここには渡さない契約(ArgumentParser にそのまま
/// 処理させるため)。ApiDeviceCommands.swift の ok:false 方針と同じ
private func runLiveAction(_ body: () async throws -> Void) async throws {
    do {
        try await body()
        emitLiveJSON(ApiLiveOkResult())
    } catch {
        emitLiveJSON(ApiLiveErrorResult(error: error.localizedDescription))
        throw ExitCode(1)
    }
}

/// 1行 JSON を stdout に出力する(ApiMonitorCommand.emitLine と同方針。withoutEscapingSlashes は
/// snapshot の image(base64。"/" を含みうる)向け)
private func emitLiveJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

// MARK: - JSON 出力

/// ftester api live snapshot の成功時出力
private struct ApiLiveSnapshotResult: Encodable {
    let ok = true
    let platform: String
    let screen: ApiLiveScreenSize
    let image: String
    let elements: [ApiLiveElement]
}

/// screen はポイント座標のサイズのみ(位置は常に (0,0) 起点のため x/y は出さない)
private struct ApiLiveScreenSize: Encodable {
    let width: Double
    let height: Double
}

/// snapshot の 1 要素分。省略可能フィールド(label/identifier/value)は JSON 上で "null" を
/// 明示する(ApiScenarioInfo と同方針。synthesized Encodable の encodeIfPresent は使わない)。
/// frame は FTElement(ElementInfo)に常に存在するフィールドなので省略しない
private struct ApiLiveElement: Encodable {
    let ref: Int
    let type: String
    let label: String?
    let identifier: String?
    let value: String?
    let frame: FTRect

    private enum CodingKeys: String, CodingKey {
        case ref, type, label, identifier, value, frame
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(type, forKey: .type)
        try container.encode(label, forKey: .label)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(value, forKey: .value)
        try container.encode(frame, forKey: .frame)
    }
}

/// snapshot 以外の全サブコマンド共通の成功時出力
private struct ApiLiveOkResult: Encodable {
    let ok = true
}

/// 全サブコマンド共通の失敗時出力(ドライバ操作の失敗のみ。引数不正はここを通らない)
private struct ApiLiveErrorResult: Encodable {
    let ok = false
    let error: String
}
