// run の終わりに出す「どのデバイスがどのエンジンで走ったか」の文言(純粋関数)。CLI の run と、
// ディスパッチの省いた出力(リモートの子の run のまとめがそのまま中継される)の両方で読める1か所。
// 頼んだエンジンから縮退したデバイスは別の行で理由つきで言う(黙って XCUITest で走った、を見落とさない)

import Foundation

public enum WorkerEngineSummary {
    /// RunEvent のワーカーのラベル("<デバイス名>(ios:<port>)")から、そのデバイスの実効エンジンを引く。
    /// 記録の worker は "ios:<デバイス名>"(ScenarioRunner.recordingWorker)なので、ラベルからデバイス名を戻して突き合わせる
    public static func engine(forLabel label: String, in records: [WorkerEngineRecord]) -> String? {
        guard RunWorker.platform(fromLabel: label) == "ios" else { return nil }
        let worker = "ios:" + RunWorker.laneKey(fromLabel: label)
        return records.first { $0.worker == worker }?.effective
    }

    /// 記録が無ければ空(Android だけの run・iOS が1台も参加しなかった run)
    public static func lines(_ records: [WorkerEngineRecord]) -> [String] {
        guard !records.isEmpty else { return [] }
        func device(_ worker: String) -> String {
            worker.hasPrefix("ios:") ? String(worker.dropFirst("ios:".count)) : worker
        }
        var lines = ["🔧 Engines: " + records.map { "\(device($0.worker)) \($0.effective)" }.joined(separator: ", ")]
        for record in records where record.requested != record.effective {
            lines.append("⚠️ \(device(record.worker)): ran on \(record.effective) instead of \(record.requested)"
                + (record.reason.map { " — \($0)" } ?? ""))
        }
        return lines
    }
}
