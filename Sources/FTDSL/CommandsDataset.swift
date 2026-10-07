// CommandsDataset.swift
// account() / data()。名前・引数・longKey の書式は Shirates と同じ(`[dataset].attribute`)。
// ファイルの置き場・上書き・照合は FTCore/ScenarioDataset.swift、伏せ字化は FTCore/SecretRedactor.swift。
// **成功してもステップを記録しない**(他のコマンドの引数に入る値を返す関数。Shirates も記録しない)。
// 値が無いときだけ、そのステップを失敗にして中断する("" を返す)。

import Foundation
import FTCore

extension FTDriveCore {
    func datasetValue(_ kind: ScenarioDataset.Kind, longKey: String, command: String,
                      file: StaticString, line: UInt) -> String {
        if scenarioAborted {
            recordStep(description: "\(command) \(longKey.debugDescription)", status: .skipped(skipReason),
                       file: "\(file)", line: Int(line), command: command)
            return ""
        }
        // dry-run・一覧ではファイルを読まず longKey をそのまま返す(Shirates の TestMode.isNoLoadRun)
        if dryRun { return longKey }
        let dataset = datasets.withLock { cache -> ScenarioDataset in
            if let loaded = cache[kind] { return loaded }
            let loaded = ScenarioDataset(kind: kind, projectDir: executor.visionClassifierProjectRoot)
            cache[kind] = loaded
            return loaded
        }
        do {
            let value = try dataset.value(longKey: longKey)
            // account の値は属性全部を伏せ字の登録簿へ(同じデータセットの別の属性も秘密として扱う)。
            // マシン側で `redactAccountValues` を立てたときだけ
            if kind == .accounts, redactAccountValues, let parts = ScenarioDataset.split(longKey: longKey) {
                SecretRedactor.shared.register(dataset.allValues(dataset: parts.dataset))
            }
            return value
        } catch {
            let reason = (error as? ScenarioDataset.Failure)?.message ?? "\(error)"
            let description = "\(command) \(longKey.debugDescription)"
            recordStep(description: description, status: .failed(reason),
                       file: "\(file)", line: Int(line), command: command)
            handleFailure(stepDescription: description, reason: reason)
            return ""
        }
    }
}

/// アカウントデータセットの値(`account("[account1].password")`)。
/// プロジェクトの `dataset/accounts.json` を、マシン側 `~/.config/fleetest/dataset/<プロジェクト名>/accounts.json` が
/// 属性単位で上書きする。マシン側で `redactAccountValues` を立てたときだけ、返した値をレポート・実行ログ・
/// 結果 JSON で `***` に伏せる(既定は伏せない)
public func account(_ longKey: String,
                    file: StaticString = #filePath, line: UInt = #line) -> String {
    FTRuntime.requireCore(command: "account")
        .datasetValue(.accounts, longKey: longKey, command: "account", file: file, line: line)
}

/// `account("[account1]", "password")` = `account("[account1].password")`(Shirates と同じ)
public func account(_ datasetName: String, _ attributeName: String,
                    file: StaticString = #filePath, line: UInt = #line) -> String {
    FTRuntime.requireCore(command: "account")
        .datasetValue(.accounts, longKey: "\(datasetName).\(attributeName)", command: "account",
                      file: file, line: line)
}

/// テストデータの値(`data("[order1].item")`)。置き場・上書きは `account` と同じ(`data.json`)。伏せ字化はしない
public func data(_ longKey: String,
                 file: StaticString = #filePath, line: UInt = #line) -> String {
    FTRuntime.requireCore(command: "data")
        .datasetValue(.data, longKey: longKey, command: "data", file: file, line: line)
}

public func data(_ datasetName: String, _ attributeName: String,
                 file: StaticString = #filePath, line: UInt = #line) -> String {
    FTRuntime.requireCore(command: "data")
        .datasetValue(.data, longKey: "\(datasetName).\(attributeName)", command: "data", file: file, line: line)
}

/// データセットのフォルダに置いたファイル(CSV・JSON・画像など)の場所(`dataFile("users.csv")`)。
/// その Mac の `~/.config/fleetest/dataset/<プロジェクト名>/<filename>` があればそれを、無ければ
/// `<プロジェクト>/dataset/<filename>` を返す(**ファイル単位の差し替え**。中身は混ぜない)。`filename` は
/// dataset フォルダからの相対パス(`csv/users.csv` 可・`..` と絶対パスは不可)。
/// **見つからなければステップを失敗にして中断し、一時フォルダの空のファイルを返す**(後続の読み込みが空を
/// 読むだけでプロセスを落とさない。`/dev/null` は `String(contentsOf:)` が EACCES で開けない)。
/// dry-run は失敗にせず、見つからなければ同じ空のファイル。成功時はステップを記録しない
public func dataFile(_ filename: String,
                     file: StaticString = #filePath, line: UInt = #line) -> URL {
    let core = FTRuntime.requireCore(command: "dataFile")
    let null = emptyDataFilePlaceholder()
    let description = "dataFile \(filename.debugDescription)"
    if core.scenarioAborted {
        core.recordStep(description: description, status: .skipped(core.skipReason),
                        file: "\(file)", line: Int(line), command: "dataFile")
        return null
    }
    switch ScenarioDataset.resolveFile(filename, projectDir: core.executor.visionClassifierProjectRoot) {
    case .success(let url):
        return url
    case .failure(let failure):
        if core.dryRun { return null }
        core.recordStep(description: description, status: .failed(failure.message),
                        file: "\(file)", line: Int(line), command: "dataFile")
        core.handleFailure(stepDescription: description, reason: failure.message)
        return null
    }
}

/// 見つからなかった `dataFile` の代わりに返す空のファイル(子の一時フォルダ = サンドボックスの中でも書ける)。
/// 作れなければ `/dev/null`(読めないが、URL を返す契約は守る)
func emptyDataFilePlaceholder() -> URL {
    let url = TemporaryDirectory.url.appendingPathComponent("fleetest-dataFile-not-found")
    if FileManager.default.fileExists(atPath: url.path)
        || FileManager.default.createFile(atPath: url.path, contents: Data()) {
        return url
    }
    return URL(fileURLWithPath: "/dev/null")
}
