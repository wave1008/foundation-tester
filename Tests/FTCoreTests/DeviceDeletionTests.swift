import XCTest
@testable import FTCore

final class DeviceDeletionTests: XCTestCase {

    // MARK: - validateIOSUDID

    func testValidateIOSUDIDAcceptsWellFormedUDID() throws {
        XCTAssertNoThrow(try DeviceDeletion.validateIOSUDID("12345678-1234-1234-1234-123456789012"))
        XCTAssertNoThrow(try DeviceDeletion.validateIOSUDID("ABCDEF12-ab34-Cd56-ef78-90ABCDEF1234"))
    }

    func testValidateIOSUDIDRejectsMalformedInput() {
        for bad in ["", "not-a-udid", "12345678-1234-1234-1234-12345678901",
                    "12345678-1234-1234-1234-1234567890123",
                    "12345678-1234-1234-1234-12345678901g",
                    "$(rm -rf /)", "12345678123412341234123456789012"] {
            XCTAssertThrowsError(try DeviceDeletion.validateIOSUDID(bad)) { error in
                XCTAssertEqual(error as? DeviceDeletionError, .invalidUDID(bad))
            }
        }
    }

    // MARK: - validateAndroidAVDName

    func testValidateAndroidAVDNameAcceptsAllowedCharacters() throws {
        XCTAssertNoThrow(try DeviceDeletion.validateAndroidAVDName("Pixel_9.Android-16"))
    }

    func testValidateAndroidAVDNameRejectsDisallowedInput() {
        for bad in ["", "Pixel 9", "avd/../etc", "avd;rm -rf", "avd$(id)"] {
            XCTAssertThrowsError(try DeviceDeletion.validateAndroidAVDName(bad)) { error in
                XCTAssertEqual(error as? DeviceDeletionError, .invalidAVDName(bad))
            }
        }
    }

    // MARK: - コマンド組み立て

    func testIOSCommandIsExact() {
        XCTAssertEqual(
            DeviceDeletion.iosCommand(udid: "12345678-1234-1234-1234-123456789012"),
            ["xcrun", "simctl", "delete", "12345678-1234-1234-1234-123456789012"])
    }

    func testAndroidCommandIsExact() {
        XCTAssertEqual(
            DeviceDeletion.androidCommand(avd: "Pixel_9_Android_16"),
            ["avdmanager", "delete", "avd", "-n", "Pixel_9_Android_16"])
    }

    // MARK: - refusalReason

    func testRefusalReasonNilWhenStoppedAndExists() {
        XCTAssertNil(DeviceDeletion.refusalReason(isRunning: false, exists: true))
    }

    func testRefusalReasonMentionsRunningWhenRunning() throws {
        let reason = try XCTUnwrap(DeviceDeletion.refusalReason(isRunning: true, exists: true))
        XCTAssertTrue(reason.contains("running"))
    }

    func testRefusalReasonMentionsMissingWhenNotFound() throws {
        let reason = try XCTUnwrap(DeviceDeletion.refusalReason(isRunning: false, exists: false))
        XCTAssertTrue(reason.contains("no such"))
    }

    /// **末尾の一手は呼び手が決める**(判定は共有・文言は呼び手ごと)。共有文言をそのまま流用すると、
    /// 上書きしようとした人に「then delete it」と言うことになる(2026-08-17 に実際に出た)
    func testRefusalReasonUsesTheCallersRemedy() throws {
        let deleting = try XCTUnwrap(DeviceDeletion.refusalReason(isRunning: true, exists: true))
        XCTAssertTrue(deleting.hasSuffix("then delete it"), deleting)
        let recreating = try XCTUnwrap(DeviceDeletion.refusalReason(
            isRunning: true, exists: true, then: "create it again"))
        XCTAssertTrue(recreating.hasSuffix("then create it again"), recreating)
        // 理由の本体(停止のさせ方)は共有したまま
        XCTAssertTrue(recreating.contains("fleetest devices down"), recreating)
    }

    /// isRunning が exists より優先される(存在確認が信頼できない状況でも走っている疑いを最優先で扱う)
    func testRefusalReasonPrioritizesRunningOverMissing() throws {
        let reason = try XCTUnwrap(DeviceDeletion.refusalReason(isRunning: true, exists: false))
        XCTAssertTrue(reason.contains("running"))
    }

    // MARK: - referencedBy

    private func run(_ entries: RunDeviceEntry...) -> RunProfileDocument {
        RunProfileDocument(app: "a", devices: entries)
    }

    func testReferencedByFindsIOSMatchByUDID() {
        let udid = "12345678-1234-1234-1234-123456789012"
        let runs: [(name: String, profile: RunProfileDocument)] = [
            ("ios", run(RunDeviceEntry(platform: "ios", spec: DeviceSpec(name: "シミュ1", udid: udid)))),
            ("other", run(RunDeviceEntry(platform: "ios", spec: DeviceSpec(
                name: "シミュ2", udid: "00000000-0000-0000-0000-000000000000")))),
        ]
        XCTAssertEqual(DeviceDeletion.referencedBy(runProfiles: runs, identifier: udid), ["ios"])
    }

    func testReferencedByFindsAndroidMatchByAVDIncludingDisabled() {
        let runs: [(name: String, profile: RunProfileDocument)] = [
            ("a", run(RunDeviceEntry(platform: "android", spec: DeviceSpec(name: "エミュ1", avd: "Pixel_9")))),
            ("b", run(RunDeviceEntry(platform: "android", spec: DeviceSpec(name: "エミュ2", avd: "Pixel_9"),
                                     enabled: false))),
        ]
        XCTAssertEqual(
            DeviceDeletion.referencedBy(runProfiles: runs, identifier: "Pixel_9"), ["a", "b"])
    }

    /// 識別子は platform ごとに見る(iOS の udid 欄と Android の avd 欄を混ぜない)
    func testReferencedByDoesNotCrossPlatforms() {
        let runs: [(name: String, profile: RunProfileDocument)] = [
            ("a", run(RunDeviceEntry(platform: "android", spec: DeviceSpec(name: "e", udid: "X")))),
            ("b", run(RunDeviceEntry(platform: "ios", spec: DeviceSpec(name: "s", avd: "X")))),
        ]
        XCTAssertEqual(DeviceDeletion.referencedBy(runProfiles: runs, identifier: "X"), [])
    }

    func testReferencedByEmptyWhenNoMatch() {
        let runs: [(name: String, profile: RunProfileDocument)] = [
            ("a", run(RunDeviceEntry(platform: "ios", spec: DeviceSpec(
                name: "シミュ1", udid: "00000000-0000-0000-0000-000000000000")))),
        ]
        XCTAssertEqual(
            DeviceDeletion.referencedBy(runProfiles: runs, identifier: "no-such-id"), [])
    }

    func testReferencedByPreservesInputOrder() {
        let runs: [(name: String, profile: RunProfileDocument)] = [
            ("Zeta", run(RunDeviceEntry(platform: "android", spec: DeviceSpec(name: "e", avd: "X")))),
            ("Alpha", run(RunDeviceEntry(platform: "android", spec: DeviceSpec(name: "e", avd: "X")))),
        ]
        XCTAssertEqual(
            DeviceDeletion.referencedBy(runProfiles: runs, identifier: "X"), ["Zeta", "Alpha"])
    }
}
