// avdmanager に渡す Java の解決(AndroidSDKLocator.javaForSDKTools / avdManagerCommand)。
// ランナー機(ssh の非対話シェル・システムに JDK 無し・Android Studio だけ入っている)で
// 「Unable to locate a Java Runtime」になった形を、同梱の Java へ倒して吸収する。

import XCTest
@testable import FTAndroid

final class AVDManagerJavaTests: XCTestCase {

    private let applications = URL(fileURLWithPath: "/Applications")
    private let userApplications = URL(fileURLWithPath: "/Users/someone/Applications")

    private func resolve(
        environment: [String: String] = [:],
        systemJava: Bool = false,
        listings: [String: [String]] = [:],
        executables: Set<String> = []
    ) -> AndroidSDKLocator.JavaForSDKTools {
        AndroidSDKLocator.javaForSDKTools(
            environment: environment,
            hasSystemJava: { systemJava },
            applicationDirectories: [applications, userApplications],
            listDirectory: { listings[$0.path] ?? [] },
            isExecutable: { executables.contains($0) })
    }

    func testAValidJavaHomeIsLeftAlone() {
        XCTAssertEqual(resolve(environment: ["JAVA_HOME": "/opt/jdk"], executables: ["/opt/jdk/bin/java"]),
                       .inherited)
    }

    func testSystemJavaIsLeftAlone() {
        XCTAssertEqual(resolve(systemJava: true,
                               listings: ["/Applications": ["Android Studio.app"]],
                               executables: ["/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"]),
                       .inherited)
    }

    /// ランナー機の実際の形: JDK 無し・Android Studio の jbr だけ
    func testFallsBackToAndroidStudiosBundledJava() {
        XCTAssertEqual(resolve(listings: ["/Applications": ["Safari.app", "Android Studio.app"]],
                               executables: ["/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"]),
                       .bundled("/Applications/Android Studio.app/Contents/jbr/Contents/Home"))
    }

    func testABrokenJavaHomeDoesNotBlockTheFallback() {
        XCTAssertEqual(resolve(environment: ["JAVA_HOME": "/gone"],
                               listings: ["/Applications": ["Android Studio.app"]],
                               executables: ["/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"]),
                       .bundled("/Applications/Android Studio.app/Contents/jbr/Contents/Home"))
    }

    /// 名前順だと "Android Studio Preview.app"(空白 < ".")が先に来るので、正式版を明示的に先にする
    func testPrefersTheReleaseAppOverAPreview() {
        XCTAssertEqual(resolve(listings: ["/Applications": ["Android Studio Preview.app", "Android Studio.app"]],
                               executables: ["/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home/bin/java",
                                             "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"]),
                       .bundled("/Applications/Android Studio.app/Contents/jbr/Contents/Home"))
    }

    func testFindsTheOlderJreLayout() {
        XCTAssertEqual(resolve(listings: ["/Applications": ["Android Studio.app"]],
                               executables: ["/Applications/Android Studio.app/Contents/jre/jdk/Contents/Home/bin/java"]),
                       .bundled("/Applications/Android Studio.app/Contents/jre/jdk/Contents/Home"))
    }

    func testLooksInTheUsersApplicationsFolder() {
        XCTAssertEqual(resolve(listings: ["/Users/someone/Applications": ["Android Studio.app"]],
                               executables: ["/Users/someone/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"]),
                       .bundled("/Users/someone/Applications/Android Studio.app/Contents/jbr/Contents/Home"))
    }

    func testMissingWhenThereIsNoJavaAnywhere() {
        XCTAssertEqual(resolve(listings: ["/Applications": ["Android Studio.app"]]), .missing)
    }

    // MARK: - avdManagerCommand

    private let avdmanager = URL(fileURLWithPath: "/sdk/cmdline-tools/latest/bin/avdmanager")

    func testPrefixesJavaHomeOnlyForTheBundledJava() {
        XCTAssertEqual(
            AndroidSDKLocator.avdManagerCommand(avdmanager, ["list", "device"],
                                                java: .bundled("/Applications/Android Studio.app/Contents/jbr/Contents/Home")),
            ["/usr/bin/env", "JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home",
             "/sdk/cmdline-tools/latest/bin/avdmanager", "list", "device"])
        XCTAssertEqual(AndroidSDKLocator.avdManagerCommand(avdmanager, ["list", "device"], java: .inherited),
                       ["/sdk/cmdline-tools/latest/bin/avdmanager", "list", "device"])
        XCTAssertEqual(AndroidSDKLocator.avdManagerCommand(avdmanager, ["list", "device"], java: .missing),
                       ["/sdk/cmdline-tools/latest/bin/avdmanager", "list", "device"])
    }

    // MARK: - 迂回の固定

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// avdmanager を撃つ `Shell.run` はすべて `avdManagerCommand` を通す。素で撃つと、ランナー機
    /// (JDK 無し)でその経路だけ「Unable to locate a Java Runtime」に戻る。撃つ場所は5つ
    /// (導入直後の確認・一覧・作成・削除・作り直し前の削除)で、増減したらここを見直す
    func testEveryAVDManagerCallGoesThroughTheJavaResolution() throws {
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        var bypasses: [String] = []
        var routed = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // コメント行は落とす(この規律を説明するコメント自体が `Shell.run([avdmanager…])` を含む)
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for call in code.components(separatedBy: "Shell.run(").dropFirst() {
                let arguments = Self.argumentsOfCall(call)
                guard arguments.contains("avdmanager") else { continue }
                if arguments.contains("avdManagerCommand(") { routed += 1 } else { bypasses.append(url.lastPathComponent) }
            }
            if code.contains("command[0] = avdmanager") { bypasses.append(url.lastPathComponent) }
        }
        XCTAssertEqual(bypasses, [], "avdmanager を avdManagerCommand を通さずに撃っている")
        XCTAssertEqual(routed, 5, "avdmanager を撃つ場所が増減した(走査が届いていない可能性もある)")
    }

    /// `Shell.run(` の直後から、対応する `)` までの引数の文字列(近くの別のコードを拾わない)
    private static func argumentsOfCall(_ rest: String) -> String {
        var depth = 1
        var arguments = ""
        for character in rest {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            arguments.append(character)
        }
        return arguments
    }
}
