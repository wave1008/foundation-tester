# imageIs

Classifies the **image** of the last grabbed element with a classifier trained from sample images
(DefaultClassifier) and asserts its label (a port of `imageIs` from Shirates' Vision edition).

## Functions

| function | description |
|---|---|
| `select(selector).imageIs(label, timeout:)` | Asserts that the label the element's image is classified as contains `label`. Retakes and waits up to `timeout`. |
| `imageIs(label, timeout:)` | The implicit form acting on the last grabbed element. |

## Where the sample images go

```
<project>/vision/classifiers/DefaultClassifier/
  @i/Settings/[Camera Icon]/   sample images (png / jpg)
  @i/Settings/[General Icon]/
  ...
```

- The label is the image's parent folder. Folders can be nested to any depth (per OS, per screen and so on).
- The judgement looks only at the part of the label **from the last `[`** (`[Camera Icon]`). Putting the same
  `[…]` in two folders is a configuration error and fails.
- Each sample should be **exactly the element's frame** cropped from a screenshot (the element is cropped the
  same way when it is judged).
- The classifier always answers one of the sample labels. **Add samples of the other, easily confused elements on
  the same screen too**, not only the one you want to recognise (at least two labels are needed).
- Files starting with `#` are not used for training. `options=` / `imageFilter=binary` in `MLImageClassifier.swift`
  are read with the same meaning as in Shirates.
- The first judgement trains the classifier (a few seconds). The result is kept under `.fleetest/` and is retrained
  only when the samples change.
- It works the same way as [CheckStateClassifier](state_assertion.md), which judges checked states from images
  (each classifier has its own folder).


## Capturing and checking samples (CLI)

Instead of cropping samples by hand, capture them from the live device. The element's frame is cropped with the
same function the judgement uses, so the crops always match.

```sh
fleetest vision capture --project <project> --classifier DefaultClassifier \
  --label "@i/Settings/[Camera Icon]" --selector "#element-id" --port <bridge port>
fleetest vision check --project <project>
```

- `vision capture` refuses mistakes before saving, such as a label that does not fit the classifier (a folder name that does not end with `[…]`) or the
  same label in another folder.
- `vision check` trains if needed and checks **whether the classifier can tell its own samples apart**. Samples it
  gets wrong are named in a warning (samples that cannot be told apart will also be confused on real screens). It
  only warns; the exit code stays 0.
- The same warning appears at the end of a scenario when a run finds such samples.
- Over MCP, `ft_capture_element` does the same (it also accepts an `ft_snapshot` ref and returns the check after saving).

## Example

```swift
select("#settings_camera").imageIs("[Camera Icon]")
```

## Notes

- Without samples, or without samples whose label contains `label`, the check fails immediately.
- The failure message shows the label the image was classified as and its confidence.

### Link
- [index](../index.md)
