// CommandsTestLog.swift
// シナリオから書けるフォルダ(Shirates の `TestLog.directoryForLog` の踏襲と、一時フォルダ)。
// **サンドボックスの中で利用者が書ける場所はこの2つ** —— `NSTemporaryDirectory()` / `FileManager.temporaryDirectory` は
// `TMPDIR` を見ず、書けないユーザーの一時領域の根を返す。実体のパスは ScenarioRunnerMain が FTDriveCore に設定する
import Foundation
import FTCore

public enum TestLog {
    /// このテストクラスの出力フォルダ `<レポートの出力先>/<run の開始 yyyy-MM-dd_HHmmss>/<テストクラス名>/`
    /// (Shirates と同じ単位 = 同じ run の同じクラスのシナリオで共有)。レポートと一緒に残り(保持容量の掃除の対象)、
    /// リモート実行では手元へ回収される。初めて読んだときに作る
    public static var directoryForLog: URL {
        prepared(FTRuntime.requireCore(command: "TestLog.directoryForLog").directoryForLog,
                 name: "TestLog.directoryForLog")
    }

    /// このシナリオ専用の一時フォルダ(並列のシナリオと共有しない)。**シナリオの終わりに消す**。初めて読んだときに作る
    public static var directoryForTemp: URL {
        prepared(FTRuntime.requireCore(command: "TestLog.directoryForTemp").directoryForTemp,
                 name: "TestLog.directoryForTemp")
    }

    private static func prepared(_ url: URL?, name: String) -> URL {
        guard let url else {
            fatalError("FTDSL: \(name) is not available here (it is set only while a scenario runs)")
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
