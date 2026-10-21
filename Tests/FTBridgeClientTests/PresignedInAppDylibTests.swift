import XCTest
import FTCore
@testable import FTBridgeClient

/// 発行側が署名して運ぶ実機用 in-app dylib を、ランナー機が使ってよいかの判定(PresignedInAppDylib)。
final class PresignedInAppDylibTests: XCTestCase {
    private let cert = "D962DE0AD687D03D44791F03EE4F94B43F8F2A4D"
    private let digest = "aaaa"

    private func manifest(_ identity: String, _ digest: String) -> PresignedInAppDylib.Manifest {
        .init(identitySHA1: identity, sourceDigest: digest)
    }

    func testUsableOnlyWhenCertificateAndSourcesMatch() {
        XCTAssertEqual(PresignedInAppDylib.decide(manifest: manifest(cert, digest), dylibExists: true,
                                                  appCertSHA1: cert, sourceDigest: digest), .usable)
    }

    func testAbsentWithoutManifestOrDylib() {
        XCTAssertEqual(PresignedInAppDylib.decide(manifest: nil, dylibExists: true,
                                                  appCertSHA1: cert, sourceDigest: digest), .absent)
        XCTAssertEqual(PresignedInAppDylib.decide(manifest: manifest(cert, digest), dylibExists: false,
                                                  appCertSHA1: cert, sourceDigest: digest), .absent)
    }

    /// アプリを別の証明書で作り直したのに古い控えが残っている形(注入しても起動で落ちる)
    func testRejectsAnotherCertificate() {
        XCTAssertEqual(PresignedInAppDylib.decide(manifest: manifest(cert, digest), dylibExists: true,
                                                  appCertSHA1: "5592AC38DFF10066D0EAC533BEF13998C0CE496F",
                                                  sourceDigest: digest), .identityMismatch)
    }

    /// 別のコミットのブリッジを注入しない(版の照合を素通りさせない)。digest が読めない側でも使わない
    func testRejectsOtherBridgeSourcesOrUnknownDigest() {
        XCTAssertEqual(PresignedInAppDylib.decide(manifest: manifest(cert, digest), dylibExists: true,
                                                  appCertSHA1: cert, sourceDigest: "bbbb"), .sourceMismatch)
        XCTAssertEqual(PresignedInAppDylib.decide(manifest: manifest(cert, digest), dylibExists: true,
                                                  appCertSHA1: cert, sourceDigest: nil), .sourceMismatch)
    }

    /// 置き場はアプリの外(アプリの署名を壊さない)で、書いた控えを lookup が読めること
    func testLookupReadsManifestNextToTheApp() throws {
        let root = TemporaryDirectory.url.appendingPathComponent("ft-presigned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("FTE2EIOS.app").path
        let dir = PresignedInAppDylib.directory(appBundle: app)
        XCTAssertFalse(dir.path.hasPrefix(app + "/"), "置き場がアプリバンドルの中にある(アプリの署名が壊れる)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent(PresignedInAppDylib.dylibName))
        try JSONEncoder().encode(manifest(cert, digest))
            .write(to: dir.appendingPathComponent(PresignedInAppDylib.manifestName))
        let found = PresignedInAppDylib.lookup(appBundle: app, appCertSHA1: cert, sourceDigest: digest)
        XCTAssertEqual(found.verdict, .usable)
        XCTAssertEqual(found.dylib.lastPathComponent, PresignedInAppDylib.dylibName)
        XCTAssertEqual(PresignedInAppDylib.lookup(appBundle: app, appCertSHA1: cert, sourceDigest: "bbbb").verdict,
                       .sourceMismatch)
    }
}
