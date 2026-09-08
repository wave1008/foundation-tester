// RunnerProfileTransfer.swift
// **転送したプロファイルからローカルエイリアスを消す**(用語の定義と理由は FTCore.RunnerProfileView)。
// プロジェクトの rsync は手元のファイルをそのまま運ぶので、そのままだとランナー機のディスクに
// `"machine": "M1Ultra"` が残る。エイリアスは発行側だけの概念なので、転送の直後に
// profiles/machines と profiles/runs を**そのランナーから見た姿**へ差し替える。
//
// **machines を先に全部読んでから畳む** —— 注記の有無はプロジェクト単位の判定で、machines と runs の
// 両方へ同じ値を渡す(RunnerProfileView.isMachineAnnotated)。
//
// 呼ぶのは転送を行う2箇所(run ディスパッチの RemoteRunDispatcher.transfer と、
// fan-out 用の RemoteProjectSync.run)。**片方だけ変えない** —— 片方が生のプロファイルを
// 上書きすると、次のコマンドでエイリアスが復活する。

import FTCore
import FTRemote
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

        let machines = readProfiles(in: localProjectDir.appendingPathComponent("profiles/machines"))
        let runs = readProfiles(in: localProjectDir.appendingPathComponent("profiles/runs"))
        let annotated = RunnerProfileView.isMachineAnnotated(machineProfiles: (machines ?? []).map { $0.object })

        var uploads: [(local: URL, remote: String)] = []
        func stage(_ dirName: String, _ profiles: [(name: String, object: [String: Any])]?,
                   _ localize: ([String: Any], String, Bool) -> [String: Any]) {
            guard let profiles else { return }
            let targetDir = staging.appendingPathComponent(dirName)
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            for profile in profiles {
                guard let rendered = try? OrderedProfileJSON.data(localize(profile.object, alias, annotated))
                else { continue }
                try? rendered.write(to: targetDir.appendingPathComponent(profile.name))
            }
            uploads.append((targetDir, "\(layout.projectDir(project))/profiles/\(dirName)/"))
        }
        stage("machines", machines, RunnerProfileView.localizeMachineProfile)
        stage("runs", runs, RunnerProfileView.localizeRunProfile)

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

    /// nil = そのディレクトリが無い(転送対象にしない)。壊れた JSON はその1件だけ落とす
    /// = 転送済みの生ファイルが向こうに残り、同じ理由で落ちる
    private static func readProfiles(in dir: URL) -> [(name: String, object: [String: Any])]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name -> (name: String, object: [String: Any])? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return (name: name, object: object)
            }
    }

    private static func makeStagingDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-runner-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
