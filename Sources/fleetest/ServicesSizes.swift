// `fleetest services status` の「大きさ」の段: fleetest が作ったイメージ(この接頭辞の build と中継)と、この接頭辞の
// 名前付きボリューム。読み取りの形は FTServices の `RuntimeSizes`(純粋)。ここはランタイムの CLI を撃って並べるだけ。
// Apple のボリュームは 512 GiB のスパースなイメージなので、名目でなく**ファイルの割り当て済みブロック**を大きさとして出す。

import FTServices
import Foundation

enum ServicesSizes {
    struct Report: Equatable {
        var volumeLines: [String] = []
        var imageLines: [String] = []
        var failures: [String] = []
    }

    static func report(cli: RuntimeCLI, prefix: String, volumes: [String],
                       allocatedBytes: (String) -> Int64? = fileAllocatedBytes) -> Report {
        var report = Report()
        let commands = cli.commands

        // イメージ
        let images = cli.run(commands.imageListWithSizes)
        if images.succeeded {
            let sizes: [RuntimeSizes.ImageSize] = cli.isDocker
                ? RuntimeSizes.dockerImageSizes(listOutput: images.output)
                : RuntimeSizes.appleImageSizes(listJSON: images.output)
                    .map { RuntimeSizes.ImageSize(reference: $0.reference, size: RuntimeSizes.formatBytes($0.bytes)) }
            for image in sizes where RuntimeSizes.isFleetestImage(image.reference, prefix: prefix, relayRepository: RelayImage.repository) {
                report.imageLines.append("image \(image.reference) \(image.size)")
            }
        } else {
            report.failures.append("listing images failed (exit \(images.status)): \(images.tail(lines: 2))")
        }

        // ボリューム
        guard !volumes.isEmpty else { return report }
        if cli.isDocker {
            let usage = cli.run(commands.systemDiskUsageJSON)
            let sizes = usage.succeeded ? RuntimeSizes.dockerVolumeSizes(dfJSON: usage.output) : [:]
            if !usage.succeeded {
                report.failures.append("reading volume sizes failed (exit \(usage.status)): \(usage.tail(lines: 2))")
            }
            for name in volumes {
                report.volumeLines.append("volume \(name)" + (sizes[name].map { " \($0)" } ?? ""))
            }
        } else {
            for name in volumes {
                let inspected = cli.run(commands.volumeInspect(name))
                let size = inspected.succeeded
                    ? RuntimeSizes.appleVolumeSource(inspectJSON: inspected.output).flatMap(allocatedBytes).map(RuntimeSizes.formatBytes)
                    : nil
                report.volumeLines.append("volume \(name)" + (size.map { " \($0) allocated" } ?? ""))
            }
        }
        return report
    }

    /// スパースなファイルの実際の使用量(割り当て済みブロック)。読めなければ nil(大きさを言わない)
    static func fileAllocatedBytes(_ path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return values?.totalFileAllocatedSize.map(Int64.init)
    }
}
