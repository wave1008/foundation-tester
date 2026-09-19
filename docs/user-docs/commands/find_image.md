# findImage, findImages, existImage

Finds the element on the screen whose appearance is nearest to a sample image (a port of `findImage` / `findImages`
from Shirates' Vision edition). Use it to grab elements a selector cannot point at, such as icons with neither an id nor a label.
`existImage` searches the same way and asserts that the image is on the screen.

## Functions

| function | description |
|---|---|
| `findImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)` | Grabs the one element nearest to the sample image. Returns an empty element instead of failing when nothing is found (branch with `.isEmpty`). By default it looks at the current screen once (`waitSeconds` defaults to 0). Pass seconds to `waitSeconds` to wait for it to appear. |
| `findImages(label, threshold:, aspectRatioTolerance:)` | Returns every element below `threshold`, nearest first (`[FTElement]`). Looks at the current screen once (no waiting, no scrolling). `threshold: nil` returns every candidate. |
| `existImage(label, threshold:, aspectRatioTolerance:, waitSeconds:, scroll:, maxSwipes:)` | Asserts that the sample image is on the screen (a port of `existImage` from Shirates' Vision edition). It searches the same way as `findImage` and **fails when nothing is found**. Returns the found element. Without `waitSeconds` it waits for the image to appear up to the run profile's default wait (same as `exist`). |
| `element.tap(holdSeconds:)` | Taps the grabbed element. An element grabbed by `findImage` / `findImages` is tapped at the centre of the found frame. |

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

- Put images cut out by **the element's own frame** (`fleetest vision capture` or the MCP tool
  `ft_capture_element` cuts them for you).
- `findImages` uses only one sample image (the one for the running OS first).

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
- **Parts of the same shape that differ only in their text (list rows, for example) are hard to tell apart.** In a
  measurement, rows of identical-looking buttons were 0.08 to 0.15 apart, and the default `threshold` (0.15) grabbed a
  different row. When looking for such parts, check the distances in the record and tighten `threshold` (for example `threshold: 0.03`).
- **Capture sample images for each OS version and screen scale you test on.** The same row is 0.04 to 0.12 apart across OS
  versions because the text is drawn differently (measured on the same row on Android 15 / 13 / 12, including differences
  you cannot see). Devices on the same OS version are 0.001 to 0.003 apart. `findImage` / `existImage` try every
  sample in the label folder, so adding the new sample to the same folder finds the element on both devices (you can
  keep `threshold` tight). `findImages` uses only one sample, so this does not help there.
- One call takes roughly 0.1 seconds for the screenshot plus about 8 milliseconds per candidate (measured on a simulator).
- `waitSeconds` defaults to 0: it looks at the current screen once (it does not follow the run profile's default wait). To wait for the
  image to appear, for example right after a screen transition, pass seconds such as `waitSeconds: 3`. While scrolling, it looks once per position.
- When `existImage` fails, the failure message says the nearest distance and the `threshold`, and the screenshot it judged is
  attached to that step in the report. While it waits, it takes a new screenshot and compares again at growing intervals (from 0.1 second up to 1 second).
- Inside `withScrollDown { }` and the like, `findImage` and `existImage` search while scrolling. Pass `scroll: .noScroll`
  to look at the current screen only (`existImage("[Icon]", scroll: .noScroll)`).
- To search while scrolling, pass `scroll:` (`findImage("[Icon]", scroll: .down)`), the same way as `exist` and `select`.
  No command has function-name aliases such as `findImageWithScrollDown` or `tapWithScrollDown` (writing one gives a compile error that shows the right form).
- When there is no sample image at all, the step fails as a configuration error.
- Occasionally the Mac's image processing (Vision) temporarily returns the same feature print for every image. Comparing in
  that state would "find" the first candidate, so the state is detected and the step fails (the message says
  `Vision returned the same image feature print for different images`). Retry the run.
- In the same way, a less extreme state where Vision returns a different feature print for the same image is detected by
  re-measuring the sample on each search (the message says `Vision returned a different image feature print for the same image`).
  Distances in that state cannot be trusted, so the step fails. Retry the run; if it keeps happening, restart the Mac.
- When the found element has a writable selector (an id or a unique label), you can chain assertions such as `textIs`.
- Moving the screen after finding makes `tap()` hit the old coordinates. Tap right after finding.
- Unlike Shirates, which cuts parts out by segmenting the image, the candidates are the frames of accessibility
  elements. Parts that do not appear in accessibility cannot be found.

### Link
- [index](../index.md)
