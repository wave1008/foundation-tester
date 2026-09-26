# Text visual verification

[in Japanese(日本語)](text_visual_check_ja.md)

`exist` and `textIs` first find the element in the tree (the accessibility tree). An element can be in
the tree, though, while the screen shows something else on top of it, or while it is cut off outside a
scrolling area. **Text visual verification** checks, on a screenshot, that the text of the element
matched in the tree is actually drawn on screen, and fails the step when it is not.

- Commands it applies to: `exist` / `waitForDisplay` / `select` (returns an empty element when the text
  is not visible) / the positive text and value assertions (`textIs` / `textContains` / `valueIs`, …)
- Settings: `textVisualCheck` (default `true`) and `ocrTextVisualCheck` (default `true`) in the run
  profile ([Run profile settings](../project/run_profile.md))
- To turn it off for one step, pass `requireVisible: false`

It only checks whether the text is visible. Whether the value is the expected one is guaranteed by the
tree check, so a different value is not its concern.

## How it decides

1. When the device's **OCR** reads the whole expected text, the step passes right there (fast).
2. Otherwise **FM** (Foundation Models) transcribes the text that is drawn, and the transcript is matched
   against the expected text.
3. When FM is unavailable (macOS 26, or FM failing), the same rules are applied to the **OCR reading
   alone**.

An element whose centre is off the screen fails before any image is looked at.

## Examples

The images are reproductions drawn in the iOS system font (SF, 17 pt) to show each shape. The OCR
reading and the result are what the check actually returned for that image.

### Visible: passes

| Image | Expected (tree) | OCR reading | Why |
|---|---|---|---|
| <img src="../images/text_visual_check/en/visible.png" width="187" alt="read in full"> | `Game Center` | `Game Center` | Read in full |
| <img src="../images/text_visual_check/en/quotes.png" width="187" alt="quotes"> | `“Calendar” updates` | `"Calendar" updates` | Curly and straight quotes are normalized before matching |
| <img src="../images/text_visual_check/en/value_differs.png" width="187" alt="only the value differs"> | `Unread: 5` | `Unread: 3` | Text close to the expected text is drawn, so it passes (the value itself is the tree check's job) |
| <img src="../images/text_visual_check/en/translucent.png" width="187" alt="translucent overlay"> | `Game Center` | `Game Center` | The overlay is translucent and the text under it can be read |

Spaces, letter case, and full-width versus half-width characters are also normalized. When the expected
text is five characters or longer, a misread of about one character (such as `¡Cloud` for `iCloud`) is
tolerated.

### Only the beginning is drawn: passes with a note

| Image | Expected (tree) | OCR reading | Result |
|---|---|---|---|
| <img src="../images/text_visual_check/en/ellipsis.png" width="187" alt="ellipsis"> | `Language & Region` | `Language &...` | Passes with the note `text-ellipsized` (truncation the app intended) |
| <img src="../images/text_visual_check/en/partially_hidden.png" width="187" alt="part of the text is hidden"> | `Notifications` | `Notificatio` | Passes with the note `text-partially-hidden` (more than half is visible) |

- When an ellipsis (`…`) is drawn at the end, the step passes however much was read. Japanese fonts draw
  `…` as dots at the middle of the line, and OCR reads them as `•••` or a row of middle dots, so a row of
  dots also counts as an ellipsis.
- With no ellipsis, the step passes when **more than half** of the expected text is drawn. The note reads
  `part of the text is hidden`.

### Not visible: fails

| Image | Expected (tree) | OCR reading | Why it fails |
|---|---|---|---|
| <img src="../images/text_visual_check/en/mostly_hidden.png" width="187" alt="most of the text is hidden"> | `Game Center` | `Game` | Half or less is drawn (`most of the text is hidden`) |
| <img src="../images/text_visual_check/en/covered_from_left.png" width="187" alt="covered from the left"> | `Game Center` | `Center` | Only the end is drawn, so the beginning is covered (`covered`) |
| <img src="../images/text_visual_check/en/blank.png" width="187" alt="nothing drawn"> | `Game Center` | (nothing legible) | No text is drawn (`notRendered`) |
| <img src="../images/text_visual_check/en/full_cover.png" width="187" alt="fully covered"> | `Game Center` | (nothing legible) | A plain overlay hides all of it (`notRendered`) |
| <img src="../images/text_visual_check/en/other_text.png" width="187" alt="other text"> | `Game Center` | `Walpaper` | Unrelated text is drawn there (`textMismatch`) |

The failure message is `false positive (occlusion): present in the tree but not visually visible
[<reason>] ...`. When FM was unavailable and OCR alone decided, it says `judged by OCR alone because FM
gave no verdict`. In both cases the step does not fail at once: it keeps taking new screenshots for its
wait time (`waitSeconds`) and passes if the text becomes visible.

### Shapes OCR cannot judge: FM decides

| Image | Expected (tree) | OCR reading | Result |
|---|---|---|---|
| <img src="../images/text_visual_check/en/fm_decides.png" width="187" alt="FM decides"> | `Game Center` | (nothing legible) | Nothing legible, but something like a button or an icon is drawn. FM transcribes it (nothing), matches that, and fails the step |

OCR cannot judge a shape where another picture is drawn over the text, or where only part of the text is
left. FM judges those. Where FM is unavailable, they pass unverified.

## When a step fails

- **Check that the screenshot is not stale**: the tree can be on the right screen while the screenshot
  still shows the previous one. This has happened while the VSCode extension's device monitor was
  streaming an Android Emulator's screen. Look at whether the failure screenshot in the report shows a
  different screen.

  <img src="../images/text_visual_check/en/stale_screenshot.png" width="94" alt="stale screenshot">

  The image above is a real case: the crop at the position of the expected `agree=false`. What it shows
  is the grey area of the map screen from the previous scenario.
- **Check that it really is not covered**: a keyboard, sheet or banner over the element.

## Limitations

- A short truncation that shows only the first few characters can fail: OCR may read `…` as a single
  dot, which does not count as an ellipsis.
- A translucent overlay counts as visible as long as the text under it can be read.
- Where FM is unavailable, shapes OCR cannot judge (the "FM decides" shape above) are not verified.
  `fleetest doctor --fm-only` tells you whether FM is available.

### Link
- [index](../index.md)
