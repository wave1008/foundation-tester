# Output folder and temporary folder (TestLog)

Returns the folders to use when a scenario writes files. Scenarios run inside a sandbox, so **these two folders
(and what is under them) are the only places a scenario can write**. The locations returned by
`NSTemporaryDirectory()` and `FileManager.default.temporaryDirectory` are not writable (the write fails with
"You don’t have permission"). The name and scope of `TestLog.directoryForLog` follow Shirates.

## Properties

| Property | Description |
|---|---|
| `TestLog.directoryForLog: URL` | The output folder of this test class: `<report directory>/<run start yyyy-MM-dd_HHmmss>/<test class name>/`. Shared by the scenarios of the class in one run. Kept with the reports. |
| `TestLog.directoryForTemp: URL` | A temporary folder for this scenario only. **Deleted when the scenario ends.** Not shared with other scenarios running in parallel. |

Each folder is created the first time it is read.

## What is kept and what is deleted

- Files in `directoryForLog` are kept like the reports and are subject to the retention cleanup (oldest days first).
  When a run is executed on another Mac (`--runner`), they are collected back together with the reports.
- `directoryForTemp` is deleted with its contents at the end of the scenario. Write anything you want to keep to
  `directoryForLog`.
- Scenario code runs in a dry run too, so both are available there (a dry run's output folder is thrown away).
- They are not available outside a scenario (for example in MCP's `ft_batch`).

## Example

```swift
@Test("Export the price list")
func S0010() {
    scenario {
        scene(1, "Save the list") {
            action {
                let csv = TestLog.directoryForLog.appendingPathComponent("prices.csv")
                try? "name,price\n".write(to: csv, atomically: true, encoding: .utf8)

                let work = TestLog.directoryForTemp.appendingPathComponent("unzipped")
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            }
        }
    }
}
```

### Link
- [index](../../index.md)
