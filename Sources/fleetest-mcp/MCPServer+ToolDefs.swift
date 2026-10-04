// MCPServer+ToolDefs.swift
// ツール定義(スキーマ)とサーバ説明文。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    // MARK: - ツール定義

    // **繰り返し載る説明は短文+詳細は serverInstructions**: 共通引数は約25本、
    // snapshotAfter 系は13本のツールへ複製されるので、1文字が十数倍の費用になる(毎セッションの
    // コンテキスト)。ニュアンスを足したくなったら serverInstructions 側へ(initialize で1回だけ渡る)
    // 以下の JSON スキーマ定数は起動時に1回だけ組み立てる不変リテラル(以後だれも変更しない)なので nonisolated(unsafe)
    nonisolated(unsafe) static let platformProperty: [String: Any] = [
        "type": "string", "enum": ["ios", "android"], "description": "default ios",
    ]
    nonisolated(unsafe) static let portProperty: [String: Any] = [
        "type": "integer", "description": "iOS bridge port",
    ]
    nonisolated(unsafe) static let serialProperty: [String: Any] = [
        "type": "string", "description": "Android device serial",
    ]
    nonisolated(unsafe) static let profileProperty: [String: Any] = [
        "type": "string", "description": "Run profile name (profiles/runs/)",
    ]
    nonisolated(unsafe) static let projectProperty: [String: Any] = [
        "type": "string", "description": "Test project name",
    ]
    nonisolated(unsafe) static let udidProperty: [String: Any] = [
        "type": "string", "description": "iOS device UDID (from ft_list_devices)",
    ]
    /// 操作系ツールの「結果の木も一緒に返す」スイッチ。**撮り直し不要と言い切る**(言わないと
    /// 読み手は木を受け取ったうえで習慣的に ft_snapshot を撃つ)
    nonisolated(unsafe) static let snapshotAfterProperty: [String: Any] = [
        "type": "boolean",
        "description": "Append the resulting tree — no follow-up ft_snapshot needed",
    ]
    /// 操作系ツールが共有する waitFor/waitSeconds(ft_snapshot と同じ待ちのロジックを流用。
    /// snapshotAfterBody 参照)。**snapshotAfter: true と併用が前提** — 無いときは操作は
    /// 実行したうえで note だけ返す(throw しない。操作自体は成功しているため)。
    /// **説明に `a||b` を残す**(`selectorQuoteStrippedKeys` との同期テストの印)
    nonisolated(unsafe) static let snapshotAfterWaitForProperty: [String: Any] = [
        "type": "string",
        "description": "Needs snapshotAfter. Selector to wait for on the result (#id, label, .type, a||b)",
    ]
    nonisolated(unsafe) static let snapshotAfterWaitSecondsProperty: [String: Any] = [
        "type": "number", "description": "Max wait for waitFor/waitForChange (default \(number(defaultWaitSeconds)))",
    ]
    /// **「何かが変わる」を待つ**: 再検索のように**同じセレクタのまま中身だけ入れ替わる**画面では
    /// waitFor が古い結果に即マッチして待ちにならない(実測: Google マップの経路再検索で
    /// `waitFor "*IC 運賃*"` が旧結果へ当たった)。waitFor とは排他(待つ理由が違う)
    nonisolated(unsafe) static let snapshotAfterWaitForChangeProperty: [String: Any] = [
        "type": "boolean",
        "description": "Needs snapshotAfter; not with waitFor. Wait until the tree differs from "
            + "before the action (screens that refresh in place)",
    ]
    /// ft_snapshot と操作系が共有する木の畳み方(2つ目の定義を作らない)。
    /// どのツールでも既定は畳む・隠さないなので、説明文もそのまま通用する
    nonisolated(unsafe) static let expandBulkProperty: [String: Any] = [
        "type": "boolean", "description": "Unfold groups of 20+ same-id elements (folded by default)",
    ]
    nonisolated(unsafe) static let interactiveOnlyProperty: [String: Any] = [
        "type": "boolean", "description": "Hide layout-only lines (refs unchanged; hidden ones stay tappable by ref)",
    ]
    /// 木を返すツールの畳み方2つ
    nonisolated(unsafe) static let foldingProperties: [String: Any] = [
        "expandBulk": expandBulkProperty,
        "interactiveOnly": interactiveOnlyProperty,
    ]
    /// 操作系ツールの snapshotAfter 一式。`waitForChange: false` は ft_launch 用 —— 起動前の木
    /// (前のアプリか、同じ画面へ戻る再起動)と比べても「着地した」とは言えず、同じ画面へ戻る
    /// 再起動では締め切りまで待つだけになる
    static func afterActionProperties(waitForChange: Bool = true) -> [String: Any] {
        var props = foldingProperties
        props["snapshotAfter"] = snapshotAfterProperty
        props["waitFor"] = snapshotAfterWaitForProperty
        props["waitSeconds"] = snapshotAfterWaitSecondsProperty
        if waitForChange { props["waitForChange"] = snapshotAfterWaitForChangeProperty }
        return props
    }
    nonisolated(unsafe) static let refProperty: [String: Any] = ["type": "integer", "description": "ft_snapshot ref"]
    nonisolated(unsafe) static let pointXProperty: [String: Any] = ["type": "number", "description": "ft_snapshot coordinates"]
    nonisolated(unsafe) static let pointYProperty: [String: Any] = ["type": "number", "description": "ft_snapshot coordinates"]
    nonisolated(unsafe) static let bundleIdProperty: [String: Any] = [
        "type": "string", "description": "bundle ID (iOS) / package name (Android)",
    ]
    nonisolated(unsafe) static let lastLaunchedBundleIdProperty: [String: Any] = [
        "type": "string",
        "description": "bundle ID (iOS) / package name (Android). Default: the last ft_launch",
    ]
    nonisolated(unsafe) static let scenarioIdProperty: [String: Any] = [
        "type": "string", "description": "Scenario ID (Class.method; see ft_list_scenarios) or a class name",
    ]
    nonisolated(unsafe) static let defaultProjectProperty: [String: Any] = [
        "type": "string", "description": "Test project name (default: the default project)",
    ]
    nonisolated(unsafe) static let skipBuildProperty: [String: Any] = ["type": "boolean", "description": "Skip the swift build"]
    nonisolated(unsafe) static let runPidProperty: [String: Any] = [
        "type": "integer", "description": "pid from ft_start_run (default: the latest)",
    ]
    /// **ft_snapshot にだけ置く**(操作系や scroll_to は木を何度も撮るので、1回限りの指定が
    /// どの取得に効いたのか読み手に説明できない)。上限に当たった応答の注記がこの引数を名指しする
    nonisolated(unsafe) static let maxElementsProperty: [String: Any] = [
        "type": "integer",
        "description": "Element limit for THIS read only (default \(BridgeAPI.maxSnapshotElements),"
            + " max \(BridgeAPI.maxSnapshotElementsCeiling)). Raise it when a note says the limit"
            + " dropped elements — scrolling will never bring them back",
    ]
    /// press/drag/pinch が共有する秒数上限の上書き口(既定 `BridgeAPI.defaultMaxGestureSeconds`・
    /// 最大 `BridgeAPI.gestureSecondsCeiling`)
    nonisolated(unsafe) static let maxGestureSecondsProperty: [String: Any] = [
        "type": "number",
        "description": "Raise the \(Int(BridgeAPI.defaultMaxGestureSeconds))s cap on duration/hold"
            + " for THIS call (max \(Int(BridgeAPI.gestureSecondsCeiling))s)",
    ]
    /// 共通引数の詳細。**各ツールのプロパティ説明は短文に留め、ニュアンスはここに1本化する**
    /// (initialize の instructions で1回だけ渡る。プロパティ側に書くと全ツールへ複製され、
    /// 毎セッションのコンテキスト費用になる)
    static let serverInstructions = """
        Common arguments accepted by every ft_* device tool: platform (default ios) / project / \
        profile (profiles/runs/<name>; same device and engine as ft_run_scenario) / \
        udid (iOS simulator or physical device, as printed by ft_list_devices — resolved to the bridge running on \
        it; a device with no bridge cannot be driven and says so; if port is also given the two \
        must agree) / serial (Android device) / port (iOS bridge port; default: the running \
        bridge. An in-app bridge answers only while the app it is injected into is frontmost — \
        driving another app, or a system app such as Maps, needs the device's xcuitest bridge \
        port) / allowVersionSkew (off by default: a stale bridge answers with its own \
        version's behaviour and notes, so selectors written from them are silently wrong; every \
        skewed response carries a warning). Once a call explicitly gives udid/port (iOS) or \
        serial (Android), this server process remembers it for its lifetime: a later call that \
        omits udid, port, AND serial entirely defaults to that same device. Giving udid/port or \
        serial again on a later call overrides the memory for that call and replaces it. \
        That default only applies while the target is unambiguous: once this session has driven \
        a second device (or both platforms, with platform omitted too), a call that names no \
        target is refused with the candidates listed instead of being sent to the most recent \
        one — running against the wrong device changes its real state, which no retry undoes.

        Coordinates (x/y and frames) are always in ft_snapshot units — iOS=pt / Android=px — never \
        screenshot pixels. Selector arguments use the DSL syntax: #id, a label, .type, a||b; quotes \
        wrapped around the whole selector are stripped.

        Tree options on tools that return an element list: expandBulk unfolds groups of 20+ \
        non-interactive leaves sharing one id (map pins and the like) that are folded into one \
        line plus a label/ref index by default — turn it on when you need their frames. \
        interactiveOnly hides layout-only lines (no label/value, neither operable nor a scroll \
        container) — typically half to two thirds of a dense screen; refs and frames of the \
        remaining lines are unchanged, and the notes above the tree are computed from the full \
        tree either way.

        Operation tools take snapshotAfter to append the resulting screen's tree: it is read \
        right after the action, and if it looks identical to the tree before the action (a \
        likely sign a transition has not finished) it is re-read once after a short wait. If an \
        animation is still running after that, pass waitFor (a selector to wait for on the \
        resulting screen) instead of repeating the action. On a screen that refreshes in place \
        (a re-run search, a pull-to-refresh) waitFor matches the OLD content immediately and does \
        not wait — pass waitForChange: true there instead. waitForChange means "something \
        changed", not "the final content arrived": a screen that first shows a loading or empty \
        intermediate (a search still fetching) satisfies it early — the response notes when the \
        difference was already on the first read, and only checking for the expected content \
        guarantees it is there. Both waits run to waitSeconds (default \(number(defaultWaitSeconds))s; the same name as the DSL's \
        waitSeconds:) when they miss — pass a smaller waitSeconds on a wait you expect to miss, a larger \
        one for a slow load. \
        snapshotAfter and ft_scroll_to inherit interactiveOnly/expandBulk from your last \
        ft_snapshot call unless passed explicitly, and say so when they do.

        Once you can name the next few steps by selector — typically right after reading a tree \
        — ft_batch runs them in one call and one approval, and a batch that passes converts 1:1 \
        into scenario lines, so it doubles as the check that the sequence is writable. It is not \
        the tool for finding your way: every step after the first must use a selector rather than \
        a ref, assertions and lifecycle commands (launchApp, clearAppData, …) are rejected, and \
        the run stops at the first failure. Explore with the single-operation tools, then batch \
        the part you have already worked out.
        """

    /// 全ツール共通のデバイス選択プロパティ。tool() が無条件で足す
    nonisolated(unsafe) static let commonDeviceProperties: [(String, [String: Any])] = [
        ("platform", platformProperty),
        ("port", portProperty),
        ("serial", serialProperty),
        ("profile", profileProperty),
        ("project", projectProperty),
        ("allowVersionSkew", allowVersionSkewProperty),
        ("udid", udidProperty),
    ]

    /// 版ズレの押し通し(G-3)。**押し通した回の応答には毎回警告が付く**ことまで書く ——
    /// 「一度断られたから付けておく」という使い方をされると、拒否そのものが無意味になる
    nonisolated(unsafe) static let allowVersionSkewProperty: [String: Any] = [
        "type": "boolean",
        "description": "Proceed despite a bridge version mismatch (every reply warns)",
    ]

    /// ft_screenshot の既定。**費用は画素数で決まる**(バイト数ではない) —— 平坦な UI では
    /// 原寸 PNG のほうが JPEG より小さいことすらあるので、バイト比較で選ぶと逆に損をする。
    /// 600 は実測で決めた: iPhone 17 Pro(1179px)の E2E 画面で CJK 本文もステータスバーも読め、
    /// 画素は 1/2.4。地図のような密な画面はこれでは潰れうるので maxWidth / fullSize で逃がす
    static let screenshotMaxWidth = 600
    static let screenshotQuality = 0.6

    /// ft_long_press の既定の押下秒数。**DSL に対応する既定は無い**(`tap(holdSeconds:)` の既定は 0、
    /// `hold()` は 3)。OS の長押し判定(iOS・Android とも約 0.5 秒)を確実に越える値。
    /// 下書きには毎回明示で残るので、この値を変えても既存の下書きの意味は変わらない
    static let defaultLongPressHoldSeconds: Double = 1.0
    /// ft_logs の既定の遡り秒数と行数(Android の logcat)。5分 = いま見た落ち方を含む幅・
    /// 100 行 = 応答に載せて読める量。足りなければ呼び手が sinceSeconds / lines で広げる
    static let logsDefaultSinceSeconds = 300
    static let logsDefaultLines = 100

    /// 説明文へ既定値を埋めるときの表記(2.0 → "2"・0.5 → "0.5")。**説明の既定値は定数から作る**
    /// (リテラルで書くと定数を変えた日に説明だけが古い値を言い続ける)
    static func number(_ value: Double) -> String { String(format: "%g", value) }

    nonisolated(unsafe) static let toolDefinitions: [[String: Any]] = [
        tool("ft_status", "Check the device/bridge connection state", [:]),
        tool("ft_list_devices", "List the devices this Mac can drive (simulators, emulators, physical) "
            + "with the udid/serial other tools take. Works before any profile exists (lists what is "
            + "booted or connected). profile: only that run profile's devices — ones on another "
            + "machine are named but not listed", [
            "platform": ["type": "string", "enum": ["ios", "android"],
                         "description": "Only this platform (default: both)"],
            "profile": profileProperty,
        ], scope: .project),
        tool("ft_list_apps", "List installed apps, to find the bundle ID / package name ft_launch takes. "
            + "User apps only by default — Maps, browsers and other preinstalled apps are system apps: "
            + "use filter or includeSystem", [
            "filter": ["type": "string", "description": "Bundle ID or display name contains this "
                + "(case-insensitive); also searches system apps unless includeSystem: false"],
            "includeSystem": ["type": "boolean", "description": "Also list system apps, marked "
                + "[system] (display names are iOS-only)"],
        ]),
        tool("ft_logs", "Read why the app died. iOS: the crash report summary and .ips path (no runtime "
            + "log, so a running app yields nothing). Android: recent logcat. Never contacts the bridge, "
            + "so it works after a crash killed it. A physical iPhone keeps its reports on the device — "
            + "pass udid or port (or have driven it this session) so it says so instead of reporting no crash", [
            "bundleId": lastLaunchedBundleIdProperty,
            "platform": platformProperty,
            "serial": serialProperty,
            "udid": ["type": "string", "description": "iOS device UDID — resolved without the bridge "
                + "(works after it died); narrows a simulator's reports to it"],
            "port": ["type": "integer", "description": "iOS bridge port the device had — read "
                + "without contacting it"],
            "lines": ["type": "integer", "description": "Android: recent lines to return (default \(logsDefaultLines))"],
            "sinceSeconds": ["type": "integer", "description": "How far back to look (default \(logsDefaultSinceSeconds))"],
            "all": ["type": "boolean", "description": "Android: read the main buffer too, not just crashes"],
        ], scope: .none),
        tool("ft_install", "Install a package (iOS: .app / Android: .apk, or .apks via bundletool)", [
            "packagePath": ["type": "string", "description": "Absolute path"],
        ], required: ["packagePath"]),
        tool("ft_launch", "Launch the app, terminating it first if running. Apps (Maps etc.) may restore "
            + "their previous UI, so do not assume the first screen — check with ft_snapshot, or pass "
            + "snapshotAfter + waitFor an element only the expected screen has (right after launch can "
            + "still be the splash). iOS: com.apple.springboard attaches to the home screen without "
            + "launching — use it to read the home screen or a system dialog", [
            "bundleId": bundleIdProperty,
            "resume": ["type": "boolean", "description": "Bring it to front WITHOUT terminating (state "
                + "kept). xcuitest engine or Android only — refused on inapp/hybrid, which would relaunch"],
        ], extra: afterActionProperties(waitForChange: false), required: ["bundleId"]),
        tool("ft_open_url", "Deliver a URL/deep link WITHOUT restarting the app (unlike ft_launch); the "
            + "destination is pushed over the current screen. Delivery is async, so snapshotAfter waits "
            + "for a change before reading (waitFor for a specific destination, waitForChange: false to "
            + "read immediately)", [
            "url": ["type": "string", "description": "URL / deep link"],
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (the Android "
                + "intent target). Default: the last ft_launch"],
        ], extra: afterActionProperties(), required: ["url"]),
        tool("ft_snapshot", "Get the current screen's element list. Line: [ref] Type \"label\" id=... (x,y WxH); "
            + "lines marked scroll are containers usable as scrollFrame. Use refs for tap/type. "
            + "waitFor polls for you", [
            "waitFor": ["type": "string", "description": "Wait until this selector is on screen (#id, label, .type, a||b)"],
            "waitSeconds": ["type": "number", "description": "Max wait for waitFor (default \(number(defaultWaitSeconds)))"],
            "maxElements": maxElementsProperty,
        ], extra: foldingProperties),
        tool("ft_tap", "Tap an element (ref) or a point (x,y). A ref is re-checked against a fresh tree: "
            + "moved → retargeted, gone → refused, scroll leftover → tapped with a warning. " + coordinateCaveat, [
            "ref": refProperty, "x": pointXProperty, "y": pointYProperty,
        ], extra: afterActionProperties()),
        tool("ft_type", "Type text; with ref it taps the field and waits for focus. APPENDS by default — "
            + "replace: true (or ft_clear_input) to replace. Typing never closes the keyboard; Enter "
            + "usually does on UIKit/SwiftUI but not on Compose/Flutter — do not retry pressEnter to close it", [
            "text": ["type": "string", "description": "Omit to fire Enter only"],
            "pressEnter": ["type": "boolean", "description": "Fire the Enter/IME action (search, submit)"],
            "ref": ["type": "integer", "description": "Input field ref (default: the focused element)"],
            // **値段と、二重払いの避け方まで書く**: replace は素の type の
            // 約2倍かかる(実測 6.1s 対 2.3s)。内訳は clear の1往復と、**打った結果の読み返し**
            // (in-app iOS は clear/type の成否を検証せず YES を返すので、読み返さないと
            // 「replaced」が嘘になる)。snapshotAfter を付ければその1枚と共有する
            "replace": ["type": "boolean", "description": "Clear before typing. Costs a clear plus a "
                + "verifying read-back — with snapshotAfter (no pressEnter) that read is shared, so "
                + "prefer it over a separate ft_snapshot"],
        ], extra: afterActionProperties()),
        // **引数名が「指の向き」と言い切っていること**: 隣の ft_scroll_to の `direction` はコンテンツの向きで
        // 意味が逆。説明を遅延ロードするクライアントは名前だけで書くので、同じ名前にしない
        tool("ft_swipe", "Swipe one screenful by finger direction (finger up = content scrolls down). "
            + "To reach an element use ft_scroll_to — it stops on it and returns fresh refs", [
            "finger": ["type": "string", "enum": ["up", "down", "left", "right"],
                       "description": "Finger direction (as the DSL's swipe) — the opposite of "
                           + "ft_scroll_to's direction, which names where the content goes"],
            "scrollFrame": ["type": ["string", "integer"],
                            "description": "Swipe inside this container instead of the whole screen: "
                                + "a selector (#id, label, .type, a||b) of a line marked scroll, or any "
                                + "ft_snapshot ref with a non-zero frame (e.g. a chip row interactiveOnly "
                                + "hides). Use it when there is nothing to ft_scroll_to (a horizontal "
                                + "table) or several scroll areas. An area absent from the tree (a web "
                                + "page's inner scroller) will not move — use ft_drag"],
        ], extra: afterActionProperties(), required: ["finger"]),
        tool("ft_scroll_to", "Scroll until a selector is on screen and return the fresh tree — the DSL's "
            + "scrollTo search (settling, container-sized steps, overshoot recovery). Use it instead of "
            + "repeating ft_swipe + ft_snapshot", [
            "selector": ["type": "string", "description": "#id, label, .type, a||b (write a label bare)"],
            "direction": ["type": "string", "enum": ["down", "up", "right", "left"],
                          "description": "Content direction to read towards (default down)"],
            "scrollFrame": ["type": ["string", "integer"],
                            "description": "Container to search inside when the screen has several "
                                + "scroll areas: a selector (#id, label, .type, a||b) of a line marked "
                                + "scroll, or any ft_snapshot ref with a non-zero frame (use a ref when "
                                + "the id is missing or duplicated, or for a row interactiveOnly hides)"],
            "maxSwipes": ["type": "integer", "description": "Swipe limit (default \(FlowStep.defaultMaxSwipes))"],
        ], extra: foldingProperties, required: ["selector"]),
        tool("ft_batch", "Run several operation/scroll DSL steps in one approval, stopping at the first "
            + "failure; replies with the screen after the last step. Arguments are quoted and "
            + "space-separated, no parentheses or commas: type '#field' 'abc'; scrollTo '#item' "
            + "direction: .down (argument names as ft_dsl_commands prints). A passing batch converts "
            + "1:1 into scenario lines. Lifecycle/data-wiping commands and assertions are rejected. "
            + "Only the FIRST step may use ref: N (re-checked, then converted to its selector; refused "
            + "when no unique selector exists — ft_tap it instead); later steps need selectors, since "
            + "an earlier step can make a ref stale", [
            "steps": ["type": "string",
                      "description": "Up to \(batchStepLimit) DSL lines separated by ';' or newlines, "
                        + "e.g. \"tap ref: 12; type '#field' 'batch'\""],
        ], extra: foldingProperties, required: ["steps"]),
        tool("ft_rotate", "Rotate the device and return the settled tree in the new orientation (new "
            + "coordinates; earlier refs no longer resolve; a note says if settling was not confirmed). "
            + "Android: turns auto-rotate off; rotating back to portrait restores it, but only on this "
            + "same connection", [
            "orientation": ["type": "string", "enum": ["portrait", "landscape"]],
        ], required: ["orientation"]),
        tool("ft_navigate", "Go back / to the home screen / to the app switcher", [
            "target": ["type": "string", "enum": ["back", "home", "appSwitcher"]],
        ], extra: afterActionProperties(), required: ["target"]),
        tool("ft_hide_keyboard", "Close the soft keyboard. Android only (sends back only while the "
            + "keyboard is up, then waits until the tree stops reporting it). Refused on iOS — "
            + "ft_type pressEnter: true closes a single-line field's keyboard",
            afterActionProperties()),
        tool("ft_clear_app_data", "Wipe the app's data and permissions; stops the app (ft_launch after). "
            + "Scenarios start from clearAppData(), so explore from this state. An iOS physical device "
            + "reinstalls instead — pass packagePath or ft_install first", [
            "bundleId": bundleIdProperty,
            "packagePath": ["type": "string", "description": "iOS physical device: .app/.ipa to "
                + "reinstall (default: the last ft_install)"],
        ], required: ["bundleId"]),
        tool("ft_clear_input", "Empty an input field (ft_type appends, so clear first to replace)", [
            "ref": ["type": "integer", "description": "Field ref (default: the focused one)"],
        ], extra: afterActionProperties()),
        tool("ft_draft_scenario", "Turn the ft_* operations you performed into a Swift scenario draft "
            + "(text only — save it under TestProjects/<project>/scenarios/ yourself). Steps use the "
            + "recommended selectors; ones without a stable selector become TODO comments. Expectation "
            + "blocks are left EMPTY on purpose (ft_dry_run flags them). The reply numbers the steps "
            + "— call again with drop:/lastN: to cut detours", [
            "all": ["type": "boolean", "description": "Use every recorded interaction, not only "
                + "those since the last ft_launch"],
            "className": ["type": "string", "description": "Class name (default DraftedScenario)"],
            "drop": ["type": "array", "items": ["type": "integer"],
                     "description": "Step numbers to omit (dead ends, retries); applied after lastN"],
            "lastN": ["type": "integer", "description": "Keep only the last N steps (before drop)"],
            "scenes": ["type": "array", "items": ["type": "integer"],
                       "description": "Step numbers that START a new scene — e.g. [9, 13] gives "
                        + "1-8, 9-12, 13-end; each gets its own empty expectation"],
            "title": ["type": "string", "description": "Text put in @Test(...)"],
        ], scope: .none),
        tool("ft_dsl_commands", "List the Swift DSL commands with signatures — call it before writing "
            + "scenarios so you do not invent commands. Also lists the project's @FTCommand helpers in "
            + "scenarios/ (marked [project: file:line]): prefer them when they fit; they run only "
            + "inside a scenario, not via MCP", [
            "category": ["type": "string", "description": "Only this category (operation/scroll/existence/text/value/app/control/…/project)"],
            "name": ["type": "string", "description": "Only this command, with its full summary"],
            "project": ["type": "string", "description": "Project whose helpers to list (default: "
                + "the only or default project)"],
        ], scope: .none),
        tool("ft_double_tap", "Double-tap an element (ref) or a point (x,y); two ft_tap calls miss the OS "
            + "double-tap window. On iOS pass profile: — without it XCUITest is used, and Compose apps "
            + "never receive the double tap. " + coordinateCaveat, [
            "ref": refProperty, "x": pointXProperty, "y": pointYProperty,
        ], extra: afterActionProperties()),
        tool("ft_drag", "Drag between points — for diagonal pans, and to expand a bottom sheet (drag its "
            + "grabber up). Start at fromRef (re-checked) or fromX/fromY; end at toX/toY or move by "
            + "dx/dy. A long durationSeconds drags slowly with no inertia; a short one flicks. "
            + coordinateCaveat, [
            "fromRef": ["type": "integer", "description": "Start at this ref's centre (e.g. a sheet grabber)"],
            "fromX": ["type": "number"],
            "fromY": ["type": "number"],
            "toX": ["type": "number"],
            "toY": ["type": "number"],
            "dx": ["type": "number", "description": "Horizontal travel (instead of toX)"],
            "dy": ["type": "number", "description": "Vertical travel, negative = up (instead of toY)"],
            "durationSeconds": ["type": "number", "description": "Travel time (default \(number(FlowStep.defaultSwipeDurationSeconds)))"],
            "maxGestureSeconds": maxGestureSecondsProperty,
        ], extra: afterActionProperties()),
        tool("ft_pinch", "Pinch to zoom: scale > 1 zooms in, < 1 out. Target a ref, or x/y on a map or "
            + "canvas; with neither it pinches the content at the screen centre (a bottom sheet on top "
            + "may take it). The zoom can fall short (fingers stay inside the target). On iOS pass "
            + "profile: — without it Flutter apps do not zoom", [
            "ref": refProperty,
            "x": ["type": "number", "description": "Pinch centre (ft_snapshot coordinates)"],
            "y": ["type": "number", "description": "Pinch centre (ft_snapshot coordinates)"],
            "radius": ["type": "number", "description": "Half-width of the pinched area (default \(Int(pinchRadiusScreenRatio * 100))% "
                + "of the screen's short side)"],
            "scale": ["type": "number", "description": "Zoom factor (default \(number(FlowStep.defaultPinchOutScale)))"],
            "durationSeconds": ["type": "number", "description": "Duration (default \(number(FlowStep.defaultPinchDurationSeconds)))"],
            "maxGestureSeconds": maxGestureSecondsProperty,
        ], extra: afterActionProperties()),
        tool("ft_gesture", "Replay several fingers' timed paths as ONE continuous touch — no lifting "
            + "between segments, unlike repeated ft_tap/ft_drag/ft_pinch. For pattern locks, "
            + "press-then-drag, custom rotations, 3+ fingers. Coordinates only (no selector form). "
            + "Each finger touches down at (x, y) after startSeconds, runs its steps in order — moves "
            + "{x, y, durationSeconds} or holds {holdSeconds} — and lifts at the end; no steps = a tap. "
            + coordinateCaveat, [
            "fingers": [
                "type": "array", "minItems": 1, "maxItems": TouchGesture.maxFingers,
                "description": "1-\(TouchGesture.maxFingers) finger paths, touching down together",
                "items": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number", "description": "Touch-down point"],
                        "y": ["type": "number", "description": "Touch-down point"],
                        "startSeconds": ["type": "number", "description": "Delay before touch-down (default 0)"],
                        "steps": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "description": "A move ({x, y, durationSeconds}) or a hold ({holdSeconds}), not both",
                                "properties": [
                                    "x": ["type": "number"],
                                    "y": ["type": "number"],
                                    "durationSeconds": ["type": "number"],
                                    "holdSeconds": ["type": "number"],
                                ],
                            ],
                        ],
                    ],
                    "required": ["x", "y"],
                ],
            ],
            "maxGestureSeconds": maxGestureSecondsProperty,
        ], extra: afterActionProperties(), required: ["fingers"]),
        // **名前が「長押し」と言い切っていること**。ツールの説明が
        // 遅延ロードされるクライアントでは、呼ぶかどうかを**名前だけ**で決める瞬間があり、
        // 「press」だけだと「ハードウェアキーを押す」と読まれる
        tool("ft_long_press", "Long-press (press and hold — NOT a hardware key) an element (ref) or a "
            + "point (x,y — e.g. on a map, where the point has no element). " + coordinateCaveat, [
            "ref": refProperty, "x": pointXProperty, "y": pointYProperty,
            "holdSeconds": ["type": "number", "description": "Hold time (default \(number(defaultLongPressHoldSeconds)), as the DSL's "
                + "tap(holdSeconds:))"],
            "maxGestureSeconds": maxGestureSecondsProperty,
        ], extra: afterActionProperties()),
        tool("ft_screenshot", "Take a screenshot for visual checks. It is downscaled — never read x/y "
            + "off it; use ft_snapshot coordinates", [
            "maxWidth": ["type": "integer", "description": "Width limit in px (default \(screenshotMaxWidth)); raise it "
                + "for dense screens"],
            "quality": ["type": "number", "description": "JPEG quality 0-1 (default \(number(screenshotQuality)))"],
            "fullSize": ["type": "boolean", "description": "Return the full-resolution PNG"],
        ]),
        tool("ft_capture_element", "Save an element's crop as an image-classifier sample under "
            + "vision/classifiers/<classifier>/<label>/ — cropped by its accessibility frame exactly as "
            + "checkIsON/checkIsOFF and imageIs crop it. Retrains if needed and reports samples it "
            + "cannot tell apart", [
            "ref": ["type": "integer", "description": "ft_snapshot ref (or selector)"],
            "selector": ["type": "string", "description": "Element selector (or ref)"],
            "classifier": ["type": "string", "enum": ["CheckStateClassifier", "DefaultClassifier"],
                           "description": "CheckStateClassifier (labels [ON] / [OFF] / [INDETERMINATE]) or "
                               + "DefaultClassifier (any folder ending with a bracketed name, e.g. @i/Settings/[Camera Icon])"],
            "label": ["type": "string", "description": "Label folder under the classifier"],
            "name": ["type": "string", "description": "Sample file name (default capture-<date>.png)"],
            "project": projectProperty,
        ], required: ["classifier", "label"]),
        tool("ft_terminate", "Terminate the app (fails if neither bundleId nor a prior ft_launch names it)", [
            "bundleId": lastLaunchedBundleIdProperty,
        ]),
        tool("ft_list_scenarios", "List the scenarios (TestProjects/<name>/scenarios/). Builds first; "
            + "compile errors are returned as-is", [
            "project": defaultProjectProperty,
            "skipBuild": skipBuildProperty,
        ], scope: .project),
        tool("ft_dry_run", "Check a scenario without a device, in seconds: errors on selector syntax; "
            + "warns (⚠️) on empty expectation blocks and #ids never seen in ft_snapshot — fix those too. "
            + "Run it after ft_list_scenarios and before ft_run_scenario; it cannot tell whether a "
            + "selector matches. A class name runs all its scenarios except @Deleted/@Draft", [
            "id": scenarioIdProperty,
            "project": defaultProjectProperty,
            "skipBuild": skipBuildProperty,
            "platform": ["type": "string", "enum": ["ios", "android"],
                        "description": "For a scenario that declares none: which ios { } / android { } "
                            + "branch and #id ledger to check (default ios)"],
        ], required: ["id"], scope: .project),
        tool("ft_run_scenario", "Quick check of a scenario (or a class, minus @Deleted/@Draft) while "
            + "writing it; builds first. On failure returns the failing step's error, tree, screenshot "
            + "and report path. Unlike ft_start_run it skips setup/teardown scripts, going home first and "
            + "results/; it installs the app only for an iOS profile with autoInstall (else ft_install). "
            + "When the user asks to run tests, use ft_start_run", [
            "id": scenarioIdProperty,
            "project": defaultProjectProperty,
            "profile": ["type": "string", "description": "Run profile (picks device, heal and report "
                + "destination); not with platform/port/serial/udid"],
            "heal": ["type": "boolean", "description": "Override fingerprint-based locator self-healing "
                + "(default: the profile's setting, else false)"],
            "skipBuild": skipBuildProperty,
        ], required: ["id"]),
        tool("ft_start_run", "Start a full test run (= fleetest run --profile) in the background and "
            + "return at once; records history, reports and recordings. Poll with ft_run_status, stop "
            + "with ft_stop_run. Use this when the user asks to run tests. One active run at a time", [
            "profile": ["type": "string", "description": "Run profile (profiles/runs/<name>.json); it picks the devices"],
            "project": defaultProjectProperty,
            "runner": ["type": "string", "description": "Run on this machine registered with `fleetest "
                + "remote machines add`, or local (raw hosts are refused)"],
            "scenario": ["type": "array", "items": ["type": "string"],
                         "description": "Only these (class or Class.method; default all)"],
            "folder": ["type": "array", "items": ["type": "string"],
                       "description": "Only scenarios under these folders of scenarios/"],
            "failed": ["type": "boolean", "description": "Only the scenarios that failed last time"],
            "broadcast": ["type": "boolean", "description": "Run each selected scenario on every device "
                + "instead of splitting them"],
        ], required: ["profile"], scope: .project),
        tool("ft_run_status", "State of an ft_start_run run: progress while running; exit code, totals, "
            + "failed scenarios with report paths and the results directory once finished; plus the log tail", [
            "pid": runPidProperty,
        ], scope: .none),
        tool("ft_stop_run", "Stop an ft_start_run run (SIGTERM; teardown may take a while — poll "
            + "ft_run_status)", [
            "pid": runPidProperty,
        ], scope: .none),
        tool("ft_results", "Read a project's results history (= fleetest results <query>, text). query: "
            + "list, summary (pass rate, duration), flaky, trend (needs scenario), devices, slow, insights "
            + "(regressions, repeated failures, stale selectors), log (a run's execution log)", [
            "query": ["type": "string", "enum": MCPResultsRequest.queries],
            "since": ["type": "string", "description": "Period start: 90s/30m/2h/30d, YYYY-MM-DD or "
                + "@epoch (default \(ResultsRendering.defaultSince); not for log)"],
            "scenario": ["type": "string", "description": "Class.method: filters summary/log; required for trend"],
            "runId": ["type": "string", "description": "log: run ID or latest (default)"],
            "limit": ["type": "integer", "description": "Rows for list (default \(ResultsRendering.defaultListLimit)) / slow (default \(ResultsRendering.defaultSlowLimit))"],
            "minRuns": ["type": "integer", "description": "flaky: minimum runs to count (default \(ResultsRendering.defaultMinRuns))"],
        ], required: ["query"], scope: .project),
        tool("ft_list_projects", "List the test projects (TestProjects/) and their run profiles", [:],
             scope: .none),
        tool("ft_doctor", "Check Foundation Models availability", [:], scope: .none),
    ]

    /// ツールがどの引数群を要るか。**デバイスに触らないツールへ5つ足さない**のが要点 ——
    /// 共通引数はツール定義全体の過半を占めており(実測 57%)、
    /// 使えない引数を並べるとコンテキストを食うだけでなく「渡せば効く」と誤解させる
    enum ToolScope {
        /// デバイスを掴む(platform/port/serial/profile/project)
        case device
        /// プロジェクトだけ要る(ビルド・シナリオ解決。デバイスには触らない)
        case project
        /// どちらも要らない
        case none
    }

    /// ref なしで入力したあと、**実際にどの欄へ入ったか**を名指しする。
    /// 焦点が無ければそれ自体が答え(撃った先が無かった = 沈黙した誤り)。
    /// 値が読めるなら期待した文字列が入っているかまで見る
    static func typedIntoNote(driver: AppDriver, expected: String?,
                              snapshot: SnapshotResponse?) async -> String {
        guard let snapshot else { return " (could not re-read the screen to confirm where it went)" }
        guard let field = snapshot.elements.first(where: { $0.focused == true }) else {
            return " (warning: nothing has input focus now, so the text may have gone nowhere"
                + " — tap the field by ref first)"
        }
        let name = RefGuard.describe(field)
        guard let value = field.value.map(FlowMatchMode.normalizeInvisibleCharacters), !value.isEmpty
        else { return " (into \(name); its value could not be read back)" }
        guard let expected, !value.contains(expected) else {
            return " (into \(name), which now reads \"\(SnapshotRenderer.truncate(value, 40))\")"
        }
        return " (warning: it went into \(name), but that field reads"
            + " \"\(SnapshotRenderer.truncate(value, 40))\" — the text may not have landed)"
    }

    /// `ft_type(replace: true)` 後の読み返し。**無条件の「replaced」を断言しない** ——
    /// in-app iOS の UIKit 経路は clearInput の成否を検証なしで YES と返すので、旧値が残ったまま
    /// 新しい文字が連結されても黙って「replaced」と言ってしまう(実害の型は typedIntoNote と同じ)。
    /// `target` は clear 前の要素(ref 指定時)—— RefGuard.relocate で同一性追跡する。
    /// ref 無指定(フォーカス任せ)のときは nil を渡し、focused な要素を見る(typedIntoNote と同じ規約)。
    /// `expected` が空文字なら **clear-only**({replace:true, text:"" or 省略})の検証 ——
    /// 一致すれば "(cleared the field)"、残存していれば警告にする。
    ///
    /// **`requestedAs`**: 判定は `ft_type(replace:true)` と `ft_clear_input` の
    /// 両方が共有するが、**文言は呼び手ごとに持つ**(CLAUDE.md の規律)—— `ft_clear_input` は
    /// 一度も「replace」を頼んでいないのに、既定の文言のまま使うと「replace requested」と
    /// 事実と違うことを言う。呼び手が自分の動詞を渡す(既定は "replace")
    static func replaceVerificationNote(target: ElementInfo?, expected: String,
                                        fresh: SnapshotResponse?,
                                        requestedAs: String = "replace") -> String {
        guard let fresh else {
            return " (\(requestedAs) requested; the field could not be read back)"
        }
        let found: ElementInfo?
        if let target {
            switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
            case .found(let f, _), .ghost(let f): found = f
            case .gone: found = nil
            }
        } else {
            found = fresh.elements.first { $0.focused == true }
        }
        guard let found else {
            return target == nil
                ? " (warning: nothing has input focus now, so the text may have gone nowhere"
                    + " — tap the field by ref first)"
                : " (\(requestedAs) requested; the field could not be read back)"
        }
        guard let rawValue = found.value else {
            // **値が無い = 空、であって「読めない」ではない**: Android の空の EditText は
            // value 属性そのものを省き、iOS も空欄は nil を返す(空文字ではなく nil)。
            // expected も空(clear-only)ならこれは成功 —— 非空を期待するとき
            // (実際に置き換える文字列がある)だけ、本当に読めないので保留のまま返す。
            // **ただし「空」と読めるのは入力欄だけ** —— 容器など入力欄でない要素はそもそも値を出さないので、
            // nil は消えた証拠にならない(容器の ref を受け付けた回に「cleared」と言っていた)
            guard expected.isEmpty, TypeReadback.isTextInput(found) else {
                return " (\(requestedAs) requested; its value could not be read back)"
            }
            return " (cleared the field)"
        }
        // **正規化してから比較する**: typedIntoNote と同じゼロ幅文字の扱いを
        // expected 側にもかける —— これが無いと、両辺が実質同じ文字列でも不一致の警告が出る
        let value = FlowMatchMode.normalizeInvisibleCharacters(rawValue)
        let normalizedExpected = FlowMatchMode.normalizeInvisibleCharacters(expected)
        let clearOnly = normalizedExpected.isEmpty
        if value == normalizedExpected {
            return clearOnly ? " (cleared the field)" : " (replaced the field's prior content)"
        }
        // **マスク欄は偽警告にしない**: パスワード欄の読み返しは伏せ字(•/●/*…)なので、
        // 期待値自体がマスク文字でない限り不一致は「違う」ではなく「確かめようがない」
        if Self.looksMasked(value), !Self.looksMasked(normalizedExpected) {
            return " (\(requestedAs) requested; the field reads back masked, so the result could not be"
                + " verified)"
        }
        if clearOnly {
            return " (warning: \(requestedAs) was requested to clear the field, but it still reads"
                + " \"\(SnapshotRenderer.truncate(value, 40))\" — the clear may not have taken)"
        }
        if value.hasSuffix(normalizedExpected) {
            return " (warning: the field now reads \"\(SnapshotRenderer.truncate(value, 40))\""
                + " — the old content does not look cleared, so this may have appended instead"
                + " of replacing it. Call ft_clear_input and retry if so)"
        }
        return " (warning: \(requestedAs) was requested, but the field now reads"
            + " \"\(SnapshotRenderer.truncate(value, 40))\" — this does not match what was typed)"
    }

    /// `ft_type`(replace なし)で既存値へ追記したときの読み返し。
    /// **連結後の値を予告しない** —— 空欄のヒント文字列が `value` に載るアプリでは撃つ前の値が
    /// 実在の内容ではないので、「今は "ヒント+入力" と読める」は**同じ応答が返す木に否定される**。
    /// witness は Google メッセージの宛先欄(`ContactSearchField`。撃つ前 value="名前、電話番号、
    /// メールアドレスのいずれかを入力" → 撃った後 value="5551234567")。`isShowingHintText()` が
    /// false なのでブリッジは `placeholder` を出さず、DSL 側の `TypeReadback.normalizedValue`
    /// (value == placeholder を落とす)でも取り切れない —— **読み返す以外に区別する手が無い**。
    /// 引数の規約は `replaceVerificationNote` と同じ(target 無指定なら focused を見る)。
    static func appendVerificationNote(target: ElementInfo?, typed: String, prior: String,
                                       fresh: SnapshotResponse?) -> String {
        let unread = " (the field showed \"\(SnapshotRenderer.truncate(prior, 30))\" before this;"
            + " ft_type appends rather than replacing, but the result could not be read back"
            + " — check it with ft_snapshot)"
        guard let fresh else { return unread }
        let found: ElementInfo?
        if let target {
            switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
            case .found(let f, _), .ghost(let f): found = f
            case .gone: found = nil
            }
        } else {
            found = fresh.elements.first { $0.focused == true }
        }
        guard let found, let rawValue = found.value else { return unread }
        let value = FlowMatchMode.normalizeInvisibleCharacters(rawValue)
        let normalizedTyped = FlowMatchMode.normalizeInvisibleCharacters(typed)
        // **撃った文字だけが残っているなら、撃つ前の値は実在の内容ではなかった**(ヒント/
        // プレースホルダ)。DSL は normalizedValue が空を返して黙るので、こちらも黙る
        if value == normalizedTyped { return "" }
        if Self.looksMasked(value), !Self.looksMasked(normalizedTyped) {
            return " (the field held a value before this and ft_type appends, but it reads back"
                + " masked, so the result could not be verified)"
        }
        return " (the field already held \"\(SnapshotRenderer.truncate(prior, 30))\";"
            + " ft_type appends, so it now reads"
            + " \"\(SnapshotRenderer.truncate(value, 60))\"."
            + " Call ft_clear_input first if you meant to replace it)"
    }

    /// パスワード欄などの読み返しが伏せ字だけで構成されているか。**1文字でも非マスクなら false**
    /// —— 実データが読めている可能性を残し、誤って中立扱いにしない
    private static func looksMasked(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let maskCharacters: Set<Character> = ["•", "●", "*"]
        return value.allSatisfy { maskCharacters.contains($0) }
    }

    /// 座標形は ref の安全網(遮蔽・残像・中身外し)を1つも通らない。**設計上そうなる**が、
    /// 説明に書いていないと読み手が ref 形と同じ信頼度だと思い込む(棚卸しで判明)
    static let coordinateCaveat = "Coordinates skip the ref safety checks (occlusion, scroll"
        + " leftovers, off-content centres) — prefer a ref."

    static func tool(_ name: String, _ description: String,
                     _ properties: [String: Any], extra: [String: Any] = [:],
                     required: [String] = [],
                     scope: ToolScope = .device) -> [String: Any] {
        var props = properties.merging(extra) { own, _ in own }
        // 個別宣言・extra があればそちらを優先する(ft_run_scenario の profile・ft_logs の udid/port は独自の説明を持つ)
        switch scope {
        case .device:
            for (key, value) in commonDeviceProperties where props[key] == nil {
                props[key] = value
            }
        case .project:
            if props["project"] == nil { props["project"] = projectProperty }
        case .none:
            break
        }
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}
