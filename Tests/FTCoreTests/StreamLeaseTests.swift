// 同じ台の二重配信を防ぐ控え(docs/remote-runner.md §18.2 M2)。
// **鍵の綴り**は `api device-stream`(書く側)と `api monitor`(読む側)の契約なので、
// 別の台が同じ鍵にならないことをここで固定する ―― 衝突すると互いの配信を止め合う。

import XCTest
@testable import FTCore
import FTRemote

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

    // MARK: - 置き場(機械グローバル)

    /// 控えは**機械グローバルな `~/.fleetest/streams`**(`FTCore.MachineStateDirectory`)。
    /// 完全一致で固定する —— 書き手と読み手が別プロセスなので、綴りが1文字ずれると
    /// 二重配信の抑止が黙って全部素通しになる
    func testDirectoryIsTheMachineGlobalStreamsDirectory() {
        XCTAssertEqual(StreamLease.directory(home: "/Users/tester"),
                       "/Users/tester/.fleetest/streams")
        XCTAssertEqual(
            StreamLease.fileURL(platform: "ios", name: "iPhone 16",
                                home: URL(fileURLWithPath: "/Users/tester")).path,
            "/Users/tester/.fleetest/streams/ios%3AiPhone%2016.json")
    }

    /// **この変更の目的そのもの**: 同じ Mac に `<base>` を2つ作っても控えは1箇所
    /// (`RemoteDispatchLockTests.testTwoBasesOnTheSameMachineShareOneLock` と同じ形)。
    /// 奪い合うのは端末側の捕捉コスト(screenrecord / simstream)= その機械の資源なので、
    /// base ごとに控えが割れると二重配信が黙って復活する
    func testTwoBasesOnTheSameMachineShareOneLeaseDirectory() {
        let first = RemoteLayout(base: "/Users/tester/fleetest-runner", issuer: "alice",
                                 home: "/Users/tester")
        let second = RemoteLayout(base: "/Volumes/ssd/other-runner", issuer: "bob",
                                  home: "/Users/tester")
        XCTAssertEqual(StreamLease.directory(home: first.home),
                       StreamLease.directory(home: second.home))
        // 逆向き: ホームが違えば別の控え(同じ base を別の Mac で使っても混ざらない)
        XCTAssertNotEqual(StreamLease.directory(home: "/Users/tester"),
                          StreamLease.directory(home: "/Users/other"))
    }

    func testWriteAndReadRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-streamlease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        XCTAssertNil(StreamLease.read(platform: "ios", name: "iPhone 16", home: home))
        StreamLease.write(platform: "ios", name: "iPhone 16",
                          info: StreamLeaseInfo(pid: 4242, issuer: "bob", startedAt: "T"),
                          home: home)
        let read = StreamLease.read(platform: "ios", name: "iPhone 16", home: home)
        XCTAssertEqual(read?.pid, 4242)
        XCTAssertEqual(read?.issuer, "bob")
        // 書いた先は `<home>/.fleetest/streams/`(`<home>/streams` でも発行者ネームスペースの
        // 中でもない)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.path + "/.fleetest/streams/"
                + StreamLease.key(platform: "ios", name: "iPhone 16") + ".json"))
    }

    // MARK: - 配線(書き手と読み手は別プロセス = 型で守れない)

    /// 書き手(`api device-stream`)も読み手(`api monitor`)も**文脈で分岐しない**。
    /// かつては `FT_RUNNER_BASE` が立っているときだけ書き・読んでいたので、手元の配信は
    /// 控えを1つも残さなかった。**書かない側の壊れ方は沈黙**(読み手は常に「誰も張っていない」と
    /// 答え、二重配信の抑止が全部素通しになる)ので、走査で落とす
    func testBothSidesTouchTheLeaseWithoutBranchingOnContext() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (file, call) in [("Sources/fleetest/ApiDeviceStreamCommand.swift", "StreamLease.write("),
                             ("Sources/fleetest/ApiMonitorCommand.swift", "StreamLease.read(")] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains(call), "\(file) が \(call) を呼んでいない")
            XCTAssertFalse(source.contains("RunnerBase"), "\(file) が置き場を環境変数から導いている")
        }
    }
}
