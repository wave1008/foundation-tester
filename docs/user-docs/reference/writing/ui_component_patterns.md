# UI Component Patterns and Quirks

[in Japanese(日本語)](ui_component_patterns_ja.md)

How to target, operate and verify the stock components of Compose Multiplatform, Flutter, React
Native, Android (Views/XML) and iOS (SwiftUI) in a scenario. **This page is meant as knowledge for an
agent (AI assistant) writing scenarios** — if the app's screen has one of these components, read the
matching section before writing.

- Verified on: Compose Multiplatform 1.11 (≈ Material3 1.4), Flutter, React Native 0.86.2 (New
  Architecture / Fabric), Android Views + Material Components, and SwiftUI. iOS 27 Simulator (hybrid
  engine / XCUITest engine) and Android 15 Emulator
- Every behaviour here reproduces with the verification apps bundled with fleetest
  (`E2EXAppCMP/`, `E2EXAppFlutter/`, `E2EXAppRN/`, `E2EXAppAndroid/`, `E2EXAppIOS/`) and their
  scenarios (`TestProjects/E2EX-{CMP,Flutter,RN,Android,iOS}/scenarios/`), read them as worked
  examples. The five apps implement the same screen layout, the same `#id`s, the same labels and the
  same echo strings with each framework's stock components
- **The `#id`s in the examples (such as `#btn_alert` and `#pager_main`) and the text used to check results (echo
  strings such as `drawerOpen=false`) belong to these verification apps.** In your app, replace them with the `#id`s and
  labels of the matching elements and the text your app actually shows. For components whose result your app does not
  show on screen, check the change on the screen instead (whether an element exists, its text)
- Each section's table lists differences in the order **CMP, Flutter, RN, Android View,
  SwiftUI (iOS)**. "Same as above" means the behaviour just described holds as-is
- **iOS native (SwiftUI) has no stock component for a modal navigation drawer or a tooltip**, so it
  omits those two screens (drawer, tooltip). If your app implements its own drawer/tooltip
  equivalent on iOS, use the other frameworks' columns as reference
- **"Current limitation" entries are unresolved limitations on the fleetest side**. Write the
  workaround given there

## Common to all components

### While a modal is open, the screen behind it drops out of the tree

