import XCTest
@testable import FTDSL
import FTCore

final class ScenarioReportWriterTests: XCTestCase {

    // MARK: - deviceLine (フォーマット単体)

    func testDeviceLineBothPresent() {
        XCTAssertEqual(
            ScenarioReportWriter.deviceLine(name: "Pixel 9(Android 15)-03", identifier: "emulator-5560"),
            "Pixel 9(Android 15)-03 (emulator-5560)")
    }

    func testDeviceLineNameOnly() {
        XCTAssertEqual(ScenarioReportWriter.deviceLine(name: "iPhone 17 Pro", identifier: nil),
                       "iPhone 17 Pro")
    }

    func testDeviceLineIdentifierOnly() {
        XCTAssertEqual(ScenarioReportWriter.deviceLine(name: nil, identifier: "emulator-5560"),
                       "(emulator-5560)")
    }

    func testDeviceLineBothMissingIsNil() {
        XCTAssertNil(ScenarioReportWriter.deviceLine(name: nil, identifier: nil))
    }

    // MARK: - write() のヘッダへの反映

    func testWriteIncludesDeviceLineWhenAvailable() throws {
        let record = ScenarioRecordData(id: "Sample.testCase", title: "サンプル",
                                        app: "com.example.app", platform: "android",
                                        deviceName: "Pixel 9(Android 15)-03",
                                        deviceIdentifier: "emulator-5560")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ScenarioReportWriter.write(record: record, to: dir)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("- デバイス: Pixel 9(Android 15)-03 (emulator-5560)\n"),
                      content)
    }

    func testWriteOmitsDeviceLineWhenUnavailable() throws {
        let record = ScenarioRecordData(id: "Sample.testCase", title: "サンプル",
                                        app: "com.example.app", platform: "ios")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ScenarioReportWriter.write(record: record, to: dir)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(content.contains("- デバイス:"), content)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenarioReportWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
