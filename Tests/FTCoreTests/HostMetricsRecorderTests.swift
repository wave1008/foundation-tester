import XCTest
@testable import FTCore

/// HostMetricsRecorder(run 単位のホスト負荷採取器)と RunRecorder への配線の検証。
/// NDJSON `kind:"hostMetrics"` の契約(monitorProcessManager.ts / host-metrics-summary と同期)も守る。
final class HostMetricsRecorderTests: XCTestCase {
    var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HostMetricsRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func lines(_ url: URL) -> [String] {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
    }

    /// 採取器が短間隔で回すと、有効な hostMetrics 行がファイルに書かれ、cpu が値を持つ行が出る
    func testRecorderWritesValidSamples() throws {
        let out = tmpRoot.appendingPathComponent("host-metrics.ndjson")
        let recorder = HostMetricsRecorder(outputURL: out, interval: 0.1, logFailure: { _ in })
        Thread.sleep(forTimeInterval: 0.8)
        recorder.stop()

        let written = lines(out)
        XCTAssertGreaterThan(written.count, 0, "採取行が1行も無い")

        var sawNonNullCPU = false
        for line in written {
            let obj = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "行が JSON object としてパースできない: \(line)")
            XCTAssertEqual(obj["kind"] as? String, "hostMetrics")
            XCTAssertNotNil(obj["ts"] as? Double, "ts が数値でない")
            if obj["cpu"] as? Double != nil { sawNonNullCPU = true }
        }
        XCTAssertTrue(sawNonNullCPU, "cpu が値を持つ行が1つも無い(初回捨てサンプル後に値が出るはず)")
    }

    /// stop() は冪等(2 回目以降はセマフォを二重待ちせず即返る)
    func testStopIsIdempotent() {
        let out = tmpRoot.appendingPathComponent("idem.ndjson")
        let recorder = HostMetricsRecorder(outputURL: out, interval: 0.1, logFailure: { _ in })
        recorder.stop()
        recorder.stop()
    }

    /// RunRecorder.begin(captureHostMetrics: true) は runDir/host-metrics.ndjson を作る
    func testRunRecorderCreatesSessionFile() {
        let project = TestProject(name: "SampleApp",
                                  rootURL: tmpRoot.appendingPathComponent("Projects/SampleApp"))
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test")
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let sessionFile = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
            .appendingPathComponent("host-metrics.ndjson")
        // HostMetricsLog は open 時にファイルを生成するので begin 直後から存在する
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path),
                      "セッションファイルが作られていない: \(sessionFile.path)")
        recorder.finish(total: 0, passed: 0, failed: 0)
    }

    /// captureHostMetrics: false では採取器を起動せず、ファイルも作らない
    func testRunRecorderSkipsCaptureWhenDisabled() {
        let project = TestProject(name: "SampleApp",
                                  rootURL: tmpRoot.appendingPathComponent("Projects/SampleApp"))
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let sessionFile = RunResultsStore.runDir(resultsDir: resultsDir, runID: recorder.runID)
            .appendingPathComponent("host-metrics.ndjson")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path),
                       "capture 無効なのにセッションファイルが作られた")
        recorder.finish(total: 0, passed: 0, failed: 0)
    }
}
