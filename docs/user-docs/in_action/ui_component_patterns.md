# UI Component Patterns and Quirks (Compose Multiplatform)

How to target, operate and verify the stock Compose Multiplatform (Material3) components in a
scenario. **This page is meant as knowledge for an agent (AI assistant) writing scenarios** — if the
app's screen has one of these components, read the matching section before writing.

- Verified on: Compose Multiplatform 1.11 (≈ Material3 1.4), iOS 27 Simulator (hybrid engine /
  XCUITest engine) and Android 15 Emulator, on 2026-09-28
- Every behaviour here reproduces with the verification app bundled with fleetest, `E2EXAppCMP/`,
  and its scenarios in `TestProjects/E2EX-CMP/scenarios/` (read them as worked examples)
- **"Current limitation" entries are unresolved limitations on the fleetest side**. Write the
  workaround given there

## Common to all components

### While a modal is open, the screen behind it drops out of the tree

While a drawer, a dropdown menu or a bottom sheet is open, **the elements of the screen behind it are
not in the tree (snapshot)** (drawer and menu verified on both iOS and Android, bottom sheet on iOS).
Only the modal's contents and the scrim's "close" button remain.

- Read result labels behind the modal (`#txt_result` etc.) **after closing the modal**
- "Tap outside the menu to close it" cannot be written as an element tap, because nothing behind it
  can be targeted (see the "Dropdown menu" section below)

```swift
tap("#btn_open_drawer")
exist("#txt_drawer_header")          // OK: prove it opened with an element inside the modal
// select("#txt_state").textIs(...)  // NG: elements behind are not found while it is open
tap("#drawer_item_sent")             // close it first
select("#txt_state").textIs("drawerOpen=false")
```

### An icon-only button is labelled by its contentDescription

`IconButton { Icon(…, contentDescription = "Back") }` can be targeted by the label `Back`
(`tap("Back")`). If a screen uses a character instead of an icon (`Text("←")`), iOS **joins the
character into the label**, as in `Back, ←`. Target such a button by `#id` or by the partial match
`*Back*`.

### Always pass scrollFrame for horizontal containers

`scroll: .right` / `withScrollRight { }` swipe **the centre of the screen** when nothing else is
given. If the pager or the overflowing tab row is not at the centre, nothing moves and the step
fails. **When searching a horizontal container, pass that container as `scrollFrame:`** (the
container needs an `#id`).

```swift
withScrollRight(scrollFrame: "#pager_main") {
    tap("#btn_page_4")
}
```

### On Android the screen edges are the OS "back"

On Android with gesture navigation, **a horizontal swipe that starts at the left or right edge of the
screen is the OS "back"**. Do not move the start of a swipe to the edge (do not make
`flickLeftToRight(startMarginRatio:)` small; keep the default).

## Pager (HorizontalPager)

- Next page: `flickRightToLeft(scrollFrame: "#pager_main")` (one page per flick)
- An element on an off-screen page: `withScrollRight(scrollFrame: "#pager_main") { tap("#…") }`
- Back to the edge: `scrollToLeftEdge(scrollFrame: "#pager_main")` (same for `scrollToRightEdge`)
- Check the current page with the page-number label the app shows

## Bottom sheet (ModalBottomSheet)

- Prove it opened with an element inside the sheet (the screen behind drops out of the tree)
- A long list inside the sheet: `tap("#row_25", scroll: .down)` reaches it (the sheet expands first,
  then its contents scroll)
- Pressing an option that closes the sheet works on both OSes
- Closing with a swipe: **move the finger from the title to a row near the bottom of the sheet**
  (both OSes). Do not use `swipeBy` — its ratio is **relative to the target's size** and capped at 0.9
  per side, so on a small title it moves only a few points
- On iOS the scrim's "close" button also works — the iOS tree has a button whose label is the
  localized "close the sheet" text. The label changes with the locale, so take it from a snapshot

```swift
swipeElementToElement("#sheet_title", "#row_04", durationSeconds: 0.3)
ios { tap("<the scrim's close label from a snapshot>") }   // also fine
```

## Dropdown menu (DropdownMenu)

- Items can be pressed by `#id` or by label (`tap("#menu_item_share")` / `tap("Delete")`)
- Pressing an item closes the menu
- **Tap outside to close**: nothing behind the menu is in the tree, so it cannot be targeted by an
  element. On Android use `back()`; on iOS tap an empty spot of the screen by coordinates

```swift
tap("#btn_open_menu")
android { back() }
ios { tap(x: 200, y: 600) }   // an empty spot that the menu does not cover
notExist("#menu_item_copy")   // confirm it closed
```

## Selection field (ExposedDropdownMenuBox)

- Pressing the field shows the options (`tap("#field_fruit")` → `tap("#opt_banana")`)
- **The chosen value is in `.value`, not in `.text`**. `.text` is the field's label on iOS
  (e.g. `Fruit`) and `nil` on Android

