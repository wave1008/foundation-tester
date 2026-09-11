// 同じ台への2本目の run を断る判定は、開始スクリプトと破壊的な準備(Wipe Data・GPU 復帰・
// レーン復活・ブリッジの供給)より**前**に置く(ProfileRunner.rejectIfDevicesLeasedBeforePreparation)。
// 後ろにあると、2本目が1本目の台を消去・再起動してから断る。配線は型では守れないのでソースで固定する
// (run と api run は別々に持つ2実装)。

import XCTest

final class RunLeaseGuardOrderingTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// 呼び出し(宣言ではない)の最初の位置
    private func firstCall(_ name: String, in text: String, excludingDeclaration: Bool = true) -> String.Index? {
        var searchStart = text.startIndex
        while let range = text.range(of: name + "(", range: searchStart..<text.endIndex) {
            let lineStart = text[..<range.lowerBound].lastIndex(of: "\n") ?? text.startIndex
            let prefix = text[lineStart..<range.lowerBound]
            if !(excludingDeclaration && prefix.contains("func ")) { return range.lowerBound }
            searchStart = range.upperBound
        }
        return nil
    }

    private func assertGuardComesFirst(in path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try source(path)
        guard let guardCall = firstCall("rejectIfDevicesLeasedBeforePreparation", in: text) else {
            return XCTFail("\(path) must call rejectIfDevicesLeasedBeforePreparation", file: file, line: line)
        }
        for later in ["RunHookRunner.begin", "wipeBloatedAVDs", "recoverCpuFallbackDevices",
                      "bootMissingDevices", "buildAndroidWorkers", "buildIOSWorkers", "buildWorkers"] {
            guard let call = firstCall(later, in: text) else { continue }
            XCTAssertLessThan(guardCall, call,
                              "\(path): the lease guard must come before \(later)", file: file, line: line)
        }
    }

    func testRunChecksTheLeaseBeforeHooksAndPreparation() throws {
        try assertGuardComesFirst(in: "Sources/fleetest/ProfileRunner.swift")
    }

    func testApiRunChecksTheLeaseBeforeHooksAndPreparation() throws {
        try assertGuardComesFirst(in: "Sources/fleetest/ApiRunCommand.swift")
    }
}
