// AppDriver.acknowledgeOpenURLConsentIfPresent の既定実装は no-op(ほとんどのドライバは正しく
// それでよい)。実装を持つべきなのは springboard を見られる接続の2箇所だけ:
//   - BridgeClient(XCUITest 接続)自身
//   - AppAttachDriver(WebViewDelegatingDriver.openURL が hybrid でここへ明示的に回す)
// AppAttachDriver は client: BridgeClient を private に包んで他の操作を1つずつ転送しており、
// この転送を消すと**コンパイルは通ったまま**既定の no-op(何もしない)に静かに落ちる
// (AppDriverDefaultDispatchTests が守るのは「宣言漏れ」で、この「個々の転送漏れ」は別物。
// OpenURLForwardingTests / SystemUIDriverHomeForwardingTests と同じ理由でソース走査にする)。

import XCTest

final class OpenURLConsentForwardingTests: XCTestCase {

    func testAppAttachDriverForwardsConsentToItsClient() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let path = root.appendingPathComponent("Sources/FTBridgeClient/AppAttachDriver.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        XCTAssertTrue(source.contains("func acknowledgeOpenURLConsentIfPresent(bundleID: String) async"),
                      "AppAttachDriver が acknowledgeOpenURLConsentIfPresent を宣言していません"
                          + "(既定の no-op に落ちると hybrid の openURL 同意が springboard を見られる"
                          + "側でも常に空振りする)")
        XCTAssertTrue(source.contains("client.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)"),
                      "AppAttachDriver.acknowledgeOpenURLConsentIfPresent が client へ転送していません")
    }

    /// WebViewDelegatingDriver.openURL が delegated(XCUITest attach)側でも同意ステップを
    /// 明示的に試すこと。primary(in-app)だけに任せると springboard を見られず必ず空振りする
    func testWebViewDelegatingDriverAlsoTriesConsentOnTheDelegatedSide() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("Sources/FTBridgeClient/WebViewDelegatingDriver.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        XCTAssertTrue(source.contains("delegated.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)"),
                      "WebViewDelegatingDriver.openURL が delegated 側で同意ステップを試していません")
    }

    /// **openURL を転送するラッパーは、同意ステップも転送しなければならない**。
    /// 既定実装が no-op(501 ではない)なので、転送を書き忘れても**コンパイルは通り、テストも緑のまま
    /// 黙って何もしない**(`DefaultImplementationForwardingTests` は 501 を投げる操作しか見ないため
    /// この穴を検出できない)。openURL を持つラッパーを列挙して両方の宣言を要求する
    func testEveryWrapperThatForwardsOpenURLAlsoForwardsConsent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/FTBridgeClient")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var missing: [String] = []
        for file in files {
            let name = String(file.lastPathComponent.dropLast(".swift".count))
            // BridgeClient は転送元ではなく実装本体
            guard name != "BridgeClient" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("func openURL(_ url: String, bundleID: String?) async throws") else { continue }
            if !source.contains("func acknowledgeOpenURLConsentIfPresent(bundleID: String) async") {
                missing.append(name)
            }
        }
        XCTAssertEqual(missing, [],
                       "openURL を転送しているのに同意ステップを転送していないラッパーがあります。"
                           + "既定は no-op なので、書き忘れても黙って空振りします")
    }
}