While a drawer, a dropdown menu, a bottom sheet or a popup menu is open, **the elements of the screen
behind it are not in the tree (snapshot)** (verified on every framework, on both iOS and Android;
SwiftUI's `Menu`/`Picker(.menu)` behave the same way). Only the modal's contents and the scrim's
"close" button remain.

- Read result labels behind the modal (`#txt_result` etc.) **after closing the modal**
- "Tap outside the modal to close it" cannot be written as an element tap, because nothing behind it
  can be targeted (see the "Dropdown menu" section below)

```swift
tap("#btn_open_drawer")
exist("#txt_drawer_header")          // OK: prove it opened with an element inside the modal
// select("#txt_state").textIs(...)  // NG: elements behind are not found while it is open
tap("#drawer_item_sent")             // close it first
select("#txt_state").textIs("drawerOpen=false")
```

**Current limitation**: React Native collapses everything under an `accessible` ancestor
(`accessible={true}` on a `View`/`Pressable`) into a single element. This collapsing happens only on
iOS, not on Android, so components whose library sets `accessible` by default — `Tooltip`,
`BottomSheetModal` — end up with their **inner elements missing from the tree on iOS only** (see
"Tooltip" and "Bottom sheet" below). The workaround is for the app to pass `accessible={false}`, so a
scenario cannot fix this on its own (it depends on the target app's implementation).

**Current limitation**: **On Flutter's iOS**, once an overlay (a `Tooltip`, a dialog, etc.) has been
shown on a screen, **that screen's a11y rects are reported at 1/screen-scale (1/3 on an iPhone) until
the next screen transition** (Flutter's own report). **The default iOS engine (in-app) corrects this
automatically**, so nothing changes in how you write scenarios. Only **the XCUITest engine**
(`iosInappEngine: false`) cannot correct it, and taps land in the wrong spot. Workaround (XCUITest
engine only): after showing an overlay on a screen, move to another screen and come back before the
next action.

### An icon-only button is labelled by its accessibility label

An icon-only button can be targeted by its accessibility label (CMP's `contentDescription`,
Flutter/RN's `Semantics`/`accessibilityLabel`, Android View's `contentDescription`, or SwiftUI's
`.accessibilityLabel`), as in `tap("Back")`. On a screen that uses a character instead of an icon,
iOS may **join the character into the label**. Target such a button by `#id` or by the partial match
`*text*`.

### Always pass scrollFrame for horizontal containers

`scroll: .right` / `withScrollRight { }` swipe **the centre of the screen** when nothing else is
given. If a pager (CMP's `HorizontalPager`, Flutter's `PageView`, RN's
`react-native-pager-view`, Android's `ViewPager2`, or iOS's `TabView(.page)`) or an overflowing tab
row is not at the centre, nothing moves and the step fails. **When searching a horizontal container,
pass that container as `scrollFrame:`** (the container needs an `#id`).

```swift
withScrollRight(scrollFrame: "#pager_main") {
    tap("#btn_page_4")
}
```

The iOS in-app engine cannot page RN's `react-native-pager-view` (a `UIPageViewController` inside) by
itself, so it switches to a real XCUITest swipe for that area only (note `fell back to XCUITest`).
Nothing changes in how you write it.

### On Android the screen edges are the OS "back"

On Android with gesture navigation, **a horizontal swipe that starts at the left or right edge of the
screen is the OS "back"** (true for every framework). Do not move the start of a swipe to the edge (do
not make `flickLeftToRight(startMarginRatio:)` small; keep the default).

### The back button is targeted differently per framework

| Framework | Back button |
|---|---|
| CMP | `#btn_back` (icon-only `IconButton`). Can also be pressed by its label |
| Flutter | Same `#btn_back`. **On iOS an edge swipe sometimes does not go back** (see "Navigation" below; use the app's back button in that case) |
| RN | **No `#btn_back`**. The `native-stack` back button is rendered natively and cannot carry a `testID`. Drive it with `back()` (the system back) |
| Android View | **No `#btn_back`**. The `MaterialToolbar`'s navigationIcon is an internal, unnamed `ImageButton`, so target it by its label (the equivalent of a "Back" content description) |
| SwiftUI (iOS) | Targetable by the fixed id **`#BackButton`**. Its label is the same string as the previous screen's title (on a narrow screen, iOS may round it to a generic label) |

```swift
ios { tap("#BackButton") }
android { tap("Back") }       // Android View: target by label (no id)
```

## Pager

- Next page: `flickRightToLeft(scrollFrame: "#pager_main")` (one page per flick)
- An element on an off-screen page: `withScrollRight(scrollFrame: "#pager_main") { tap("#…") }`
- Back to the edge: `scrollToLeftEdge(scrollFrame: "#pager_main")` (same for `scrollToRightEdge`)
- Check the current page with the page-number label the app shows

| Framework | Component / difference |
|---|---|
| CMP | `HorizontalPager`. Same as above |
| Flutter | `PageView`. Same as above |
| RN | `react-native-pager-view`. Same as above (on the iOS in-app engine, only the paging switches to a real XCUITest swipe) |
| Android View | `ViewPager2`. Same as above |
| SwiftUI (iOS) | `TabView(.page)`. Same as above (the verification app is native, so it is not subject to the in-app limitation) |

## Bottom sheet

- Prove it opened with an element inside the sheet (the screen behind drops out of the tree)
- A long list inside the sheet: `tap("#row_25", scroll: .down)` reaches it (the sheet expands first,
  then its contents scroll). When `scrollFrame:` points at the list inside the sheet and **the list does
  not move at all inside a partially open sheet, the search drags once, further, inside that list to
  expand the sheet and then searches again** (on XCUITest the short search swipe can be used up by the
  sheet's own resizing and snap back; the step carries a note)
- Pressing an option that closes the sheet works on every framework
- Closing with a swipe: **move the finger from the title to a row near the bottom of the sheet**. Do
  not use `swipeBy` — its ratio is **relative to the target's size** and capped at 0.9 per side, so on
  a small title it moves only a few points

```swift
swipeElementToElement("#sheet_title", "#row_04", durationSeconds: 0.3)
```

| Framework | Component / difference |
|---|---|
| CMP | `ModalBottomSheet` (expands halfway by default). On iOS the scrim's "close" button also works (the iOS tree has a button with a localized label; take it from a snapshot, since it changes with the locale) |
| Flutter | `showModalBottomSheet(isScrollControlled: true)` + a fixed height (70%). **You must drag past half the sheet's height to close it** (the closing distance depends on the app's setting; dragging less snaps back) |
| RN | `@gorhom/bottom-sheet`'s `BottomSheetModal`. **On iOS its contents default to a single `accessible=true` element** (the title, options and rows disappear; the app passes `accessible={false}` to avoid this. Android is not affected) |
| Android View | `BottomSheetDialogFragment`. Same as above |
| SwiftUI (iOS) | `.sheet` + `.presentationDetents([.medium, .large])`. The app manages the dismiss verdict itself |

**Current limitation**: with RN's `@gorhom/bottom-sheet` persistent sheet (`BottomSheet`) half open, **the search cannot expand
the sheet on iOS** (a swipe that starts on the list inside the sheet does not expand it, even a real XCUITest swipe; Android
expands it and then scrolls the list). Workaround: swipe up from the sheet's title to open it fully before searching

```swift
swipeElementToElement("#txt_player_title", "#txt_sheet_state", durationSeconds: 0.5)
tap("#queue_row_21", scroll: .down)
```

## Dropdown menu / popup menu

- Items can be pressed by `#id` or by label
- Pressing an item closes the menu
- **Tap outside to close**: nothing behind the menu is in the tree, so it cannot be targeted by an
  element. On Android use `back()`; on iOS tap an empty spot of the screen by coordinates

```swift
tap("#btn_open_menu")
android { back() }
ios { tap(x: 200, y: 600) }   // an empty spot that the menu does not cover
notExist("#menu_item_copy")   // confirm it closed
```

| Framework | Component / difference |
|---|---|
| CMP | `DropdownMenu`. Same as above |
| Flutter | `PopupMenuButton` (`onCanceled` reports dismissed). Same as above |
| RN | `react-native-paper`'s `Menu`. **The app explicitly consumes the Android back button** (a known library quirk: without that, the whole screen would navigate back instead of just closing the menu — an app-implementation detail, so an app without this handling may pop the screen instead) |
| Android View | `PopupMenu`. Its rows are unnamed `ListPopupWindow` rows, so it **can only be targeted by label** (there is no `#menu_item_*`) |
| SwiftUI (iOS) | `Menu`. Whether an identifier set on an item reaches the AX tree is not guaranteed by SwiftUI's public API. **If it does not reach, target by label** (this app is verified to work as expected, but other layouts may not) |

## Selection field (read-only dropdown)

A read-only selection field puts **the chosen value in a different place depending on the
framework**.

| Framework | Component | Where the value shows up |
|---|---|---|
| CMP | `ExposedDropdownMenuBox` | **`.value`**. `.text` is the field's label on iOS (e.g. the localized "Fruit" text) and `nil` on Android |
| Flutter | `DropdownMenu` | The id sits on the outer container; **the chosen value only shows up on an inner node, on iOS**. **On Android the tree carries no value at all** |
| RN | `Pressable` + a read-only `TextInput` | The app exposes it as `accessibilityValue` on the outer `View` (an app-implementation choice; the field itself may drop out of the tree on iOS) |
| Android View | `MaterialAutoCompleteTextView` | **No value in the tree**. Confirm through the app's own echo instead |
| SwiftUI (iOS) | `Picker(.pickerStyle: .menu)` | **The chosen value appears in the label itself** (e.g. "Fruit, Banana"). There is no `.value` |

```swift
select("#field_fruit").valueContains("Banana")   // OK on CMP (both OSes)
// Android View / Flutter (Android) put no value in the tree; verify via the app's echo instead
select("#txt_fruit_result").textIs("fruit=banana")
```

**Current limitation**: Android View's `MaterialAutoCompleteTextView` also gives its suggestion popup
rows no id (unnamed `ListPopupWindow` rows), so target suggestions by label. Flutter's `DropdownMenu`
suggestions are the same — label is the reliable choice.

## Date picker

- The day cells cannot carry an `#id`. **Target them by label**. The label changes with the locale,
  so list the candidates with `||`

```swift
tap("<the day cell's label from a snapshot>||20")
tap("OK")
```

| Framework | Component / difference |
|---|---|
| CMP | `DatePickerDialog`. OK/Cancel can be given a `testTag` (`#btn_date_ok` / `#btn_date_cancel`) |
| Flutter | `showDatePicker`. **OK/Cancel cannot carry an id** (inside a built-in dialog; the labels stay the English default). **`date=null` cannot be reproduced in the verification app** (there is no UI to reset the selection to none, so anything but Cancel always returns a selected date). A loose match (`*January 20*`) also matches the header ("January 2026"), so **include the year: `*January 20, 2026*`** |
| RN | `@react-native-community/datetimepicker`. **Android shows a fully native dialog** whose OK/Cancel cannot carry a `testID` (target by label). `#btn_date_ok` / `#btn_date_cancel` exist **only on the iOS inline modal** |
| Android View | `MaterialDatePicker`. OK/Cancel are the library's internal buttons (their id cannot be overridden); target by the label set via `setPositiveButtonText` etc |
| SwiftUI (iOS) | `.sheet` + `DatePicker(.graphical)`. iOS's `DatePicker` always holds a value, so **`date=null` never occurs** |

## Navigation drawer

- Opening with a button and closing by pressing an item work on every framework
- While it is open, the screen behind drops out of the tree (the "Common to all components"
  section). Read state labels after closing it
- **Opening with a swipe**: `flickLeftToRight()` / close with `flickRightToLeft()`. **Keep the default
  start point** — on Android, a small `startMarginRatio:` (such as 0.05) moves the start onto the
  screen edge, which becomes the OS "back" and goes to the previous screen

| Framework | Component / difference |
|---|---|
| CMP | `ModalNavigationDrawer(gesturesEnabled = true)`. Same as above |
| Flutter | `Scaffold.drawer` + `Drawer`. Same as above |
| RN | `@react-navigation/drawer`. **Opening with a swipe uses the same screen-edge zone as Android's gesture-navigation "back"** — drive it with the app's open button instead of a swipe in scenarios |
| Android View | `DrawerLayout` + `NavigationView`. Same edge conflict as above, so **drive it with a button in scenarios** |
| SwiftUI (iOS) | **Not present** (iOS has no stock modal navigation drawer, so the verification app does not have this screen) |

## Pull to refresh

- Trigger a refresh: move a finger from an upper row to a lower row of the list
  (`swipeElementToElement("#row_01", "#row_06", durationSeconds: 0.6)`)
- Check that the refresh finished with what the app shows (a count, a timestamp, …)

| Framework | Component / difference |
|---|---|
| CMP | `PullToRefreshBox`. Responds to `swipeElementToElement` |
| Flutter | `RefreshIndicator`. Same as above |
| RN | `RefreshControl`. **On iOS, `swipeElementToElement`'s short distance does not trigger it** (below) |
| Android View | `SwipeRefreshLayout`. Same as above (responds to `swipeElementToElement`) |
| SwiftUI (iOS) | `.refreshable`. **A short `swipeElementToElement` distance (5 rows, roughly 260pt) does not trigger it** (below) |

**Current limitation**:

- **SwiftUI's `.refreshable` and RN's iOS `RefreshControl` need a long pull** (measured around
  470pt; a 5-row swipe of roughly 260pt via `swipeElementToElement` does not start it). Workaround:
  use a raw gesture that drags the full screen ratio from top to bottom.
  ```swift
  gesture {
      FTFinger(x: 0.5, y: 0.3).move(x: 0.5, y: 0.85, durationSeconds: 1.0).hold(seconds: 0.3)
  }
  ```
- With **the iOS XCUITest engine** (`iosInappEngine: false`), `scrollToTop()` at the top of the list
  **runs one extra refresh** (the swipe that confirms the edge becomes a pull, because XCUITest does
  not tell whether a container can still scroll). It does not happen with the default iOS engine
- **On Flutter's iOS, `scrollToTop()` back to the top can also trigger a refresh** (under investigation)
- Same workaround for both: in scenarios that verify the refresh count, do not read the count
  **after** `scrollToTop()` (verify the count before it)
- It does not happen on Android with any framework (`scrollToTop()` / `scrollToBottom()` move the list
  with accessibility scroll actions, so they never overscroll into a pull)

## Snackbar / toast

- Its contents cannot carry an `#id`. Target both the message and the action **by label**
  (`exist("Deleted")` / `tap("Undo")`)
- Wait for it to go away: `waitForClose("Saved", waitSeconds: 10)`
  (short ≈ 4 s, long ≈ 10 s)

| Framework | Component / difference |
|---|---|
| CMP | Scaffold's `SnackbarHost`. Same as above |
| Flutter | `ScaffoldMessenger.showSnackBar`. Same as above (duration is a literal number of seconds) |
| RN | `react-native-paper`'s `Snackbar`. Same as above |
| Android View | Material `Snackbar` (`setDuration` set explicitly to 10000ms / 4000ms; the default LENGTH_LONG/SHORT is not used) |
| SwiftUI (iOS) | **No stock snackbar component**, so it is a custom overlay. Behaviour is the same |

**Turn visual verification off when checking short-lived components**: `exist("Deleted", requireVisible: false)`.
Text visual verification captures the screen and reads it, which takes time (more so with many parallel
lanes, on a busy machine, or on a project's first run while the OCR model compiles). If the component disappears
before the verification finishes, the step fails with "not found" even though it was shown. With it
turned off, the check only confirms that the element is in the tree.

## Grid

- Off-screen cells are not in the tree. `tap("#cell_86", scroll: .down)` reaches them; go back with
  `scroll: .up`
- Vertical search works as-is even with several elements per row

Same across every framework (CMP `LazyVerticalGrid`, Flutter `GridView.builder`, RN
`FlatList numColumns={3}`, Android View `RecyclerView` + `GridLayoutManager`, SwiftUI
`LazyVGrid`).

## Swipe to dismiss

- Swipe horizontally on the row: `swipeBy("#row_3", dxRatio: -0.5, dyRatio: 0, durationSeconds: 0.3)`.
  The ratio is capped at 0.9 per side
- You can also verify that a swipe in the disabled direction does nothing (the row stays)

| Framework | Component / difference |
|---|---|
| CMP | `SwipeToDismissBox`. The swipe removes the row directly |
| Flutter | `Dismissible(direction: .endToStart)`. The swipe removes the row directly |
| RN | `react-native-gesture-handler`'s `Swipeable`. The swipe removes the row directly |
| Android View | `ItemTouchHelper` (LEFT only). The swipe removes the row directly; the tool keeps the swipe path inside the OS "back" edge zones (the left and right edges of the screen) |
| SwiftUI (iOS) | `.swipeActions(edge: .trailing, allowsFullSwipe: true)`. **The swipe alone does not remove the row — a "Delete" button appears at the right edge and must be pressed** (the standard iOS presentation). **On iOS 26 and later, swiping right on a row with nothing registered on the leading side can navigate back** (a rightward swipe over the content is also the OS "back" gesture; measured at 1 in 12). To verify "the disabled direction does nothing", the app has to turn that gesture off on the screen |

```swift
// SwiftUI (iOS) only: press the button that appears after the swipe
swipeBy("#swipe_row_3", dxRatio: -0.5, dyRatio: 0, durationSeconds: 0.3)
ios { tap("<the delete button's label from a snapshot>") }
```

## Tabs (fixed, horizontal-scroll, bottom navigation)

- Fixed tabs can be pressed by `#id` or by label
- For an overflowing tab row, **give the row an `#id` and pass it as `scrollFrame:`**
  (`withScrollRight(scrollFrame: "#stab_row") { tap("#stab_11") }`)
- Bottom navigation items can be pressed by label (the text under the icon)

| Framework | Component / difference |
|---|---|
| CMP | `PrimaryTabRow` / `ScrollableTabRow` / `NavigationBar`. Same as above |
| Flutter | `TabBar` / `TabBar(isScrollable: true)` / `NavigationBar`. **Tab labels carry a suffix such as "Tab 3 of 3"**, so target them with a **partial match** (`*Tab C*`) instead of an exact match |
| RN | `material-top-tabs` / `bottom-tabs`. **Labels carry a suffix such as "tab, 2 of 3"**, so target them the same way with a partial match |
| Android View | `TabLayout` (fixed + scrollable) / `BottomNavigationView`. Same as above |
| SwiftUI (iOS) | Fixed tabs use `Picker(.segmented)`, the horizontal-scroll tabs use a row of buttons in a `ScrollView`, and the bottom one is an embedded `TabView`. **Whether the bottom navigation bar's identifier reaches the actual tab button is iOS-version dependent and known to be flaky** — target by label when it does not reach |

## Animation (fade, switch)

- An element that fades in can be read directly with `select("#…").textIs("…")` (it waits until it
  can be read)
- Wait for it to go away: `waitForClose("#…", waitSeconds: 5)`
- Pressing repeatedly during a transition still lets you read the last value

| Framework | Component / difference |
|---|---|
| CMP | `AnimatedVisibility` (removed from composition when hidden, so it drops out of the tree) / `AnimatedContent` |
| Flutter | `AnimatedOpacity` (**the element stays mounted in the tree even when hidden** — only its opacity moves. Unlike CMP, presence in the tree cannot be used as the visibility check, so **read the visibility echo instead**, e.g. `visible=true`/`visible=false`) / `AnimatedSwitcher` |
| RN | `react-native-reanimated`'s `FadeIn`/`FadeOut`. **A counter switch is implemented as a remount keyed on the value**, so the old and new elements can briefly coexist in the tree during the transition (the same property as CMP's `AnimatedContent`) |
| Android View | `Fade` (`TransitionManager`) / `TextSwitcher`. Same as above |
| SwiftUI (iOS) | `withAnimation` + `.transition(.opacity)` / `.contentTransition(.numericText())`. Same as above |

**Current limitation**: Flutter's `AnimatedOpacity` does not remove the element from the tree when
hidden, so do not use "the element is absent" as a visibility check. Beyond this screen, whenever you
verify a fade-based visibility toggle in Flutter, judge it by the state echo the app shows (or by
`checkIsON`/`checkIsOFF` for components that support it).

## Tooltip

- Long-press the anchor: `tap("#btn_info", holdSeconds: 1.0)`
- A tooltip that is shown **only while the finger is down** is verified while it is down:
  `hold("#btn_info", holdSeconds: 3) { select("#txt_tooltip").textIs("…") }`

| Framework | Component / difference |
|---|---|
| CMP | `TooltipBox` + `PlainTooltip`. On iOS it stays for a while after the release. **On Android it is shown only while the finger is down**, so verify it inside `hold { }` (its text is in the tree too) |
| Flutter | `Tooltip(triggerMode: longPress)`. Its bubble text cannot carry an id, so target it by label. **Its "shown" state is an approximation** (the app waits a fixed display duration from the show event and then treats it as hidden — not a direct observation of the hide animation finishing) |
| RN | `react-native-paper`'s `Tooltip`. **An `accessible` ancestor collapses the anchor (`IconButton`) into one element, so an identifier set on the anchor itself drops out of the tree on iOS** (Android is not affected). The app works around this by putting the anchor's identifier on an outer `View` instead. **The tooltip is shown only while the finger is down and disappears when it is lifted**, so verify it inside the block of `hold("#anchor", holdSeconds: 3) { … }` (`tap(holdSeconds:)` verifies after the release and cannot confirm it) |
| Android View | `TooltipCompat`'s standard popup is drawn in a separate process, so its content cannot be read. The text of an app's own `PopupWindow` (a separate window that does not take focus) is **not in the tree either**. Confirm that it is shown from the state the app displays, inside `hold { }` |
| SwiftUI (iOS) | **Not present** (iOS's long press convention leads to a context menu instead, so the verification app does not have this screen) |

`tap(holdSeconds:)` lifts the finger before the next line runs, so a component that is shown only
while the finger is down is already gone by then. `hold { }` runs its block while the finger is down.

## Chips and segmented buttons

- A FilterChip's / SegmentedButton's selection can be read with `checkIsON()` / `checkIsOFF()`
- A range slider's thumbs cannot carry an `#id`. Check the value with the label the app shows

| Framework | Component / difference |
|---|---|
| CMP | `FilterChip` / `AssistChip` / `SegmentedButtonRow` / `RangeSlider`. Same as above |
| Flutter | `FilterChip` / `ActionChip` / `SegmentedButton` / `RangeSlider`. Same as above |
| RN | `react-native-paper`'s `Chip` / `SegmentedButtons`. **There is no dual-thumb range-slider component**, so `#range_slider` is a container around two independent Sliders (`#range_slider_min` / `#range_slider_max`). Those two are what you actually operate |
| Android View | `Chip` (filter/assist) / `MaterialButtonToggleGroup` / `RangeSlider`. Same as above |
| SwiftUI (iOS) | `Toggle(.toggleStyle(.button))` / `Button(.bordered)` / `Picker(.segmented)`. **There is no stock range-slider component**, so the range-slider equivalent is omitted (only a fixed result label exists; there is no operable component behind it) |

## Search bar

- Press the input field, `type("…")`, and press a suggestion by `#id`

```swift
tap("#field_search")
type("...")   // or type(".textField", "...") to target the input by type
```

| Framework | Component / difference |
|---|---|
| CMP | Material3 `SearchBar`. **On iOS the input field reports a description as its value instead of the typed text**, so `select(...).valueIs(…)` cannot confirm the input; check the suggestions or the result after submitting instead (the tool confirms the input by OCR on the screen, so `type` itself goes through without duplicating) |
| Flutter | `SearchAnchor.bar`. **Pressing the bar opens a separate input field with no `#id`**. Target the opened field by type (`type(".textField", "...")`) — fleetest refuses a locator-less `type` once focus has moved to another field, to prevent double input |
| RN | `react-native-paper`'s `Searchbar`. Same as above (a single input field is the search field itself) |
| Android View | `com.google.android.material.search.SearchBar` + `SearchView`. **`#field_search` targets the bar while it is collapsed** (the expanded, real input field has a separate id, `#field_search_input`, but you usually do not need it — `tap("#field_search")` moves focus to the expanded real input field, so the following locator-less `type(...)` picks it up directly) |
| SwiftUI (iOS) | `.searchable`. **`#field_search` does not exist** (there is no public API to give the field `.searchable` produces an identifier). Target it by its placeholder text |

## Navigation

- Routes with arguments, stacking and icon-only back buttons work on every framework
- `back()` goes back one screen: the OS back on Android, an edge swipe on iOS (true for
  navigation-compose, go_router, react-navigation and the Navigation component /
  NavigationStack alike)

| Framework | Component / difference |
|---|---|
| CMP | navigation-compose's `NavHost`. Same as above |
| Flutter | `go_router`. **On iOS an edge swipe sometimes does not go back** (a synthesized edge swipe does not trigger `MaterialPage`'s pop, regardless of the start point or duration). Workaround: use the app's back button (`#btn_back`) on iOS and the OS `back()` only on Android |
| RN | `@react-navigation/native-stack`. Same as above (back is always the system `back()` or the native back button) |
| Android View | The Navigation component's `NavHostFragment`. **Current limitation**: with several detail screens stacked, tapping the toolbar back (labelled "Back") sometimes does not go back one level (under investigation). Workaround: in scenarios that verify a multi-level stack, use the OS `back()` instead of tapping the toolbar |
| SwiftUI (iOS) | `NavigationStack`. The back button is the fixed id `#BackButton` |

## Collapsing header

A TopAppBar/AppBar-style header that shows a large title while expanded and shrinks as you scroll
down.

| Framework | Component / difference |
|---|---|
| CMP | A screen-local `Scaffold` + `LargeTopAppBar` + `exitUntilCollapsedScrollBehavior()`. The root `TopAppBar` also stays visible at the same time, so `#txt_screen_title` can be read from there |
| Flutter | `CustomScrollView` + `SliverAppBar(pinned, expandedHeight)` + `SliverList`. Same as above |
| RN | An `Animated.FlatList` + `useAnimatedScrollHandler`-driven header (a custom implementation layered as a separate view). Same as above |
| Android View | `CoordinatorLayout` + `AppBarLayout` + `CollapsingToolbarLayout`. Same as above |
| SwiftUI (iOS) | `List` + `.navigationBarTitleDisplayMode(.large)`. **The system large title that actually collapses cannot carry an identifier** (same reason as the back button — UINavigationBar's internal drawing has no public API for it). The equivalent of the "large heading" is a separate element instead, and `#txt_collapse_result` sits at a fixed position that stays in the tree after the header collapses |

Pressing a row shows an echo, and the echo stays in the tree at a fixed position even after
collapsing, on every framework.

**Current limitation**: with RN's `react-native-collapsible-tab-view`, **right after switching tabs the first rows of the list can
sit behind the header on iOS**. The in-app engine's tree does not show what covers them, so fleetest cannot scroll them out
from under it (on the XCUITest engine the failure message names `#Toolbar`). Tap a row that is visible below the header

## Sticky header

A list whose section headers stick to the top while scrolling.

| Framework | Component / difference |
|---|---|
| CMP | `LazyColumn`'s `stickyHeader`. Same as above |
| Flutter | A `SliverPersistentHeader(pinned)` per section, grouped with `SliverMainAxisGroup` (simply lining up the headers would make several of them stick at once) |
| RN | `SectionList` (`stickySectionHeadersEnabled`). **As the next section's header reaches the top, it overlaps that section's first row by the header's height** (a property common to any sticky-header list implementation, not RN-specific). **When you `tap` a row hidden under the header, fleetest scrolls it out from under the header first** (note `scrolled the container to bring the target out from under #hdr_… before touching it`), so nothing changes in how you write it |
| Android View | `RecyclerView` + a sticky-header `ItemDecoration`. **The header while it is stuck is drawn directly to canvas and does not appear in the a11y tree**. The actual header row exists separately as an ordinary list item and is only in the tree while it scrolls past |
| SwiftUI (iOS) | `List(.plain)` + `Section(header:)`. A plain-style Section header sticks to the top by default |

## Time picker

- Confirm / cancel. Target by label if it cannot carry an id

| Framework | Component / difference |
|---|---|
| CMP | `AlertDialog` + `TimePicker`/`TimeInput`. `#btn_time_ok` / `#btn_time_cancel` carry a `testTag` |
| Flutter | `showTimePicker`. **OK/Cancel cannot carry an id** (inside a built-in dialog; the labels stay the English default) |
| RN | `@react-native-community/datetimepicker` (`mode="time"`). Android shows the native `TimePickerDialog` (it has a clock/keyboard-input toggle icon by default), while iOS lays `display="spinner"` inside a custom modal with OK/Cancel. **Only iOS lacks the toggle to keyboard-input mode** |
| Android View | `MaterialTimePicker`. **`#btn_time_ok` / `#btn_time_cancel` do not exist** (the library's internal layout id cannot be overridden). Target by label ("OK"/"Cancel") |
| SwiftUI (iOS) | `.sheet` + `DatePicker(.wheel, .hourAndMinute)`. Same as above |

## Dialogs (alert, with input, action sheet, full screen, toast)

| `#id` | Kind | Result |
|---|---|---|
| `#btn_alert` | Confirmation alert (OK/Cancel) | `alert=ok` / `alert=cancel` |
| `#btn_prompt` | With an input field (`#field_prompt`) | `prompt=<input>` / `prompt=cancel` |
| `#btn_action_sheet` | Action sheet | `sheet=camera` / `sheet=library` / `sheet=cancel` |
| `#btn_fullscreen` | Full-screen dialog | `fullscreen=saved` / `fullscreen=closed` |
| `#btn_toast` | OS toast | `toast=shown` |

```swift
tap("#btn_alert")
tap("OK")
select("#txt_dialogs_result").textIs("alert=ok")
```

| Framework | Component / difference |
|---|---|
| CMP | `AlertDialog` / `ModalBottomSheet` (as the action-sheet substitute) / `Dialog(usePlatformDefaultWidth = false)`. **Toast is not implemented** (there is no stock component in commonMain) |
| Flutter | `AlertDialog` / `showCupertinoModalPopup` + `CupertinoActionSheet` / `Dialog.fullscreen`. **The internal buttons of the alert, the with-input dialog and the action sheet carry no id** (target by label). **Toast is not implemented** (iOS has no OS-standard API equivalent to Android's `Toast`) |
| RN | `Alert.alert` / `react-native-paper`'s `Dialog` + `TextInput` (a single implementation shared by both OSes) / iOS `ActionSheetIOS` + Android `Dialog`+`List.Item` (as the substitute) / core `Modal` (full screen; wrapped in `SafeAreaView` by the app) / `ToastAndroid` on Android only. **`#btn_toast` exists only on Android** |
| Android View | `MaterialAlertDialogBuilder` / `BottomSheetDialog` (as the action-sheet substitute) / `DialogFragment` (full screen) / `Toast` |
| SwiftUI (iOS) | `.alert` / `.alert` + `TextField` / `.confirmationDialog` / `.fullScreenCover`. **`#btn_toast` is omitted** (iOS has no OS-standard toast; this is separate from the custom toast used by the snackbar screen described earlier) |

## Long-press menu (context menu)

- Long-press a row and pick an item: `tap("#ctx_row_2", holdSeconds: 1.0)` then `tap("Duplicate")`

```swift
tap("#ctx_row_2", holdSeconds: 1.0)
tap("Duplicate")
select("#txt_context_result").textIs("context=row2:copy")
```

The same pattern works across every framework (CMP's `combinedClickable(onLongClick)` +
`DropdownMenu`, Flutter's `onLongPressStart` + `showMenu`, RN's `Pressable(onLongPress)` +
`react-native-paper`'s `Menu`, Android View's `registerForContextMenu`, SwiftUI's `.contextMenu`).
The menu is a separate window, so the common modal rule (the screen behind drops out of the tree)
applies here too.

## Reorder (drag)

- Long-press then move without lifting the finger — this cannot be written as tap + move, only as a
  `gesture`
- **The landing position differs by framework** (how many rows of movement equals one step differs by
  component). Do not assert an exact landing row — assert that it moved

```swift
// Coordinates are ratios of #reorder_row_1's frame. y=2.5 means 2 rows down (assuming uniform row
// heights)
gesture("#reorder_row_1") {
    FTFinger(x: 0.5, y: 0.5).hold(seconds: 0.8)
        .move(x: 0.5, y: 2.5, durationSeconds: 1.0)
        .hold(seconds: 0.3)
}
// The same 2-row move lands one row down on CMP/Flutter but all the way to the end on RN (the
// components differ in sensitivity)
select("#txt_reorder_result").textMatches("^order=2,")
```

| Framework | Component / difference |
|---|---|
| CMP | No stock component (a custom implementation with `detectDragGesturesAfterLongPress`. **It hops one slot the instant a threshold is crossed, rather than settling at the release point** — it advances roughly in proportion to the distance moved) |
| Flutter | `ReorderableListView` (built-in drag handle). The release point becomes the final order |
| RN | A custom implementation with `Gesture.Pan().activateAfterLongPress()`, not a third-party library. It reorders every time a threshold (half a row's height) is crossed, so **it can move all the way to the release point** (a 2-row move can end up at the last position) |
| Android View | `ItemTouchHelper`. Even if the drag crosses several rows, a single drag correctly settles at the final release position |
| SwiftUI (iOS) | `List` + `.onMove` + an always-on edit mode (`.environment(\.editMode, .constant(.active))`). You grab the handle at the trailing edge and drag |

## Types of input fields

**Every echo sits in a fixed area at the top of the screen (does not scroll, is never hidden by the
keyboard)**.

| `#id` | Kind | Echo |
|---|---|---|
| `#field_number` | Number keypad | `number=<value>` |
| `#field_password` | Password | `password_len=<length>` |
| `#field_multiline` | Multiline | `lines=<count>` |
| `#field_first` → `#field_second` | IME "next" | `focus=second` |
| `#field_auto` | Autocomplete | `auto=Japan` |
| `#field_bottom` | Bottom of the screen (hidden by the keyboard) | `bottom=<value>` |

```swift
type("#field_number", "123")
select("#txt_number_echo").textIs("number=123")

type("#field_first", "Smith")
pressEnter()
select("#txt_focus_echo").textIs("focus=second")
```

| Framework | Component / difference |
|---|---|
| CMP | `OutlinedTextField` + `ExposedDropdownMenuBox` (editable). **On iOS, the whole screen is pushed up by default when the keyboard appears** (`OnFocusBehavior.FocusableAboveKeyboard` is the default; text fixed near the top can go off-screen. The app can set `DoNothing` to avoid this) |
| Flutter | `TextField` + Material `Autocomplete<String>`. The number-keypad field rejects non-digit characters (`FilteringTextInputFormatter.digitsOnly`) |
| RN | `react-native-paper`'s `TextInput` + a custom prefix-match suggestion list. Because a Japanese-locale device's default keyboard converts romaji into kana, an ASCII-only field needs `autoCorrect={false}` + `keyboardType="ascii-capable"` etc. (a workaround the app applies itself) |
| Android View | `TextInputLayout` + `TextInputEditText` + `MaterialAutoCompleteTextView` (editable). **The autocomplete suggestion rows carry no id** (unnamed `ListPopupWindow` rows; target by label) |
| SwiftUI (iOS) | `TextField` (`.numberPad` / `.vertical` axis) / `SecureField` + `@FocusState`. **The autocomplete suggestions are only verifiable on iOS** (on Android the suggestion popup does not appear in the a11y tree; see below) |

- **Autocomplete suggestions show up a moment after you type** (they are asynchronous). Wait for the
  suggestion before tapping it; without the wait, the step fails with "not found" only on slower machines.

  ```swift
  type("#field_auto", "Ja")
  tap("#auto_opt_japan", waitSeconds: 5)
  ```

**Current limitation**:

- **On Android, across every framework, a non-focused popup window's content can be missing from the
  tree**. Android's a11y tree root is "the single active window" (`getRootInActiveWindow()`), so a
  popup that never takes focus (such as an autocomplete suggestion list) may not appear in some
  screens. **Popups that do take focus, such as `Spinner`/`ExposedDropdownMenuBox`, show their
  suggestions**. **Tooltip popups and some autocomplete suggestions still do not**.
  Workaround: when a suggestion cannot be verified directly, check the confirmed value through the
  app's own echo instead
- **Android refuses `ACTION_SET_TEXT` on some fields** (observed on Material's `SearchView` and some
  Flutter fields). There is no workaround; `type` types normally via regular keystrokes anyway (only
  the bulk, a11y-driven write is refused, not ordinary `type` keystrokes)
- **On React Native's iOS (in-app engine), a suggestion shown right below the field may not be tappable** (under
  investigation). The keyboard stays up after `pressEnter()`, so the suggestion stays hidden beneath it. Workaround:
  lay the screen out so suggestions are not covered by the keyboard, or check the committed value through the app's own echo

## FAB (floating action button)

- The FAB floats above the list (it can cover a row). A row below it is still reached by ordinary
  scroll search
- **In a layout that lays the bottom bar over the list, the last rows never come out from under the bar unless the list has bottom padding, and `exist` fails as "not visible"** (this is how the app is built: on Android View give the `RecyclerView` `clipToPadding="false"` + `paddingBottom`; on RN do not make the bar `position: absolute`, put it below the list)

```swift
tap("#fab_add")
select("#txt_fab_result").textIs("fab=add")
```

| Framework | Component / difference |
|---|---|
| CMP | A screen-local `Scaffold`'s `floatingActionButton` + `bottomBar` (`BottomAppBar`). Same as above |
| Flutter | `Scaffold.floatingActionButton` (`FloatingActionButton` + `.extended`) + `BottomAppBar`. Same as above |
| RN | `react-native-paper`'s `FAB` + `AnimatedFAB` + `Appbar`. Same as above |
| Android View | `CoordinatorLayout` + `BottomAppBar` + `FloatingActionButton`. **The FAB's cradle can leave too little width, folding the BottomAppBar's items into "More options"** (below) |
| SwiftUI (iOS) | iOS has no stock FAB, so it is a custom overlay `Button` + `.toolbar(placement: .bottomBar)`. Same as above |

**Current limitation**: Android (View)'s `BottomAppBar` folds its items into a single "More options"
icon when the remaining width, after subtracting the FAB's cradle, is not enough. A folded row is an
unnamed `ListPopupWindow` row and cannot carry an id. Workaround:

```swift
tap("More options")   // open the overflow first if items are folded
tap("Search")
```

## Expandable list

- Press a group to open it, then pick a child

| Framework | Component / difference |
|---|---|
| CMP | `AnimatedVisibility`'s open/close. Same as above |
| Flutter | `ExpansionTile`. **Only the `title` itself carries an id** (giving the whole `ExpansionTile` an id would collapse the opened children into the same single node — the same trap as Compose's Slider; the children carry their own separate ids, so it does not affect operation) |
| RN | `react-native-paper`'s `List.Accordion` + `List.Item`. Same as above |
| Android View | `ExpandableListView`. Same as above |
| SwiftUI (iOS) | `DisclosureGroup` (inside a List). Closed by default |

## Stepper and progress

- Increase/decrease the quantity with +/- buttons. The progress bar deterministically goes from 0 to
  100% in 2 seconds
- The indeterminate spinner is shown only while running

```swift
tap("#btn_qty_plus")
select("#txt_qty").textIs("qty=2")

tap("#btn_start_progress")
select("#txt_progress").textIs("progress=running")
select("#txt_progress", waitSeconds: 3).textIs("progress=done")
```

| Framework | Component / difference |
|---|---|
| CMP | +/- buttons + `LinearProgressIndicator` (`Animatable`) + `CircularProgressIndicator`. Same as above |
| Flutter | `IconButton` x2 + an `AnimationController`-driven `LinearProgressIndicator` + `CircularProgressIndicator`. Same as above |
| RN | `react-native-paper`'s `IconButton` + `ProgressBar` + `ActivityIndicator` (stepped deterministically via `requestAnimationFrame`). Same as above |
| Android View | `MaterialButton` +/- + `LinearProgressIndicator` (`ValueAnimator`) + `CircularProgressIndicator`. Same as above |
| SwiftUI (iOS) | `Stepper` / `ProgressView(value:)` / `ProgressView()`. **There are no dedicated +/- buttons** (`#btn_qty_plus`/`#btn_qty_minus`) — the +/- is built into the `Stepper` itself, surfacing under the system's standard labels `#<id>-Increment` / `#<id>-Decrement` |

```swift
// SwiftUI (iOS) only: +/- shows up as children of the Stepper itself
ios { tap("#stepper_qty-Increment") }
```

## Infinite scroll

- Scrolling close to the end auto-loads the next batch. A loading indicator shows at the end while it
  loads
- Reach a far row by raising `maxSwipes:`

```swift
tap("#row_i_57", scroll: .down, maxSwipes: 30)
select("#txt_infinite_result").textIs("infinite=row_i_57")
```

Same across every framework (CMP's `snapshotFlow`-based end detection, Flutter's `ScrollController`
listener, RN's `onEndReached`, Android View's `OnScrollListener`, SwiftUI's `.onAppear` on the last
row).

**A quirk that depends on how the app is built (Android View)**: in an app that refreshes **the whole
list** when loading finishes (`RecyclerView`'s `notifyDataSetChanged()`), a tap on a row that is being
pressed at that moment is cancelled. `tap` reports success, the row is not selected, and the next check
fails (it shows up only now and then, and only on slower machines). An app that adds just the new rows
(`notifyItemRangeInserted`) does not have this. Workaround: wait for the loading indicator to go away
before tapping.

```swift
scrollTo("#row_i_57", direction: .down, maxSwipes: 30)
waitForClose("#txt_loading", waitSeconds: 5)
tap("#row_i_57")
```

**Current limitation**: RN's `FlatList`'s `onEndReached` can fire just because the initial data fits
on one screen, even without ever scrolling (this app avoids it by loading only after real scrolling
has started; an app without that guard can load several pages at once right after opening). There is
no scenario-side workaround, so keep this app-side behaviour in mind if you assert an exact initial
row count.

## Pinch to zoom

- `pinchOut(sel, scale: 2.0)` / `pinchIn(sel, scale: 0.5)` zooms in / out
- **The scale actually reached depends on the component's sensitivity** (Android's
  `ScaleGestureDetector` reached 1.2 for a requested `scale: 2.0`). Assert a range — "it zoomed in" —
  rather than an exact scale

```swift
pinchOut("#zoom_target", scale: 2.0)
select("#txt_zoom_scale").textMatches("^scale=(1\\.[1-9]|[2-4]\\.[0-9])$")
```

Same across every framework (CMP's `Modifier.transformable`, Flutter's `InteractiveViewer`, RN's
gesture-handler `Gesture.Pinch()`, Android View's `PinchZoomImageView` (a custom
`ScaleGestureDetector` implementation), SwiftUI's `MagnificationGesture`). Every framework clips the
zoomed content so it does not spill outside the frame.

## Inline links (links, mentions and URLs inside one sentence)

- Use `tap(element, linkText: "text")`: it taps where that text is drawn inside the element
- Flutter and RN expose links as child nodes, so the position comes from the tree. Compose, Android Views
  (`ClickableSpan`) and SwiftUI (`AttributedString` links) do not, so the position comes from reading the
  screenshot with OCR (the step note says `located by tree` / `located by ocr`)
- `tap("Terms")` only hits the whole paragraph and cannot press the link. Do not tap the paragraph centre to
  check that "nothing happens" — which word sits at the centre depends on the screen width
- A link wrapped across two lines may not be found by OCR

```swift
tap("#txt_terms", linkText: "Terms of Service")
select("#txt_links_result").textIs("link=terms")
```

## Inverted chat lists (newest at the bottom)

- The list starts at the bottom (newest), so older messages are found by scrolling up
  (`withScrollUp(scrollFrame: "#list_chat") { tap("#msg_20") }`)
- Even when the input bar lives on the keyboard side (UIKit `inputAccessoryView`), the field can be addressed by `#id`

## Loading skeletons

- When the placeholder rows carry the same `#id` and labels as the real rows, `exist` already passes while loading
- `tap` waits until its target is enabled, so you can `tap` right after reloading (if the skeleton is exposed as
  disabled, the tap lands once the real row appears)
- For lists that show a temporary "loading" / "retry" row at the end, press retry before searching further

```swift
tap("#btn_reload")
tap("#row_l_03")          // waits through the skeleton and taps the real row
select("#txt_loading_result").textIs("loading=row_l_03")
```

## Bars that hide on scroll

- Bars and FABs that hide when you scroll down are not in the tree while hidden; use `tap(sel, scroll: .up)` to
  scroll back a little and bring them out first

```swift
tap("#fab_hiding", scroll: .up)
```

**Current limitation**: a bar hidden with Flutter's `AnimatedSlide` is still reported at its original place in the tree while hidden, so the search does not scroll and the tap may land where the button no longer is.

## Partial swipes (revealing buttons, swipe to reply)

- Swipe **slowly** for a partial swipe (`swipeBy("#sw_row_3", dxRatio: -0.45, dyRatio: 0, durationSeconds: 2.0)`).
  A fast release lets the component fling to the next stop (all the way to delete)
- `swipeBy` caps its ratio at 0.9 per side. To drag further than the element itself (for example pulling up a
  sheet) use `swipeElementToElement("#mini_player", "#txt_sheet_state")`

## Framework-native components

A single screen collecting the components unique to each framework. Its content differs per verification app, so
read this section only if your target app uses a similar component. The common approach is the same
as any other section — target by `#id` or label, verify with the echo.

| Framework | Components included |
|---|---|
| CMP | M3 `HorizontalMultiBrowseCarousel` / `NavigationRail` / `BottomSheetScaffold` |
| Flutter | Screen transition via `Hero` (**this app puts `Hero` on a separate decorative element rather than on the trigger button**, since wrapping the button itself would make the transition look odd) / `CupertinoSwitch` / `CupertinoPicker` / `PlatformView` (a native `UILabel`/`TextView` embedded with a label) |
| RN | `@shopify/flash-list`'s `FlashList` (**virtualized, so only what fits the screen is in the tree** — the same property as the other `FlatList`-based screens) / core `Modal` (non-full-screen) / core `Switch` |
| Android View | `Spinner` / `NumberPicker` / `MotionLayout` (a button-driven, one-way transition) |
| SwiftUI (iOS) | `UICollectionView` (compositional layout) / `.popover` / `.confirmationDialog`. **`.popover` can render as a sheet on iPhone through adaptive presentation** (a standard iOS default behaviour) |

### Link
- [index](../../index.md)
