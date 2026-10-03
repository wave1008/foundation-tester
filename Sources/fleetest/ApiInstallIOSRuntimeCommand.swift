// iOS Simulator ランタイム導入コマンド(fleetest api install-ios-runtime)。
// VSCode拡張の「デバイスを追加」が、iOS のダウンロード候補の作成前に1回だけ呼ぶ(バッチでも1回。
// 失敗したら1台も作らずに打ち切るため create-device の自動導入とは別に持つ)。
// 進捗は stdout の NDJSON(log* → finished)、診断は stderr のみ(ApiInstallSystemImageCommand と同方針)。
// create-device 内の自動導入は残す(profile setup・拡張以外からの直接呼びのため)。

import ArgumentParser
import Foundation
import FTCore

struct ApiInstallIOSRuntimeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-ios-runtime",
        abstract: "Download and install the iOS Simulator runtime of the selected Xcode"
            + " (NDJSON: log* -> finished on stdout; diagnostics on stderr only;"
            + " exit code 1 when ok:false)")

    @Option(help: ArgumentHelp(
        "The iOS version to install (ios.downloadableRuntimes[].version from device-catalog)."
        + " Must equal the selected Xcode's SDK version: xcodebuild -downloadPlatform iOS installs"
        + " only that version, so any other version is refused and nothing is installed"))
    var version: String

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)

        let installed: [DevicePicker.IOSRuntimeInfo]
        do {
            installed = try IOSRuntimeInstaller.installedRuntimes()
        } catch {
            emitFinished(ok: false, error: error.localizedDescription)
            throw ExitCode(1)
        }
        switch Self.decide(version: version, sdkVersion: IOSRuntimeInstaller.sdkVersion(),
                           installedIdentifiers: installed.map(\.identifier)) {
        case .refuse(let reason):
            emitFinished(ok: false, error: reason)
            throw ExitCode(1)
        case .alreadyInstalled:
            emitLog("The iOS \(version) simulator runtime is already installed")
            emitFinished(ok: true, error: nil)
        case .install(let expectedIdentifier):
            do {
                try IOSRuntimeInstaller.install(
                    version: version, expectedIdentifier: expectedIdentifier, log: { emitLog($0) })
                emitFinished(ok: true, error: nil)
            } catch {
                emitFinished(ok: false, error: error.localizedDescription)
                throw ExitCode(1)
            }
        }
    }

    // MARK: - 判定(純粋。デバイス/ファイルシステムに触れないのでテストで固定できる)

    enum Decision: Equatable {
        case install(expectedIdentifier: String)
        case alreadyInstalled
        case refuse(String)
    }

    /// 版が読めない → 拒む / 導入済み → 何もしない(SDK の版との一致より先。冪等) /
    /// SDK の版と主・副が一致しない(SDK 不明を含む)→ 拒む / それ以外 → 入れる
    static func decide(version: String, sdkVersion: String?, installedIdentifiers: [String]) -> Decision {
        guard let expected = DevicePicker.predictedIOSRuntimeIdentifier(version: version) else {
            return .refuse("invalid --version (expected an iOS version such as 27.0): \(version)")
        }
        if installedIdentifiers.contains(expected) { return .alreadyInstalled }
        guard let sdkVersion, DevicePicker.predictedIOSRuntimeIdentifier(version: sdkVersion) == expected else {
            return .refuse(
                "iOS \(version) cannot be installed: xcodebuild -downloadPlatform iOS installs only the selected"
                + " Xcode's SDK version (\(sdkVersion ?? "unreadable")). Nothing was installed")
        }
        return .install(expectedIdentifier: expected)
    }

    // MARK: - NDJSON 出力

    private func emitLog(_ message: String) {
        emitLine(ApiInstallIOSRuntimeLogEvent(message: message))
    }

    private func emitFinished(ok: Bool, error: String?) {
        emitLine(ApiInstallIOSRuntimeFinishedEvent(ok: ok, error: error))
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        ConsoleOut.out(line)
    }
}

private struct ApiInstallIOSRuntimeLogEvent: Encodable {
    let kind = "log"
    let message: String
}

/// error は省略可能フィールドとして明示的に null を encode する(ApiInstallSystemImageFinishedEvent と同方針)
private struct ApiInstallIOSRuntimeFinishedEvent: Encodable {
    let kind = "finished"
    let ok: Bool
    let error: String?

    private enum CodingKeys: String, CodingKey { case kind, ok, error }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
    }
}
