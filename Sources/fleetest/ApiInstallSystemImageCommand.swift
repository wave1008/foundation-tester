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

    /// 検証済み package("system-images;android-<N>;<tag>;<abi>")を3分割する。
    /// validatePackage を通っている前提(通っていなければ nil)
    static func components(of package: String) -> (apiLevel: String, tag: String, abi: String)? {
        let segments = package.components(separatedBy: ";")
        guard segments.count == 4, segments[1].hasPrefix("android-") else { return nil }
        return (String(segments[1].dropFirst("android-".count)), segments[2], segments[3])
    }

    // MARK: - 実処理

    private func execute() async throws {
        guard let parts = Self.components(of: package) else {
            throw InstallSystemImageError("invalid --package: \(package)")
        }
        guard let sdkRoot = AndroidSDKLocator.findSDKRoot() else {
            throw InstallSystemImageError("Android SDK not found (check ANDROID_HOME / ANDROID_SDK_ROOT)")
        }
        let targetDir = sdkRoot.appendingPathComponent(
            "system-images/android-\(parts.apiLevel)/\(parts.tag)/\(parts.abi)")
        if FileManager.default.fileExists(atPath: targetDir.path) {
            emitLog("Already installed: \(package)")
            return
        }

        guard let sdkmanagerURL = AndroidSDKLocator.findSDKManager() else {
            throw InstallSystemImageError(
                AndroidSDKLocator.sdkManagerMissingMessage + ". " + AndroidSDKLocator.avdManagerInstallHint)
        }

        emitLog("Downloading and installing \(package) (this can take several minutes)...")
        let java = AndroidSDKLocator.javaForSDKTools()
        // sdkmanager --licenses は SDK 全体を一括承諾するため使わない。--install が対話で出す
        // 「Accept? (y/N)」だけに答える(件数はライセンスの数だけ)。No timeout: ダウンロード時間は
        // ネットワーク依存で上限の根拠が無い
        let result = try Shell.run(
            AndroidSDKLocator.sdkToolCommand(sdkmanagerURL, ["--install", package], java: java),
            timeout: nil,
            stdin: Data(String(repeating: "y\n", count: Self.licenseAnswerRepeatCount).utf8))

        guard result.status == 0, FileManager.default.fileExists(atPath: targetDir.path) else {
            var message = "sdkmanager --install failed: \(result.tail)"
            if java == .missing { message += " (\(AndroidSDKLocator.javaMissingHint))" }
            throw InstallSystemImageError(message)
        }
        emitLog("Installed: \(package)")
    }

    /// --install 中に出る「ライセンスに同意しますか? [y/N]」への回答回数の上限。
    /// システムイメージ本体は通常1問だが、未導入の依存(platform-tools 等)を伴って増えることがある。
    /// 実測ではなく安全側の余裕値 —— 尽きても残りのプロンプトは未回答のまま stdin が閉じるだけで、
    /// sdkmanager 側が「承諾されなかった」として失敗する(待ち続けはしない)
    static let licenseAnswerRepeatCount = 20

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

/// install-system-image の実行時エラー。NDJSON の finished.error にそのまま載せるため
/// LocalizedError に準拠する(ApiCreateDeviceCommand の CreateDeviceError と同方針)
private struct InstallSystemImageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
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
