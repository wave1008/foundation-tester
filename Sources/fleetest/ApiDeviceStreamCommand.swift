// ApiDeviceStreamCommand.swift
// **1台ぶんの画面配信を、その機械の上で始める**(`fleetest api device-stream`)。
//
// 手元のデバイスなら拡張が配信ヘルパー(fleetest-simstream / fleetest-androidstream /
// fleetest-devicepoll)を直接起こす。**リモートのデバイスにはそれができない** —— udid も
// adb serial も向こうの機械のものだから。そこで拡張は代わりに
// `fleetest remote exec <host> -- api device-stream --device-machine <host> --platform … --name …`
// を起こす。このコマンドは向こうで宛先を解決してヘルパーへ **exec で化ける**ので、
// **stdout に流れるバイト列はヘルパーが直に書いたものと1バイトも変わらない**。
//
// これが設計の要: 拡張から見ると「コマンドと引数が違うだけの同じ StreamPipeline」であり、
// 多重化の枠も新しいワイヤ形式も要らない(そのぶん、デコード・再同期・欠落の面倒が丸ごと無い)。
// 契約(v1 MJPEG / v2 H.264 のレコード形式)は vscode-fleetest/src/deviceStream.ts が唯一の定義元。
//
// exec で置き換える理由は3つ: ①stdout をコピーしないので遅延も CPU も増えない
// ②stdin の EOF(= 拡張が配信をやめた合図)がそのままヘルパーへ届く
// ③ssh が切れたときの SIGPIPE がヘルパー本人に当たる(見張り役の中間プロセスが残らない)

import ArgumentParser
import FTAndroid
import FTBridgeClient
import FTCore
import Foundation

struct ApiDeviceStreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-stream",
        abstract: "Stream one device's screen on this machine (raw helper output on stdout; for the"
            + " monitor's remote tiles)",
        discussion: "Resolves the device on this machine and execs the matching stream helper, so"
            + " stdout is byte-for-byte what the helper writes (see vscode-fleetest/src/deviceStream.ts"
            + " for the record format). Ends when stdin reaches EOF.")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (scopes the machine profile the same way `api monitor --profile` does)")
    var profile: String?

    @Option(name: [.customLong("device-machine"), .customLong("device-host")],
            help: "Treat the devices assigned to this machine name as local (set by the caller on the other end of ssh)")
    var deviceMachine: String?

    @Option(help: "Platform of the device to stream (ios or android)")
    var platform: String

    @Option(help: "Device name exactly as written in the machine profile")
    var name: String

    @Option(help: "Frames per second the helper should aim for")
    var fps: Int = 8

    @Option(name: .customLong("max-width"), help: "Maximum size of the frame long edge in px")
    var maxWidth: Int = 480

    @Option(help: "Wire format: mjpeg (v1) or h264 (v2)")
    var codec: String = "mjpeg"

    func run() async throws {
        guard platform == "ios" || platform == "android" else {
            throw ValidationError("--platform must be ios or android")
        }
        guard codec == "mjpeg" || codec == "h264" else {
            throw ValidationError("--codec must be mjpeg or h264")
        }
        let machineProfile = try MachineProfileLoad.load(
            project: project, profile: profile, deviceMachine: deviceMachine,
            noteAutoMachine: { _ in }, warn: { _ in })
        let targets = DeviceMachineGrouping.entries(machine: machineProfile).map {
            MonitorTarget(platform: $0.platform, spec: $0.spec)
        }
        guard let target = targets.first(where: { $0.platform == platform && $0.name == name }) else {
            let available = targets.filter { $0.platform == platform }.map(\.name)
            throw ValidationError("no \(platform) device named \"\(name)\" on this machine"
                + (available.isEmpty ? "" : " (available: \(available.joined(separator: ", ")))"))
        }

        // 宛先(udid / adb serial / ブリッジのポート)の解決は monitor と同じ判定を通す ——
        // 「どの実体か」の規則を2つ持たない
        let states = await ApiMonitorCommand.determineStates(targets: [target])
        guard let state = states.first else {
            throw ValidationError("could not determine the state of \(name)")
        }
        let argv = try helperArgv(target: target, state: state)
        // ヘルパーへ化ける(戻ってこない)。失敗したときだけ下へ落ちる
        try Self.exec(argv: argv)
    }

    /// 起こすヘルパーと引数。**選び方は拡張の monitorDeviceStreamController.ts と同じ規則**
    /// (実機はスクリーンショットのポーリング / iOS の仮想デバイスは simstream /
    /// Android は androidstream)。片方だけ変えない
    private func helperArgv(target: MonitorTarget, state: DeviceRuntimeState) throws -> [String] {
        let codecArgs = codec == "h264" ? ["--codec", "h264"] : []
        let sizeArgs = ["--fps", String(fps), "--max-width", String(maxWidth)]

        if target.spec.isPhysical {
            // 実機は種別を問わず devicepoll(iOS 実機に simstream は使えず[CoreSimulator 私有 API]、
            // Android 実機は screenrecord だと静止画面でフレームが流れない)。MJPEG 固定
            let helper = try helperPath("fleetest-devicepoll")
            if target.platform == "ios" {
                guard let port = state.iosPort else {
                    throw ValidationError("\(name) has no running bridge on this machine yet")
                }
                let host = (try? RepoRoot.find()).map { BridgeEndpoint.load(port: port, repoRoot: $0).host }
                return [helper, "--platform", "ios", "--host", host ?? "127.0.0.1",
                        "--port", String(port)] + sizeArgs
            }
            guard let serial = state.androidSerial else {
                throw ValidationError("\(name) is not connected to adb on this machine")
            }
            return [helper, "--platform", "android", "--serial", serial,
                    "--adb", try AndroidDriver.findADB()] + sizeArgs
        }
        if target.platform == "ios" {
            guard let udid = state.iosUdid else {
                throw ValidationError("no simulator named \"\(name)\" on this machine")
            }
            return [try helperPath("fleetest-simstream"), "--udid", udid] + sizeArgs + codecArgs
        }
        guard let serial = state.androidSerial else {
            throw ValidationError("\(name) is not running on this machine")
        }
        return [try helperPath("fleetest-androidstream"), "--serial", serial,
                "--adb", try AndroidDriver.findADB()] + sizeArgs + codecArgs
    }

    /// 配信ヘルパーは `fleetest` と同じディレクトリに置かれる(拡張の config.ts の
    /// resolveSimStream 等と同じ規則。swift build の成果物が並ぶ場所)
    private func helperPath(_ helper: String) throws -> String {
        let dir = URL(fileURLWithPath: RemoteProjectSync.selfBinaryPath()).deletingLastPathComponent()
        let path = dir.appendingPathComponent(helper).path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ValidationError("\(helper) is not built on this machine (run: swift build --product \(helper))")
        }
        return path
    }

    /// argv[0] のプログラムへ化ける。成功したら戻らない
    private static func exec(argv: [String]) throws {
        var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        execv(argv[0], &pointers)
        throw ValidationError("cannot start \(argv[0]): \(String(cString: strerror(errno)))")
    }
}
