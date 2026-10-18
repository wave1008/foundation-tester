// xctrace export の XML の読み手(id/ref の解決・sentinel・壊れた入力)。

import XCTest
@testable import FTCore

final class XctraceTableTests: XCTestCase {

    private func parse(_ xml: String) -> XctraceTable? { XctraceTable.parse(xml: Data(xml.utf8)) }

    private let header = """
        <?xml version="1.0"?>
        <trace-query-result><node xpath="x">
        <schema name="displayed-surfaces-interval">
          <col><mnemonic>start</mnemonic><name>Start</name><engineering-type>start-time</engineering-type></col>
          <col><mnemonic>duration</mnemonic><name>Duration</name><engineering-type>duration</engineering-type></col>
          <col><mnemonic>label</mnemonic><name>Label</name><engineering-type>string</engineering-type></col>
        </schema>
        """
    private let footer = "</node></trace-query-result>"

    func testReadsColumnsAndRows() throws {
        let table = try XCTUnwrap(parse(header + """
            <row><start-time id="1" fmt="00:00.100">100000000</start-time><duration id="2" fmt="5 ms">5000000</duration><string id="3" fmt="a">a</string></row>
            """ + footer))
        XCTAssertEqual(table.columns, ["start", "duration", "label"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0]["start"], XctraceTable.Cell(raw: "100000000", fmt: "00:00.100"))
        XCTAssertEqual(table.rows[0]["duration"]?.raw, "5000000")
    }

    func testRefReusesTheEarlierValueIncludingAcrossRows() throws {
        let table = try XCTUnwrap(parse(header + """
            <row><start-time id="1" fmt="f">100</start-time><duration id="2" fmt="d">7</duration><string id="3" fmt="s">x</string></row>
            <row><start-time id="4" fmt="g">200</start-time><duration ref="2"/><string ref="3"/></row>
            """ + footer))
        XCTAssertEqual(table.rows[1]["start"]?.raw, "200")
        XCTAssertEqual(table.rows[1]["duration"], XctraceTable.Cell(raw: "7", fmt: "d"))
        XCTAssertEqual(table.rows[1]["label"], XctraceTable.Cell(raw: "x", fmt: "s"))
    }

    func testSentinelIsNullAndKeepsColumnPositions() throws {
        let table = try XCTUnwrap(parse(header + """
            <row><start-time id="1">100</start-time><sentinel/><string id="3">z</string></row>
            """ + footer))
        XCTAssertNil(table.rows[0]["duration"])
        XCTAssertEqual(table.rows[0]["label"]?.raw, "z", "sentinel が列の位置をずらさない")
    }

    func testNestedElementIdsCanBeReferenced() throws {
        let table = try XCTUnwrap(parse(header + """
            <row><start-time id="1">1</start-time><duration id="2">2</duration><string id="3" fmt="outer">o<pid id="9" fmt="p">42</pid></string></row>
            <row><start-time id="4">3</start-time><duration ref="2"/><pid ref="9"/></row>
            """ + footer))
        XCTAssertEqual(table.rows[0]["label"]?.raw, "o", "複合値の本文に子の本文を含めない")
        XCTAssertEqual(table.rows[1]["label"], XctraceTable.Cell(raw: "42", fmt: "p"))
    }

    func testUnknownRefIsAnErrorNotANull() {
        XCTAssertNil(parse(header + "<row><start-time ref=\"99\"/><duration/><string/></row>" + footer))
    }

    func testMalformedXMLIsNilAndEmptyTableIsNotNil() {
        XCTAssertNil(parse("<trace-query-result><row>"))
        XCTAssertEqual(parse(header + footer)?.rows.count, 0)
    }

    func testTocDuration() {
        let toc = "<trace-toc><run number=\"1\"><info><summary><duration>12.5</duration></summary></info></run></trace-toc>"
        XCTAssertEqual(XctraceToc.durationSeconds(xml: Data(toc.utf8)), 12.5)
        XCTAssertNil(XctraceToc.durationSeconds(xml: Data("<trace-toc/>".utf8)))
        XCTAssertNil(XctraceToc.durationSeconds(xml: Data("<duration>abc</duration>".utf8)))
    }
}
