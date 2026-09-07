// ConsoleOut(Sources/FTCore/ConsoleOut.swift)は stdout/stderr を1個のロックで直列化する。
// ここでは実際の標準出力を奪わず、`emit(_:fd:)`(内部の実体。fd を直接受け取る)へ
// パイプの書き込み端を渡して検証する ―― 差し替えたいのは書き込み先の fd だけで、
// out()/err() が標準出力/標準エラーへ実際に書くかどうかはこのテストの関心事ではない。

import Foundation
import XCTest
@testable import FTCore

final class ConsoleOutTests: XCTestCase {

    /// PIPE_BUF(macOS では 512 バイト)より長い行を使う。これより短いと OS 自体が
    /// 単発の write(2) を分割しないため、ロックが無くても偶然裂けずに通ってしまい
    /// テストとして無意味になる
    private static let lineLength = 6000

    /// 複数スレッドが emit(_:fd:) を同時に叩いても、1行が他の書き手のバイト列と
    /// 混ざらない(裂けない)ことを確かめる。裂けなければ「1回の呼び出し = 1本の
    /// アトミックな出力」というロックの契約が効いている証拠になる
    func testConcurrentEmitsDoNotInterleaveMidLine() throws {
        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        let readHandle = pipe.fileHandleForReading

        var collected = Data()
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }  // 書き込み端が閉じられた(EOF)
                collected.append(chunk)
            }
            readerDone.signal()
        }

        let writerCount = 16
        let linesPerWriter = 25
        // 書き手ごとに固有の1文字を敷き詰めた行にする —— 読み戻した行がどの書き手の物か、
        // 途中で別の書き手の文字が混入していないかを1文字単位で判別できる
        let expectedLines = (0..<writerCount).map { w in
            String(repeating: Character(UnicodeScalar(UInt8(65 + w))), count: Self.lineLength)
        }

        DispatchQueue.concurrentPerform(iterations: writerCount) { w in
            for _ in 0..<linesPerWriter {
                ConsoleOut.emit(expectedLines[w], fd: writeFD)
            }
        }
        try pipe.fileHandleForWriting.close()
        readerDone.wait()

        let text = try XCTUnwrap(String(data: collected, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, writerCount * linesPerWriter,
                       "行数が合わない = どこかの emit が分割されて別の行として数えられている")
        let expectedSet = Set(expectedLines)
        for line in lines {
            XCTAssertTrue(expectedSet.contains(line),
                          "行が裂けている/他の書き手の文字が混ざっている: \(line.prefix(80))…")
        }
    }

    /// stdout 用の口と stderr 用の口が同じロックを取ることの確認(このテストが落ちる変異は
    /// 「out/err で別ロックにする」— まさに CLAUDE.md が挙げている「片方だけ直列化しても
    /// 効かない」の再発)。1本の fd へ両方の口から交互に書き、裂けないことを確認する
    func testOutAndErrShareOneLockOnTheSameDestination() throws {
        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        let readHandle = pipe.fileHandleForReading

        var collected = Data()
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            readerDone.signal()
        }

        let outLine = String(repeating: "O", count: Self.lineLength)
        let errLine = String(repeating: "E", count: Self.lineLength)
        let iterations = 20
        DispatchQueue.concurrentPerform(iterations: iterations * 2) { i in
            if i % 2 == 0 {
                ConsoleOut.emit(outLine, fd: writeFD)
            } else {
                ConsoleOut.emit(errLine, fd: writeFD)
            }
        }
        try pipe.fileHandleForWriting.close()
        readerDone.wait()

        let text = try XCTUnwrap(String(data: collected, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, iterations * 2)
        for line in lines {
            XCTAssertTrue(line == outLine || line == errLine,
                          "out() と err() の出力が同じ fd 上で混ざった: \(line.prefix(80))…")
        }
    }
}
