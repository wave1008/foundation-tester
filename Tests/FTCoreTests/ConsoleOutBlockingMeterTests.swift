// ConsoleOut の「出力経路でブロックされた時間」の計器。
//
// **なぜ要るか**(実測 2026-09-10): フル E2E の 120 秒打ち切り 7 件は、3台の Mac で**同時刻に**
// 起きていた。ステップ側の計器では説明できない(順番待ち 0ms・プロセス CPU は 100 秒で 3〜6 秒・
// snapshot/action/wait のどれにも計上されない)。stdout/stderr は全書き手が1個のロックと
// blocking な write(2) を共有するので、読み手が詰まると**書いていないレーンまで巻き添えで固まる**。
// この計器はその待ちを可視化する。

import Foundation
import XCTest
@testable import FTCore

final class ConsoleOutBlockingMeterTests: XCTestCase {

    /// 読み手が居ないパイプへ埋まるまで書くと write(2) が返らない。**その待ちが計上される**こと。
    /// 読み手を 400ms 眠らせてから排水することで、ブロックを意図的に作る
    func testBlockedWriteIsMeasured() throws {
        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        let readHandle = pipe.fileHandleForReading

        let before = ConsoleOut.blockedMilliseconds
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            // パイプのバッファ(64KB)が埋まった状態を作ってから排水する
            Thread.sleep(forTimeInterval: 0.4)
            while !readHandle.availableData.isEmpty {}
            drained.signal()
        }
        // バッファ(64KB)を確実に超える量を1回で書く
        ConsoleOut.emit(Data(repeating: 0x61, count: 400_000), fd: writeFD)
        try? pipe.fileHandleForWriting.close()
        _ = drained.wait(timeout: .now() + 10)

        let elapsed = ConsoleOut.blockedMilliseconds - before
        XCTAssertGreaterThanOrEqual(elapsed, 300, "読み手を待った時間が計上されていない")
        XCTAssertGreaterThanOrEqual(ConsoleOut.longestBlockMilliseconds, 300)
    }

    /// 累計は減らない(差分を取る読み手が負の値を見ない)
    func testTotalIsMonotonic() {
        let first = ConsoleOut.blockedMilliseconds
        ConsoleOut.emit("x", fd: FileHandle.nullDevice.fileDescriptor)
        XCTAssertGreaterThanOrEqual(ConsoleOut.blockedMilliseconds, first)
    }
}
