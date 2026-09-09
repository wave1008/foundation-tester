import XCTest

@testable import FTAndroid
@testable import FTBridgeClient
import FTCore

/// ユーザー決定 2026-09-08: **一括起動**(devices up・api start-all-devices・
/// モニターの「全て起動」)は実機を**含む** —— 実機の「起動」= ブリッジの起動(iOS は
/// `BridgeProvisioner.provision`、Android は `DeviceBooter.startPhysicalAndroidBridge`)。
/// **仮想デバイスの同時起動枠(maxConcurrent)とは別の、幅1の専用レーン**(`bootAll` が
/// `physicalItems` を直列に流す追加タスク)で走らせることで、数分かかる iOS のビルド
/// (xcodebuild build-for-testing)が仮想デバイスの起動を遅らせないようにする
/// (2026-08-30 に丸ごと除外していた理由がこれで、レーンを分けたことで解消した)。
/// `restart-devices` は down→up の1台単位サイクルなので、実機は down 側が成立せず
/// 従来どおり丸ごと対象外のまま(この決定の対象外)。
///
/// **一括停止**(devices down --profile・devices down の掃討(profile 無し)・
/// api stop-all-devices・モニターの「全て終了」= 上記のいずれか)は 2026-09-08 に
/// ユーザーが規則を改めた ——「全て終了」した実機は**ブリッジだけ**止まってほしい
/// (端末そのものは絶対に落とさない)。**この規則は掃討(devices down・profile 無し)にも及ぶ**
/// —— 以前は掃討だけ実機のブリッジを素通りしていたが、それでは「全て終了」を押しても
/// 実機のブリッジが残る(ユーザー指摘 2026-09-08)。
/// - profile 指定の個別停止(devices down --profile・api stop-all-devices)は共通の
///   `DeviceBooter.shutdownAll` に一本化(呼び出し側は実機の知識を持たない)。実機には
///   deviceStopping/deviceFinished を出さない(実機は端末が生き続けるので、出すと拡張のタイルが
///   「停止した」→次の観測で「接続中」に戻りちらつく) —— この抑止も shutdownAll 内の1箇所だけ
/// - 掃討(profile 無し)は個々の DeviceSpec を持たない(接続中の全台を対象にするため)ので
///   shutdownOne は経由しない —— iOS は `BridgeLauncher.stopAll(skipPhysical: false)`
///   (ps 走査でランナーを殺すだけ)、Android は `AndroidDeviceCatalog.connectedSerials()` から
///   `allEmulatorSerials()` を引いた残り(= 実機の serial)へ個別に
///   `AndroidDriver(serial:).stopBridge()` を撃つ(`DevicesCommand.Down.run` 内)。
///   どちらも端末停止コマンド(`simctl shutdown` / `adb emu kill`)は実機に一切撃たない
///
/// ここで固定する純関数が壊れると黙って退化する:
/// - `DeviceBooter.buildBootQueue` が実機を items(仮想デバイス用の maxConcurrent レーン)へ
///   混ぜてしまうと、数分のブリッジ供給が仮想デバイスの同時起動枠を専有する退行が戻る
/// - `BridgeLauncher.isPhysicalRunnerCommand` の判定が壊れると、`stopAll(skipPhysical: true)` を
///   将来どこかが呼んだときに、生きている実機ランナーの pid ファイルを消してポート採番
///   (assignPort)がずれる(現状どの呼び出し元も false で呼ぶ)
/// - `DeviceBooter.shutdownOne` の実機分岐が壊れると、利用者の端末そのものを落とす
///   (`simctl shutdown` / `adb emu kill`)か、逆に一括停止で実機のブリッジが残り続ける
/// - `DevicesCommand.Down.run` の掃討側 Android ブロックが壊れると、同じ2通りの失敗が起きる
final class BulkOperationPhysicalPolicyTests: XCTestCase {

    // MARK: - DeviceBooter.buildBootQueue(一括起動は実機を専用レーンで含む)

