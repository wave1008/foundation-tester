import XCTest
@testable import ftester_mcp

/// デバイス選択プロパティの過不足を防ぐ。**「全ツールに付ける」ではなく「要るツールにだけ付ける」**
/// (2026-08-05 変更): 5つ × ツール数で定義全体の約4割を占めるため、デバイスに触らないツールに
/// 並べるとコンテキストを食うだけでなく「渡せば効く」と誤解させる。
/// 逆に**デバイス系から漏れると MCP クライアントから送れない**ので、両方向を検査する。
final class MCPServerToolDefinitionsTests: XCTestCase {
    private static let requiredDeviceKeys: Set<String> = ["platform", "port", "serial", "profile", "project"]

    /// デバイスを掴まないツール(driver(_:) を呼ばない)と、そこで**意味を持つ**選択プロパティ。
    /// 空 = 1つも宣言してはいけない。増減したらここも直す。
    /// ft_list_devices はプロファイルを読むだけ・ft_logs は adb とホストのファイルだけを見るので、
    /// 宛先を絞る引数は要るが port/serial/profile の全部は要らない
    private static let deviceFreeTools: [String: Set<String>] = [
        "ft_list_scenarios": [], "ft_dry_run": [], "ft_list_projects": [], "ft_doctor": [],
        "ft_dsl_commands": [],
        // 記録済みの操作列から下書きを組むだけ = デバイスに触らない
        "ft_draft_scenario": [],
        "ft_list_devices": ["platform", "profile"],
        "ft_logs": ["platform", "serial"],
    ]

    func testDeviceToolsDeclareDeviceSelectionProperties() {
        for definition in MCPServer.toolDefinitions {
            let name = definition["name"] as? String ?? "(unnamed)"
            guard let schema = definition["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else {
                XCTFail("\(name): inputSchema.properties がありません")
                continue
            }
            if let allowed = Self.deviceFreeTools[name] {
                let declared = Self.requiredDeviceKeys.subtracting(["project"])
                    .intersection(properties.keys)
                XCTAssertEqual(declared, allowed,
                               "\(name) の選択プロパティが許可集合と違う: 宣言 \(declared.sorted())"
                                + " / 許可 \(allowed.sorted())")
                continue
            }
            let missing = Self.requiredDeviceKeys.subtracting(properties.keys)
            XCTAssertTrue(missing.isEmpty, "\(name) にデバイス選択プロパティが不足: \(missing.sorted())")
        }
    }

    func testToolDefinitionsIsNonEmpty() {
        XCTAssertFalse(MCPServer.toolDefinitions.isEmpty)
    }

