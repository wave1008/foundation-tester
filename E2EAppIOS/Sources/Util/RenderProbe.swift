import QuartzCore
import UIKit

/// 計測用の描画プローブ(起動環境に FT_RENDER_PROBE=1 があるときだけ動く。`simctl launch` なら SIMCTL_CHILD_FT_RENDER_PROBE=1)。
/// 毎フレーム(CADisplayLink・.common = スクロール追従中も回る)キーウィンドウの presentation レイヤー木の署名を取り、
/// 変わったフレームの時刻を NSTemporaryDirectory()/render-probe.log へ1行ずつ追記する(`<CACurrentMediaTime> <レイヤー数>`)。
/// CACurrentMediaTime は mach_absolute_time 基準 = Simulator でもホストの CLOCK_UPTIME_RAW と同じ時計。
/// 署名に入れるもの: 位置・大きさ(スクロールビューは bounds.origin = contentOffset)・不透明度・非表示・変換・描画内容の同一性
/// (描き直すと contents のオブジェクトが替わる)。ここで見えるのはアプリがコミットした状態で、画面に出るのは次の vsync(+約 16ms)。
final class RenderProbe: NSObject {
    static let shared = RenderProbe()
    private var link: CADisplayLink?
    private var last: Int?
    private var handle: FileHandle?

    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["FT_RENDER_PROBE"] == "1" else { return }
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
        for window in windows { visit(window.layer, &hasher, &count) }
        let signature = hasher.finalize()
        guard signature != last else { return }
        last = signature
        let line = String(format: "%.6f %d\n", CACurrentMediaTime(), count)
        handle?.write(line.data(using: .utf8)!)
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
        for sub in model.sublayers ?? [] { visit(sub, &hasher, &count) }
    }
}
