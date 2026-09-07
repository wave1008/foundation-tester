// 掃除が「自分が書いたファイル」だけに効くことを固定する。置き場は環境変数で差し替えられるので、
// 拡張子や名前で絞らないと、同じディレクトリの別のダンプや利用者のファイルまで消える。

import Foundation
import XCTest
@testable import FTCore

final class DumpRetentionTests: XCTestCase {

    func testPrunesOnlyOwnOldFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        func write(_ name: String, modified: Date) throws {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try write("crop-old.png", modified: old)
        try write("crop-old.json", modified: old)
        try write("crop-fresh.png", modified: Date())
        try write("occlusion-old.png", modified: old)     // 別のダンプ(FM 側)
        try write("notes.txt", modified: old)             // 利用者のファイル
        // **名前だけ見ると自分のダンプに見えるディレクトリ**(通常ファイル判定がここを守る)
        let subdir = dir.appendingPathComponent("crop-stale.png")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: subdir.path)

        DumpRetention.prune(in: dir, prefix: "crop-", extensions: ["png", "json"])

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["crop-fresh.png", "occlusion-old.png", "notes.txt", "crop-stale.png"],
                       "消してよいのは古い crop-*.png/.json だけ(ディレクトリも他人のファイルも残す)")
    }
}
