import XCTest
@testable import FTServices

final class RelayImageTests: XCTestCase {
    func testPinnedBaseImageAndPackage() {
        XCTAssertEqual(RelayImage.baseImage,
                       "docker.io/library/alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8")
        XCTAssertEqual(RelayImage.socatPackage, "socat=1.8.1.3-r0")
    }

    func testDockerfileContents() {
        XCTAssertEqual(RelayImage.dockerfile, """
            FROM docker.io/library/alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8
            RUN apk add --no-cache socat=1.8.1.3-r0
            LABEL fleetest-relay=1

            """)
    }

    func testTagIsDeterministicAndTwelveHexDigits() {
        XCTAssertEqual(RelayImage.tag, RelayImage.tag)
        let hex = RelayImage.tag.dropFirst("fleetest-relay:".count)
        XCTAssertTrue(RelayImage.tag.hasPrefix("fleetest-relay:"))
        XCTAssertEqual(hex.count, 12)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
