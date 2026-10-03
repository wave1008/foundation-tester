// VSCode拡張の「デバイスを追加」ダイアログ(システムイメージがまだ入っていないとき)から呼ばれる
// システムイメージ導入コマンド(fleetest api install-system-image)。
// device-catalog の android.downloadableSystemImages[].package をそのまま渡す前提。
// 進捗は stdout の NDJSON(log* → finished)、診断は stderr のみ(ApiCreateDeviceCommand と同方針)。
//
// **ライセンスはここでは絶対に自動承諾しない** —— 呼び手(拡張)が利用者に確認を取ってから
// --accept-licenses を付けて呼ぶ契約。`sdkmanager --licenses` はホストの SDK 全体のライセンスを
// 一括承諾してしまうため使わない。承諾の "y" は、この1 package を --install したときに
// 出る分のプロンプトにだけ答える。

import ArgumentParser
import Foundation
import FTAndroid
import FTCore

struct ApiInstallSystemImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-system-image",
        abstract: "Download and install an Android system image via sdkmanager"
            + " (NDJSON: log* -> finished on stdout; diagnostics on stderr only;"
            + " exit code 1 when ok:false)")

    @Option(help: ArgumentHelp(
        "The system-images package to install"
        + " (android.systemImages[].package / android.downloadableSystemImages[].package"
        + " from device-catalog)"))
    var package: String

    @Flag(name: .customLong("accept-licenses"), help: ArgumentHelp(
        "Accept the Android SDK license(s) this package requires. Required — without it the"
        + " command refuses and installs nothing. The caller must ask the person first;"
        + " this CLI never accepts licenses on its own"))
    var acceptLicenses = false

    func run() async throws {
        // finished 到達を読み手が確実に検知できるよう、log イベントもすぐ流す
        setvbuf(stdout, nil, _IOLBF, 0)

        switch Self.decide(package: package, acceptLicenses: acceptLicenses) {
        case .refuse(let reason):
            emitFinished(ok: false, error: reason)
            throw ExitCode(1)
        case .proceed:
            break
        }

        do {
            try await execute()
            emitFinished(ok: true, error: nil)
        } catch {
            emitFinished(ok: false, error: error.localizedDescription)
            throw ExitCode(1)
        }
    }

    // MARK: - 判定(純粋。デバイス/ファイルシステムに触れないのでテストで固定できる)

    enum InstallDecision: Equatable {
        case proceed
        case refuse(String)
    }

    static let packagePattern = "^system-images;android-[0-9]+;[A-Za-z0-9_]+;[A-Za-z0-9_-]+$"

    static func validatePackage(_ package: String) -> Bool {
        package.range(of: packagePattern, options: .regularExpression) != nil
    }

    /// package の形と --accept-licenses の有無だけで進める/拒むを決める
    static func decide(package: String, acceptLicenses: Bool) -> InstallDecision {
        guard validatePackage(package) else {
            return .refuse(
                "invalid --package (expected system-images;android-<apiLevel>;<tag>;<abi>): \(package)")
        }
        guard acceptLicenses else {
            return .refuse(
                "installing \(package) requires accepting the Android SDK license(s) it needs;"
                + " pass --accept-licenses to proceed (the caller must ask the person first)")
        }
        return .proceed
    }

    // MARK: - 実処理

    private func execute() async throws {
        try SystemImageInstaller.install(package: package, log: { emitLog($0) })
    }

    // MARK: - NDJSON 出力

    private func emitLog(_ message: String) {
        emitLine(ApiInstallSystemImageLogEvent(message: message))
    }

    private func emitFinished(ok: Bool, error: String?) {
        emitLine(ApiInstallSystemImageFinishedEvent(ok: ok, error: error))
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        ConsoleOut.out(line)
    }
}

private struct ApiInstallSystemImageLogEvent: Encodable {
    let kind = "log"
    let message: String
}

/// 末尾イベント。error は省略可能フィールドとして明示的に null を encode する
/// (ApiCreateDeviceFinishedEvent と同方針)
private struct ApiInstallSystemImageFinishedEvent: Encodable {
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
