# Test data and accounts (account, data, dataFile, addMedia)

[in Japanese(日本語)](dataset_ja.md)

Read accounts and test data from JSON files instead of writing them into the scenario source. Names, arguments and
the key format are the same as Shirates.

## Functions

| Function | Description |
|---|---|
| `account("[account1].password") -> String` | Returns a value of the account dataset (`accounts.json`). |
| `account("[account1]", "password") -> String` | Same as above (dataset name and attribute name passed separately). |
| `data("[order1].item") -> String` / `data("[order1]", "item") -> String` | Returns a value of the test data (`data.json`). Locations and overriding are the same as `account`. |

A key is `[datasetName].attributeName` and is **split at the last `.`** (`[a.b].x` is attribute `x` of dataset
`[a.b]`). The value can be passed straight to other commands.

```swift
action {
    type("#login_id", account("[account1].id"))
    type("#login_password", account("[account1].password"))
}
```

A successful call records no step (it only returns a value).

## Where the files go, and overriding

The files have the same shape as Shirates dataset JSON (attribute values must be strings; a dataset with a number or
boolean attribute is rejected).

```json
{
  "[account1]": { "id": "alice@example.com", "password": "..." },
  "[account2]": { "id": "bob@example.com",   "password": "..." }
}
```

| Location | Use |
|---|---|
| `<project>/dataset/accounts.json`, `data.json` | Shared values kept in the project (values that may go into the repository) |
| `~/.config/fleetest/dataset/<project name>/accounts.json`, `data.json` | **Values for this Mac only** (passwords and the like that stay out of the repository). The project name is the project folder's name |

- The machine-side file **overrides the project's values attribute by attribute**. Attributes it does not override stay
  as in the project, and attributes or datasets that exist only on the machine side can be used too.
- Either file may be absent (nothing happens if you do not use it). **If one of the files is broken (not readable as
  JSON), the call fails even when the other file has the value**, so a broken file is never skipped in favour of a stale value.
- When you run on another Mac, that Mac's machine-side files are used.
- The files are read once per scenario run (on the first call).

## When the value is missing

A missing file, dataset or attribute, broken JSON, or a key without a `.` fails the step and aborts the scenario. The
failure text lists every file it looked at and what was missing (never the value).

## Dry-run

Dry-run and listing do not read the files and **return the key string as is** (same as Shirates' no-load run).

## Using a file as it is (`dataFile`)

Data that does not fit keys and values (a CSV with many rows, a JSON body to send to an API, an image...) goes in the
dataset folder as a file, and `dataFile("file name")` returns its location (a `URL`). Read it the usual Swift way.

```swift
let rows = (try? String(contentsOf: dataFile("csv/users.csv"), encoding: .utf8)) ?? ""
for line in rows.split(separator: "\n").dropFirst() {   // the first line is the header
    // ...
}

let body = (try? String(contentsOf: dataFile("api/new_order.json"), encoding: .utf8)) ?? ""
httpRequest("https://api.example.com/orders", method: "POST", body: body)
```

- It looks in the same two places as `account()` / `data()`: `~/.config/fleetest/dataset/<project name>/<file name>`
  on the Mac that runs the scenario if it exists, otherwise `TestProjects/<project name>/dataset/<file name>`.
- **The whole file is replaced** (there is no per-attribute override as with `accounts.json`; contents are not merged).
- Write the file name relative to the dataset folder (folders are fine, as in `csv/users.csv`). Names that start with
  `/` or `~`, and names containing `..`, are not allowed.
- If it is in neither place, the step fails and the scenario stops (both paths it looked at are shown). The returned
  `URL` then points to an empty file, so a read written right after it reads an empty string and the scenario process
  does not crash.
- When the file is found, no step is recorded. Dry-run does not fail even if the file is missing (it returns the empty
  file).

## Adding a photo or video to the device (`addMedia`)

`addMedia("file name")` puts an image or video from the dataset folder into the device's photo library. Use it for
screens that pick a photo (profile picture, attachment).

```swift
addMedia("img/avatar.png")
```

- The file is looked up exactly as in `dataFile` (`~/.config/fleetest/dataset/<project name>/<file name>` on the Mac
  that runs the scenario if it exists, otherwise `TestProjects/<project name>/dataset/<file name>`). If it is in
  neither place, the step fails and the scenario stops.
- Supported extensions (case does not matter): images `jpg` `jpeg` `png` `heic` `gif`, videos `mp4` `mov`. Any other
  file fails without being sent.
- **iOS Simulator**: the file is added to the Photos library.
- **Android** (Emulator and physical device): the file is placed in `Pictures` (images) or `Movies` (videos) and the step
  waits until the media library lists it. If that cannot be confirmed within 10 seconds, the step fails. The file name
  may only contain letters, digits, `.`, `-` and `_`.
- **iOS physical devices fail**: there is no way to add media to the photo library from the Mac. Run it on a Simulator,
  or put the photo on the device by hand.
- **There is no command to remove what you added.** The Simulator has no command line to delete photos; erase the
  device if you need a clean library.
- Because scenarios run in a sandbox, **only files inside the dataset folder can be sent** (a link that leads outside
  the folder is refused).
- The step is recorded as `addMedia "file name"`. Dry-run sends nothing and only records the step.

## Masking secrets

**Values are not masked by default.** If you write `type(account("[account1].password"))`, the password stays in the
step description, the run log and the report as it is.

Write `redactAccountValues` in `~/.config/fleetest/config.json` on the Mac that runs the scenarios, and scenarios run on
that Mac **replace values returned by `account()` with `***` in reports, run logs and result JSON** (`data()` is not
masked). The setting of the Mac that runs the scenario is used (when you run on another Mac, write it on that Mac).

```json
{
  "redactAccountValues": true
}
```

When masking is on:

- All attributes of the dataset you called are masked (`id` too).
- **Values shorter than 4 characters are not masked** (a short value such as `ab` would turn unrelated text into `***`).
- What is masked is the text the scenario writes out: step descriptions, failure reasons, the run log, and the
  Markdown report with the failure-time element list. **Screenshots (text inside the pixels) cannot be masked.** If a
  screen shows the password in plain text, a failure-time screenshot shows it.
- If you write an `account()` value with `writeMemo`, the memo value handed to other scenarios also becomes `***`
  (do not put secrets in the memo).
- A value that happens to match part of other text masks that part too (for example a 4-character password `true`
  would also change the JSON word `true`).

### Link
- [index](../../index.md)
