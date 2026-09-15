// avdmanager/sdkmanager に渡す Java の解決(AndroidSDKLocator.javaForSDKTools / sdkToolCommand /
// avdManagerCommand)。ランナー機(ssh の非対話シェル・システムに JDK 無し・Android Studio だけ
// 入っている)で「Unable to locate a Java Runtime」になった形を、同梱の Java へ倒して吸収する。

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

    // MARK: - sdkToolCommand / avdManagerCommand

    private let avdmanager = URL(fileURLWithPath: "/sdk/cmdline-tools/latest/bin/avdmanager")
    private let sdkmanager = URL(fileURLWithPath: "/sdk/cmdline-tools/latest/bin/sdkmanager")

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

    /// avdManagerCommand は sdkToolCommand の別名。sdkmanager 側でも同じ規則が効くことを直接確かめる
    func testSdkToolCommandPrefixesJavaHomeOnlyForTheBundledJava() {
        XCTAssertEqual(
            AndroidSDKLocator.sdkToolCommand(sdkmanager, ["--install", "system-images;android-36;google_apis;arm64-v8a"],
                                             java: .bundled("/Applications/Android Studio.app/Contents/jbr/Contents/Home")),
            ["/usr/bin/env", "JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home",
             "/sdk/cmdline-tools/latest/bin/sdkmanager", "--install", "system-images;android-36;google_apis;arm64-v8a"])
        XCTAssertEqual(
            AndroidSDKLocator.sdkToolCommand(sdkmanager, ["--install", "x"], java: .inherited),
            ["/sdk/cmdline-tools/latest/bin/sdkmanager", "--install", "x"])
        XCTAssertEqual(
            AndroidSDKLocator.sdkToolCommand(sdkmanager, ["--install", "x"], java: .missing),
            ["/sdk/cmdline-tools/latest/bin/sdkmanager", "--install", "x"])
    }

    // MARK: - 迂回の固定

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// avdmanager/sdkmanager を撃つ `Shell.run` はすべて `avdManagerCommand`/`sdkToolCommand` を
    /// 通す。素で撃つと、ランナー機(JDK 無し)でその経路だけ「Unable to locate a Java Runtime」に
    /// 戻る。撃つ場所は6つ(avdmanager: 導入直後の確認・一覧・作成・削除・作り直し前の削除 /
    /// sdkmanager: システムイメージ導入)で、増減したらここを見直す
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
                guard arguments.contains("avdmanager") || arguments.contains("sdkmanager") else { continue }
                if arguments.contains("avdManagerCommand(") || arguments.contains("sdkToolCommand(") {
                    routed += 1
                } else {
                    bypasses.append(url.lastPathComponent)
                }
            }
            if code.contains("command[0] = avdmanager") || code.contains("command[0] = sdkmanager") {
                bypasses.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(bypasses, [], "avdmanager/sdkmanager を avdManagerCommand/sdkToolCommand を通さずに撃っている")
        XCTAssertEqual(routed, 6, "avdmanager/sdkmanager を撃つ場所が増減した(走査が届いていない可能性もある)")
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
