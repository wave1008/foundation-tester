// DSL コマンドの機械可読な索引(`fleetest api dsl-commands`)。読者は**コードを生成する側**で、
// 「その名前は在るか・引数は何か・exist の戻り値に繋げられるか」を実行前に確かめるためのもの。
//
// **表は手書きで、`CommandIndexSyncTests` がソースと突き合わせる**(Commands.swift ほかコマンド定義3ファイルの
// `public func` + トップレベル `public var` 全件 + ValueAssertions.swift の `this*` 全件 = この表の name 集合、
// chainable は FTElement のメソッド集合と一致)。コマンドを足す/消す/改名したら
// ここも直さないとテストが落ちる —— 索引が古いまま配られるのを防ぐのが唯一の目的。
// 併せて docs/commands.md も直す(あちらは人間向けの散文、こちらは名前の正典)。
//
// summary は**英語**(CLI は英語のみ。docs/design.md の方針)。1行・命令形にしない。
//
// FTCore に居る理由: 表は静的データで Foundation にしか依存しない(コマンド定義自体は
// Sources/FTDSL/Commands*.swift に残る。この索引はその名前の一覧を映すだけ)。

import Foundation

public struct DSLCommandInfo: Sendable, Encodable {
    public let name: String
    /// structure / operation / scroll / flick / existence / id / text / value / this / app / control
    public let category: String
    /// 代表的な呼び出し形(セレクタを取るものは文字列版。型付き `Sel` 版が必ず併設されている)。
    /// **検証は `select(selector).xxx(...)` の形で載せる** —— 対象は「直前に掴んだ要素」なので、
    /// 名前と引数だけを見て `xxx(selector, expected)` と書かれるのを防ぐ(その形は無い)
    public let signature: String
    public let summary: String
    /// `exist(...)` / `waitForDisplay(...)` の戻り値へ `.name(...)` で繋げられるか
    public let chainable: Bool

    init(_ name: String, _ category: String, _ signature: String, _ summary: String,
         chainable: Bool = false) {
        self.name = name
        self.category = category
        self.signature = signature
        self.summary = summary
        self.chainable = chainable
    }
}

public enum DSLCommandIndex {

    /// 索引に載せない `public func`(マクロが生成する呼び出し口で、利用者は書かない)
    public static let internalNames: Set<String> = ["ftRunSetUp", "ftRunTearDown"]

    /// 分類の一覧(索引に出てくる順)。`api dsl-commands --category` の help はここから導出する
    /// (手書きの列挙は分類を足したときに必ずずれる)
    public static var categories: [String] {
        var seen: [String] = []
        for command in all where !seen.contains(command.category) { seen.append(command.category) }
        return seen
    }

