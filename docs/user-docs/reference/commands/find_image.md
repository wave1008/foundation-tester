# Find by image (findImage, findImages, existImage)

[in Japanese(日本語)](find_image_ja.md)

Finds the element on the screen whose appearance is nearest to a sample image (a port of `findImage` / `findImages`
from Shirates' Vision edition). Use it to grab elements a selector cannot point at, such as icons with neither an id nor a label.
`existImage` searches the same way and asserts that the image is on the screen.

## Functions

| function | description |
|---|---|
| `findImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)` | Grabs the one element nearest to the sample image. Returns an empty element instead of failing when nothing is found (branch with `.isEmpty`). By default it looks at the current screen once (`waitSeconds` defaults to 0). Pass seconds to `waitSeconds` to wait for it to appear. |
| `findImages(label, threshold:, aspectRatioTolerance:)` | Returns every element below `threshold`, nearest first (`[FTElement]`). Looks at the current screen once (no waiting, no scrolling). `threshold: nil` returns every candidate. |
| `existImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)` | Asserts that the sample image is on the screen (a port of `existImage` from Shirates' Vision edition). It searches the same way as `findImage` and **fails when nothing is found**. Returns the found element. Without `waitSeconds` it waits for the image to appear up to the run profile's default wait (same as `exist`). |
| `element.tap(holdSeconds:, maxGestureSeconds:)` | Taps the grabbed element. An element grabbed by `findImage` / `findImages` is tapped at the centre of the found frame. `holdSeconds` greater than 0 makes it a long press, capped at 10s by default — pass `maxGestureSeconds:` to allow up to 60 for this one call. |

## How it searches

1. It looks up the sample images of DefaultClassifier. It uses the images in folders whose label ends with `label`,
   trying the ones for the running OS (marked `@i` for iOS / `@a` for Android) first.
2. It cuts the accessibility elements of the screen out of the screenshot by their frames. Only the elements whose
   **aspect ratio is close** to the sample (tolerance `aspectRatioTolerance`, 0.2 by default) become candidates, closest first.
3. For each candidate it measures the **image feature print distance** to the sample (Vision's FeaturePrint; smaller is more similar).
4. `findImage` grabs the nearest one when its distance is at most `threshold` (0.15 by default). Otherwise it
   classifies that one with DefaultClassifier (the same classifier as [imageIs](image_assertion.md)). It grabs it only when the
   label matches and, in addition, its distance to one of that label's samples is at most `threshold` (or the classification
   confidence is at most `threshold`). A matching label alone is not enough, because the classifier always answers one of
   the sample labels.

## Where the sample images go

It uses the same samples as [imageIs](image_assertion.md).

```
<project>/vision/classifiers/DefaultClassifier/
  @i/Home/[Camera Icon]/   sample images (png / jpg)
  @a/Home/[Camera Icon]/
```

- Put images cut out by **the element's own frame** (`fleetest vision capture` cuts them for you;
  for MCP, see [MCP server](../tools/mcp_server.md)).
- `findImages` also uses every sample in the label folder. When several samples hit the same element, it is returned once with the nearest distance (Shirates' `findImages` uses only one sample).

## Example

```swift
findImage("[Camera Icon]").tap()

let icon = findImage("[Camera Icon]", waitSeconds: 3)
if icon.isEmpty {
    // not found
}

findImage("[Share Icon]", scroll: .down).tap()

let stars = findImages("[Star Icon]")
stars.first?.tap()

existImage("[Camera Icon]")
existImage("[Share Icon]", scroll: .down).tap()
```

## Notes

- The distance and the number of compared candidates are written to the record (the nearest distance when nothing was found). Use it to choose `threshold`.
- **Parts of the same shape that differ only in their text (list rows, for example) are hard to tell apart.** Their
  distance can fall below the default `threshold` (0.15), so a different row gets grabbed. When looking for such parts,
  check the distances in the record and tighten `threshold` (for example `threshold: 0.03`).
- **Capture sample images for each OS version and screen scale you test on.** The same row is drawn differently across OS
  versions, so its distance grows even when you cannot see the difference; devices on the same OS version are almost 0
  apart. `findImage` / `existImage` try every sample in the label folder, so adding a sample for each version to the
  same folder finds the element on both devices (you can keep `threshold` tight). The same goes for `findImages`: for
  parts whose look changes with their state (on / off), put a sample for each state and both are returned.
- `waitSeconds` defaults to 0: it looks at the current screen once (it does not follow the run profile's default wait). To wait for the
  image to appear, for example right after a screen transition, pass seconds such as `waitSeconds: 3`. While scrolling, it looks once per position.
- When `existImage` fails, the failure message says the nearest distance and the `threshold`, and the screenshot it judged is
  attached to that step in the report. While it waits, it takes a new screenshot and compares again.
- Inside `withScrollDown { }` and the like, `findImage` and `existImage` search while scrolling. Pass `scroll: .noScroll`
  to look at the current screen only (`existImage("[Icon]", scroll: .noScroll)`).
- To search while scrolling, pass `scroll:` (`findImage("[Icon]", scroll: .down)`), the same way as `exist` and `select`.
  No command has function-name aliases such as `findImageWithScrollDown` or `tapWithScrollDown` (writing one gives a compile error that shows the right form).
- When there is no sample image at all, the step fails as a configuration error.
- Occasionally the Mac's image processing (Vision) temporarily returns odd feature prints, so distances cannot be
  trusted (it shows up when the Mac is busy). When this is detected, the tool waits and searches again (no device operation
  is repeated; the step records the note `vision-anomaly-retried`). The step fails only when the state does not clear; the
  message starts with `Vision returned the same image feature print for different images` or
  `Vision returned a different image feature print for the same image`. Retry the run; if it keeps happening, restart the Mac.
- When the app area of the screenshot is a single colour (all black or all white), the screenshot is treated as not captured
  and nothing is compared. The tool waits and takes it again (note `blank-screenshot-retaken`); the step fails if it is
  still a single colour.
- When the found element has a writable selector (an id or a unique label), you can chain assertions such as `textIs`.
- Moving the screen after finding makes `tap()` hit the old coordinates. Tap right after finding.
- Unlike Shirates, which cuts parts out by segmenting the image, the candidates are the frames of accessibility
  elements. Parts that do not appear in accessibility cannot be found.

### Link
- [index](../../index.md)
