// RunnerProfileTransfer.swift
// **転送したプロファイルからローカルエイリアスを消す**(用語の定義と理由は FTCore.RunnerProfileView)。
// プロジェクトの rsync は手元のファイルをそのまま運ぶので、そのままだとランナー機のディスクに
// `"machine": "M1Ultra"` が残る。エイリアスは発行側だけの概念なので、転送の直後に
// profiles/machines と profiles/runs を**そのランナーから見た姿**へ差し替える。
//
// 呼ぶのは転送を行う2箇所(run ディスパッチの RemoteRunDispatcher.transfer と、
// fan-out 用の RemoteProjectSync.run)。**片方だけ変えない** —— 片方が生のプロファイルを
// 上書きすると、次のコマンドでエイリアスが復活する。

import FTCore
import Foundation

enum RunnerProfileTransfer {

    /// 転送済みの profiles/ を畳んだ姿へ差し替える。戻り値 = 失敗理由(nil なら成功)。
    /// **`--delete` は付けない** —— 直前のプロジェクト転送が既に不要なファイルを消しており、
    /// ここは中身の差し替えだけを行う(apps/ 等は触らない)
    static func localizeAndUpload(localProjectDir: URL, project: String, alias: String,
                                  layout: RemoteLayout, sshTarget: String) -> String? {
        let staging: URL
        do {
            staging = try makeStagingDir()
        } catch {
            return "cannot stage the localized profiles: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        var uploads: [(local: URL, remote: String)] = []
        for (dirName, localize) in [
            ("machines", RunnerProfileView.localizeMachineProfile),
            ("runs", RunnerProfileView.localizeRunProfile),
        ] as [(String, ([String: Any], String) -> [String: Any])] {
            let sourceDir = localProjectDir.appendingPathComponent("profiles/\(dirName)")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: sourceDir.path) else {
                continue
            }
            let targetDir = staging.appendingPathComponent(dirName)
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            for name in names where name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: sourceDir.appendingPathComponent(name)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue  // 壊れた JSON はそのまま(向こうが同じ理由で落ちる)
                }
                guard let rendered = try? OrderedProfileJSON.data(localize(object, alias)) else { continue }
                try? rendered.write(to: targetDir.appendingPathComponent(name))
            }
            uploads.append((targetDir, "\(layout.projectDir(project))/profiles/\(dirName)/"))
        }

        for upload in uploads {
            let args = ["-az", "\(upload.local.path)/", "\(sshTarget):\(upload.remote)"]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return "rsync (localized profiles) failed to start: \(error.localizedDescription)"
            }
            guard process.terminationStatus == 0 else {
                return "rsync (localized profiles) exited with \(process.terminationStatus)"
            }
        }
        return nil
    }

    private static func makeStagingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-runner-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