    private func mixedMachine() -> MachineProfile {
        MachineProfile(
            ios: MachineDeviceList(devices: [
                DeviceSpec(name: "iPhone-B", kind: .virtual),
                DeviceSpec(name: "iPhone-A", kind: .virtual),
                DeviceSpec(name: "iPhone-Real", kind: .physical, udid: "00008130-AAAA"),
            ]),
            android: MachineDeviceList(devices: [
                DeviceSpec(name: "Pixel-B", kind: .virtual, avd: "pixel_b"),
                DeviceSpec(name: "Pixel-A", kind: .virtual, avd: "pixel_a"),
                DeviceSpec(name: "Pixel-Real", kind: .physical, serial: "R3CN123"),
            ]))
    }

    /// 実機は items(仮想デバイス用・maxConcurrent レーン)に一切現れず、専用の
    /// physicalItems へ ios→android・各内 name 昇順で入る。items の並びは従来どおり
    /// ios→android・各内 name 昇順(vscode-fleetest/src/monitorModel.ts sortMonitorDevices
    /// と対のタイル表示順契約)。物理項目は必ず restart: false(down→up を行わない)
    func testBuildBootQueuePutsPhysicalDevicesInTheirOwnLane() {
        let result = DeviceBooter.buildBootQueue(
            machine: mixedMachine(), restartNames: [], cpuRenderNames: [])

        XCTAssertEqual(result.items.map(\.spec.name), ["iPhone-A", "iPhone-B", "Pixel-A", "Pixel-B"])
        XCTAssertEqual(result.physicalItems.map(\.spec.name), ["iPhone-Real", "Pixel-Real"])
        XCTAssertFalse(result.items.contains { $0.spec.isPhysical },
                       "実機は仮想デバイスの同時起動枠を専有するので items に入れてはいけない")
        XCTAssertTrue(result.physicalItems.allSatisfy { !$0.restart },
                      "実機は down→up を行わないので常に restart: false")
    }

    /// restartNames(凍結復帰の強制再起動リスト)に実機の名前が混じっても、実機は
    /// down→up ではなく通常の起動項目として physicalItems に入る(watchdog の名簿は
    /// 仮想デバイスしか知らないはずだが、万一混入しても実機側で down→up を撃たないことを固定する)
    func testBuildBootQueueNeverRestartsPhysicalDevicesEvenWhenNamed() {
        let result = DeviceBooter.buildBootQueue(
            machine: mixedMachine(), restartNames: ["iPhone-Real"], cpuRenderNames: [])

        XCTAssertTrue(result.physicalItems.contains { $0.spec.name == "iPhone-Real" && !$0.restart })
        XCTAssertFalse(result.items.contains { $0.spec.isPhysical })
    }

    // MARK: - DeviceBooter.bootAll(実機レーンは maxConcurrent の外・幅1)

    /// `bootAll` は仮想デバイス用のワーカー数(`min(maxConcurrent, items.count)`)に手を加えず、
    /// physicalItems 用にちょうど1本だけ追加のタスクを立てて直列に流す。**両方向の変異で
    /// 落ちる形**: 実機レーンを削除する変異(実機が二度と起動しない)も、physicalItems を
    /// items へ畳み込む変異(仮想デバイスの同時起動枠を専有する退行の再発)も検出する
    func testBootAllRunsPhysicalItemsInASeparateSingleWidthLane() throws {
        let source = try source("Sources/FTAndroid/DeviceBooter.swift")
        guard let bootAllStart = source.range(of: "public static func bootAll("),
              let bootAllEnd = source.range(of: "struct BootItem: Sendable {")
        else {
            XCTFail("bootAll の定義が見つからない(リファクタでシグネチャが変わった?)")
            return
        }
        let body = String(source[bootAllStart.upperBound..<bootAllEnd.lowerBound])

        XCTAssertTrue(body.contains("min(maxConcurrent, items.count)"),
                      "仮想デバイスのワーカー数式は items.count のままで physicalItems を含めない")
        XCTAssertEqual(body.components(separatedBy: "group.addTask {").count - 1, 2,
                       "追加タスクはちょうど1本(仮想デバイス用の for ループ1箇所 + 実機レーン1箇所)")
        XCTAssertTrue(body.contains("physicalQueue.next()"),
                      "実機レーンは physicalQueue を直列に(1本のタスクで)消費する")
        XCTAssertFalse(body.contains("min(maxConcurrent, items.count + physicalItems.count)"),
                       "実機は maxConcurrent のワーカー数計算に含めてはいけない(専有の再発)")
    }

