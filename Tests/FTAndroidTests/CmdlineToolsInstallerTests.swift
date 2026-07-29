// CmdlineToolsInstaller のうち、ネットワークとファイル配置を伴わない部分(リポジトリ XML から
// 当ホスト向けアーカイブを選ぶところ)のテスト。ここを間違えると x86_64 版を arm64 機へ入れる・
// checksum 未取得で検証を素通しする、という気付きにくい壊れ方をする。

import XCTest
@testable import FTAndroid

final class CmdlineToolsInstallerTests: XCTestCase {

    /// 実物(repository2-3.xml)と同じ構造を最小化したもの
    private func xml(includeArchArchives: Bool = true) -> Data {
        let archArchives = """
              <archive>
                <complete>
                  <size>156281494</size>
                  <checksum type="sha1">aaaa1111</checksum>
                  <url>commandlinetools-mac_x86_64-15859902_latest.zip</url>
                </complete>
                <host-os>macosx</host-os>
                <host-arch>x64</host-arch>
              </archive>
              <archive>
                <complete>
                  <size>156083281</size>
                  <checksum type="sha1">bbbb2222</checksum>
                  <url>commandlinetools-mac_arm64-15859902_latest.zip</url>
                </complete>
                <host-os>macosx</host-os>
                <host-arch>aarch64</host-arch>
              </archive>
        """
        let legacyArchive = """
              <archive>
                <complete>
                  <size>86521848</size>
                  <checksum type="sha1">cccc3333</checksum>
                  <url>commandlinetools-mac-6514223_latest.zip</url>
                </complete>
                <host-os>macosx</host-os>
              </archive>
        """
        return Data("""
        <?xml version="1.0" ?>
        <sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03">
          <remotePackage path="cmdline-tools;2.0">
            <revision><major>2</major><minor>0</minor></revision>
            <archives>
              <archive>
                <complete>
                  <size>1</size>
                  <checksum type="sha1">dddd4444</checksum>
                  <url>old.zip</url>
                </complete>
                <host-os>macosx</host-os>
              </archive>
            </archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;latest">
            <revision><major>22</major><minor>0</minor></revision>
            <display-name>Android SDK Command-line Tools (latest)</display-name>
            <archives>
              <archive>
                <complete>
                  <size>181833628</size>
                  <checksum type="sha1">eeee5555</checksum>
                  <url>commandlinetools-linux-15859902_latest.zip</url>
                </complete>
                <host-os>linux</host-os>
              </archive>
        \(includeArchArchives ? archArchives : legacyArchive)
            </archives>
          </remotePackage>
        </sdk:sdk-repository>
        """.utf8)
    }

    func testSelectsArchiveMatchingHostArch() throws {
        let archive = try CmdlineToolsInstaller.selectArchive(xml: xml(), hostArch: "aarch64")
        XCTAssertEqual(archive.url, "commandlinetools-mac_arm64-15859902_latest.zip")
        XCTAssertEqual(archive.sha1, "bbbb2222")
        XCTAssertEqual(archive.size, 156_083_281)
        XCTAssertEqual(archive.revision, "22.0")

        let intel = try CmdlineToolsInstaller.selectArchive(xml: xml(), hostArch: "x64")
        XCTAssertEqual(intel.url, "commandlinetools-mac_x86_64-15859902_latest.zip")
    }

    /// host-arch を持たない古い形式(mac 単一アーカイブ)へフォールバックする
    func testFallsBackToArchlessMacArchive() throws {
        let archive = try CmdlineToolsInstaller.selectArchive(
            xml: xml(includeArchArchives: false), hostArch: "aarch64")
        XCTAssertEqual(archive.url, "commandlinetools-mac-6514223_latest.zip")
        XCTAssertEqual(archive.sha1, "cccc3333")
    }

    /// cmdline-tools;2.0 など別バージョンの package を拾わない(latest だけを見る)
    func testIgnoresOtherPackages() throws {
        let archive = try CmdlineToolsInstaller.selectArchive(xml: xml(), hostArch: "aarch64")
        XCTAssertNotEqual(archive.url, "old.zip")
    }

    func testThrowsWhenPackageMissing() {
        let empty = Data("<?xml version=\"1.0\" ?><sdk:sdk-repository xmlns:sdk=\"x\"/>".utf8)
        XCTAssertThrowsError(try CmdlineToolsInstaller.selectArchive(xml: empty, hostArch: "aarch64"))
    }

    func testThrowsWhenNoMacArchive() {
        let linuxOnly = Data("""
        <?xml version="1.0" ?>
        <sdk:sdk-repository xmlns:sdk="x">
          <remotePackage path="cmdline-tools;latest">
            <revision><major>22</major><minor>0</minor></revision>
            <archives>
              <archive>
                <complete><size>1</size><checksum type="sha1">ffff</checksum><url>l.zip</url></complete>
                <host-os>linux</host-os>
              </archive>
            </archives>
          </remotePackage>
        </sdk:sdk-repository>
        """.utf8)
        XCTAssertThrowsError(try CmdlineToolsInstaller.selectArchive(xml: linuxOnly, hostArch: "aarch64"))
    }

    /// url はリポジトリ相対。ダウンロード先の絶対 URL に化けないこと
    func testAbsoluteURLResolvesAgainstRepository() throws {
        let archive = try CmdlineToolsInstaller.selectArchive(xml: xml(), hostArch: "aarch64")
        XCTAssertEqual(archive.absoluteURL.absoluteString,
                       "https://dl.google.com/android/repository/"
                       + "commandlinetools-mac_arm64-15859902_latest.zip")
    }
}
