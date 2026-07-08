// ScenarioDirectoryWatcher.swift
// Scenarios/ の外部変更(Finder・エディタ・CLI でのファイル移動や編集)を FSEvents で監視する。
// イベントは latency で粗くまとめられるだけなので、実際に再読込するかどうかは
// 受け手(AppModel)がディレクトリ署名(ScenarioFolders.directorySignature)で判断する。

import CoreServices
import Foundation

final class ScenarioDirectoryWatcher {
    private var stream: FSEventStreamRef?
    private(set) var watchedPath: String?
    /// 変更通知(メインキューで呼ばれる)
    var onChange: () -> Void = {}

    /// 監視先を切り替える(同じパスなら何もしない)
    func watch(path: String) {
        guard path != watchedPath else { return }
        stop()

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ScenarioDirectoryWatcher>.fromOpaque(info)
                .takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,  // 連続イベント(エディタ保存・git checkout 等)をまとめる
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        watchedPath = path
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPath = nil
    }

    deinit {
        stop()
    }
}