    /// Android 実機のブリッジ起動は `DeviceBooter.startPhysicalAndroidBridge` の1箇所に
    /// 定義され、呼び出し元は `DeviceBooter.bootItem`(一括起動の実機レーン)と
    /// `ApiDeviceCommands.swift` の `api start-device`(単体操作)の**ちょうど2箇所**。
    /// 本数で数える —— 「存在するか」だけだと片方の呼び出し元が重複実装に戻っても緑のまま通る
    func testAndroidPhysicalBridgeStartRoutesThroughTheSingleDefinition() throws {
        let booter = try source("Sources/FTAndroid/DeviceBooter.swift")
        let api = try source("Sources/fleetest/ApiDeviceCommands.swift")

        XCTAssertEqual(booter.components(separatedBy: "public static func startPhysicalAndroidBridge(").count - 1, 1,
                       "定義は DeviceBooter に1箇所だけ")
        XCTAssertEqual(booter.components(separatedBy: "try await startPhysicalAndroidBridge(spec: spec").count - 1, 1,
                       "bootItem の実機分岐が呼ぶのはちょうど1回")
        XCTAssertEqual(api.components(separatedBy: "DeviceBooter.startPhysicalAndroidBridge(spec: spec").count - 1, 1,
                       "api start-device の実機分岐が呼ぶのはちょうど1回")
    }

    // MARK: - BridgeLauncher.isPhysicalRunnerCommand

    /// 実機とシミュレータは DerivedData を分けてある(BridgeLauncher.derivedDataPath)ので、
    /// -xctestrun のパスにそれがそのまま写る。stopAll(skipPhysical: true) はこれ1本で
    /// 「殺してよいか」を決めるので、判定がここで崩れると生きた実機ランナーの pid ファイルを
    /// 消してしまう(assignPort の採番ずれに直結)
    func testIsPhysicalRunnerCommandDetectsDerivedDataDeviceRoot() {
        let physical = "/usr/bin/xcodebuild test-without-building -xctestrun"
            + " /Users/x/repo/.fleetest/DerivedData-device/Build/Products/FleetestRunner-8123.xctestrun"
            + " -destination platform=iOS,id=00008130-AAAA"
        XCTAssertTrue(BridgeLauncher.isPhysicalRunnerCommand(physical))
    }

    func testIsPhysicalRunnerCommandRejectsSimulatorDerivedDataRoot() {
        let simulator = "/usr/bin/xcodebuild test-without-building -xctestrun"
            + " /Users/x/repo/.fleetest/DerivedData/Build/Products/FleetestRunner-8123.xctestrun"
            + " -destination platform=iOS Simulator,id=ABCDEF"
        XCTAssertFalse(BridgeLauncher.isPhysicalRunnerCommand(simulator))
    }

    func testIsPhysicalRunnerCommandRejectsUnrelatedCommand() {
        XCTAssertFalse(BridgeLauncher.isPhysicalRunnerCommand("/usr/bin/ps -ax"))
    }

