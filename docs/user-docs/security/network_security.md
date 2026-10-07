# Network Exposure and Security

[in Japanese(日本語)](network_security_ja.md)

A summary for explaining to IT/security what this tool opens and where, when running on a
corporate LAN that does not reach the internet. It is not a setup guide.
How the files and destinations that test code (scenarios) can reach are restricted is covered in [The sandbox](sandbox.md).

## What listens where

| What | Where it listens | Authentication |
|---|---|---|
| Your Mac (CLI, MCP server, monitor, live control) | **Opens no externally reachable port.** Everything is NDJSON over standard input/output between parent and child processes only | — |
| The scenario sandbox's proxy | `127.0.0.1` only. Started only when `sandbox.allowedDomains` is set, on a port that changes each time | Not needed (loopback; it relays only to the `allowedDomains` destinations) |
| iOS Simulator bridge (XCUITest / in-app) | `127.0.0.1` inside the device only. The Simulator shares its host's network stack, so your machine can reach it | Not needed (loopback) |
| Android bridge (physical device and Emulator alike) | **Loopback inside the device only.** Reached from your machine through a dynamic local port that `adb forward` opens | Not needed (loopback) |
| Android Emulator gRPC | `127.0.0.1` | A Bearer token the Emulator itself issues once per boot |
| **Physical iPhone, USB path (default, recommended)** | An iproxy (libimobiledevice) USB tunnel. **Stays entirely on loopback** | Not needed (loopback) |
| **Physical iPhone, LAN path** | **All of the device's network interfaces.** Reachable from the same LAN | **Token required** (see below) |
| Remote Login (SSH) on the runner machine. Turned on there only when you use remote runs | Port 22 of the runner machine | Key-based authentication |
| Screen Sharing on the runner machine (recommended; turned on there only when you use remote runs) | Port 5900 of the runner machine. Do not open it on the router | macOS authentication |

- The bridge uses **32 ports, 8123-8154** (iOS).
- **Two conditions make a physical iPhone fall back to the LAN path**: (1) the Mac does not have
  iproxy installed, or (2) the device is connected over Wi-Fi rather than USB. Either one is
  enough to switch to LAN automatically.
- **Loopback bridges refuse requests sent by a web browser**.
  An unauthenticated loopback listener could otherwise receive requests that a web page you are viewing sends to
  `http://127.0.0.1:<port>`, or be reached by DNS rebinding (pointing a host name at `127.0.0.1` to read the
  responses too). Requests with an `Origin` header, a `Sec-Fetch-Site` other than `none`, or a `Host` that is not
  loopback are refused with **403** without touching the device. fleetest's own clients never send these headers.
- **The in-app bridge is never bundled into a production build.** It is injected at launch via
  `DYLD_INSERT_LIBRARIES` and is not linked into the app's binary.

## Token authentication for the LAN path

- Each time the bridge starts, the host generates a **32-byte random value** and passes it to the
  test runner as an environment variable.
- Every request from your machine carries it in an `X-FT-Token` header. **A mismatch returns
  401** without touching the device at all. The comparison is constant-time.
- **The bridge cannot open on all interfaces without a token** — the runner refuses to start if
  one is missing.
- The token lives in `.fleetest/bridge-<port>.endpoint` (at the work folder's root, not inside a
  `TestProjects/<project>/`) and **never passes through
  arguments or environment variables to other processes** (so it does not show up in `ps`).
- **This protects against a third party on the same LAN.** The loopback path has no
  authentication at all — anyone who can log into that Mac already has equivalent access.

## Outbound traffic

- **No telemetry or analytics is ever sent.**
- Apple Intelligence (Foundation Models) runs **entirely on-device**. Nothing leaves the device.
- **The app under test is never sent to Google.** Android's `adb install` can otherwise be
  blocked indefinitely by a Play Protect prompt, so verification is turned off only for the
  duration of the install and always restored afterward.