    /// **snapshotAfter を持つツールは interactiveOnly/expandBulk も持つ**(2026-08-10):
    /// `snapshotAfterBody` は `snapshotBody` を経由するので、args を渡せば元々効いていた
    /// (`snapshotBody` が `args["interactiveOnly"]`/`args["expandBulk"]` を読む) —— スキーマに
    /// 無いだけで MCP クライアントから渡す術が無かった。2026-08-10 の語彙統一で
    /// 操作系の全ツール(tap/type/drag/swipe/double_tap/press/pinch/navigate/open_url)が対象
    /// (ft_scroll_to/ft_snapshot は別途宣言済み)
    func testSnapshotAfterToolsDeclareTheSameFoldingPropertiesAsSnapshot() {
        func properties(_ name: String) -> [String: Any] {
            let definition = MCPServer.toolDefinitions.first { $0["name"] as? String == name }
            let schema = definition?["inputSchema"] as? [String: Any]
            return schema?["properties"] as? [String: Any] ?? [:]
        }
        let snapshotToolNames = MCPServer.toolDefinitions.filter {
            ($0["inputSchema"] as? [String: Any])
                .flatMap { $0["properties"] as? [String: Any] }?["snapshotAfter"] != nil
        }.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(snapshotToolNames),
                       ["ft_tap", "ft_type", "ft_drag", "ft_swipe", "ft_double_tap",
                        "ft_press", "ft_pinch", "ft_navigate", "ft_open_url"],
                       "snapshotAfter を持つツールの集合が変わった場合はこのテストごと見直すこと")
        for name in snapshotToolNames {
            let props = properties(name)
            XCTAssertNotNil(props["expandBulk"], "\(name) に expandBulk が無い")
            XCTAssertNotNil(props["interactiveOnly"], "\(name) に interactiveOnly が無い")
        }
    }

    /// **実挙動と食い違わない**(2026-08-10): iOS の system app(Maps 等)は前回のUI状態を
    /// 復元して起動することがあるので、「1画面目から再開する」と言い切らない
    func testLaunchDescriptionDoesNotPromiseTheFirstScreen() {
        let description = MCPServer.toolDefinitions
            .first { $0["name"] as? String == "ft_launch" }?["description"] as? String
        XCTAssertNotNil(description)
        XCTAssertFalse(description?.contains("restarts from the first screen") ?? true,
                       description ?? "")
        XCTAssertTrue(description?.contains("ft_snapshot") ?? false, description ?? "")
    }

    /// **ft_scroll_to は ft_snapshot と同じ畳み方の引数を持つ**(2026-08-10): 最後の render
    /// 呼び出しだけが collapsingBulk: true 固定で interactiveOnly を渡していなかった —— スキーマに
    /// 無ければ MCP クライアントから渡す術が無いので、まずここで漏れを防ぐ
    func testScrollToDeclaresTheSameFoldingPropertiesAsSnapshot() {
        func properties(_ name: String) -> [String: Any] {
            let definition = MCPServer.toolDefinitions.first { $0["name"] as? String == name }
            let schema = definition?["inputSchema"] as? [String: Any]
            return schema?["properties"] as? [String: Any] ?? [:]
        }
        let snapshotProps = properties("ft_snapshot")
        let scrollToProps = properties("ft_scroll_to")
        for key in ["expandBulk", "interactiveOnly"] {
            XCTAssertNotNil(scrollToProps[key], "ft_scroll_to に \(key) が無い")
            XCTAssertNotNil(snapshotProps[key], "ft_snapshot に \(key) が無い")
        }
    }

    // MARK: - 引用符剥がし対象キーの同期(2026-08-12)

    /// スキーマ全体を走査し、「a||b」(DSL のセレクタ構文表記に必ず出る記号)を含む説明文を持つ
    /// string 系プロパティのキー集合を返す。**マーカーはこの記号1つだけ** —— 現状のスキーマでは
    /// selector/waitFor/scrollFrame の3キーの説明文だけがこれを含む
    private func selectorSyntaxMarkedKeys(in definitions: [[String: Any]]) -> Set<String> {
        var keys: Set<String> = []
        for definition in definitions {
            guard let schema = definition["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else { continue }
            for (key, value) in properties {
                guard let property = value as? [String: Any],
                      let description = property["description"] as? String,
                      description.contains("a||b") else { continue }
                keys.insert(key)
            }
        }
        return keys
    }

    /// **現3キーで通ること**: セレクタ構文を謳う引数は必ず引用符剥がし
    /// (`MCPServer.selectorQuoteStrippedKeys`)の対象に含まれる。将来セレクタ引数を追加して
    /// 説明文に同じ表記を書いたのに剥がしリストへ足し忘れたら、ここが検出する
    func testSelectorSyntaxMarkedPropertiesAreAllQuoteStripped() {
        let marked = selectorSyntaxMarkedKeys(in: MCPServer.toolDefinitions)
        XCTAssertEqual(marked, Set(MCPServer.selectorQuoteStrippedKeys),
                       "selector syntax marker (a||b) is on \(marked.sorted()), but the quote-"
                        + "stripping list is \(MCPServer.selectorQuoteStrippedKeys.sorted())"
                        + " — keep them in sync")
    }

    /// **リストから1つ消すと落ちること**(陰性対照): 「常に一致する」変異(比較そのものを
    /// 無力化する類)ではないことを、実際に1本欠けたリストで不一致になることで確かめる
    func testSelectorSyntaxMarkerCatchesAKeyMissingFromTheStripList() {
        let marked = selectorSyntaxMarkedKeys(in: MCPServer.toolDefinitions)
        let missingOne = Set(MCPServer.selectorQuoteStrippedKeys.dropFirst())
        XCTAssertNotEqual(marked, missingOne,
                          "この対照は剥がしリストが1本欠けても検出できることを示すためのもの —"
                            + " marked と missingOne が一致してしまうなら本検査は無力")
    }
}

final class MCPServerDriverCacheKeyTests: XCTestCase {
    func testDirectKeyDiffersByPort() {
        let a = MCPServer.driverCacheKey(platform: "ios", port: 8123, serial: nil)
        let b = MCPServer.driverCacheKey(platform: "ios", port: 8124, serial: nil)
        XCTAssertNotEqual(a, b)
    }

    func testDirectKeyDiffersBySerial() {
        let a = MCPServer.driverCacheKey(platform: "android", port: nil, serial: "AAA")
        let b = MCPServer.driverCacheKey(platform: "android", port: nil, serial: "BBB")
        XCTAssertNotEqual(a, b)
    }