```swift
select("#field_fruit").valueContains("Banana")   // OK on both OSes
// select("#field_fruit").textContains("Banana") // NG: the label on iOS, nil on Android
```

## Date picker (DatePickerDialog)

- The day cells cannot carry an `#id`. **Target them by label**. The label changes with the locale,
  so list the candidates with `||`

```swift
tap("<the day cell's label from a snapshot>||20")
tap("#btn_date_ok")
```

- The OK / Cancel buttons can be given a `testTag` by the app, so target them by `#id`

## Navigation drawer (ModalNavigationDrawer)

- Opening with a button and closing by pressing an item work on both OSes
- While it is open, the screen behind drops out of the tree (the "Common to all components"
  section). Read state labels after closing it
- **Opening with a swipe**: `flickLeftToRight()` / close with `flickRightToLeft()` (both OSes).
  **Keep the default start point** — on Android, a small `startMarginRatio:` (such as 0.05) moves the
  start onto the screen edge, which becomes the OS "back" and goes to the previous screen

## Pull to refresh (PullToRefreshBox)

- Trigger a refresh: move a finger from an upper row to a lower row of the list
  (`swipeElementToElement("#row_01", "#row_06", durationSeconds: 0.6)`)
- Check that the refresh finished with what the app shows (a count, a timestamp, …)

**Current limitation**: with **the iOS XCUITest engine** (`iosInappEngine: false`), `scrollToTop()`
at the top of the list **runs one extra refresh** (the swipe that confirms the edge becomes a pull,
because XCUITest does not tell whether a container can still scroll). It does not happen on Android
or with the default iOS engine. Workaround: in scenarios that verify the refresh count, do not read
the count after `scrollToTop()` (verify the count before it).

## Snackbar

- Its contents cannot carry an `#id`. Target both the message and the action **by label**
  (`exist("Deleted")` / `tap("Undo")`)
- Wait for it to go away: `waitForClose("Saved", waitSeconds: 10)`
  (short ≈ 4 s, long ≈ 10 s)

## Grid (LazyVerticalGrid)

- Off-screen cells are not in the tree. `tap("#cell_86", scroll: .down)` reaches them; go back with
  `scroll: .up`
- Vertical search works as-is even with several elements per row

## Swipe to dismiss (SwipeToDismissBox)

- Swipe horizontally on the row: `swipeBy("#row_3", dxRatio: -0.5, dyRatio: 0, durationSeconds: 0.3)`
  (verified on both OSes). The ratio is capped at 0.9 per side. On Android the tool keeps the path
  inside the OS "back" edge zones (the left and right edges of the screen)
- You can also verify that a swipe in the disabled direction does nothing (the row stays)

## Tabs (PrimaryTabRow, ScrollableTabRow, NavigationBar)

- Fixed tabs can be pressed by `#id` or by label (`tap("#tab_b")` / `tap("Tab C")`)
- For an overflowing tab row, **give the row an `#id` and pass it as `scrollFrame:`**
  (`withScrollRight(scrollFrame: "#stab_row") { tap("#stab_11") }`)
- NavigationBar items can be pressed by label (the text under the icon)

## Animation (AnimatedVisibility, AnimatedContent)

- An element that fades in can be read directly with `select("#…").textIs("…")` (it waits until it
  can be read)
- Wait for it to go away: `waitForClose("#…", waitSeconds: 5)`
- Pressing repeatedly during a transition still lets you read the last value

## Tooltip (TooltipBox)

- Long-press the anchor: `tap("#btn_info", holdSeconds: 1.0)`. On iOS this shows the tooltip

- **It cannot be verified on Android**. The Material3 tooltip is shown **only while the finger is
  down** and disappears on release (`tap(holdSeconds:)` releases before the next line runs, so it is
  already gone). Even while shown, its text lives in a separate window and is not in the tree. Wrap
  tooltip checks in `ios { }`

## Chips and segmented buttons (FilterChip, SegmentedButton)

- A FilterChip's selection can be read with `checkIsON()` / `checkIsOFF()` (both OSes)
- A SegmentedButton's selection can also be read with `checkIsON()` / `checkIsOFF()`
- RangeSlider thumbs cannot carry an `#id`. Check the value with the label the app shows

## Search bar (SearchBar)

- Press the input field, `type("…")`, and press a suggestion by `#id` (both OSes, both engines)
- On iOS the SearchBar's input field **reports a localized description (roughly "the suggestions
  follow") as its value** instead of the typed text. `select("#field_search").valueIs(…)` cannot
  confirm the input; check the suggestions or the result after submitting instead (the tool confirms
  the input by OCR on the screen, so `type` itself goes through without duplicating)

## Navigation (navigation-compose NavHost)

- Routes with arguments, stacking and icon-only back buttons work on both OSes
- `back()` goes back one screen: the OS back on Android, an edge swipe on iOS

### Link
- [index](../index.md)
