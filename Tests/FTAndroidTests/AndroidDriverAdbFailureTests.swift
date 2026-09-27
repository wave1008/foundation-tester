// adb が失敗した回(台が居ない等)を成功に畳まない: hideKeyboard は dumpsys が読めないと
// 「キーボードは出ていない」と読み、terminate は force-stop の失敗を捨てて、どちらも成功を返していた
// (負荷テスト: 居ない emulator-5560 へのライブ操作 terminate / hideKeyboard が ok:true)

import XCTest
@testable import FTAndroid

final class AndroidDriverAdbFailureTests: XCTestCase {
    private var dir: URL!
    private var serial: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-adbfail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        serial = "fake-\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-android-\(serial!).json"))
    }

    private func fakeADB(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("adb")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testHideKeyboardThrowsWhenDumpsysCannotBeRead() async throws {
        let driver = AndroidDriver(serial: serial, adbPath: try fakeADB(
            "echo \"adb: device '$2' not found\" >&2; exit 1"))
        do {
            try await driver.hideKeyboard()
            XCTFail("adb の失敗を「キーボードは出ていない」と読んで成功を返した")
        } catch {
            XCTAssertTrue("\(error)".contains("not found"), "\(error)")
        }
    }

    func testHideKeyboardIsANoOpWhenTheKeyboardIsReadAsHidden() async throws {
        let driver = AndroidDriver(serial: serial, adbPath: try fakeADB("echo 'mInputMethodWindow=null'; exit 0"))
        try await driver.hideKeyboard()
    }

    func testTerminateThrowsWhenForceStopFails() async throws {
        let state = #"{"centers":{},"screen":{"x":0,"y":0,"width":0,"height":0},"package":"com.example.app"}"#
        try state.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-android-\(serial!).json"), atomically: true, encoding: .utf8)
        let driver = AndroidDriver(serial: serial, adbPath: try fakeADB(
            "echo \"adb: device '$2' not found\" >&2; exit 1"))
        do {
            try await driver.terminate()
            XCTFail("force-stop の失敗を捨てて成功を返した")
        } catch {
            XCTAssertTrue("\(error)".contains("com.example.app"), "\(error)")
        }
    }
}