    func testProfileKeyDiffersByProfileName() {
        let a = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: nil)
        let b = MCPServer.driverCacheKey(profile: "device-b", project: "E2E", platform: nil)
        XCTAssertNotEqual(a, b)
    }

    func testProfileKeyDiffersByProject() {
        let a = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: nil)
        let b = MCPServer.driverCacheKey(profile: "device-a", project: "SampleApp", platform: nil)
        XCTAssertNotEqual(a, b)
    }

    func testProfileKeyNeverCollidesWithDirectKey() {
        let direct = MCPServer.driverCacheKey(platform: "ios", port: 8123, serial: nil)
        let profile = MCPServer.driverCacheKey(profile: "device-a", project: nil, platform: "ios")
        XCTAssertNotEqual(direct, profile)
    }

    func testSameInputsProduceSameKey() {
        let a = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: "ios")
        let b = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: "ios")
        XCTAssertEqual(a, b)
    }
}

/// 整数を受ける引数の**全数振り分け**(2026-08-13)。`ref` を受ける引数の見落としは
/// 2026-08-13 の1日で3度起きた(`ref` → `fromRef` → `scrollFrame`)。綴りの類似では
/// 判定できない(`scrollFrame` は名前から ref だと分からない)ので、
/// **スキーマ側の「整数を受ける引数」を ref 系と非 ref 系へ全部振り分けて等号照合**する ——
/// 新しい整数引数を足したらどちらかに入れることになり、黙って穴が開かない。
final class MCPServerIntegerArgumentPartitionTests: XCTestCase {

    /// `"type": "integer"` と `"type": ["string", "integer"]` の**両方**を拾う。
    /// 後者を取りこぼしたのが `scrollFrame` の見落としの直接の原因だった
    private func integerArgumentNames() -> Set<String> {
        var names: Set<String> = []
        for definition in MCPServer.toolDefinitions {
            guard let schema = definition["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else { continue }
            for (name, value) in properties {
                guard let property = value as? [String: Any] else { continue }
                let accepts: Bool
                if let single = property["type"] as? String { accepts = single == "integer" }
                else if let many = property["type"] as? [String] { accepts = many.contains("integer") }
                else { accepts = false }
                if accepts { names.insert(name) }
            }
        }
        return names
    }

    func testEveryIntegerArgumentIsClassifiedAsRefOrNotRef() {
        let declared = integerArgumentNames()
        let classified = Set(MCPServer.refBearingKeys).union(MCPServer.nonRefIntegerKeys)
        XCTAssertFalse(declared.isEmpty, "スキーマ走査が空振りしている(穴を検出できない)")
        XCTAssertEqual(declared, classified,
                       "整数を受ける引数の振り分けがスキーマと食い違っている"
                       + "(未分類: \(declared.subtracting(classified).sorted()) /"
                       + " 実在しない: \(classified.subtracting(declared).sorted()))。"
                       + "ref を受けるなら refBearingKeys へ —— 入れ忘れると、その引数の"
                       + "呼び出しだけ機の同一性が確認されない")
    }

    /// **走査が配列型を拾えること**の陰性対照(`scrollFrame` を取りこぼした形の再発防止)
    func testTheScanSeesArrayTypedIntegerArguments() {
        XCTAssertTrue(integerArgumentNames().contains("scrollFrame"),
                      "`[\"string\", \"integer\"]` 形の宣言を走査が拾えていない")
    }

    /// `ft_batch` の先頭 ref は綴りの揺れを許して拾う(パーサが `ref : 12` を受理する)
    func testBatchStepRefDetectionToleratesSpacing() {
        // **ガード本体(usesRememberedDeviceState)越しに見る** —— 補助関数を直に叩くと、
        // 「呼び出し側を素朴な contains へ戻す」変異が届かない
        XCTAssertTrue(MCPServer.usesRememberedDeviceState(["steps": "tap ref: 12"]))
        XCTAssertTrue(MCPServer.usesRememberedDeviceState(["steps": "tap ref : 12"]),
                      "パーサが受理する `ref : 12` の綴りで確認を飛ばしている")
        XCTAssertTrue(MCPServer.usesRememberedDeviceState(["steps": "tap ref  :12; type '#f' 'x'"]))
        XCTAssertFalse(MCPServer.usesRememberedDeviceState(["steps": "tap '#btn'; type '#f' 'x'"]))
        XCTAssertFalse(MCPServer.usesRememberedDeviceState(["steps": "tap '#refresh'"]))
    }
}
