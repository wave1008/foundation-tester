# For Shirates Users

Ftester's Swift DSL follows Shirates (Classic) conventions — command names, argument names,
defaults, and behavior are carried over rather than reinvented. This page maps what you already
know from Shirates onto ftester, and lists what's deliberately different or missing.

## Structure

| Shirates | ftester |
|---|---|
| `scenario` / `case` / `condition` / `action` / `expectation` | `scenario` / `scene` / `condition` / `action` / `expectation` |
| a `UITest` class | a class annotated `@TestClass` |
| `@Testrun` | a run profile (`profiles/runs/<name>.json`) |

## Same name, works as you'd expect

| Category | Commands |
|---|---|
| Tap / select | `tap` (+`holdSeconds:`), `tapWithScrollDown/Up/Left/Right`, `tapWithoutScroll`, `select`, `selectWithScroll*`, `selectWithoutScroll` |
| Existence | `exist`, `existWithScrollDown/Up`, `existWithoutScroll`, `appIs` |
| Text / value assertions | `textIs` / `textIsNot` / `textContains(Not)` / `textStartsWith(Not)` / `textEndsWith(Not)` / `textMatches(Not)` / `textMatchesDateFormat` / `textIsEmpty` / `textIsNotEmpty`, and the same 10-form set for `valueIs…` |
| Any-value assertions | `thisIs` / `thisIsNot` / `thisIsTrue` / `thisIsFalse` / `thisIsEmpty` / `thisIsNotEmpty` / `thisIsBlank` / `thisIsNotBlank` / `thisContains(Not)` / `thisStartsWith(Not)` / `thisEndsWith(Not)` / `thisMatches(Not)` / `thisMatchesDateFormat` / `thisIsGreaterThan(OrEqual)` / `thisIsLessThan(OrEqual)` |
| Scroll | `scrollDown/Up/Left/Right` (+`repeat:`), `scrollToBottom/Top/RightEdge/LeftEdge` (+`maxSwipes:`), `withScrollDown/Up/Left/Right`, `withoutScroll` |
| Flick | `flickCenterToTop/Bottom/Left/Right`, `flickLeftToRight/RightToLeft`, `flickBottomToTop/TopToBottom` |
| Swipe | `swipePointToPoint`, `swipeElementToElement` |
| Branch / loop | `ifCanSelect { }.ifElse { }`, `doUntilTrue`, `ios { }` / `android { }` |
| Interrupt handling | `suppressHandler { }` / `useHandler { }` / `disableHandler()` / `enableHandler()` |
| App control | `launchApp` / `terminateApp` / `restartApp` / `installApp` / `removeApp` |
| Waiting | `wait` / `waitForDisplay` / `waitForClose` |
| Recording / flow | `procedure`, `screenshot`, `verify`, `@Deleted` |

## Renamed / different form

| Shirates | ftester | Note |
|---|---|---|
| `dontExist` | `notExist(sel, timeout:scroll:maxSwipes:)` | reads more clearly as a negation of `exist` |
| `sendKeys` | `type("…")` / `type(sel, "…")` | `type(sel, "…", replace: true)` also folds in a clear-before-type, which Shirates does as two separate calls |
| `pressBack` | `back()` | works on both OS (iOS falls back to an edge swipe when there's no navigation bar back button) |
| `pressHome` | `home()` | works on both OS |
| `irregularHandler { }` (lambda registration) | `irregularHandler(sel, dismiss:, maxDismissals:)` | declared by selector rather than by registering a lambda; auto-dismisses an in-app modal whenever it appears |
| `goPreviousApp` | `appSwitcher()` | opens the app switcher only; it doesn't select the previous app for you |
| `displayedIs` | `requireVisible:` argument + a run profile's `falsePositiveCheck` | visibility checking is a parameter on the relevant command rather than its own assertion |

## Not present — write it this way instead

| Shirates | Write it in ftester as |
|---|---|
| Nicknames (selector / screen / dataset nicknames) | selectors written directly; no indirection layer |
| `screenIs` / `screenIsOf` / `isScreen(Of)` / `waitScreen(Of)` / `switchScreen` | `screenLooksLike("description")` (FM visual check), or `exist(sel)` on an element unique to that screen |
| `existImage` / `dontExistImage` / `findImage*` / `imageIs` / `imageContains` (image template matching) | `screenLooksLike("description")` (FM visual verification) |
| `macro` | a plain Swift function |
| `manual` / `knownIssue` | not available — a failing command always aborts the scenario; there is no escape hatch to mark a failure as expected |
| `must` / `should` / `want`, `SKIP` / `MANUAL` / `NOTIMPL` | not available — for OS-specific tests use `@TestClass(platform:)` / `@Test(platform:)` instead |
| Datasets (`account` / `app` / `data` / `dataPattern`) | Swift literals or constants written directly in the scenario |
| `canSelect` on its own | wrap it in `ifCanSelect { }` or `repeatWhileCanSelect(sel, max:) { }` |
| `existAll` / `canSelectAll` / `dontExistAll` | a chain of individual `exist` calls (each can have its own `timeout:` / `scroll:`) |
| `tempSelector` / `tempValue` | write the selector directly at the call site |
| `withContext` (native/web context switching) | not needed — WebView content is read transparently through the same selectors and commands |

## ftester-only additions

Shirates has no equivalent for these:

| Command | What it does |
|---|---|
| `screenLooksLike("description")` | FM multimodal visual verification against a screenshot |
| `countIs(sel, n)` | asserts the number of matching elements |
| `scrollTo(sel, direction:, maxSwipes:)` | scrolls in the given direction until the selector resolves |
| `swipeBy(sel?, dxRatio:dyRatio:)` | a relative drag by ratio of the target's size, diagonal included (for panning maps) |
| `doubleTap(sel?)` | a genuine double-tap gesture (two separate `tap` calls are too slow to register as one) |
| `pinchOut(sel?, scale:)` / `pinchIn(sel?, scale:)` | two-finger pinch zoom |
| `clearAppData(bundleID?)` | clears app data and permissions without reinstalling — for onboarding / permission-dialog tests |
| `openURL(url)` / `launchApp(url:)` | deep-link delivery, with or without restarting the app |
| `rotateTo(.landscape)` | rotates the device; the scenario restores the original orientation on completion |
| `iosAlertHandler(alert:, button:)` | auto-dismisses iOS system alerts (permission prompts etc. — a separate process, so `irregularHandler` can't see them) |
| `@Draft("reason")` | marks a scenario as work-in-progress; excluded from bulk runs like `@Deleted`, but can still be run by exact ID |
| `group("name") { }` | prefixes a run of steps with a label in the report; doesn't change execution or failure handling |
| Typed selectors (`Sel`) | `tap(.id("login_btn").or(.text("Log In")))` — the same locators as strings, but typo'd names become compile errors |
| `#id` also matches `placeholder` | if no element's identifier matches, `#id` falls back to matching the `placeholder` value (input fields are addressed differently depending on the platform/engine) |
| `\|\|` in a selector | a union of candidates — `tap` lands on the first one found, so `"#id\|\|Label"` reads as "prefer the id, fall back to the label" |

### Link
- [index](../index.md)
