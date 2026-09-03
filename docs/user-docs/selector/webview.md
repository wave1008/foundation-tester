# Elements Inside a WebView

Content inside a native WebView (iOS `WKWebView`, Android `android.webkit.WebView`) uses the
same selectors and the same commands as native elements. Three conventions differ from
native screens, though.

## `#id` availability depends on the read path

Whether the HTML `id` attribute is usable as `#id` depends on how the tree is read: it works
when the DOM can be read directly (iOS's default engine; Android WebViews and browsers), or
when accessibility exposes id (Android WebView 150+). **iOS's `xcuitest` engine does not
expose it** — WebKit doesn't forward HTML `id` into accessibility. iOS's default engine
(hybrid) handles reading and delegating into WebView content automatically, so no special
handling is needed on the scenario side there.

## Links appear as two elements

A link shows up as both a `.link` and a `.staticText` (on both OSes), with the same label —
so the label alone is ambiguous. Narrow by type: `.link&&Label`.

## Write input fields as two clauses

```swift
// field id is "email_input", its placeholder text is "Email"
type("#email_input||#Email", "user@example.com")
```

Write an input field's selector as **two `#` clauses joined by `||`**: one with the field's
`id`, one with its placeholder text. `#x` already tries placeholder when no element matches
by identifier (see below), so this two-clause form covers both "id-only" and
"placeholder-only" configurations — which matters because **Android's id and placeholder
availability can flip between WebView versions**. Writing only one clause means the selector
breaks on whichever configuration you didn't write for.

## The container type and timing

The container itself appears as type `.webView` (usable as a scope: `.webView >> …`). Give
extra time right after a navigation — content can take a few seconds to appear in the
accessibility/DOM tree, so use a longer `timeout:` on the first assertion after landing on a
WebView screen.

## `#x` also matches placeholder

```swift
type("#email_input", "user@example.com")   // matches by id, or by placeholder if id doesn't
```

`#x` first tries an exact `id` match; **only if nothing matches by identifier** does it try
`placeholder` instead. This means a single `#x` clause already covers the case where only
one of id/placeholder is exposed — the two-clause form above is for when you need to cover
*both* possibilities because the configuration can vary at runtime (e.g. across Android
WebView versions). See [docs/commands.md](../../commands.md) for the full explanation.

## Android: the WebView layer can be missing from screenshots

On Android, a device screenshot can occasionally drop the WebView layer entirely (the
accessibility tree still has every element at its real coordinates — only the captured
image is blank in that area). This is intermittent and self-corrects on relaunch, so
**write reachability checks as tree assertions (`exist` / `notExist`), not as a screenshot
check** — a screenshot-based check can fail for reasons that have nothing to
do with your scenario. Seeing the WebView content in a screenshot also requires WebView
debugging to be enabled in the app (typically only in debug builds); see
[docs/commands.md](../../commands.md) for detail.

## Android: `user` system images (Play Store images) close the DOM path

On Android, fleetest reads an app's WebView content over Chromium's devtools socket
(`webview_devtools_remote_<pid>`). Chromium only opens that socket when **at least one** of
these holds: the system image is debuggable (`ro.debuggable=1` — the `userdebug` builds
behind **Google APIs** images), the app is a debuggable build, or the app itself calls
`WebView.setWebContentsDebuggingEnabled(true)`.

**Play Store images (`google_apis_playstore`) are `user` builds (`ro.debuggable=0`).** Run a
release build of your app on one and none of the three holds, so the socket never opens and
fleetest silently falls back to the accessibility tree. The symptom is that attributes that
only exist in the DOM — `placeholder` above all — stop matching, while the same scenario is
green on a Google APIs image. Nothing else looks wrong: the APK and the WebView version are
identical, only the AVD's system image differs.

fleetest names the cause once per device on stderr when this happens:

```
⚠️ [emulator-5556] could not read com.example.app's WebView content over CDP — falling back to
   the accessibility tree. … the system is not debuggable (ro.debuggable=0) and the app under
   test is not a debuggable build either …
```

Fix any one of the three:

- **Create the AVD from a Google APIs image** (`google_apis`, not `google_apis_playstore`) —
  the recommended choice for a test fleet, since it works for release builds unchanged
- Test a **debuggable build** of the app
- Have the app call **`WebView.setWebContentsDebuggingEnabled(true)`**

Check which case you are in with `adb -s <serial> shell getprop ro.debuggable` (`1` = the
socket can open regardless of the app's build).

### Link
- [index](../index.md)