    public static let all: [DSLCommandInfo] = [
        // MARK: structure
        .init("scenario", "structure", "scenario { }",
              "The body of one @Test. Wraps the scenes."),
        .init("scene", "structure", "scene(number, title) { }",
              "One step of the test, recorded as a section of the report."),
        .init("condition", "structure", "condition { }",
              "The precondition part of a scene (chained: condition { }.action { }.expectation { })."),
        .init("action", "structure", "action { }",
              "The operation part of a scene."),
        .init("expectation", "structure", "expectation { }",
              "The verification part of a scene. A block with no assertions is reported as a warning."),
        .init("group", "structure", "group(name) { }",
              "Prefixes the recorded steps with [name]. Execution and failure semantics are unchanged."),
        .init("procedure", "structure", "procedure(description) { try await ... }",
              "Runs arbitrary async Swift as one step. A throw fails the scenario."),
        .init("verify", "structure", "verify(message) { }",
              "Records the block as one check step. Zero assertions inside is inconclusive."),
        .init("irregularHandler", "structure", "irregularHandler(detect, dismiss:, maxDismissals:?)",
              "Declares an in-app message to close automatically whenever it appears."),
        .init("iosAlertHandler", "structure", "iosAlertHandler(alert:, button:)",
              "Announces ONE upcoming OS system alert (permission / ATT) and the button to press on it."
                  + " alert: (which alert, matched against its title) is mandatory."
                  + " Register before the action that triggers it; the entry is removed once pressed."
                  + " Both fields use selector syntax: || alternatives (ja/en devices) and *"
                  + " for the match mode (bare = exact, *x* = contains)."
                  + " Titles embed the app name, so alert: is written *x* in practice"
                  + " (alert: \"*トラッキング*||*track your activity*\", button: \"許可||Allow\")."
                  + " hybrid engine only."),
        .init("suppressHandler", "structure", "suppressHandler { }",
              "Runs the block without closing declared interruptions, so the scenario can"
                  + " check or operate the modal itself. It does not stop the app from showing one."),
        .init("useHandler", "structure", "useHandler { }",
              "Inside suppressHandler or disableHandler, restores automatic closing for the block."),
        .init("disableHandler", "structure", "disableHandler()",
              "Stops closing declared interruptions until enableHandler(). Unlike suppressHandler,"
                  + " this spans condition/action/expectation blocks."),
        .init("enableHandler", "structure", "enableHandler()",
              "Resumes what disableHandler() stopped."),

        // MARK: operation
        .init("tap", "operation",
              "tap(selector, holdSeconds:, maxGestureSeconds:, containerInference:, waitSeconds:, scroll:, maxSwipes:)",
              // **座標形はオーバーロードなので別項目にできない**(索引は関数名で一意。
              // signature 文字列は BatchArgSpecTable が位置引数名を導出するのにも使うので触らない)
              "Taps an element. holdSeconds greater than 0 makes it a long press, capped at 10s by "
                + "default — pass maxGestureSeconds: (up to 60) to allow longer. "
                + "There is also tap(x:, y:, holdSeconds:, maxGestureSeconds:) for raw coordinates — "
                + "iOS pt / Android px, the same system as the snapshot frames. Prefer a selector: "
                + "coordinates hit something else as soon as the layout moves, and they are for screens "
                + "where the app publishes nothing to select. Also chains as "
                + "element.tap(holdSeconds:, maxGestureSeconds:): an element grabbed by "
                + "findImage/findImages is tapped at the centre of the found frame.",
              chainable: true),
        .init("select", "operation", "select(selector, requireVisible:, waitSeconds:, scroll:, maxSwipes:)",
              "Grabs an element without touching the device. Returns an empty element instead of failing."),
        .init("findImage", "operation",
              "findImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)",
              "Finds the element whose image is nearest to a DefaultClassifier sample image whose label ends with label "
                + "(a11y elements of a similar aspect ratio are compared by Vision image feature print distance). "
                + "Returns an empty element instead of failing; tap it with .tap()."),
        .init("findImages", "operation", "findImages(label, threshold:, aspectRatioTolerance:)",
              "Returns every element whose image distance to the sample image is below threshold, nearest first "
                + "(threshold: nil returns every candidate). Looks at the current screen once."),
        .init("lastElement", "operation", "lastElement",
              "The element the last single-element command grabbed. Values are frozen at grab time and cleared between scenes."),
        .init("type", "operation",
              "type(selector, text, replace:, waitSeconds:, scroll:, maxSwipes:) / type(text, replace:)",
              "Types text. replace: true clears the field first (like clearInput) instead of appending."
                  + " The single-argument form targets the focused element and takes text, not a selector."),
        .init("pressEnter", "operation", "pressEnter()",
              "Fires the Enter/IME action on the focused input."),
        .init("hideKeyboard", "operation", "hideKeyboard()",
              "Closes the soft keyboard. Android only; on iOS use pressEnter()."),
        .init("clearInput", "operation",
              "clearInput(selector, waitSeconds:, scroll:, maxSwipes:) / clearInput()",
              "Empties an input field. type appends, so clear first to replace."),
        .init("swipe", "operation", "swipe(.up / .down / .left / .right)",
              "Swipes the whole screen. The direction is the finger motion, unlike the scroll commands."),
        .init("rotateTo", "operation",
              "rotateTo(.portrait / .landscape)",
              "Rotates the app UI to that orientation. Reverted automatically to "
                  + "the original orientation at the end of the scenario."),
        .init("swipePointToPoint", "operation",
              "swipePointToPoint(startX:, startY:, endX:, endY:, durationSeconds:, maxGestureSeconds:)",
              "Drags between two coordinates (iOS = pt / Android = px). durationSeconds is capped at "
                  + "10s by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("swipeBy", "operation",
              "swipeBy(selector?, dxRatio:, dyRatio:, durationSeconds:, maxGestureSeconds:, waitSeconds:)",
              "Drags from the center of the target by a ratio of its size. Diagonal is allowed "
                  + "(both ratios non-zero). No selector = the whole screen. durationSeconds is capped "
                  + "at 10s by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("doubleTap", "operation", "doubleTap(selector?, waitSeconds:)",
              "Double-taps. No selector = the center of the screen."),
        .init("pinchOut", "operation",
              "pinchOut(selector?, scale:, durationSeconds:, maxGestureSeconds:, waitSeconds:)",
              "Pinches open (zoom in). scale must be > 1. No selector = the whole screen. "
                  + "durationSeconds is capped at 10s by default — pass maxGestureSeconds: "
                  + "(up to 60) to allow longer."),
        .init("pinchIn", "operation",
              "pinchIn(selector?, scale:, durationSeconds:, maxGestureSeconds:, waitSeconds:)",
              "Pinches closed (zoom out). scale must be between 0 and 1. durationSeconds is capped "
                  + "at 10s by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("gesture", "operation",
              "gesture(selector?, maxGestureSeconds:, waitSeconds:) { FTFinger(...).move(...).hold(...) }",
              "Replays several fingers' timed paths as one continuous touch sequence (no lifting "
                  + "between segments) — for gestures pinchOut/pinchIn/doubleTap/swipeBy cannot express. "
                  + "The trailing closure is an FTGestureBuilder returning [FTFinger]: each FTFinger "
                  + "starts at a ratio position (0...1 of the target's frame) and chains .move(x:y:"
                  + "durationSeconds:) / .hold(seconds:) in order; the last point lifts the finger. "
                  + "No selector = the whole screen. Total duration is capped at 10s by default — "
                  + "pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("swipeElementToElement", "operation",
              "swipeElementToElement(from, to, durationSeconds:, maxGestureSeconds:, waitSeconds:)",
              "Drags from one element to another. Only the start point is healed. durationSeconds is "
                  + "capped at 10s by default — pass maxGestureSeconds: (up to 60) to allow longer."),

        // MARK: scroll
        .init("scrollTo", "scroll",
              "scrollTo(selector, direction:, scrollFrame:, startMarginRatio:, endMarginRatio:,"
                  + " containerInference:, maxSwipes:)",
              "Scrolls until the element is found. Does not tap it."),
        .init("scrollDown", "scroll",
              "scrollDown(scrollFrame:, startMarginRatio:, endMarginRatio:, repeat:)",
              "Scrolls one screen further down the content."),
        .init("scrollUp", "scroll",
              "scrollUp(scrollFrame:, startMarginRatio:, endMarginRatio:, repeat:)",
              "Scrolls one screen back up the content."),
        .init("scrollRight", "scroll",
              "scrollRight(scrollFrame:, startMarginRatio:, endMarginRatio:, repeat:)",
              "Scrolls one screen further right in the content."),
        .init("scrollLeft", "scroll",
              "scrollLeft(scrollFrame:, startMarginRatio:, endMarginRatio:, repeat:)",
              "Scrolls one screen back left in the content."),
        .init("scrollToBottom", "scroll",
              "scrollToBottom(scrollFrame:, startMarginRatio:, endMarginRatio:, maxSwipes:)",
              "Scrolls until the screen stops changing. maxSwipes only caps a runaway."),
        .init("scrollToTop", "scroll",
              "scrollToTop(scrollFrame:, startMarginRatio:, endMarginRatio:, maxSwipes:)",
              "Scrolls back to the top edge."),
        .init("scrollToRightEdge", "scroll",
              "scrollToRightEdge(scrollFrame:, startMarginRatio:, endMarginRatio:, maxSwipes:)",
              "Scrolls to the right edge."),
        .init("scrollToLeftEdge", "scroll",
              "scrollToLeftEdge(scrollFrame:, startMarginRatio:, endMarginRatio:, maxSwipes:)",
              "Scrolls to the left edge."),
        .init("withScrollDown", "scroll", "withScrollDown(scrollFrame:) { }",
              "Makes every command in the block search by scrolling down."),
        .init("withScrollUp", "scroll", "withScrollUp(scrollFrame:) { }",
              "Makes every command in the block search by scrolling up."),
        .init("withScrollRight", "scroll", "withScrollRight(scrollFrame:) { }",
              "Makes every command in the block search by scrolling right."),
        .init("withScrollLeft", "scroll", "withScrollLeft(scrollFrame:) { }",
              "Makes every command in the block search by scrolling left."),
        .init("withoutScroll", "scroll", "withoutScroll { }",
              "Cancels an enclosing withScroll* for the block. For a single command pass scroll: .noScroll "
                + "(tap / type / clearInput / select / exist / notExist / findImage / existImage); "
                + "scrolling is specified only by scroll: (scroll: .down to search while scrolling). "
                + "There are no *WithScrollDown/Up/Right/Left or *WithoutScroll functions."),
        .init("withoutContainerInference", "scroll", "withoutContainerInference { }",
              "Disables container-inference-based tap/scroll correction for every command in the block."),

        // MARK: flick
        .init("flickCenterToTop", "flick",
              "flickCenterToTop(scrollFrame:, durationSeconds:, maxGestureSeconds:, repeat:, intervalSeconds:)",
              "One fast stroke from the center towards the top edge. durationSeconds is capped at 10s "
                  + "by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("flickCenterToBottom", "flick",
              "flickCenterToBottom(scrollFrame:, durationSeconds:, maxGestureSeconds:, repeat:, intervalSeconds:)",
              "One fast stroke from the center towards the bottom edge. durationSeconds is capped at "
                  + "10s by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("flickCenterToLeft", "flick",
              "flickCenterToLeft(scrollFrame:, durationSeconds:, maxGestureSeconds:, repeat:, intervalSeconds:)",
              "One fast stroke from the center towards the left edge. durationSeconds is capped at 10s "
                  + "by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("flickCenterToRight", "flick",
              "flickCenterToRight(scrollFrame:, durationSeconds:, maxGestureSeconds:, repeat:, intervalSeconds:)",
              "One fast stroke from the center towards the right edge. durationSeconds is capped at "
                  + "10s by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("flickLeftToRight", "flick",
              "flickLeftToRight(scrollFrame:, startMarginRatio:, durationSeconds:, maxGestureSeconds:,"
                  + " repeat:, intervalSeconds:)",
              "One fast stroke from the left edge to the right edge. durationSeconds is capped at 10s "
                  + "by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("flickRightToLeft", "flick",
              "flickRightToLeft(scrollFrame:, startMarginRatio:, durationSeconds:, maxGestureSeconds:,"
                  + " repeat:, intervalSeconds:)",
              "One fast stroke from the right edge to the left edge. durationSeconds is capped at 10s "
                  + "by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("flickBottomToTop", "flick",
              "flickBottomToTop(scrollFrame:, startMarginRatio:, durationSeconds:, maxGestureSeconds:,"
                  + " repeat:, intervalSeconds:)",
              "One fast stroke from the bottom edge to the top edge. durationSeconds is capped at 10s "
                  + "by default — pass maxGestureSeconds: (up to 60) to allow longer."),
        .init("flickTopToBottom", "flick",
              "flickTopToBottom(scrollFrame:, startMarginRatio:, durationSeconds:, maxGestureSeconds:,"
                  + " repeat:, intervalSeconds:)",
              "One fast stroke from the top edge to the bottom edge. durationSeconds is capped at 10s "
                  + "by default — pass maxGestureSeconds: (up to 60) to allow longer."),

        // MARK: existence
        .init("exist", "existence", "exist(selector, requireVisible:, waitSeconds:, scroll:, maxSwipes:)",
              "Asserts existence and returns the matched element for chaining."),
        .init("existImage", "existence",
              "existImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)",
              "Asserts that a DefaultClassifier template image is on the screen (same search as findImage; "
                + "fails when not found, saying the nearest distance) and returns the found element for chaining."),
        .init("waitForDisplay", "existence", "waitForDisplay(selector, waitSeconds:)",
              "Waits until the element is displayed. Does not scroll."),
        .init("waitForClose", "existence", "waitForClose(selector, waitSeconds:)",
              "Waits until the element is gone. Does not scroll."),
        .init("notExist", "existence", "notExist(selector, waitSeconds:, scroll:, maxSwipes:)",
              "Waits until the element is absent. With scroll:, finding it fails the check."),
        .init("countIs", "existence", "countIs(selector, count, waitSeconds:)",
              "Asserts the number of candidates in the tree. Visibility is not considered."),
        .init("enabledIsTrue", "existence", "select(selector).enabledIsTrue(waitSeconds:)",
              "Asserts the element is enabled. The target is the element grabbed last.", chainable: true),
        .init("enabledIsFalse", "existence", "select(selector).enabledIsFalse(waitSeconds:)",
              "Asserts the element is disabled. The target is the element grabbed last.", chainable: true),
        .init("checkIsON", "existence", "select(selector).checkIsON(prefer:, waitSeconds:)",
              "Asserts the element is checked. The target is the element grabbed last.", chainable: true),
        .init("checkIsOFF", "existence", "select(selector).checkIsOFF(prefer:, waitSeconds:)",
              "Asserts the element is not checked. Warns if a checked state was never observed. The target is the element grabbed last.",
              chainable: true),
        .init("imageIs", "existence", "select(selector).imageIs(label, waitSeconds:)",
              "Asserts the element's image is classified by DefaultClassifier (sample images in vision/classifiers/DefaultClassifier) as a label containing the given text. The target is the element grabbed last.",
              chainable: true),
        .init("keyboardIsShown", "existence", "keyboardIsShown(waitSeconds:)",
              "Asserts the soft keyboard is shown."),
        .init("keyboardIsNotShown", "existence", "keyboardIsNotShown(waitSeconds:)",
              "Asserts the soft keyboard is hidden."),
        .init("screenLooksLike", "existence", "screenLooksLike(description)",
              "Visual screen check by Foundation Models. Skipped when fm is off."),
        .init("appIs", "existence", "appIs(appID, waitSeconds:)",
              "Asserts the foreground app is the given bundle ID / package name."),

        // MARK: id
        .init("idIs", "id", "select(selector).idIs(expected, strict:, waitSeconds:)",
              "Asserts the identifier of the element equals expected. The target is the element grabbed last.",
              chainable: true),

        // MARK: text
        .init("textIs", "text", "select(selector).textIs(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the label equals expected. The target is the element grabbed last.", chainable: true),
        .init("textIsNot", "text", "select(selector).textIsNot(expected, strict:, waitSeconds:)",
              "Asserts the label differs from expected. The target is the element grabbed last.", chainable: true),
        .init("textContains", "text", "select(selector).textContains(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the label contains expected. The target is the element grabbed last.", chainable: true),
        .init("textContainsNot", "text", "select(selector).textContainsNot(expected, strict:, waitSeconds:)",
              "Asserts the label does not contain expected. The target is the element grabbed last.", chainable: true),
        .init("textStartsWith", "text", "select(selector).textStartsWith(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the label starts with expected. The target is the element grabbed last.", chainable: true),
        .init("textStartsWithNot", "text", "select(selector).textStartsWithNot(expected, strict:, waitSeconds:)",
              "Asserts the label does not start with expected. The target is the element grabbed last.", chainable: true),
        .init("textEndsWith", "text", "select(selector).textEndsWith(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the label ends with expected. The target is the element grabbed last.", chainable: true),
        .init("textEndsWithNot", "text", "select(selector).textEndsWithNot(expected, strict:, waitSeconds:)",
              "Asserts the label does not end with expected. The target is the element grabbed last.", chainable: true),
        .init("textMatches", "text", "select(selector).textMatches(pattern, requireVisible:, strict:, waitSeconds:)",
              "Asserts the label matches the regular expression (substring match). The target is the element grabbed last.", chainable: true),
        .init("textMatchesNot", "text", "select(selector).textMatchesNot(pattern, strict:, waitSeconds:)",
              "Asserts the label does not match the regular expression. The target is the element grabbed last.", chainable: true),
        .init("textMatchesDateFormat", "text", "select(selector).textMatchesDateFormat(format, requireVisible:, waitSeconds:)",
              "Asserts the label parses with the DateFormatter format. The target is the element grabbed last.", chainable: true),
        .init("textIsEmpty", "text", "select(selector).textIsEmpty(strict:, waitSeconds:)",
              "Asserts the label is empty. Visibility is not considered. The target is the element grabbed last.", chainable: true),
        .init("textIsNotEmpty", "text", "select(selector).textIsNotEmpty(strict:, waitSeconds:)",
              "Asserts the label is not empty. The target is the element grabbed last.", chainable: true),

        // MARK: value
        .init("valueIs", "value", "select(selector).valueIs(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the value equals expected. The target is the element grabbed last.", chainable: true),
        .init("valueIsNot", "value", "select(selector).valueIsNot(expected, strict:, waitSeconds:)",
              "Asserts the value differs from expected. The target is the element grabbed last.", chainable: true),
        .init("valueContains", "value", "select(selector).valueContains(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the value contains expected. The target is the element grabbed last.", chainable: true),
        .init("valueContainsNot", "value", "select(selector).valueContainsNot(expected, strict:, waitSeconds:)",
              "Asserts the value does not contain expected. The target is the element grabbed last.", chainable: true),
        .init("valueStartsWith", "value", "select(selector).valueStartsWith(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the value starts with expected. The target is the element grabbed last.", chainable: true),
        .init("valueStartsWithNot", "value", "select(selector).valueStartsWithNot(expected, strict:, waitSeconds:)",
              "Asserts the value does not start with expected. The target is the element grabbed last.", chainable: true),
        .init("valueEndsWith", "value", "select(selector).valueEndsWith(expected, requireVisible:, strict:, waitSeconds:)",
              "Asserts the value ends with expected. The target is the element grabbed last.", chainable: true),
        .init("valueEndsWithNot", "value", "select(selector).valueEndsWithNot(expected, strict:, waitSeconds:)",
              "Asserts the value does not end with expected. The target is the element grabbed last.", chainable: true),
        .init("valueMatches", "value", "select(selector).valueMatches(pattern, requireVisible:, strict:, waitSeconds:)",
              "Asserts the value matches the regular expression (substring match). The target is the element grabbed last.", chainable: true),
        .init("valueMatchesNot", "value", "select(selector).valueMatchesNot(pattern, strict:, waitSeconds:)",
              "Asserts the value does not match the regular expression. The target is the element grabbed last.", chainable: true),
        .init("valueMatchesDateFormat", "value", "select(selector).valueMatchesDateFormat(format, requireVisible:, waitSeconds:)",
              "Asserts the value parses with the DateFormatter format. The target is the element grabbed last.", chainable: true),
        .init("valueIsEmpty", "value", "select(selector).valueIsEmpty(strict:, waitSeconds:)",
              "Asserts the value is empty. Visibility is not considered. The target is the element grabbed last.", chainable: true),
        .init("valueIsNotEmpty", "value", "select(selector).valueIsNotEmpty(strict:, waitSeconds:)",
              "Asserts the value is not empty. The target is the element grabbed last.", chainable: true),

        // MARK: app
        .init("launchApp", "app", "launchApp(appID?, url:?)",
              "Terminates (if running) and launches the app fresh, starting at the entry screen."
                  + " With url:, also delivers the URL right after launch."),
        .init("openURL", "app", "openURL(url)",
              "Delivers a URL (deep link) to the already-running app without restarting it."),
        .init("restartApp", "app", "restartApp(appID?)",
              "Terminates and launches again, resetting in-process state."),
        .init("terminateApp", "app", "terminateApp()",
              "Terminates the app."),
        .init("installApp", "app", "installApp(path?)",
              "Installs the app. Without a path, the run profile appPath is used."),
        .init("removeApp", "app", "removeApp(appID?)",
              "Uninstalls the app. Removing the app under test breaks the rest of the run."),
        .init("clearAppData", "app", "clearAppData(appID?)",
              "Clears app data and permissions but keeps the app. iOS is simulator only."),
        .init("home", "app", "home()",
              "Goes to the home screen."),
        .init("back", "app", "back()",
              "Goes back (Android back key / iOS left-edge swipe)."),
        .init("appSwitcher", "app", "appSwitcher()",
              "Opens the app switcher."),
        .init("tapAppIcon", "app", "tapAppIcon(name?)",
              "Finds and taps the app icon on the home screen."),
        .init("screenshot", "app", "screenshot(filename?)",
              "Captures the screen and embeds it in the report after this step."
              + " The file name can also be passed positionally: screenshot(\"a.png\")."),

        // MARK: control
        .init("wait", "control", "wait(seconds)",
              "Fixed sleep. Not for waiting on elements — every command already polls."),
        .init("ifCanSelect", "control", "ifCanSelect(selector, waitSeconds:) { }.ifElse { }",
              "Runs the block when the selector resolves. Decides immediately unless waitSeconds is given."),
        .init("ios", "control", "ios { }",
              "Runs the block only on iOS."),
        .init("android", "control", "android { }",
              "Runs the block only on Android."),
        .init("repeatWhileCanSelect", "control",
              "repeatWhileCanSelect(selector, maxLoopCount:, waitSeconds:, title:) { }",
              "Repeats while the selector keeps resolving."),
        .init("doUntilTrue", "control", "doUntilTrue(description, waitSeconds:, intervalSeconds:, maxLoopCount:) { condition }",
              "Repeats until the async condition is true. For app or external state, not elements."),

        // MARK: this (device-independent values)
        .init("thisIs", "this", "value.thisIs(expected, strict:)", "Asserts equality."),
        .init("thisIsNot", "this", "value.thisIsNot(expected, strict:)", "Asserts inequality."),
        .init("thisIsTrue", "this", "value.thisIsTrue()", "Asserts the Bool is true."),
        .init("thisIsFalse", "this", "value.thisIsFalse()", "Asserts the Bool is false."),
        .init("thisIsEmpty", "this", "value.thisIsEmpty()", "Asserts the string is empty."),
        .init("thisIsNotEmpty", "this", "value.thisIsNotEmpty()", "Asserts the string is not empty."),
        .init("thisIsBlank", "this", "value.thisIsBlank()", "Asserts the string is whitespace only."),
        .init("thisIsNotBlank", "this", "value.thisIsNotBlank()", "Asserts the string is not whitespace only."),
        .init("thisContains", "this", "value.thisContains(expected)", "Asserts a substring match."),
        .init("thisContainsNot", "this", "value.thisContainsNot(expected)", "Asserts no substring match."),
        .init("thisStartsWith", "this", "value.thisStartsWith(expected)", "Asserts a prefix match."),
        .init("thisStartsWithNot", "this", "value.thisStartsWithNot(expected)", "Asserts no prefix match."),
        .init("thisEndsWith", "this", "value.thisEndsWith(expected)", "Asserts a suffix match."),
        .init("thisEndsWithNot", "this", "value.thisEndsWithNot(expected)", "Asserts no suffix match."),
        .init("thisMatches", "this", "value.thisMatches(pattern)", "Asserts a regular expression match."),
        .init("thisMatchesNot", "this", "value.thisMatchesNot(pattern)", "Asserts no regular expression match."),
        .init("thisMatchesDateFormat", "this", "value.thisMatchesDateFormat(format)",
              "Asserts the string parses with the DateFormatter format."),
        .init("thisIsGreaterThan", "this", "value.thisIsGreaterThan(other)", "Asserts a numeric greater-than."),
        .init("thisIsGreaterThanOrEqual", "this", "value.thisIsGreaterThanOrEqual(other)",
              "Asserts a numeric greater-than-or-equal."),
        .init("thisIsLessThan", "this", "value.thisIsLessThan(other)", "Asserts a numeric less-than."),
        .init("thisIsLessThanOrEqual", "this", "value.thisIsLessThanOrEqual(other)",
              "Asserts a numeric less-than-or-equal."),
    ]

    /// `exist(...)` の戻り値だけが持つメソッド(自由関数の対応が無い)。chainable の照合に使う。
    /// **現在は空** —— チェーンできる検証はすべて同名の1引数自由関数を持つ
    public static let chainOnlyNames: Set<String> = []
}
