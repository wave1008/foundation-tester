// 発行側(ディスパッチする Mac)で署名してランナー機へ運ぶ実機用 in-app dylib。
//
// ディスパッチはアプリを発行側でワークスペースへステージングして運ぶので、アプリの署名の鍵は発行側にしか無いことがある
// (ランナー機のキーチェーンに無い → 自分では dylib に署名できず XCUITest へ縮退していた)。発行側が署名して
// アプリの隣(`<App>.app.fleetest-inapp/`)に置き、ランナー機は**自分で署名できないときだけ**これを使う。
// 置き場をアプリの外にするのはアプリの署名を壊さないため。ワークスペースの転送でそのまま届く。
//
// 使ってよいのは ①控えの証明書がアプリの leaf 証明書と同じ ②in-app ブリッジのソースの digest が使う側と同じ
// (別のコミットのブリッジを注入しない = ブリッジの版の照合を素通りさせない)ときだけ。

import Foundation
import FTCore

public enum PresignedInAppDylib {
    struct Manifest: Codable, Equatable {
        let identitySHA1: String
        let sourceDigest: String
    }

    static let manifestName = "manifest.json"
    static let dylibName = "libFTInAppBridge-device.dylib"

    public static func directory(appBundle: String) -> URL {
        URL(fileURLWithPath: appBundle + ".fleetest-inapp")
    }

    public enum Verdict: Equatable {
        case usable
        case absent
        case identityMismatch
        case sourceMismatch

        /// 使えなかったときに縮退の理由へ足す句(absent は何も言わない)
        var reason: String? {
            switch self {
            case .usable, .absent: return nil
            case .identityMismatch:
                return "the in-app bridge signed on the dispatching Mac was signed for a different certificate"
            case .sourceMismatch:
                return "the in-app bridge signed on the dispatching Mac was built from different bridge sources"
                    + " (align the runner to the same commit)"
            }
        }
    }

    /// 判定(純粋)。digest が読めない側では使わない(版を照合できない注入をしない)
    static func decide(manifest: Manifest?, dylibExists: Bool, appCertSHA1: String,
                       sourceDigest: String?) -> Verdict {
        guard let manifest, dylibExists else { return .absent }
        guard manifest.identitySHA1 == appCertSHA1 else { return .identityMismatch }
        guard let sourceDigest, manifest.sourceDigest == sourceDigest else { return .sourceMismatch }
        return .usable
    }

    static func lookup(appBundle: String, appCertSHA1: String, sourceDigest: String?)
        -> (dylib: URL, verdict: Verdict) {
        let dir = directory(appBundle: appBundle)
        let dylib = dir.appendingPathComponent(dylibName)
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent(manifestName)))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        let verdict = decide(manifest: manifest,
                             dylibExists: FileManager.default.fileExists(atPath: dylib.path),
                             appCertSHA1: appCertSHA1, sourceDigest: sourceDigest)
        return (dylib, verdict)
    }

    /// 発行側: このアプリが手元の鍵で署名できるなら、device 用 dylib を署名してアプリの隣に置く。
    /// 戻り値 = 置いたときのログ1行(既に同じ控えがある・手元で署名できないときは nil = 何もしない)
    public static func prepare(appBundle: String, repoRoot: URL) throws -> String? {
        let info = InAppCodeSign.inspect(appBundle: appBundle, sourceDigest: nil)
        guard let identity = info.identitySHA1 else { return nil }
        let digest = try BridgeSourceSet.inApp.digest(repoRoot: repoRoot)
        if lookup(appBundle: appBundle, appCertSHA1: identity, sourceDigest: digest).verdict == .usable {
            return nil
        }
        try InAppLauncher(repoRoot: repoRoot, udid: "", port: 0, physical: true).buildIfNeeded()
        let dir = directory(appBundle: appBundle)
        _ = try InAppCodeSign.signedCopy(deviceDylib: InAppLauncher.dylibPath(repoRoot: repoRoot, physical: true),
                                         identitySHA1: identity, outputDir: dir, basename: dylibName)
        let manifest = try JSONEncoder().encode(Manifest(identitySHA1: identity, sourceDigest: digest))
        try manifest.write(to: dir.appendingPathComponent(manifestName), options: .atomic)
        return "signed the in-app bridge for \((appBundle as NSString).lastPathComponent) with this Mac's"
            + " certificate (\(identity.prefix(8))…) — a runner without that key injects this copy"
    }
}
