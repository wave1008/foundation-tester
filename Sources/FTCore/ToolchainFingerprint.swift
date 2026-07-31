// ToolchainFingerprint.swift
// デバイス側の成果物(XCUITest ランナー・in-app ブリッジ dylib)を「どの Xcode/SDK で作ったか」で
// 鮮度判定するための指紋。
//
// なぜ要るか: 再ビルド判定はソースの mtime 比較だけだったため、**Xcode を上げてもソースの mtime は
// 動かず、旧 SDK でビルドした成果物が使われ続けた**。旧ランナーを新ランタイムに載せると実行中に
// 「Application is not running」で落ちる(2026-07-21 実害)。macOS/Xcode がベータのうちは更新が
// 頻繁なので、人間の記憶ではなく機械で検知する。
//
// 使い方: 成果物の隣に current() を書き、次回 matches(storedAt:) が false なら作り直す。

import Foundation

public enum ToolchainFingerprint {

    /// `xcodebuild -version` の Build 行 + iphonesimulator SDK の版。プロセス内で1回だけ実行する
    /// (needsBuild は起動のたびに呼ばれるので、その都度 2 プロセス起動するのは高い)
    public static func current() -> String? { cached }

    private static let cached: String? = compute()

    private static func compute() -> String? {
        guard let xcode = run(["xcodebuild", "-version"]) else { return nil }
        let sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"]) ?? "sdk?"
        return compose(xcodeVersionOutput: xcode, sdkBuild: sdk)
    }

    /// リモートホストの指紋を同じ規則で合成するために公開する(RemoteRunDispatcher が
    /// ssh 経由で採取した `xcodebuild -version` / SDK build を渡す)。
    /// **フォーマットを1バイトも変えない**こと(成果物の指紋ファイルと文字列比較される)
    public static func compose(xcodeVersionOutput: String, sdkBuild: String) -> String {
        // "Xcode 27.0\nBuild version 27A5228h" → 両行を1行に畳む(改行はファイルの区切りに使う)
        let xcodeLine = xcodeVersionOutput.split(separator: "\n").map(String.init).joined(separator: " ")
        return "\(xcodeLine.trimmingCharacters(in: .whitespaces)) / iphonesimulator \(sdkBuild)"
    }

    private static func run(_ command: [String]) -> String? {
        guard let result = try? Shell.run(command), result.status == 0 else { return nil }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// 保存済みの指紋が現在のツールチェーンと一致するか。
    /// **判定できない場合(未保存・読めない・現在値が取れない)は false = 作り直す**
    /// (古い成果物で走るより、無駄に1回ビルドする方が安い)
    public static func matches(storedAt url: URL, current value: String? = current()) -> Bool {
        guard let value,
              let stored = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }

    /// ビルド成功後に呼ぶ。失敗は無視する(指紋が無ければ次回作り直すだけで、壊れはしない)
    public static func store(at url: URL, current value: String? = current()) {
        guard let value else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? value.write(to: url, atomically: true, encoding: .utf8)
    }
}
