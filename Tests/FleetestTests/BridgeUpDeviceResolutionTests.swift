// `fleetest bridge up --device <名前>` はシミュレータ名を xcodebuild の
// `-destination platform=iOS Simulator,name=<名前>` へそのまま渡していたため、名前に丸括弧等が
// 入ると一致に失敗していた(実測 2026-09-17: simctl 上に1台しか無い名前でも build-for-testing が
// 「Unable to find a device matching the provided destination specifier」で落ちた。UDID なら通る)。
// `Bridge.Up.resolveDeviceUDID` は --device を常に UDID へ解決してから使う。

import XCTest
import ArgumentParser
import FTBridgeClient
@testable import fleetest

final class BridgeUpDeviceResolutionTests: XCTestCase {

    private func sim(_ udid: String, _ name: String, os: String = "iOS 27.0",
                     booted: Bool = false) -> SimDeviceInfo {
        SimDeviceInfo(udid: udid, name: name, os: os, booted: booted)
    }

    /// UDID 形の --device はカタログを引かずにそのまま使う
    func testAUDIDShapedDeviceIsUsedAsIsWithoutConsultingTheCatalog() throws {
        let udid = "0113A6C1-AAAA-BBBB-CCCC-000000000000"
        XCTAssertEqual(udid.count, 36)
        let resolved = try Bridge.Up.resolveDeviceUDID(device: udid, physical: false) {
            XCTFail("UDID 形なのにカタログを引いた")
            return []
        }
        XCTAssertEqual(resolved, udid)
    }

    /// --physical は名前の形に関わらずそのまま(実機 UDID はシミュレータ UUID と形が違う)
    func testAPhysicalDeviceIsUsedAsIsRegardlessOfShape() throws {
        let resolved = try Bridge.Up.resolveDeviceUDID(device: "00008130-000A1B2C3D4E5678", physical: true) {
            XCTFail("physical なのにカタログを引いた")
            return []
        }
        XCTAssertEqual(resolved, "00008130-000A1B2C3D4E5678")
    }

    /// 名前が1台だけに一致すればその UDID(丸括弧の入った名前でも文字列一致だけで解決する)
    func testANameThatMatchesExactlyOneDeviceResolves() throws {
        let devices = [sim("UDID-A", "iPhone 17(iOS 27.0)"), sim("UDID-B", "iPhone 17 Pro")]
        let resolved = try Bridge.Up.resolveDeviceUDID(device: "iPhone 17(iOS 27.0)", physical: false) { devices }
        XCTAssertEqual(resolved, "UDID-A")
    }

    /// 一致0台は名前を名指しして断る(推測しない)
    func testANameWithNoMatchIsRefused() {
        XCTAssertThrowsError(
            try Bridge.Up.resolveDeviceUDID(device: "iPhone 999", physical: false) { [] }
        ) { error in
            guard let validation = error as? ValidationError else {
                return XCTFail("expected ValidationError, got \(error)")
            }
            XCTAssertTrue(validation.message.contains("iPhone 999"), validation.message)
        }
    }

    /// 同名複数(規則で1台に決まらない)は候補の UDID を挙げて断る(黙って1台目を選ばない)
    func testAmbiguousNamesAreRefusedWithCandidatesNamed() {
        let devices = [sim("UDID-A", "iPhone 17"), sim("UDID-B", "iPhone 17")]
        XCTAssertThrowsError(
            try Bridge.Up.resolveDeviceUDID(device: "iPhone 17", physical: false) { devices }
        ) { error in
            guard let validation = error as? ValidationError else {
                return XCTFail("expected ValidationError, got \(error)")
            }
            XCTAssertTrue(validation.message.contains("UDID-A") && validation.message.contains("UDID-B"),
                          validation.message)
        }
    }

    /// カタログの読み取り自体が失敗した(simctl 不調等)場合も推測せず断る
    func testACatalogReadFailureIsSurfacedAsAValidationError() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try Bridge.Up.resolveDeviceUDID(device: "iPhone 17", physical: false) { throw Boom() }
        )
    }
}
