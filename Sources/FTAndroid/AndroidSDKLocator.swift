// Android SDK ルート・avdmanager の場所解決。
// AndroidDriver.findADB / DeviceBooter.findEmulatorBinary と同じ探索方針を SDK ルート単位でまとめる
// (探索順を変えるときはそちらとの整合も確認する)。

import Foundation
import FTCore

public enum AndroidSDKLocator {

    /// $ANDROID_HOME → $ANDROID_SDK_ROOT → 既定パス → adb からの相対推定の順。全て失敗で nil
    public static func findSDKRoot() -> URL? {
        let fm = FileManager.default

        func existingDirectory(_ path: String) -> URL? {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }

        for env in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let path = ProcessInfo.processInfo.environment[env],
               let dir = existingDirectory(path) {
                return dir
            }
        }
        let defaultPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk").path
        if let dir = existingDirectory(defaultPath) { return dir }

        if let adb = try? AndroidDriver.findADB() {
            let sdk = URL(fileURLWithPath: adb)
                .deletingLastPathComponent().deletingLastPathComponent()
            if let dir = existingDirectory(sdk.path) { return dir }
        }
        return nil
    }

    /// findAVDManager() が nil のときに利用者へ出す理由文。device-catalog(モデル定義が空になる)・
    /// create-device(作成不能)・doctor で同じ文言を使う。Android Studio 標準の SDK 導入では
    /// cmdline-tools が入らないことがあり、そのとき「モデルを選べない」だけが症状として出る。
    public static let avdManagerMissingMessage =
        "avdmanager not found (the Android SDK Command-line Tools are not installed)"

    /// 上の理由文に添える解決手段。モニターのダイアログは導入ボタンを併記するので使わない
    /// (ボタンの隣に同じ案内が並ぶため)
    public static let avdManagerInstallHint =
        "they can be installed with `fleetest api install-cmdline-tools`"

    /// findSDKManager() が nil のときに利用者へ出す理由文(avdManagerMissingMessage と対)。
    /// install-system-image で使う
    public static let sdkManagerMissingMessage =
        "sdkmanager not found (the Android SDK Command-line Tools are not installed)"

    /// cmdline-tools/latest → cmdline-tools/*(名前順)→ tools(旧レイアウト)の順。
    /// avdmanager/sdkmanager は同じディレクトリに同居するのでこの探索順を共有する
    private static func findCmdlineTool(named name: String) -> URL? {
        guard let sdkRoot = findSDKRoot() else { return nil }
        let fm = FileManager.default

        let latest = sdkRoot.appendingPathComponent("cmdline-tools/latest/bin/\(name)")
        if fm.isExecutableFile(atPath: latest.path) { return latest }

        let cmdlineToolsDir = sdkRoot.appendingPathComponent("cmdline-tools")
        if let entries = try? fm.contentsOfDirectory(
            at: cmdlineToolsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let candidate = entries
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/\(name)") }
                .first { fm.isExecutableFile(atPath: $0.path) }
            if let candidate { return candidate }
        }

        let legacy = sdkRoot.appendingPathComponent("tools/bin/\(name)")
        if fm.isExecutableFile(atPath: legacy.path) { return legacy }

        return nil
    }

    public static func findAVDManager() -> URL? { findCmdlineTool(named: "avdmanager") }

    /// システムイメージの導入(`sdkmanager --install`)に使う。探索順は findAVDManager と同じ
    public static func findSDKManager() -> URL? { findCmdlineTool(named: "sdkmanager") }

    // MARK: - avdmanager が要る Java

    /// avdmanager は Java を要る。Android Studio 標準の導入ではシステムに JDK が入らず
    /// (`/usr/libexec/java_home` が失敗)、`JAVA_HOME` を書いた `~/.zshrc` は ssh の非対話シェルでは
    /// 読まれない —— ランナー機ではこの形で「Unable to locate a Java Runtime」になる。
    /// そのときだけ Android Studio 同梱の Java を渡す(利用者が用意した Java を上書きしない)
    public enum JavaForSDKTools: Equatable {
        /// `JAVA_HOME` かシステムの Java がそのまま使える(何も渡さない)
        case inherited
        /// Android Studio 同梱の Java(`JAVA_HOME` に渡す Home のパス)
        case bundled(String)
        /// どれも無い
        case missing
    }

    /// Android Studio の中の Java Home。新しい版は jbr、古い版は jre(さらに古い版は jre/jdk)
    static let bundledJavaHomeSubpaths = [
        "Contents/jbr/Contents/Home", "Contents/jre/Contents/Home", "Contents/jre/jdk/Contents/Home",
    ]

    /// 順: 有効な `JAVA_HOME` → システムの Java → Android Studio 同梱。同梱は `Android Studio.app` を
    /// 先に、次に `Android Studio*.app`(Preview 等)を名前順で見る
    public static func javaForSDKTools(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasSystemJava: () -> Bool = systemJavaAvailable,
        applicationDirectories: [URL] = defaultApplicationDirectories,
        listDirectory: (URL) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] },
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> JavaForSDKTools {
        if let home = environment["JAVA_HOME"], !home.isEmpty, isExecutable(home + "/bin/java") {
            return .inherited
        }
        if hasSystemJava() { return .inherited }
        for directory in applicationDirectories {
            let studios = listDirectory(directory)
                .filter { $0.hasPrefix("Android Studio") && $0.hasSuffix(".app") }
                .sorted { ($0 == "Android Studio.app" ? 0 : 1, $0) < ($1 == "Android Studio.app" ? 0 : 1, $1) }
            for studio in studios {
                for subpath in bundledJavaHomeSubpaths {
                    let home = directory.appendingPathComponent(studio).appendingPathComponent(subpath).path
                    if isExecutable(home + "/bin/java") { return .bundled(home) }
                }
            }
        }
        return .missing
    }

    public static var defaultApplicationDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// `/usr/libexec/java_home` は JDK が1つも無いと非0で終わる。上限 5 秒 = 手元のファイルを見るだけの
    /// コマンドで、尽きたら「無い」扱い(同梱の Java を探しに行く)
    public static func systemJavaAvailable() -> Bool {
        (try? Shell.run(["/usr/libexec/java_home"], timeout: 5))?.status == 0
    }

    /// sdkmanager/avdmanager を撃つ引数列。**sdkmanager/avdmanager は必ずこれを通して撃つ**
    /// (素の `Shell.run([avdmanager/sdkmanager…])` は `AVDManagerJavaTests` のソース走査が落とす)。
    /// 同梱の Java が要るときは `/usr/bin/env JAVA_HOME=…` を前置する
    public static func sdkToolCommand(
        _ tool: URL, _ arguments: [String], java: JavaForSDKTools = javaForSDKTools()
    ) -> [String] {
        if case .bundled(let home) = java {
            return ["/usr/bin/env", "JAVA_HOME=\(home)", tool.path] + arguments
        }
        return [tool.path] + arguments
    }

    /// avdManagerCommand は sdkToolCommand の別名(既存呼び出し元の記名を変えないため残す)。
    /// 挙動は完全に同じ
    public static func avdManagerCommand(
        _ avdmanager: URL, _ arguments: [String], java: JavaForSDKTools = javaForSDKTools()
    ) -> [String] {
        sdkToolCommand(avdmanager, arguments, java: java)
    }

    /// avdmanager が Java 不在で落ちたときに添える案内(`.missing` のときだけ)
    public static let javaMissingHint =
        "no Java runtime was found: install Android Studio (it bundles one) or a JDK, or set JAVA_HOME"
}
