// 実機の in-app 注入のための dylib 署名(ユーザー決定: ツールが自動で署名・開発署名のアプリだけ対応)。
//
// DYLD_INSERT_LIBRARIES で実機のアプリへ dylib を注入するには2つ要る:
//   ① アプリが **開発署名(get-task-allow == true)** = デバッグ可能。TestFlight / App Store 版は不可
//   ② dylib が **アプリと同じチームの証明書**で署名されている(実測: 同じ leaf 証明書で署名して通った)
// どちらも満たせないアプリは呼び手(供給)が XCUITest へ黙って縮退する(ユーザー決定)。
//
// 署名に使う証明書は **アプリバンドルから leaf 証明書を取り出し、その SHA-1 を `codesign -s` に渡す**
// (PoC と同じ)。秘密鍵がキーチェーンに無ければ署名できない = 注入不可として縮退する。

import Foundation
import FTCore

public enum InAppCodeSign {
    /// アプリへ dylib を注入できるか(= 開発署名 + 署名に使える証明書がキーチェーンにある)。
    /// `identitySHA1` は署名に使う leaf 証明書の SHA-1(注入可のときだけ非 nil)
    public struct Injectability: Sendable, Equatable {
        public let injectable: Bool
        public let devSigned: Bool
        public let identitySHA1: String?
        public let reason: String?
    }

    /// アプリバンドルの署名を調べ、注入できるかを返す。**デバイス不要**(ローカルの codesign/security だけ)
    public static func inspect(appBundle: String) -> Injectability {
        let ent = (try? Shell.run(["codesign", "-d", "--entitlements", ":-", appBundle]))?.outputIfSucceeded ?? ""
        let devSigned = parseGetTaskAllow(entitlementsPlist: ent)
        guard devSigned else {
            return Injectability(injectable: false, devSigned: false, identitySHA1: nil,
                                 reason: "the app is not development-signed (no get-task-allow)")
        }
        guard let sha1 = leafCertSHA1(appBundle: appBundle) else {
            return Injectability(injectable: false, devSigned: true, identitySHA1: nil,
                                 reason: "could not read the app's signing certificate")
        }
        let identities = codesigningIdentities()
        guard identities.contains(sha1) else {
            return Injectability(injectable: false, devSigned: true, identitySHA1: nil,
                                 reason: "the app's signing certificate (\(sha1.prefix(8))…) is not in this machine's keychain")
        }
        return Injectability(injectable: true, devSigned: true, identitySHA1: sha1, reason: nil)
    }

    /// device dylib を、アプリと同じ証明書で署名したコピーを作り、そのパスを返す。
    /// `identitySHA1` は `inspect` が返した値(呼び手が注入可を確かめてから署名する)
    public static func signedCopy(deviceDylib: URL, identitySHA1: String,
                                  outputDir: URL, basename: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let dest = outputDir.appendingPathComponent(basename)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: deviceDylib, to: dest)
        let result = try Shell.run(["codesign", "-f", "-s", identitySHA1, dest.path])
        guard result.status == 0 else {
            throw InAppCodeSignError.signingFailed(result.tail)
        }
        return dest
    }

    // MARK: - 純粋ヘルパー(テスト対象)

    /// `codesign -d --entitlements :-` の plist に get-task-allow==true があるか。
    /// XML の整形は環境で変わる(改行・空白)ので、鍵と値の間の空白・改行を無視して見る
    static func parseGetTaskAllow(entitlementsPlist: String) -> Bool {
        let squeezed = entitlementsPlist.replacingOccurrences(
            of: "[\\s]+", with: "", options: .regularExpression)
        return squeezed.contains("<key>get-task-allow</key><true/>")
    }

    /// `security find-identity -v -p codesigning` の出力から、使える証明書の SHA-1 の集合。
    /// 失効した証明書(CSSMERR_TP_CERT_REVOKED)は除く(署名に使うと落ちる)
    static func parseCodesigningIdentities(_ output: String) -> Set<String> {
        var out: Set<String> = []
        for line in output.split(separator: "\n") {
            if line.contains("REVOKED") { continue }
            // "  7) D962...F8F2A4D "Apple Development: …""
            if let match = line.range(of: "[0-9A-F]{40}", options: .regularExpression) {
                out.insert(String(line[match]))
            }
        }
        return out
    }

    // MARK: - Shell 経由

    private static func codesigningIdentities() -> Set<String> {
        let output = (try? Shell.run(["security", "find-identity", "-v", "-p", "codesigning"]))?.outputIfSucceeded ?? ""
        return parseCodesigningIdentities(output)
    }

    /// アプリバンドルの leaf 証明書の SHA-1(大文字16進40桁)。取り出せなければ nil
    private static func leafCertSHA1(appBundle: String) -> String? {
        let dir = TemporaryDirectory.url.appendingPathComponent("ft-appcert-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = dir.appendingPathComponent("cert").path
        guard let result = try? Shell.run(
            ["codesign", "-d", "--extract-certificates=\(prefix)", appBundle]),
              result.status == 0 else { return nil }
        let leaf = dir.appendingPathComponent("cert0")  // 0 が leaf(署名に使った証明書)
        guard let shasum = try? Shell.run(["shasum", "-a", "1", leaf.path]),
              let hex = shasum.output.split(separator: " ").first else { return nil }
        return hex.uppercased()
    }
}

public enum InAppCodeSignError: Error, LocalizedError {
    case signingFailed(String)
    public var errorDescription: String? {
        switch self {
        case .signingFailed(let tail):
            return "codesign of the in-app bridge dylib failed:\n\(tail)"
        }
    }
}