    // MARK: - 配線(純関数では届かない呼び出し側)

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// `DeviceBooter.shutdownOne` の実機分岐は、①端末停止コマンド(simctl shutdown/adb emu kill)
    /// を絶対に撃たない ②Android は AndroidDriver.stopBridge() でブリッジだけ止める、の両方を
    /// 満たす。**両方向の変異で落ちる形**にするため、実機分岐のテキストを厳密な隣接部分文字列で
    /// 切り出して判定する —— return を消す変異(端末停止コマンドへフォールスルーする)も、
    /// Android のブリッジ停止呼び出しを消す変異(一括停止で実機のブリッジが残り続ける)も、
    /// この切り出しが変わるので必ず検出できる
    func testShutdownOnePhysicalBranchNeverShutsDownTheDeviceItself() throws {
        let android = try source("Sources/FTAndroid/DeviceBooter.swift")

        guard let startRange = android.range(
            of: "if spec.isPhysical {\n            if platform == \"ios\", let repoRoot {"),
              let endRange = android.range(
                of: "physical device — stopped its bridge only (the device itself keeps running)\")"
                    + "\n            return\n        }\n        if platform == \"ios\" {")
        else {
            XCTFail("shutdownOne の実機分岐の目印文字列が見つからない(リファクタで文言/構造が変わった?"
                + " このテストも合わせて直すこと)")
            return
        }
        XCTAssertLessThan(startRange.upperBound, endRange.lowerBound,
                          "実機分岐が return で閉じる前に見つかるはず")
        let block = String(android[startRange.upperBound..<endRange.lowerBound])

        XCTAssertFalse(block.contains("\"emu\", \"kill\""),
                       "実機の Android に adb emu kill を撃ってはいけない(存在しないコマンドで15秒空振りする)")
        XCTAssertFalse(block.contains("\"simctl\", \"shutdown\""),
                       "実機の iOS に simctl shutdown を撃ってはいけない(利用者の端末を落とす)")
        XCTAssertTrue(block.contains("AndroidDriver(serial: serial)") && block.contains(".stopBridge()"),
                      "実機の Android は一括停止でブリッジ(と adb forward)を止める経路が要る")
    }

    /// 一括停止(api stop-all-devices)は実機の特別扱いを自前で持たず、共通実装
    /// `DeviceBooter.shutdownAll` に一本化している(実機で deviceStopping/deviceFinished を
    /// 出さない規律そのものは Tests/FTAndroidTests/DeviceBooterShutdownAllTests.swift の
    /// testProgressIsNotEmittedForPhysicalDevices が行動として固定する)。旧来の
    /// stopPhysicalBridgeOnly/shutdownOneEmitting の2実装に戻っていないことを本数で確かめる ——
    /// 「存在するか」だけだと片方が復活しても緑のまま通る
    func testStopAllDevicesRoutesThroughTheSharedShutdownAll() throws {
        let api = try source("Sources/fleetest/ApiDeviceCommands.swift")
        XCTAssertEqual(api.components(separatedBy: "await DeviceBooter.shutdownAll(").count - 1, 1,
                       "api stop-all-devices は DeviceBooter.shutdownAll をちょうど1回呼ぶ")
        XCTAssertFalse(api.contains("stopPhysicalBridgeOnly"),
                       "実機の特別扱いは shutdownAll 側に一本化したので、呼び出し側に専用関数を残さない")
        XCTAssertFalse(api.contains("shutdownOneEmitting"),
                       "1台停止+イベント送出も shutdownAll に一本化したので、呼び出し側に専用関数を残さない")
    }

    /// api restart-devices は今回のユーザー決定の対象外(down→up の1台単位サイクルなので、
    /// 実機は従来どおり丸ごと対象外のまま)。stop-all-devices の隣にある `if spec.isPhysical {` を
    /// 壊してこちらまで巻き込んでいないことを確かめる
    func testRestartDevicesStillLeavesPhysicalDevicesAloneEntirely() throws {
        let api = try source("Sources/fleetest/ApiDeviceCommands.swift")
        guard let start = api.range(of: "guard case .found(let spec, let platform) = ApiDeviceOperation.findDevice("),
              let end = api.range(of: "items.append(RestartItem(spec: spec, platform: platform))")
        else {
            XCTFail("restart-devices の実機分岐が見つからない")
            return
        }
        let body = api[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("physical device — restart leaves it alone"),
                      "restart-devices は実機を丸ごとスキップする文言のまま")
        XCTAssertFalse(body.contains("stopPhysicalBridgeOnly"),
                       "restart-devices は stopPhysicalBridgeOnly を呼ばない(対象外のまま。呼ぶなら"
                        + " down→up の up 側が実機で成立しない)")
        XCTAssertFalse(body.contains("DeviceBooter.shutdownOne"),
                       "restart-devices の実機分岐は shutdownOne を呼ばない(端末を丸ごと対象外にする)")
    }

