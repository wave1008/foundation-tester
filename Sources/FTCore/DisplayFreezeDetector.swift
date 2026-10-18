// DisplayFreezeDetector.swift
// 「表示が止まっている」(ブリッジの撮影が同じ絵を返し続ける)の判定。run のレーンがシナリオの境目で撮った絵を
// 前回と比べる(配線: ProfileRunOrchestrator → RunOrchestrator.checkLaneDisplay → FTAndroid.DisplayFreezeWatch)。
//
// 一様(白/黒ベタ)でない凍結は FrozenVerdict の一様判定では見えない —— 実測(Android Emulator): 表示が
// 凍ると `UiAutomation.takeScreenshot` は数分前の絵を返し続け、分類器・findImage・可視性検証が別の画面の絵で誤判定した
// (同時刻の adb screencap は黒)。絵の中身では見分けられないので**時間**で見る。
//
// 判定: 同じバイト列の絵が `minSpanSeconds` 以上離れて返った = 疑い。疑いだけでデバイスを触らない ——
// 確認(home を押して絵が変わるか)は DisplayFreezeWatch が行う。

import CryptoKit
import Foundation

public enum DisplayFreezeDetector {
    /// 1 回の観測。`digest` はプロセスを跨いで比べられる(Hasher は起動ごとに種が変わるので使わない)
    public struct Sample: Equatable, Sendable {
        public let digest: String
        /// 観測した時刻(秒。単調時計でも壁時計でもよいが、比べる 2 つは同じ時計で採る)
        public let at: TimeInterval

        public init(digest: String, at: TimeInterval) {
            self.digest = digest
            self.at = at
        }

        public init(png: Data, at: TimeInterval) {
            self.init(digest: DisplayFreezeDetector.digest(png), at: at)
        }
    }

    public enum Suspicion: Equatable, Sendable {
        case none
        /// 同じ絵が `spanSeconds` 離れて返った
        case suspect(spanSeconds: TimeInterval)
    }

    /// 同じ絵を「止まっている」と疑う最短の間隔(秒)。**根拠**: ステータスバーの時計は 1 分に 1 回変わる =
    /// 生きた表示の 2 枚が 60 秒以上離れて同一バイトになることは無い(時計を隠す全画面のアプリだけが例外で、
    /// その分は確認の home 押しが分ける)。短くすると、同じ画面で終わる短いシナリオの連続が同じ分の中で
    /// 同一の絵を返し、疑いが毎回立つ。**尽きたときの発話**: 疑いは 1 行のログと確認(home)で、絵が変われば
    /// 健全に戻す(再起動は確認でも変わらなかったときだけ)
    public static let minSpanSeconds: TimeInterval = 60

    /// PNG の生バイトの SHA-256(16 進)。縮小・再エンコードを挟まない(決定的でない)
    public static func digest(_ png: Data) -> String {
        SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    }

    /// 前回と同じ絵が `minSpan` 以上離れて返ったら疑い。前回が無い・絵が違う・間隔が短いは none
    public static func judge(previous: Sample?, current: Sample,
                             minSpan: TimeInterval = minSpanSeconds) -> Suspicion {
        guard let previous, previous.digest == current.digest else { return .none }
        let span = current.at - previous.at
        guard span >= minSpan else { return .none }
        return .suspect(spanSeconds: span)
    }

    /// 陽性対照の注入口: このデバイス(serial / udid をカンマ区切り)の撮影を固定の絵に差し替える(検知も確認も同じ絵 =
    /// 確認でも変わらず、回復まで本当に撃つ)。**保守者だけが使う** —— FrozenInjection と違い、確かめたいのが
    /// 「再起動まで届くこと」なのでデバイスを触る。キーは FTCore に置き、読むのは DisplayFreezeWatch.production
    public static let frozenFrameInjectionKey = "FT_FAKE_FROZEN_FRAME_KEYS"

    public static func injectedKeys(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        guard let raw = environment[frozenFrameInjectionKey] else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

/// シナリオの境目の表示の確認の結果(RunOrchestrator が読む)
public enum LaneDisplayCheckOutcome: Equatable, Sendable {
    /// 判定しなかった(実機・撮れなかった・対象外)
    case notChecked
    case healthy
    /// 確認(home)でも絵が変わらなかった。`recovery` は撃った回復(nil = 何も撃てなかった)。
    /// レーンは RunOrchestrator が .frozen と同じ扱いにする(直前の結果を捨てて振り直し・離脱・revive)
    case frozen(detail: String, recovery: WorkerRecoveryKind?)
}
