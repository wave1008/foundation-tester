import FTCore
import XCTest
@testable import FTAndroid

/// AVD の config.ini から機種/OS を取り出す(編集フォームの表示専用情報)。
/// ANDROID_AVD_HOME を一時ディレクトリへ向けて実 AVD に依存させない
final class AvdModelAndOSTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-avd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("ANDROID_AVD_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("ANDROID_AVD_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    private func writeAVD(id: String, config: String) throws {
        let dir = home.appendingPathComponent("\(id).avd")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(to: dir.appendingPathComponent("config.ini"),
                         atomically: true, encoding: .utf8)
    }

    func testExtractsModelAndDerivesOSFromSysdir() throws {
        try writeAVD(id: "Pixel_9", config: """
        abi.type=arm64-v8a
        hw.device.name=pixel_9
        image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/
        """)
        let info = AndroidDeviceCatalog.avdModelAndOS(id: "Pixel_9")
        XCTAssertEqual(info.model, "pixel_9")
        // API 35 → Android 15(33 以降は apiLevel-20。MachineProfileEditor 参照)
        XCTAssertEqual(info.os, "Android 15")
    }

    func testMissingKeysYieldNil() throws {
        try writeAVD(id: "Bare", config: "abi.type=arm64-v8a\n")
        let info = AndroidDeviceCatalog.avdModelAndOS(id: "Bare")
        XCTAssertNil(info.model, "hw.device.name が無ければ nil(行を出さない側に倒す)")
        XCTAssertNil(info.os)
    }

    func testUnknownAvdYieldsNil() {
        let info = AndroidDeviceCatalog.avdModelAndOS(id: "NoSuchAVD")
        XCTAssertNil(info.model)
        XCTAssertNil(info.os)
    }
}