    /// devices down --profile はもう実機を特別扱いしない —— `DeviceBooter.shutdownAll` 側の
    /// 実機分岐に一本化し、呼び出し側は実機の知識を持たない(物理か否かの分岐がここに残っていたら、
    /// また `stopPhysicalBridgeOnly` のような特例が二重に生えている兆候)
    func testDevicesDownProfilePathHasNoPhysicalSpecialCasing() throws {
        let devices = try source("Sources/fleetest/DevicesCommand.swift")
        XCTAssertFalse(devices.contains("isPhysical"),
                       "devices down --profile は shutdownAll に実機判定を一本化したので isPhysical を書かない")
        XCTAssertEqual(devices.components(separatedBy: "await DeviceBooter.shutdownAll(").count - 1, 1,
                       "devices down --profile は共通の DeviceBooter.shutdownAll をちょうど1回呼ぶ")
        XCTAssertFalse(devices.contains("DeviceBooter.shutdownOne("),
                       "個々の shutdownOne 直呼びは shutdownAll に一本化したので呼び出し側に残らない")
    }

    /// 掃討(profile 無しの devices down = モニターの「全て終了」の実体)と明示コマンドの
    /// `bridge down --all` は、2026-09-08 のユーザー決定でどちらも実機の iOS ブリッジを止める
    /// (skipPhysical: false)。以前はこの2つを別の引数で呼び分けていたが、掃討側だけ実機の
    /// ブリッジが残る不具合になっていた —— この等号がまた `true` に戻ると同じ不具合が再発する
    func testSweepAndBridgeDownAllBothStopIOSPhysicalBridges() throws {
        XCTAssertTrue(try source("Sources/fleetest/DevicesCommand.swift")
            .contains("BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)"),
            "掃討(devices down・profile 無し)も実機の iOS ブリッジを止めること")
        XCTAssertTrue(try source("Sources/fleetest/Fleetest.swift")
            .contains("BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)"))
    }

    /// 掃討(profile 無しの devices down)は Android の実機ブリッジも止める。対象は
    /// `connectedSerials()`(adb に見えている全台)から `allEmulatorSerials()` を引いた残り
    /// (= 実機の serial)で、エミュレータの停止ループ(emu kill/simctl 相当)とは別の枠に
    /// 切り出してあることをブロックごと厳密な隣接部分文字列で確認する。
    /// **両方向の変異で落ちる形**: ブロックが消える変異(実機ブリッジが残り続ける退行)も、
    /// ブロックの中に端末停止コマンドが紛れ込む変異(利用者の端末を落とす退行)も検出する
    func testSweepStopsAndroidPhysicalBridgesWithoutTouchingDevicePower() throws {
        let devices = try source("Sources/fleetest/DevicesCommand.swift")
        guard let startRange = devices.range(
            of: "if let connected = try? AndroidDeviceCatalog.connectedSerials(),"),
              let endRange = devices.range(of: "await fanout")
        else {
            XCTFail("掃討の Android 実機ブリッジ停止ブロックの目印文字列が見つからない"
                + "(リファクタで構造が変わった? このテストも合わせて直すこと)")
            return
        }
        XCTAssertLessThan(startRange.upperBound, endRange.lowerBound,
                          "実機ブリッジ停止ブロックは await fanout より前にあるはず")
        let block = String(devices[startRange.lowerBound..<endRange.lowerBound])

        XCTAssertTrue(block.contains("AndroidDeviceCatalog.allEmulatorSerials()"),
                      "connectedSerials() からエミュレータ分を引いて実機の serial だけ残す")
        XCTAssertTrue(block.contains("AndroidDriver(serial: serial)") && block.contains(".stopBridge()"),
                      "実機は AndroidDriver.stopBridge() でブリッジだけ止める")
        XCTAssertFalse(block.contains("\"emu\", \"kill\""),
                       "実機の Android に adb emu kill を撃ってはいけない(存在しないコマンドで空振りする)")
        XCTAssertFalse(block.contains("\"simctl\", \"shutdown\""),
                       "この経路は Android 用(iOS の simctl shutdown が紛れ込んではいけない)")
        XCTAssertFalse(block.contains("EmulatorControl.shutdown"),
                       "実機はエミュレータ用の gRPC shutdown 経路を通らない(別ブロックのまま)")
    }
}
