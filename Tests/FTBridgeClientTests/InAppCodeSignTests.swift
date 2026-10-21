import XCTest
@testable import FTBridgeClient

/// 実機 in-app 注入の署名可否の純粋ロジック(InAppCodeSign)。デバイス不要の部分だけ固定する。
final class InAppCodeSignTests: XCTestCase {

    func testParseGetTaskAllowTrue() {
        let plist = """
        <?xml version="1.0"?><plist><dict>
        <key>application-identifier</key><string>9UH4ZDZ6W3.com.ftester.e2e.ios</string>
        <key>get-task-allow</key><true/>
        </dict></plist>
        """
        XCTAssertTrue(InAppCodeSign.parseGetTaskAllow(entitlementsPlist: plist))
    }

    func testParseGetTaskAllowFalseOrMissing() {
        XCTAssertFalse(InAppCodeSign.parseGetTaskAllow(
            entitlementsPlist: "<dict><key>get-task-allow</key><false/></dict>"))
        XCTAssertFalse(InAppCodeSign.parseGetTaskAllow(
            entitlementsPlist: "<dict><key>application-identifier</key><string>x</string></dict>"))
        XCTAssertFalse(InAppCodeSign.parseGetTaskAllow(entitlementsPlist: ""))
    }

    /// 空白・改行の整形に依存しない(環境で XML の整形が変わる)
    func testParseGetTaskAllowIgnoresWhitespace() {
        XCTAssertTrue(InAppCodeSign.parseGetTaskAllow(
            entitlementsPlist: "<key>get-task-allow</key>\n    <true/>"))
    }

    func testParseCodesigningIdentities() {
        let output = """
          1) 5592AC38DFF10066D0EAC533BEF13998C0CE496F "Apple Development: A (T1)"
          2) 52B4790004D175E55BC81EA9347531941428F594 "Apple Development: B (T2)" (CSSMERR_TP_CERT_REVOKED)
          3) D962DE0AD687D03D44791F03EE4F94B43F8F2A4D "Apple Development: C (T3)"
             3 valid identities found
        """
        let ids = InAppCodeSign.parseCodesigningIdentities(output)
        XCTAssertTrue(ids.contains("5592AC38DFF10066D0EAC533BEF13998C0CE496F"))
        XCTAssertTrue(ids.contains("D962DE0AD687D03D44791F03EE4F94B43F8F2A4D"))
        XCTAssertFalse(ids.contains("52B4790004D175E55BC81EA9347531941428F594"), "失効した証明書は除く(署名に使うと落ちる)")
    }
}
