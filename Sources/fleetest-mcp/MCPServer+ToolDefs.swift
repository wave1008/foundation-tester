// MCPServer+ToolDefs.swift
// ツール定義(スキーマ)とサーバ説明文。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    // MARK: - ツール定義

    // **共通引数の説明は最小限にする**: 5つ × デバイス系ツールで定義全体の約4割を占めるため、
    // 1文字が13倍になる(2026-08-05 実測)。意味は enum と名前で足りる
    static let platformProperty: [String: Any] = [
        "type": "string", "enum": ["ios", "android"], "description": "default ios",
    ]
    static let portProperty: [String: Any] = [
        "type": "integer", "description": "iOS bridge port (default: the running bridge)",
    ]
    static let serialProperty: [String: Any] = [
        "type": "string", "description": "Android device serial (default: the connected device)",
    ]
    static let profileProperty: [String: Any] = [
        "type": "string",
        "description": "profiles/runs/<name>. Same device and engine as ft_run_scenario",
    ]
    static let projectProperty: [String: Any] = [
        "type": "string", "description": "Test project name",
    ]
    /// iOS の宛先を udid で指す(H)。ft_list_devices が出す udid をそのまま渡せる
    // **繰り返し載る説明は短文+詳細は serverInstructions**(2026-08-10 のスキーマ痩身)。
    // ここを長くすると全ツールに複製されて毎セッションのコンテキスト費用になる —— ニュアンスを
    // 足したくなったら serverInstructions 側へ(initialize で1回だけ渡る)
    static let udidProperty: [String: Any] = [
        "type": "string",
        "description": "iOS simulator UDID to drive (as printed by ft_list_devices)",
    ]
    /// 操作系ツールの「結果の木も一緒に返す」スイッチ。**撮り直し不要と言い切る**(言わないと
    /// 読み手は木を受け取ったうえで習慣的に ft_snapshot を撃つ)
    static let snapshotAfterProperty: [String: Any] = [
        "type": "boolean",
        "description": "Append the resulting screen's element list (as ft_snapshot would) — "
            + "saves the follow-up ft_snapshot call",
    ]
    /// 操作系ツールが共有する waitFor/timeout(ft_snapshot と同じ待ちのロジックを流用。
    /// snapshotAfterBody 参照)。**snapshotAfter: true と併用が前提** — 無いときは操作は
    /// 実行したうえで note だけ返す(throw しない。操作自体は成功しているため)
    static let snapshotAfterWaitForProperty: [String: Any] = [
        "type": "string",
        "description": "Requires snapshotAfter: true. Wait for this selector on the resulting "
            + "screen (syntax: #id, a label, .type, a||b — quotes wrapped around the whole "
            + "selector are stripped)",
    ]
    static let snapshotAfterTimeoutProperty: [String: Any] = [
        "type": "number",
        "description": "Seconds to wait for waitFor (default 5, same as ft_snapshot)",
    ]
    /// **「何かが変わる」を待つ**: 再検索のように**同じセレクタのまま中身だけ入れ替わる**画面では
    /// waitFor が古い結果に即マッチして待ちにならない(実測: Google マップの経路再検索で
    /// `waitFor "*IC 運賃*"` が旧結果へ当たった)。waitFor とは排他(待つ理由が違う)
    static let snapshotAfterWaitForChangeProperty: [String: Any] = [
        "type": "boolean",
        "description": "Requires snapshotAfter: true, and not with waitFor. Poll until the tree "
            + "differs from the one before the action (for screens that refresh in place, where a "
            + "selector you would wait for is already on the old content)",
    ]
    /// ft_snapshot と操作系が共有する木の畳み方(2つ目の定義を作らない)。
    /// どのツールでも既定は畳む・隠さないなので、説明文もそのまま通用する
    static let expandBulkProperty: [String: Any] = [
        "type": "boolean", "description": "List every element of a large same-id group "
            + "individually (default: 20+ folded into one line)",
    ]
    static let interactiveOnlyProperty: [String: Any] = [
        "type": "boolean", "description": "Hide layout-only lines — refs/frames unchanged, "
            + "and a hidden element can still be tapped by ref",
    ]
    /// **ft_snapshot にだけ置く**(操作系や scroll_to は木を何度も撮るので、1回限りの指定が
    /// どの取得に効いたのか読み手に説明できない)。上限に当たった応答の注記がこの引数を名指しする
    static let maxElementsProperty: [String: Any] = [
        "type": "integer",
        "description": "Element limit for THIS read only (default \(BridgeAPI.maxSnapshotElements),"
            + " max \(BridgeAPI.maxSnapshotElementsCeiling)). Raise it when a note says elements"
            + " were dropped by the limit — on a dense web page the dropped ones are the body text,"
            + " and scrolling will never bring them back",
    ]
    /// 共通引数の詳細。**各ツールのプロパティ説明は短文に留め、ニュアンスはここに1本化する**
    /// (initialize の instructions で1回だけ渡る。プロパティ側に書くと全ツールへ複製され、
    /// 毎セッションのコンテキスト費用になる —— 2026-08-10 のスキーマ痩身)
    static let serverInstructions = """
        Common arguments accepted by every ft_* device tool: platform (default ios) / project / \
        profile (profiles/runs/<name>; same device and engine as ft_run_scenario) / \
        udid (iOS simulator, as printed by ft_list_devices — resolved to the bridge running on \
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
        guarantees it is there. Both waits run to timeout (default 5s) when they miss — pass a \
        smaller timeout on a wait you expect to miss, a larger one for a slow load. \
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
    static let commonDeviceProperties: [(String, [String: Any])] = [
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
    static let allowVersionSkewProperty: [String: Any] = [
        "type": "boolean",
        "description": "Operate despite a bridge protocol version mismatch — every such "
            + "response carries a warning",
    ]

    /// ft_screenshot の既定。**費用は画素数で決まる**(バイト数ではない) —— 平坦な UI では
    /// 原寸 PNG のほうが JPEG より小さいことすらあるので、バイト比較で選ぶと逆に損をする。
    /// 600 は実測で決めた: iPhone 17 Pro(1179px)の E2E 画面で CJK 本文もステータスバーも読め、
    /// 画素は 1/2.4。地図のような密な画面はこれでは潰れうるので maxWidth / fullSize で逃がす
    static let screenshotMaxWidth = 600
    static let screenshotQuality = 0.6

    static let toolDefinitions: [[String: Any]] = [
        tool("ft_status", "Check the device/bridge connection state", [:]),
        tool("ft_list_devices", "List the devices this Mac can drive (simulators, emulators and "
            + "physical devices) with the udid/serial the other tools take. It works before any "
            + "profile exists — without a machine profile it lists what is booted or connected now", [
            "platform": ["type": "string", "enum": ["ios", "android"],
                         "description": "Only this platform (default: both)"],
            "profile": profileProperty,
        ], scope: .project),
        tool("ft_list_apps", "List the apps installed on the device. Use it to find the bundle ID "
            + "(iOS) / package name (Android) that ft_launch takes. By default it lists user apps "
            + "only — the maps, browser and other preinstalled apps are system apps, so reach for "
            + "filter or includeSystem when the app you want is not in the list", [
            "filter": ["type": "string", "description": "Only apps whose bundle ID or display name "
                + "contains this (case-insensitive). Passing it searches system apps too, unless "
                + "you also pass includeSystem: false"],
            "includeSystem": ["type": "boolean", "description": "List system apps as well, marked "
                + "[system]. Display names are iOS-only — Android's package manager reports "
                + "package names only"],
        ]),
        tool("ft_logs", "Read why the app died. iOS returns the crash report summary and the .ips "
            + "path for a simulator — there is no runtime log on iOS, so a running app yields "
            + "nothing here; Android returns recent logcat lines. It never goes through the bridge, "
            + "so it still answers after a crash took the bridge with it", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android). "
                + "Defaults to the bundle ID of the last ft_launch"],
            "platform": platformProperty,
            "serial": serialProperty,
            "lines": ["type": "integer", "description": "Android: how many recent lines to return (default 100)"],
            "sinceSeconds": ["type": "integer", "description": "How far back to look (default 300)"],
            "all": ["type": "boolean", "description": "Android: read the main buffer too, not just crashes"],
        ], scope: .none),
        tool("ft_install", "Install an app from a package file (iOS: .app bundle / Android: .apk, or .apks — a split bundle, installed via bundletool)", [
            "packagePath": ["type": "string", "description": "Absolute path of the package file"],
        ], required: ["packagePath"]),
        tool("ft_launch", "Launch the app (terminating it first if it is already running). The app "
            + "itself may restore its previous UI state on launch — system apps such as Maps often "
            + "do — so do not assume the first screen: check with ft_snapshot. "
            + "iOS: com.apple.springboard attaches to the home screen instead, without launching "
            + "anything — that is how you read the home screen or a system dialog", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android)"],
        ], required: ["bundleId"]),
        tool("ft_open_url", "Deliver a URL (deep link) to the app WITHOUT restarting it — unlike "
            + "ft_launch, the app keeps running and whatever it navigates to is pushed on top of the "
            + "current screen. Use this to jump into a specific screen of an already-running app; use "
            + "ft_launch when you need it from the first screen instead. Delivery is asynchronous, so "
            + "snapshotAfter waits for the screen to change before reading (pass waitFor when the "
            + "destination needs more than 'something changed', or waitForChange: false to read "
            + "immediately)", [
            "url": ["type": "string", "description": "The URL/deep link to deliver"],
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name — the Android "
                + "intent target. Defaults to the bundle ID of the last ft_launch"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ], required: ["url"]),
        tool("ft_snapshot", "Get the element list of the current screen. Each line: [ref] Type \"label\" id=... (x,y WxH). "
            + "A line marked scroll is a scrolling container you can pass as scrollFrame. "
            + "Use these refs for tap/type. With waitFor it polls for you instead of you calling this again", [
            "waitFor": ["type": "string", "description": "Wait until this selector is on screen. Same syntax as the DSL: #id, a label, .type, a||b (quotes wrapped around the whole selector are stripped)"],
            "timeout": ["type": "number", "description": "Seconds to wait for waitFor (default 5, same as the DSL)"],
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
            "maxElements": maxElementsProperty,
        ]),
        tool("ft_tap", "Tap an element (ref) or a coordinate (x,y). x/y match the ft_snapshot frames (iOS=pt / Android=px), not screenshot pixels. "
            + "A ref is re-checked against a fresh tree before the tap, so a ref that moved is retargeted and "
            + "one that is gone is refused; a scroll leftover is tapped with a warning naming what "
            + "it may have hit instead. " + coordinateCaveat, [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        tool("ft_type", "Type text (with ref, taps that field first and waits for it to take focus). "
            + "It APPENDS to whatever the field already holds by default — pass replace: true to clear it "
            + "first, or call ft_clear_input yourself. "
            + "text is required unless pressEnter is true — pressEnter alone fires the Enter/IME action. "
            + "Typing itself never closes the soft keyboard. pressEnter fires the Enter/IME action — on "
            + "UIKit/SwiftUI the return key usually closes the keyboard as a side effect; Compose and Flutter "
            + "keep it open, so do not retry pressEnter waiting for the keyboard to go away.", [
            "text": ["type": "string", "description": "Omit it to fire Enter only"],
            "pressEnter": ["type": "boolean", "description": "Fire Enter/IME action (search, submit)"],
            "ref": ["type": "integer", "description": "Reference number of the input field (defaults to the focused element)"],
            // **値段と、二重払いの避け方まで書く**: replace は素の type の
            // 約2倍かかる(実測 6.1s 対 2.3s)。内訳は clear の1往復と、**打った結果の読み返し**
            // (in-app iOS は clear/type の成否を検証せず YES を返すので、読み返さないと
            // 「replaced」が嘘になる)。snapshotAfter を付ければその1枚と共有する
            "replace": ["type": "boolean", "description": "Clear the field before typing, instead "
                + "of appending. Costs a clear round trip plus one read-back that verifies what the "
                + "field ends up holding — with snapshotAfter (and no pressEnter) that read is the "
                + "same one, so pass it instead of taking a separate ft_snapshot"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        tool("ft_swipe", "Swipe one screenful (up = scroll down the content). To reach a specific element use "
            + "ft_scroll_to instead — it stops on the element and hands back fresh refs", [
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"],
                          "description": "Finger direction (same vocabulary as the DSL's swipe)"],
            "scrollFrame": ["type": ["string", "integer"],
                            "description": "Swipe inside this scrolling container only, instead of the "
                                + "whole screen — selector of the container (e.g. #list_rows), or its "
                                + "ft_snapshot ref (an integer) when it has no unique id. Use this when "
                                + "the thing you want to move has no selector to search for with "
                                + "ft_scroll_to (e.g. a horizontally-scrolling table), or the screen has "
                                + "more than one scrollable area. Same syntax as the DSL: #id, a label, "
                                + ".type, a||b (quotes wrapped around the whole value are stripped). Only "
                                + "a container that appears in the tree works (a line ft_snapshot marks "
                                + "scroll) — if the area you want is not one (e.g. a web page's inner "
                                + "overflow scroller, where only the whole page is a container), the "
                                + "finger passes outside it and nothing moves; use ft_drag with "
                                + "coordinates instead"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ], required: ["direction"]),
        tool("ft_scroll_to", "Scroll until a selector is on screen, then return the fresh element list. "
            + "Use this instead of repeating ft_swipe + ft_snapshot: it runs the same search the DSL's "
            + "scrollTo does (settling, container-sized steps, overshoot recovery) and the refs it returns "
            + "are taken after the scroll", [
            "selector": ["type": "string", "description": "Same syntax as the DSL: #id, a label, .type, a||b (a plain label is written bare — quotes wrapped around the whole selector are stripped)"],
            "direction": ["type": "string", "enum": ["down", "up", "right", "left"],
                          "description": "Content direction to read towards (default down)"],
            "scrollFrame": ["type": ["string", "integer"],
                            "description": "Selector of the scrolling container to search inside (e.g. #list_rows), "
                                + "or its ft_snapshot ref (an integer) when the container has no unique id — "
                                + "a duplicated or missing id makes a selector unusable. Pass it when the screen "
                                + "has more than one scrollable area — ft_snapshot marks those lines scroll and "
                                + "says so at the top. When passing a selector: same syntax as the DSL: #id, "
                                + "a label, .type, a||b (quotes wrapped around the whole value are stripped)"],
            "maxSwipes": ["type": "integer", "description": "Swipe limit (default 8, same as the DSL)"],
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ], required: ["selector"]),
        tool("ft_batch", "Run several operation/scroll DSL steps in one approval, stopping at "
            + "the first failure; the reply shows the screen after the last executed step. "
            + "Steps are DSL lines in one string, separated by ';' (or newlines); arguments "
            + "are quoted ('x' and \"x\" are equivalent) and space-separated — no parentheses "
            + "or commas: type '#field' 'abc'; scrollTo '#item' direction: .down. "
            + "Argument names are whatever ft_dsl_commands prints. "
            + "A passing batch converts 1:1 into scenario lines (Swift needs parentheses "
            + "and commas) — steps that used ref are converted using the selector they were "
            + "resolved to, not the ref. Only operation/scroll commands run — lifecycle/"
            + "data-wiping commands (launchApp, clearAppData, …) and assertions are rejected "
            + "with the tool to call instead. Target elements by selector, not ref, except on "
            + "the FIRST step: ref (from ft_snapshot/ft_tap/ft_scroll_to) is accepted there "
            + "because nothing has run yet to make it stale; every later step needs a selector, "
            + "since a step can change the tree and a ref taken before it would silently hit a "
            + "different element by then. A first-step ref is re-checked against a fresh "
            + "snapshot and converted to the selector it resolves to (reported in the reply) "
            + "before anything runs; a ref with no selector that would pick it out uniquely is "
            + "rejected — call ft_tap with that ref instead, then batch the rest.", [
            "steps": ["type": "string",
                      "description": "Up to \(batchStepLimit) DSL lines in one string, e.g. "
                        + "\"tap '#nav_input'; type '#field' 'batch'; "
                        + "scrollTo '#btn_submit' direction: .down\" — ';' and newlines "
                        + "(outside quotes) separate steps. The first step may target its "
                        + "element with ref: N (an ft_snapshot ref) instead of a selector — "
                        + "e.g. \"tap ref: 12; type '#field' 'batch'\" — every step after the "
                        + "first must use a selector"],
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ], required: ["steps"]),
        tool("ft_rotate", "Rotate the device and return the screen in the new orientation. "
            + "It waits for the rotation to settle (re-reading until the tree stops changing), "
            + "so the tree that comes back is normally already relaid out — every frame is in "
            + "the new coordinate system and refs taken before the rotation no longer resolve. "
            + "If it could not confirm settling within budget, a note says so and the frames may "
            + "still be mid-relayout. A scenario written with rotateTo() restores the "
            + "original orientation when it ends; this tool does not, so rotate back yourself "
            + "before leaving the device to the next task. On Android it also turns auto-rotate "
            + "off (otherwise the angle does not stick) and leaves it off — rotating back to "
            + "portrait does not turn it on again", [
            "orientation": ["type": "string",
                            "enum": ["portrait", "landscape"]],
        ], required: ["orientation"]),
        tool("ft_navigate", "Go back / to the home screen / to the app switcher", [
            "target": ["type": "string", "enum": ["back", "home", "appSwitcher"]],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ], required: ["target"]),
        tool("ft_clear_app_data", "Wipe the app's data and permissions, keeping it installed (iOS: simulator only). "
            + "Stops the app, so ft_launch after it. Scenarios start from clearAppData(), so explore from that same state", [
            "bundleId": ["type": "string", "description": "bundle ID (iOS) / package name (Android)"],
        ], required: ["bundleId"]),
        tool("ft_clear_input", "Empty an input field (ft_type appends, so clear first to replace)", [
            "ref": ["type": "integer", "description": "Reference number of the field (default: the focused one)"],
        ]),
        tool("ft_draft_scenario", "Turn the operations you just performed with ft_* into a Swift "
            + "scenario draft and return it as text (it writes no file — place it yourself under "
            + "TestProjects/<project>/scenarios/). Every step is written with the selector this "
            + "server recommended at the time; a step that had no stable selector is kept as a TODO "
            + "comment so the draft still matches what you did. The expectation block comes back "
            + "EMPTY on purpose — assertions are never guessed, and ft_dry_run reports the empty "
            + "block so it cannot be forgotten. The reply lists the steps it used, numbered — an "
            + "exploration records dead ends and retries as faithfully as the real path, so read "
            + "that listing and call again with drop:/lastN: to cut the detours", [
            "all": ["type": "boolean", "description": "Draft from every recorded interaction "
                + "instead of only those since the last ft_launch (the default)"],
            "className": ["type": "string", "description": "Name of the generated class "
                + "(default: DraftedScenario)"],
            "drop": ["type": "array", "items": ["type": "integer"],
                     "description": "Step numbers (1-based, as printed in the listing) to leave "
                        + "out — use it to remove dead-end taps and retries. Applied after lastN"],
            "lastN": ["type": "integer", "description": "Keep only the last N recorded steps "
                + "before applying drop. Use it when the useful part is at the end of a long "
                + "exploration"],
            "scenes": ["type": "array", "items": ["type": "integer"],
                       "description": "Step numbers (as printed in the listing) that START a new "
                        + "scene — e.g. [9, 13] gives scene 1 = steps 1-8, scene 2 = 9-12, "
                        + "scene 3 = 13-end. Each scene gets its own empty expectation, so "
                        + "dry-run asks what every one of them proves. Scene boundaries are never "
                        + "guessed: they say what a scene is for, which the recording cannot know"],
            "title": ["type": "string", "description": "Text put in @Test(...)"],
        ], scope: .none),
        tool("ft_dsl_commands", "List the Swift DSL commands with their signatures — the source of truth for "
            + "writing scenarios. Call it before writing code so you do not invent commands. "
            + "Without arguments it returns names and signatures only", [
            "category": ["type": "string", "description": "Only this category (operation/scroll/existence/text/value/app/control/…)"],
            "name": ["type": "string", "description": "Only this command, with its full summary"],
        ], scope: .none),
        tool("ft_double_tap", "Double-tap an element (ref) or a coordinate (x,y). Two ft_tap calls do not work "
            + "(the round trip exceeds the OS double-tap window). Pass profile: on iOS — without it these "
            + "tools use XCUITest, where Compose apps never receive a double tap (see docs/commands.md). "
            + coordinateCaveat, [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        tool("ft_drag", "Drag from a point to a point — the only way to pan diagonally (set both axes), "
            + "and the way to expand a half-open bottom sheet (drag its grabber upward). "
            + "Start from fromRef (an element, re-checked against a fresh tree) or fromX/fromY; "
            + "end at toX/toY, or dx/dy to move by that much. "
            + "Coordinates use the same system as the ft_snapshot frames (iOS=pt / Android=px). "
            + "A long durationSeconds drags slowly and leaves no inertia; a short one flicks. "
            + coordinateCaveat, [
            "fromRef": ["type": "integer", "description": "Reference number to start the drag from (its centre). Use it for a sheet grabber instead of reading its frame yourself"],
            "fromX": ["type": "number"],
            "fromY": ["type": "number"],
            "toX": ["type": "number"],
            "toY": ["type": "number"],
            "dx": ["type": "number", "description": "Horizontal travel from the start point (ignored when toX is given)"],
            "dy": ["type": "number", "description": "Vertical travel from the start point — negative moves up (ignored when toY is given)"],
            "durationSeconds": ["type": "number", "description": "Travel time in seconds (default 1.5)"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        tool("ft_pinch","Pinch to zoom. scale > 1 zooms in, 0 < scale < 1 zooms out. Target it with ref, "
            + "or with x/y on a map or canvas that has no element of its own — without either, the fingers "
            + "span the whole screen, so a bottom sheet on top of it may take the gesture instead. "
            + "The actual zoom can be smaller than requested (fingers stay inside the target). "
            + "Pass profile: on iOS — without it Flutter apps do not zoom (see docs/commands.md).", [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "Centre of the pinch, iOS=pt / Android=px (same coordinate system as the snapshot frames). "
                + "Android and the iOS in-app engine honour it; the iOS XCUITest engine cannot (XCTest has no coordinate pinch) and says so"],
            "y": ["type": "number", "description": "Centre of the pinch, iOS=pt / Android=px"],
            "radius": ["type": "number", "description": "Half the width of the pinched area around x/y "
                + "(default: 22% of the screen's short side, clamped to stay on screen)"],
            "scale": ["type": "number", "description": "Zoom factor (default 2.0)"],
            "durationSeconds": ["type": "number", "description": "Gesture duration in seconds (default 0.5)"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        // **名前が「長押し」と言い切っていること**。ツールの説明が
        // 遅延ロードされるクライアントでは、呼ぶかどうかを**名前だけ**で決める瞬間があり、
        // `ft_press` は「ハードウェアキーを押す」と読まれていた。旧名は dispatch で受け続ける
        tool("ft_long_press", "Long-press (press and hold) an element (ref) or a coordinate (x,y). "
            + "This is NOT a hardware key press. Use x/y on a map or "
            + "canvas, where the point you want has no element of its own. " + coordinateCaveat, [
            "ref": ["type": "integer", "description": "Reference number from ft_snapshot"],
            "x": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "y": ["type": "number", "description": "iOS=pt / Android=px (same coordinate system as the snapshot frames)"],
            "holdSeconds": ["type": "number", "description": "Hold time in seconds (default 1.0; "
                + "same vocabulary as the DSL's tap(holdSeconds:))"],
            "snapshotAfter": snapshotAfterProperty,
            "waitForChange": snapshotAfterWaitForChangeProperty,
            "waitFor": snapshotAfterWaitForProperty,
            "timeout": snapshotAfterTimeoutProperty,
            "expandBulk": expandBulkProperty,
            "interactiveOnly": interactiveOnlyProperty,
        ]),
        tool("ft_screenshot", "Take a screenshot (returns an image). Use it for visual verification. "
            + "It comes back downscaled — the pixels are NOT the coordinate system, so read x/y off "
            + "ft_snapshot (iOS=pt / Android=px) and never off this image", [
            "maxWidth": ["type": "integer", "description": "Width limit in pixels (default 600). "
                + "Raise it for dense screens where small labels stop being readable"],
            "quality": ["type": "number", "description": "JPEG quality 0-1 (default 0.6)"],
            "fullSize": ["type": "boolean", "description": "Return the original PNG at full "
                + "resolution instead, for when fine detail matters"],
        ]),
        tool("ft_terminate", "Terminate the running app", [:]),
        tool("ft_list_scenarios", "List the Swift DSL scenarios (TestProjects/<name>/scenarios/). Builds automatically; compile errors are returned as-is", [
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "skipBuild": ["type": "boolean", "description": "Skip the swift build (default false)"],
        ], scope: .project),
        tool("ft_dry_run", "Dry-run a scenario without any device. Catches selector syntax errors, unreachable scenes and expectation blocks with no assertions in seconds. "
            + "Run it after ft_list_scenarios (compile) and before ft_run_scenario (real device) — it cannot tell whether a selector matches a real element", [
            "id": ["type": "string", "description": "Scenario ID (Class.method; see ft_list_scenarios)"],
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "skipBuild": ["type": "boolean", "description": "Skip the swift build (default false)"],
        ], required: ["id"], scope: .project),
        tool("ft_run_scenario", "Run a scenario deterministically. On failure, returns the triage and the report path. Builds automatically", [
            "id": ["type": "string", "description": "Scenario ID (Class.method; see ft_list_scenarios)"],
            "project": ["type": "string", "description": "Test project name (defaults to the default project)"],
            "profile": ["type": "string", "description": "Run profile name (profiles/runs/; resolves the connection, heal and report destination)"],
            "heal": ["type": "boolean", "description": "Override for locator self-healing (defaults to the profile setting, or false without a profile; ineffective when the profile has fm:false)"],
            "port": ["type": "integer", "description": "iOS bridge port (default: the running bridge)"],
            "serial": ["type": "string", "description": "Android device serial (default: the connected device)"],
        ], required: ["id"]),
        tool("ft_list_projects", "List the test projects (TestProjects/) and their run profiles", [:],
             scope: .none),
        tool("ft_doctor", "Check Foundation Models availability", [:], scope: .none),
    ]

    /// ツールがどの引数群を要るか。**デバイスに触らないツールへ5つ足さない**のが要点 ——
    /// 共通引数はツール定義全体の過半を占めており(2026-08-05 実測 57%)、
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
    /// 一致すれば "(cleared the field)"、残存していれば警告にする
    static func replaceVerificationNote(target: ElementInfo?, expected: String,
                                        fresh: SnapshotResponse?) -> String {
        guard let fresh else {
            return " (replace requested; the field could not be read back)"
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
                : " (replace requested; the field could not be read back)"
        }
        guard let rawValue = found.value else {
            return " (replace requested; its value could not be read back)"
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
            return " (replace requested; the field reads back masked, so the result could not be"
                + " verified)"
        }
        if clearOnly {
            return " (warning: replace was requested to clear the field, but it still reads"
                + " \"\(SnapshotRenderer.truncate(value, 40))\" — the clear may not have taken)"
        }
        if value.hasSuffix(normalizedExpected) {
            return " (warning: the field now reads \"\(SnapshotRenderer.truncate(value, 40))\""
                + " — the old content does not look cleared, so this may have appended instead"
                + " of replacing it. Call ft_clear_input and retry if so)"
        }
        return " (warning: replace was requested, but the field now reads"
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
    /// 説明に書いていないと読み手が ref 形と同じ信頼度だと思い込む(2026-08-07 の棚卸し)
    static let coordinateCaveat = "Coordinates skip the ref safety checks (occlusion, scroll"
        + " leftovers, a container whose centre misses its own content), so prefer a ref when the"
        + " element is in the tree."

    static func tool(_ name: String, _ description: String,
                     _ properties: [String: Any], required: [String] = [],
                     scope: ToolScope = .device) -> [String: Any] {
        var props = properties
        // 個別宣言があればそちらを優先する(ft_run_scenario は profile/port/serial により詳細な説明を持つ)
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
