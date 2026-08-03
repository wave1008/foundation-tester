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

        XCTAssertTrue(content.contains("- Device: Pixel 9(Android 15)-03 (emulator-5560)\n"),
                      content)
    }

    func testWriteOmitsDeviceLineWhenUnavailable() throws {
        let record = ScenarioRecordData(id: "Sample.testCase", title: "サンプル",
                                        app: "com.example.app", platform: "ios")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ScenarioReportWriter.write(record: record, to: dir)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(content.contains("- Device:"), content)
    }

    // MARK: - screenshot() の埋め込み(該当ステップの直後)

    func testWriteEmbedsStepScreenshotImmediatelyAfterItsStep() throws {
        var record = ScenarioRecordData(id: "Sample.testCase", title: "サンプル",
                                        app: "com.example.app", platform: "ios")
        var scene = SceneRecordData(number: 1, title: "s")
        let imageData = Data([0x01, 0x02, 0x03])
        scene.steps = [
            DSLStepRecord(index: 1, section: nil, description: "tap \"#a\"", status: .passed,
                         file: "", line: 0),
            DSLStepRecord(index: 2, section: nil, description: "screenshot \"before-tap.png\"",
                         status: .passed, file: "", line: 0,
                         screenshotData: imageData, screenshotLabel: "before-tap.png"),
            DSLStepRecord(index: 3, section: nil, description: "tap \"#b\"", status: .passed,
                         file: "", line: 0),
        ]
        record.scenes = [scene]

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ScenarioReportWriter.write(record: record, to: dir)
        let content = try String(contentsOf: url, encoding: .utf8)

        // 画像タグは screenshot ステップ(2行目)の直後・3行目より前に現れること
        guard let stepRange = content.range(of: "2. screenshot"),
              let imgRange = content.range(of: "<img", range: stepRange.upperBound..<content.endIndex),
              let nextStepRange = content.range(of: "3. tap", range: stepRange.upperBound..<content.endIndex)
        else {
            return XCTFail("期待した行が見つからない: \(content)")
        }
        XCTAssertLessThan(imgRange.lowerBound, nextStepRange.lowerBound,
                          "画像は screenshot ステップの直後・次のステップより前に埋め込まれること")

        // ディスクに書かれたファイルの中身が指定した Data と一致すること(生成名は実装詳細なので検索する)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let matching = try files.filter { try Data(contentsOf: $0) == imageData }
        XCTAssertEqual(matching.count, 1, "screenshot の画像データを持つファイルが1つ書かれること: \(files)")

        // screenshotData を持たないステップは画像参照を作らないこと(全体で img タグは1つだけ)
        let imgCount = content.components(separatedBy: "<img").count - 1
        XCTAssertEqual(imgCount, 1)
    }

    // MARK: - inconclusive ステップの表示

    func testWriteMarksInconclusiveStepsWithQuestionIconAndReason() throws {
        var record = ScenarioRecordData(id: "Sample.testCase", title: "サンプル",
                                        app: "com.example.app", platform: "ios")
        var scene = SceneRecordData(number: 1, title: "s")
        scene.steps = [
            DSLStepRecord(index: 1, section: nil, description: ##"verify "何か""##,
                         status: .inconclusive("verify block contains no assertions"),
                         file: "", line: 0),
        ]
        record.scenes = [scene]

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ScenarioReportWriter.write(record: record, to: dir)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("❓"), content)
        XCTAssertTrue(content.contains("inconclusive: verify block contains no assertions"), content)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenarioReportWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