- Outbound traffic happens **only during setup, updates, the update check (once a day by the VSCode extension, with
  `git ls-remote`), and when Android system images are downloaded**. **Nothing goes out while tests run** (except what a
  scenario sends to destinations listed in `sandbox.allowedDomains`; with nothing listed, a scenario cannot reach
  anything outside the Mac. See [Accessible folders and destinations](access.md)).

| What is fetched | Destination | When |
|---|---|---|
| Bootstrap scripts | `raw.githubusercontent.com` | Setup and update |
| fleetest itself | `github.com` | clone, pull, update check |
| **20+ Swift dependencies** | `github.com` (`apple/*`, `grpc/*`, `swiftlang/*`) | `swift build` |
| 8 VSCode extension dependencies | `registry.npmjs.org` | Building the extension |
| `xcodegen` (required), `libimobiledevice` | Homebrew's distribution hosts | Setup |
| Android system images and command-line tools | `dl.google.com` | Creating an Emulator, installing Android SDK tools |

**By volume the Swift dependencies dominate** — not the fleetest repository itself. The Android
bridge APK ships inside the repository, so no Android build tooling is needed.

## Closed networks (no internet access)

### Option A (recommended): allow HTTPS to the destinations above

Five destinations need to be reachable (`raw.githubusercontent.com`, `github.com`,
`registry.npmjs.org`, Homebrew's distribution hosts, and `dl.google.com` if you use Android). Since there is no telemetry and **nothing
goes out while tests run**, this is usually straightforward to justify in an exemption request.
**No extra configuration is needed on the tool side.**

### Option B: an internal mirror (when A is not possible)

Use git's `insteadOf` to redirect **all** GitHub traffic. Neither `Package.swift` nor
`Package.resolved` is edited, so upstream version bumps need no follow-up work.

```
git config --global url."https://<internal-mirror>/".insteadOf "https://github.com/"
```

That single setting routes **both fleetest itself and all 20+ Swift dependencies** through the
mirror.

SwiftPM also follows this setting, so dependencies are fetched from the mirror rather than from `github.com`.

Three things remain:

- **Bootstrap scripts**: `insteadOf` applies to git only, not to `curl`. Clone first, then run
  `bash <TOOL_ROOT>/Scripts/install.sh` directly (the curl form will not work). Updates use
  `bash <TOOL_ROOT>/Scripts/update.sh` the same way
- **npm**: point `registry` in `.npmrc` at the internal proxy
- **Homebrew**: provide an internal tap, or pre-install `xcodegen` and `libimobiledevice`

To redirect only the initial clone, `FLEETEST_REPO_URL=<mirror URL>` also works.

### Pinning a version

There is **no supported way for a user to pin a version** — distribution is a single `main`.
On a closed network you do not need one: **how often you advance `main` on the mirror is itself
the internal release gate**, so you control which revision is taken without changing anything the
user does.

## Remote runners (running tests on another Mac)

The only path is **SSH with key-based authentication**. The trust model and what ends up on a runner machine are
covered in "Using it safely" in [Remote Runners](../fleet/remote_runners.md).

**Runner machines reach the same destinations as your Mac.** Each `fleetest remote setup` and version alignment makes
the runner machine fetch fleetest from GitHub and build it. On a closed network, apply Option A / B above to the
runner machines too.

## Decisions to make operationally

1. **Install `brew install libimobiledevice` on every Mac that uses a physical iPhone.** This
   switches it to the USB tunnel and removes the LAN exposure entirely (communication is also faster).
2. If a Wi-Fi-connected physical device must be used anyway, **put the test devices and runner
   machines on a segregated VLAN.**
3. On a closed network, first check whether the **Option A destinations can be allowed** (Option A
   under "Closed networks" above). If not, set up an internal mirror (Option B). **Decide one of
   them before you start — otherwise neither setup nor updates work.**
4. **Never write production credentials into scenarios or profiles.**

### Link
- [index](../index.md)
