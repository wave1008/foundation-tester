// `fleetest api install-system-image` の判定部分だけを固定する。--package の形と
// --accept-licenses の有無だけで進める/拒むを決める純粋関数なので、デバイス/ネットワーク無しで
// 「ライセンス未承諾では絶対に進まない」ことをテストで担保できる。

import XCTest
@testable import fleetest

final class ApiInstallSystemImageCommandTests: XCTestCase {

    private let validPackage = "system-images;android-36;google_apis;arm64-v8a"

    // MARK: - validatePackage

    func testValidatePackageAcceptsTheExpectedShape() {
        XCTAssertTrue(ApiInstallSystemImageCommand.validatePackage(validPackage))
        XCTAssertTrue(ApiInstallSystemImageCommand.validatePackage(
            "system-images;android-21;default;x86_64"))
    }

    func testValidatePackageRejectsOtherPackageKinds() {
        // platforms; 等、system-images 以外の SDK パッケージを紛れ込ませない
        XCTAssertFalse(ApiInstallSystemImageCommand.validatePackage("platforms;android-36"))
    }

    func testValidatePackageRejectsDottedAPILevel() {
        XCTAssertFalse(ApiInstallSystemImageCommand.validatePackage(
            "system-images;android-36.1;google_apis;arm64-v8a"))
    }

    func testValidatePackageRejectsMissingSegment() {
        XCTAssertFalse(ApiInstallSystemImageCommand.validatePackage("system-images;android-36;google_apis"))
    }

    // MARK: - decide

    func testDecideRefusesWithoutAcceptLicensesEvenForAValidPackage() {
        guard case .refuse(let reason) = ApiInstallSystemImageCommand.decide(
            package: validPackage, acceptLicenses: false) else {
            return XCTFail("expected .refuse")
        }
        XCTAssertTrue(reason.contains("--accept-licenses"))
    }

    func testDecideRefusesAnInvalidPackageEvenWithAcceptLicenses() {
        guard case .refuse(let reason) = ApiInstallSystemImageCommand.decide(
            package: "not-a-system-image", acceptLicenses: true) else {
            return XCTFail("expected .refuse")
        }
        XCTAssertTrue(reason.contains("invalid --package"))
    }

    func testDecideProceedsOnlyWhenBothAreSatisfied() {
        XCTAssertEqual(
            ApiInstallSystemImageCommand.decide(package: validPackage, acceptLicenses: true), .proceed)
    }

    // MARK: - components(of:)

    func testComponentsOfSplitsApiLevelTagAbi() {
        let parts = ApiInstallSystemImageCommand.components(of: validPackage)
        XCTAssertEqual(parts?.apiLevel, "36")
        XCTAssertEqual(parts?.tag, "google_apis")
        XCTAssertEqual(parts?.abi, "arm64-v8a")
    }

    func testComponentsOfIsNilForAMalformedPackage() {
        XCTAssertNil(ApiInstallSystemImageCommand.components(of: "system-images;android-36"))
    }
}
