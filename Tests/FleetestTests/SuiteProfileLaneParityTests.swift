import XCTest

/// suite プロファイル(ios-inapp / ios-xcuitest / android)のレーンは**全プロジェクト共通**
/// (ユーザー決定 2026-09-01)。共通集合の根拠は実測(docs/verification.md の run #2):
/// 最大36本で稼働 ≈80%・test time の下限は最長シナリオ1本なのでこれ以上増やしても速くならない。
/// 片方のプロジェクトだけ台数を変えると LPT の分散比較と計測の前提(デバイス構成の一致)が
/// 静かに崩れるので、集合の等号で縛る。変えるときは**全プロジェクト+この期待値**を一緒に。
final class SuiteProfileLaneParityTests: XCTestCase {
    private static let iosLanes: Set<String> =
        Set((1...8).map { String(format: "local|iPhone 17 Pro(iOS 27.0)-%02d", $0) })
        .union((1...2).map { String(format: "M1Max|iPhone 17 Pro(iOS 27.0)-%02d", $0) })
        .union((1...4).map { String(format: "M1Ultra|iPhone 17 Pro(iOS 27.0)-%02d", $0) })
    private static let androidLanes: Set<String> =
        Set((1...6).map { String(format: "local|Pixel 9(Android 15)-%02d", $0) })
        .union((1...2).map { String(format: "M1Max|Pixel 9(Android 15)-%02d", $0) })
        .union((1...4).map { String(format: "M1Ultra|Pixel 9(Android 15)-%02d", $0) })

    /// project -> このプロジェクトが持つ suite プロファイル(存在しない組は書かない)
    private static let suiteProfiles: [String: [String: Set<String>]] = [
        "E2E-CMP": ["ios-inapp": iosLanes, "ios-xcuitest": iosLanes, "android": androidLanes],
        "E2E-iOS": ["ios-inapp": iosLanes, "ios-xcuitest": iosLanes],
        "E2E-Android": ["android": androidLanes],
        "E2E-Flutter": ["ios-inapp": iosLanes, "ios-xcuitest": iosLanes, "android": androidLanes],
        "E2E-RN": ["ios-inapp": iosLanes, "ios-xcuitest": iosLanes, "android": androidLanes],
    ]

    private struct RunProfileDevices: Decodable {
        struct Ref: Decodable {
            let machine: String?
            let name: String
        }
        let devices: [Ref]
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }

    func testSuiteProfilesShareTheCommonLaneSets() throws {
        let root = repoRoot()
        for (project, profiles) in Self.suiteProfiles.sorted(by: { $0.key < $1.key }) {
            for (profile, expected) in profiles.sorted(by: { $0.key < $1.key }) {
                let url = root.appendingPathComponent(
                    "TestProjects/\(project)/profiles/runs/\(profile).json")
                let doc = try JSONDecoder().decode(RunProfileDevices.self,
                                                   from: Data(contentsOf: url))
                let actual = Set(doc.devices.map { "\($0.machine ?? "local")|\($0.name)" })
                XCTAssertEqual(actual, expected,
                    "\(project)/\(profile) のレーンが共通集合とズレています(変えるなら全プロジェクト+この期待値を一緒に)")
            }
        }
    }
}
