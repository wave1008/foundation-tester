// 同じ台の二重配信を防ぐ控え(docs/remote-runner.md §18.2 M2)。
// **鍵の綴り**は `api device-stream`(書く側)と `api monitor`(読む側)の契約なので、
// 別の台が同じ鍵にならないことをここで固定する ―― 衝突すると互いの配信を止め合う。

import XCTest
@testable import FTCore

final class StreamLeaseTests: XCTestCase {

    /// 名前は空白・括弧・"/" を含む(実在例: "Pixel 10(Android 14(API 34) / arm64-v8a)-01")。
    /// ファイル名に使える形へ畳んでも**別の台は別の鍵**になること
    func testKeysAreFilesystemSafeAndDistinct() {
        let a = StreamLease.key(platform: "android", name: "Pixel 10(API 34 / arm64-v8a)-01")
        let b = StreamLease.key(platform: "android", name: "Pixel 10(API 34 / arm64-v8a)-02")
        XCTAssertNotEqual(a, b)
        for key in [a, b] {
            XCTAssertFalse(key.contains("/"), key)
            XCTAssertFalse(key.contains(" "), key)
        }
        // プラットフォームも鍵の一部(同名の iOS/Android が別々に数えられる)
        XCTAssertNotEqual(StreamLease.key(platform: "ios", name: "X"),
                          StreamLease.key(platform: "android", name: "X"))
    }

    func testKeyKeepsSafeCharactersReadable() {
        XCTAssertEqual(StreamLease.key(platform: "ios", name: "iPhone-16.Pro_1"),
                       "ios%3AiPhone-16.Pro_1")
    }

    // MARK: - heldByOther(両方向: 止める / 止めない)

    func testNoLeaseIsNotHeld() {
        XCTAssertFalse(StreamLease.heldByOther(info: nil, myIssuer: "alice", pidAlive: { _ in true }))
    }

    func testOwnLeaseIsNotHeldByOther() {
        let info = StreamLeaseInfo(pid: 10, issuer: "alice", startedAt: "T")
        XCTAssertFalse(StreamLease.heldByOther(info: info, myIssuer: "alice", pidAlive: { _ in true }),
                       "自分の配信で自分を止めない")
    }

    func testAnotherIssuersLiveLeaseIsHeld() {
        let info = StreamLeaseInfo(pid: 10, issuer: "bob", startedAt: "T")
        XCTAssertTrue(StreamLease.heldByOther(info: info, myIssuer: "alice", pidAlive: { $0 == 10 }))
    }

    /// **生存判定は pid だけ**(RunHookLease と同じ規律)。死んだ配信の控えは残るので、
    /// pid を見ないと相手がやめた後も永久に配信できない
    func testDeadLeaseIsNotHeld() {
        let info = StreamLeaseInfo(pid: 10, issuer: "bob", startedAt: "T")
        XCTAssertFalse(StreamLease.heldByOther(info: info, myIssuer: "alice", pidAlive: { _ in false }))
    }

    func testWriteAndReadRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-streamlease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        XCTAssertNil(StreamLease.read(base: base.path, platform: "ios", name: "iPhone 16"))
        StreamLease.write(base: base.path, platform: "ios", name: "iPhone 16",
                          info: StreamLeaseInfo(pid: 4242, issuer: "bob", startedAt: "T"))
        let read = StreamLease.read(base: base.path, platform: "ios", name: "iPhone 16")
        XCTAssertEqual(read?.pid, 4242)
        XCTAssertEqual(read?.issuer, "bob")
        // 控えはホスト共有の場所に置く(発行者ネームスペースの中だと他人の配信が見えない)
        XCTAssertTrue(StreamLease.directory(base: base.path).hasSuffix("/.fleetest/streams"))
    }
}
