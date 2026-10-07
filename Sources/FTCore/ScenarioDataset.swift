// ScenarioDataset.swift
// シナリオの `account()` / `data()` が引くデータセット(Shirates の dataset JSON と同じ形:
// `{ "[account1]": { "id": "...", "password": "..." } }`)。純粋な読み込みと照合だけ(DSL 側は呼ぶだけ)。
//
// 置き場: プロジェクト `<project>/dataset/<kind>.json` と、マシン側
// `<実ホーム>/.config/fleetest/dataset/<プロジェクト名>/<kind>.json`。**マシン側が属性単位で上書き**し、
// マシン側にだけある属性・データセットも使える。
// longKey は Shirates と同じ「最後の `.` で分ける」(`[account1].password` → `[account1]` と `password`。
// 属性名に `.` は使えない・データセット名には使える)。属性値が文字列でないデータセットは Shirates と同じく拒む。
// **読めないファイルがあるときは、他のファイルに値があっても失敗にする**(壊れたマシン側を黙って飛ばすと
// 古いプロジェクト側の値で動く)。**失敗文に値は出さない**(キーとパスだけ)。

import Foundation

public struct ScenarioDataset: Sendable {
    public enum Kind: String, Sendable {
        case accounts, data

        /// 失敗文での呼び名(DSL のコマンド名)
        var commandName: String { self == .accounts ? "account" : "data" }
    }

    /// 1ファイルの読み込み結果。`dataset` の属性値が文字列でないものは `nil`(照合時に名指しで拒む)
    struct Loaded: Sendable {
        let url: URL
        /// 存在しなかった
        var absent = false
        /// 存在したが読めなかった理由(値は含めない)
        var error: String?
        var datasets: [String: [String: String?]] = [:]
    }

    public let kind: Kind
    let sources: [Loaded]

    public init(kind: Kind, projectDir: URL?, home: String = ScenarioSandbox.realHome()) {
        self.kind = kind
        var urls: [URL] = []
        if let projectDir {
            urls.append(projectDir.appendingPathComponent("dataset/\(kind.rawValue).json"))
            urls.append(Self.machineURL(kind: kind, projectDir: projectDir, home: home))
        }
        self.sources = urls.map(Self.load)
    }

    /// マシン側の置き場。プロジェクト名は projectDir の末尾のディレクトリ名
    public static func machineURL(kind: Kind, projectDir: URL, home: String = ScenarioSandbox.realHome()) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".config/fleetest/dataset")
            .appendingPathComponent(projectDir.standardizedFileURL.lastPathComponent)
            .appendingPathComponent("\(kind.rawValue).json")
    }

    private static func load(_ url: URL) -> Loaded {
        var loaded = Loaded(url: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            loaded.absent = true
            return loaded
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            loaded.error = "cannot be read (\((error as NSError).localizedDescription))"
            return loaded
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            loaded.error = "is not a JSON object (expected {\"[name]\": {\"attribute\": \"value\"}})"
            return loaded
        }
        for (name, body) in root {
            guard let attributes = body as? [String: Any] else {
                loaded.error = "dataset \(name.debugDescription) is not a JSON object"
                return loaded
            }
            loaded.datasets[name] = attributes.mapValues { $0 as? String }
        }
        return loaded
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// `[dataset].attribute` を最後の `.` で分ける(Shirates と同じ)。`.` が無ければ nil
    public static func split(longKey: String) -> (dataset: String, attribute: String)? {
        guard let dot = longKey.lastIndex(of: ".") else { return nil }
        return (String(longKey[..<dot]), String(longKey[longKey.index(after: dot)...]))
    }

    /// longKey(`[dataset].attribute`)の値。無ければ `Failure`(値を含まない説明)
    public func value(longKey: String) throws -> String {
        guard let parts = Self.split(longKey: longKey) else {
            throw fail(longKey, "invalid format (expected [datasetName].attributeName)")
        }
        return try value(dataset: parts.dataset, attribute: parts.attribute, longKey: longKey)
    }

    func value(dataset: String, attribute: String, longKey: String) throws -> String {
        if let broken = sources.first(where: { $0.error != nil }) {
            throw fail(longKey, "\(broken.url.path) \(broken.error ?? "")")
        }
        var merged: [String: String?]?
        for source in sources {
            guard let attributes = source.datasets[dataset] else { continue }
            merged = (merged ?? [:]).merging(attributes) { _, later in later }
        }
        guard let merged else { throw fail(longKey, "dataset \(dataset.debugDescription) not found") }
        if let bad = merged.first(where: { $0.value == nil })?.key {
            throw fail(longKey, "attribute \(bad.debugDescription) of dataset \(dataset.debugDescription) is not a string")
        }
        guard let found = merged[attribute] else {
            throw fail(longKey, "attribute \(attribute.debugDescription) not found in dataset \(dataset.debugDescription)")
        }
        return found ?? ""
    }

    /// 登録簿(`SecretRedactor`)へ渡す、データセットの全属性(上書き後)。無いデータセットは空
    public func allValues(dataset: String) -> [String] {
        var merged: [String: String?] = [:]
        for source in sources {
            if let attributes = source.datasets[dataset] { merged.merge(attributes) { _, later in later } }
        }
        return merged.values.compactMap { $0 }
    }

    private func fail(_ longKey: String, _ reason: String) -> Failure {
        let looked = sources.isEmpty
            ? "no project directory is known to this scenario process"
            : sources.map { "\($0.url.path) (\($0.absent ? "not found" : "read"))" }.joined(separator: ", ")
        return Failure(message: "\(kind.commandName)(\(longKey.debugDescription)): \(reason). Looked at: \(looked)")
    }
}
