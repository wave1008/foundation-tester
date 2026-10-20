// xcodegen の場所(唯一の定義元。XCUITest ランナーの生成 `BridgeLauncher.generateProjectIfNeeded` と `fleetest doctor` が引く)。
// **PATH に頼り切らず既知の場所も見る**: ssh 越しの非対話シェル・launchd から起きた fleetest の PATH は
// `/usr/bin:/bin:/usr/sbin:/sbin` だけのことがあり、ブリッジの版上げでランナーを作り直す回だけ
// `env: xcodegen: No such file or directory` で全デバイスの供給が落ちた(M1Ultra。xcodegen は sudo が無いので `~/.local/bin`)。
// リモートのディスパッチが足す PATH(`RemoteShell.remoteRunCommand`)は Homebrew の2つだけで `~/.local/bin` を含まない
import Foundation

public enum XcodegenLocator {
    /// PATH の後に見る場所。Homebrew(Apple Silicon / Intel)と、利用者の置き場(`~/.local/bin` = Homebrew を使えない機械で手で置く先)
    static func fallbackDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
    }

    public static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs + fallbackDirectories(home: home) where !dir.isEmpty {
            let candidate = dir.hasSuffix("/") ? dir + "xcodegen" : dir + "/xcodegen"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// 見つからなかったときの文(探した場所を事実として並べる)
    public static func notFoundMessage(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return "xcodegen was not found on PATH (\(environment["PATH"] ?? "unset")) or in "
            + fallbackDirectories(home: home).joined(separator: ", ")
            + " — install it (brew install xcodegen) or put it in one of those directories"
    }
}
