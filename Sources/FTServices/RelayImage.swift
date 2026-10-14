// 中継とエコーのイメージの定義(docs/remote-runner.md §17「中継のコンテナ」)。純粋。
// 公式の alpine を digest で固定し、socat を版を指定して入れる(タグの付け替えで中身が変わらない)。

public enum RelayImage {
    /// Docker Hub の library/alpine 3.22 のインデックスの digest(arm64 / amd64 の両方を含む)。
    /// 版を上げるときにレジストリから取り直す。
    public static let baseImage = "docker.io/library/alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8"
    /// alpine 3.22 の main リポジトリの版。版を上げるときに APKINDEX で取り直す。
    public static let socatPackage = "socat=1.8.1.3-r0"

    public static var dockerfile: String {
        "FROM \(baseImage)\nRUN apk add --no-cache \(socatPackage)\nLABEL fleetest-relay=1\n"
    }

    /// 桁数: 12 桁の hex = 48 ビット。Dockerfile 1種類の版識別に足りる(ServicePlanner.prefix と同じ長さ)。
    private static let tagHexDigits = 12

    public static var tag: String {
        let hash = ServiceBuildFingerprint.compute(FingerprintInputs(files: [], dockerfileContents: dockerfile))
        return "fleetest-relay:" + hash.prefix(tagHexDigits)
    }
}
