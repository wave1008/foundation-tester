// リポジトリ内の実行プロファイルの devices が「platform と machine を省略しない」形を保っているかの走査
// (ユーザー指示)。machine の省略は手元の意味になるが、書き出し経路のどれかが machine を落としても
// 失敗の形が沈黙(別の機械の台が手元扱いになる)なので、ここで機械的に落とす。
//
// 形(字下げ・キー順)は見ない: 手で編集したプロファイルを整形の違いで赤くしないため
// (書き出し側の順序は OrderedProfileJSONTests が固定している)。

import XCTest
@testable import FTCore

final class RunProfileDeviceMachineExplicitTests: XCTestCase {

    func testEveryDeviceInEveryRunProfileDeclaresItsMachine() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let projectsDir = repo.appendingPathComponent("TestProjects")
        let projects = try FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil)

        var missing: [String] = []
        var checked = 0
        for project in projects {
            let dir = project.appendingPathComponent("profiles/runs")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "json" {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                    file.path)
                for device in (object["devices"] as? [[String: Any]]) ?? [] {
                    checked += 1
                    let machine = (device["machine"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if machine == nil || machine?.isEmpty == true || device["platform"] == nil {
                        missing.append("\(project.lastPathComponent)/\(file.lastPathComponent)"
                            + " \(device["name"] ?? "?")")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10, "検査対象が少なすぎる(パスの解決を疑う)")
        XCTAssertEqual(missing, [],
                       "platform / machine を書いていないデバイスがある(手元なら \"local\" と明示する)")
    }
}
