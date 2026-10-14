import XCTest
@testable import FTServices

/// 大きさの読み取り。fixture は 2026-10-15 の実データ(Docker 29.5 / Apple Container 1.1.0)の形。
final class RuntimeSizesTests: XCTestCase {
    func testDockerImageListParsesRepositoryTagAndSize() {
        let output = "fleetest-relay:ec3bdcb0cd00\t15.6MB\nalpine:3.22\t13.4MB\nrancher/mirrored-library-traefik:3.7.13\t230MB\n\n"
        XCTAssertEqual(RuntimeSizes.dockerImageSizes(listOutput: output), [
            .init(reference: "fleetest-relay:ec3bdcb0cd00", size: "15.6MB"),
            .init(reference: "alpine:3.22", size: "13.4MB"),
            .init(reference: "rancher/mirrored-library-traefik:3.7.13", size: "230MB"),
        ])
        XCTAssertEqual(RuntimeSizes.dockerImageSizes(listOutput: "broken line\n"), [])
    }

    func testDockerVolumeSizesComeFromSystemDF() {
        let json = """
        {"Images":[{"Repository":"fleetest-relay","Size":"15.6MB","Tag":"ec3bdcb0cd00"}],"Containers":[],
         "Volumes":[{"Driver":"local","Links":"0","Name":"fleetest-probe-size","Size":"3.146MB"},{"Name":"other","Size":"0B"}],
         "BuildCache":[]}
        """
        XCTAssertEqual(RuntimeSizes.dockerVolumeSizes(dfJSON: json), ["fleetest-probe-size": "3.146MB", "other": "0B"])
        XCTAssertEqual(RuntimeSizes.dockerVolumeSizes(dfJSON: "not json"), [:])
    }

    func testAppleImageSizesSumTheVariants() {
        let json = """
        [{"configuration":{"name":"docker.io/library/busybox:latest","descriptor":{"size":9535}},"id":"fd7d",
          "variants":[{"platform":{"architecture":"arm64"},"size":4100000},{"platform":{"architecture":"amd64"},"size":4200000}]},
         {"configuration":{"name":"fleetest-relay:ec3bdcb0cd00"},"id":"e11b","variants":[{"size":15600000}]},
         {"id":"no-name"}]
        """
        let sizes = RuntimeSizes.appleImageSizes(listJSON: json)
        XCTAssertEqual(sizes.map(\.reference), ["docker.io/library/busybox:latest", "fleetest-relay:ec3bdcb0cd00"])
        XCTAssertEqual(sizes.map(\.bytes), [8_300_000, 15_600_000])
    }

    func testAppleVolumeSourceIsTheImageFile() {
        let json = """
        [{"configuration":{"driver":"local","format":"ext4","name":"fleetest-ab-pgdata","sizeInBytes":549755813888,
          "source":"/Users/u/Library/Application Support/com.apple.container/volumes/fleetest-ab-pgdata/volume.img"},"id":"fleetest-ab-pgdata"}]
        """
        XCTAssertEqual(RuntimeSizes.appleVolumeSource(inspectJSON: json),
                       "/Users/u/Library/Application Support/com.apple.container/volumes/fleetest-ab-pgdata/volume.img")
        XCTAssertNil(RuntimeSizes.appleVolumeSource(inspectJSON: "[]"))
    }

    func testOnlyBuiltAndRelayImagesCountAsFleetestMade() {
        let prefix = "fleetest-0123456789ab"
        XCTAssertTrue(RuntimeSizes.isFleetestImage("\(prefix)-server:build", prefix: prefix, relayRepository: "fleetest-relay"))
        XCTAssertTrue(RuntimeSizes.isFleetestImage("fleetest-relay:ec3bdcb0cd00", prefix: prefix, relayRepository: "fleetest-relay"))
        XCTAssertFalse(RuntimeSizes.isFleetestImage("postgres:16", prefix: prefix, relayRepository: "fleetest-relay"))
        XCTAssertFalse(RuntimeSizes.isFleetestImage("fleetest-ffffffffffff-db:build", prefix: prefix, relayRepository: "fleetest-relay"))
    }

    func testFormatBytesUsesSIUnitsWithOneDecimal() {
        XCTAssertEqual(RuntimeSizes.formatBytes(0), "0B")
        XCTAssertEqual(RuntimeSizes.formatBytes(999), "999B")
        XCTAssertEqual(RuntimeSizes.formatBytes(15_600_000), "15.6MB")
        XCTAssertEqual(RuntimeSizes.formatBytes(412_300_000), "412.3MB")
        XCTAssertEqual(RuntimeSizes.formatBytes(3_146_000), "3.1MB")
        XCTAssertEqual(RuntimeSizes.formatBytes(2_000_000_000_000), "2.0TB")
    }
}
