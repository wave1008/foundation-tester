import QuartzCore
import UIKit

/// 計測用の描画プローブ(E2EAppIOS/Sources/Util/RenderProbe.swift の写し。片方だけ変えない。起動環境に FT_RENDER_PROBE=1 があるときだけ動く。`simctl launch` なら SIMCTL_CHILD_FT_RENDER_PROBE=1)。
/// 毎フレーム(CADisplayLink・.common = スクロール追従中も回る)キーウィンドウの presentation レイヤー木の署名を取り、
/// 変わったフレームの時刻を NSTemporaryDirectory()/render-probe.log へ1行ずつ追記する(`<CACurrentMediaTime> <レイヤー数>`)。
/// CACurrentMediaTime は mach_absolute_time 基準 = Simulator でもホストの CLOCK_UPTIME_RAW と同じ時計。
/// 署名に入れるもの: 位置・大きさ(スクロールビューは bounds.origin = contentOffset)・不透明度・非表示・変換・描画内容の同一性
/// (描き直すと contents のオブジェクトが替わる)。ここで見えるのはアプリがコミットした状態で、画面に出るのは次の vsync(+約 16ms)。
/// FT_RENDER_PROBE=2 は詳細: 行末に、変わったレイヤーの持ち主(delegate のビュー or レイヤー)のクラス名を最大4つと、増減した数を足す。
final class RenderProbe: NSObject {
    static let shared = RenderProbe()
    private var link: CADisplayLink?
    private var last: Int?
    private var handle: FileHandle?
    private var verbose = false
    private var lastLayers: [ObjectIdentifier: Int] = [:]
    private var layers: [ObjectIdentifier: Int] = [:]
    private var names: [ObjectIdentifier: String] = [:]

    static func startIfRequested() {
        // 起動の環境変数を渡せない起動(ツールの in-app 起動など)向けに、tmp/render-probe.on(中身 "1" か "2")でも有効にできる
        let flag = (NSTemporaryDirectory() as NSString).appendingPathComponent("render-probe.on")
        let mode = ProcessInfo.processInfo.environment["FT_RENDER_PROBE"]
            ?? (try? String(contentsOfFile: flag, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 目印は読んだら消す(次の起動の1回だけ効く)。残すと以後の普段の起動・E2E でも毎フレームの走査が回り続ける
        try? FileManager.default.removeItem(atPath: flag)
        guard mode == "1" || mode == "2" else { return }
        shared.verbose = mode == "2"
        DispatchQueue.main.async { shared.start() }
    }

    private func start() {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("render-probe.log")
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
        guard !windows.isEmpty else { return }
        var hasher = Hasher()
        var count = 0
        layers.removeAll(keepingCapacity: true)
        for window in windows { visit(window.layer, &hasher, &count) }
        let signature = hasher.finalize()
        guard signature != last else { return }
        last = signature
        var line = String(format: "%.6f %d", CACurrentMediaTime(), count)
        if verbose {
            let changed = layers.filter { lastLayers[$0.key] != $0.value }.map(\.key)
            let added = changed.filter { lastLayers[$0] == nil }.count
            let removed = lastLayers.keys.filter { layers[$0] == nil }.count
            let top = Array(Set(changed.filter { lastLayers[$0] != nil }.compactMap { names[$0] })).sorted().prefix(4)
            line += " +\(added) -\(removed) \(top.joined(separator: ","))"
            lastLayers = layers
        }
        handle?.write((line + "\n").data(using: .utf8)!)
    }

    private func visit(_ model: CALayer, _ hasher: inout Hasher, _ count: inout Int) {
        // スクロールインジケータは止まった後もフェードで約 1 秒変わり続ける(内容の描画ではない)ので数えない
        if let view = model.delegate as? UIView, NSStringFromClass(type(of: view)).contains("ScrollIndicator") { return }
        let layer = model.presentation() ?? model
        count += 1
        hasher.combine(layer.position.x); hasher.combine(layer.position.y)
        hasher.combine(layer.bounds.origin.x); hasher.combine(layer.bounds.origin.y)
        hasher.combine(layer.bounds.size.width); hasher.combine(layer.bounds.size.height)
        hasher.combine(layer.opacity); hasher.combine(layer.isHidden)
        let t = layer.transform
        hasher.combine(t.m11); hasher.combine(t.m22); hasher.combine(t.m41); hasher.combine(t.m42)
        if let contents = model.contents { hasher.combine(ObjectIdentifier(contents as AnyObject)) }
        if verbose {
            var own = Hasher()
            own.combine(layer.position.x); own.combine(layer.position.y)
            own.combine(layer.bounds.origin.x); own.combine(layer.bounds.origin.y)
            own.combine(layer.bounds.size.width); own.combine(layer.bounds.size.height)
            own.combine(layer.opacity); own.combine(layer.isHidden); own.combine(t.m41); own.combine(t.m42)
            if let contents = model.contents { own.combine(ObjectIdentifier(contents as AnyObject)) }
            let id = ObjectIdentifier(model)
            layers[id] = own.finalize()
            if names[id] == nil { names[id] = NSStringFromClass(type(of: (model.delegate as? UIView) ?? model)) }
        }
        for sub in model.sublayers ?? [] { visit(sub, &hasher, &count) }
    }
}
