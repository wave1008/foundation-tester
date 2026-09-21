// MachineStateDirectory.swift
// **機械グローバルな `~/.fleetest`** の唯一の定義元。プロジェクトの `.fleetest/`
// (`TestProject.stateDir`)とは別物 —— あちらは1つのプロジェクトの状態で、こちらは
// **その Mac 全体で1つしかない資源**(デバイス・loopback のポート・FM・CoreSimulatorService)を
// 巡る台帳の置き場。既に run ボード(`RunProgressLedger` = runs/)・FM の控え(`FMUsageLedger` =
// fm-usage/)・FM の死活(`FMLiveness`)・掃除の flock(`RetentionSweepLock`)がここに居る。
//
// **文字列版(`path(home:)`)がある理由**: ランナー機のロックの置き場は **ssh 先の `$HOME`**
// で、手元のプロセスの home ではない。発行側は `echo $HOME` の1往復で確定した絶対パスを
// 文字列で持つので、URL ではなくその文字列から組む。

import Foundation

public enum MachineStateDirectory {

    /// ホームの直下に置く名前。プロジェクトの `.fleetest/` と同じ綴りだが**別の区画**
    public static let directoryName = ".fleetest"

    /// `<home>/.fleetest`。`home` は**その区画を持つ機械のホーム**(リモートなら ssh 先の
    /// `$HOME` を手元で確定した絶対パス)。末尾のスラッシュは畳む —— `echo $HOME` は `/` で
    /// 終わらないが、登録簿や `--remote-dir` 由来の値が混ざっても同じ1本を指すようにする
    public static func path(home: String) -> String {
        var stripped = home
        while stripped.count > 1, stripped.hasSuffix("/") { stripped.removeLast() }
        return (stripped == "/" ? "" : stripped) + "/" + directoryName
    }

    /// この機械自身の `~/.fleetest`。`home` はテスト用の差し替え口(環境変数ではなく引数 ——
    /// `RunProgressLedger.directory(home:)` と同じ形)
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(directoryName, isDirectory: true)
    }
}
