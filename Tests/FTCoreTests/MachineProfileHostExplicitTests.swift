// リポジトリ内のマシンプロファイルが「host を省略しない」形を保っているかの走査
// (ユーザー指示)。**省略は「直下の既定を継ぐ」の意味**で、既定がリモートの
// プロファイルでは手元のデバイスが黙って別の機械のもの扱いになる —— 失敗の形が沈黙なので、
// 書き出し経路のどれかが host を落としても実行するまで気付けない。ここで機械的に落とす。
//
// 形(字下げ・キー順)は見ない: 手で編集したプロファイルを整形の違いで赤くしないため
// (書き出し側の順序は OrderedProfileJSONTests が固定している)。

import XCTest
@testable import FTCore

final class MachineProfileHostExplicitTests: XCTestCase {

    func testEveryDeviceInEveryMachineProfileDeclaresItsHost() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let projectsDir = repo.appendingPathComponent("TestProjects")
        let projects = try FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil)

        var missing: [String] = []
        var checked = 0
        for project in projects {
            let dir = project.appendingPathComponent("profiles/machines")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "json" {
                let data = try Data(contentsOf: file)
                guard let profile = try? JSONDecoder().decode(MachineProfile.self, from: data)
                else { continue }
                for (platform, list) in [("ios", profile.ios), ("android", profile.android)] {
                    for device in list?.devices ?? [] {
                        checked += 1
                        let host = device.machine?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if host == nil || host?.isEmpty == true {
                            missing.append(
                                "\(project.lastPathComponent)/\(file.lastPathComponent)"
                                + " \(platform):\(device.name)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10, "検査対象が少なすぎる(パスの解決を疑う)")
        XCTAssertEqual(missing, [],
                       "host を書いていないデバイスがある(手元なら \"local\" と明示する)")
    }
}
