# Network Exposure and Security

[in Japanese(日本語)](network_security_ja.md)

A summary for explaining to IT/security what this tool opens and where, when running on a
corporate LAN that does not reach the internet. It is not a setup guide.
How the files and destinations that test code (scenarios) can reach are restricted is covered in [Checking the sandbox and opening the holes you need](sandbox.md).

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
| Published ports from compose.yaml (a run of a project that has `scripts/compose.yaml`) | Normally `127.0.0.1`. `0.0.0.0` for a run with a physical-device lane and for `services up --physical` | Not needed |
| fleetest's proxy (Apple Container, when `allowedDomains` is set) | The gateway IP of the container network | Not needed (it relays only to the `allowedDomains` destinations) |
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
  scenario sends to destinations listed in `sandbox.allowedDomains`, and the images a run of a project with compose.yaml pulls
  from a container registry (docker.io etc.) when they are not on the Mac; the relay image is also built from alpine on docker.io.
  An image you built yourself and wrote in `image:` is not pulled. On a closed network, load images first with
  `fleetest services pull` or `fleetest services load <tar>`. With nothing listed in `allowedDomains`, a scenario cannot reach
  anything outside the Mac. See [Sandbox defaults](../reference/running/sandbox_access.md)).

| What is fetched | Destination | When |
|---|---|---|
| Bootstrap scripts | `raw.githubusercontent.com` | Setup and update |
| fleetest itself | `github.com` | clone, pull, update check |
| **20+ Swift dependencies** | `github.com` (`apple/*`, `grpc/*`, `swiftlang/*`, `swift-server/*`, `jpsim/Yams`) | `swift build` |
| 8 VSCode extension dependencies | `registry.npmjs.org` | Building the extension |
| `xcodegen` (required), `libimobiledevice` | Homebrew's distribution hosts | Setup |
| Android system images and command-line tools | `dl.google.com` | Creating an Emulator, installing Android SDK tools |
| Container images (when you use compose.yaml) | A container image registry (docker.io) | Start of a run, `fleetest services pull` |

**By volume the Swift dependencies dominate** — not the fleetest repository itself. The Android
bridge APK ships inside the repository, so no Android build tooling is needed.

## Firewall settings

### The sandbox is what narrows a scenario's outbound traffic

The macOS firewall (System Settings → Network → Firewall) stops **incoming** connections per app; it cannot narrow
traffic a scenario sends out. What allows a scenario's outbound traffic per destination is `sandbox.allowedDomains`
(see "Destinations" in [Sandbox defaults](../reference/running/sandbox_access.md)).
**If you write nothing, a scenario cannot reach the outside at all**, so you do not need an extra firewall.

- The actual connection to an allowed destination is made by fleetest itself (this Mac). The restrictions of the Mac's
  and your company network's firewalls and proxies still apply. If the destination is allowed but unreachable from
  the Mac, the proxy returns `502 Bad Gateway`.
- If **a local proxy runs on this Mac's localhost** (a traffic analysis tool, a corporate proxy agent, SSH port
  forwarding), a scenario can go through it to destinations outside `allowedDomains`. Stop it on Macs that run
  untrusted scenarios ([Notes and limitations](limitations.md)).

### Keep the macOS firewall on

- **fleetest opens no externally reachable port on this Mac.** The CLI, the MCP server and the monitor talk over
  standard input/output, and the bridges and the proxy listen only on loopback (`127.0.0.1`). Loopback is outside the
  firewall's scope, so fleetest works with the firewall on and without adding per-app permissions. **There are two
  exceptions, both in runs that use compose.yaml services**: with Apple Container the proxy's forwarder listens on the
  container network's gateway IP (the table above), and in a run with a physical device lane the services' published
  ports open on every interface (the machine setting `services.publishForPhysicalDevices` is the consent to that).
- When you use a physical iOS device over Wi-Fi, the device listens and the Mac connects to it. No setting is needed
  on the Mac.
- **Only on a Mac you use as a remote runner**, turn off the firewall's "Block all incoming connections" (when it is
  on, SSH is blocked too; the firewall itself can stay on). The steps are in
  [Adding a Mac](../fleet/adding_mac.md).

### Company firewalls

While tests run, fleetest itself does not go outside (except for scenarios connecting to `allowedDomains`). It goes
outside only for installation and updates; the destinations are in "Outbound traffic" above, and how to run in a closed
network is in "Closed networks (no internet access)" below.

## Closed networks (no internet access)

### Option A (recommended): allow HTTPS to the destinations above

Five destinations need to be reachable (`raw.githubusercontent.com`, `github.com`,
`registry.npmjs.org`, Homebrew's distribution hosts, and `dl.google.com` if you use Android), plus a container image registry (docker.io) if you use compose.yaml. Since there is no telemetry and **nothing
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

There is **no supported way for a user to pin a version** — distribution is the latest release tag.
On a closed network you do not need one: **when you add a new release tag to the mirror is itself
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

## Check it on your own Mac

These steps check that what is described above actually holds on your own Mac. All of them only read; none changes a setting.

### 1. See which ports are listening

The ports fleetest uses are the bridge ports, 8123-8154. Check that none is open in a form reachable from outside (on all interfaces).

#### Instruction for your AI assistant

```text
Check the TCP listeners on this Mac. Split the result of lsof -nP -iTCP:8123-8154 -sTCP:LISTEN into those whose address is 127.0.0.1 (loopback) and those with * or 0.0.0.0 (all interfaces). Also run fleetest doctor and tell me about any warning.
```

<details>
<summary><b>Run it manually (click to expand)</b></summary>

```bash
lsof -nP -iTCP:8123-8154 -sTCP:LISTEN    # the bridge ports
lsof -nP -iTCP -sTCP:LISTEN | grep -i fleetest    # fleetest's own listeners
fleetest doctor
```

</details>
<br>

What you should see:

- The first command prints a line for each running bridge, and nothing if no bridge is running. An address (the `NAME`
  column) such as `127.0.0.1:8123` or `localhost:8123` means loopback only. The bridge of a physical iOS device connected
  over Wi-Fi listens on the device, so it does not appear in this list (only while a scenario runs, fleetest's relay
  appears as `127.0.0.1:<port>`).
- The second prints fleetest's own listeners. Normally nothing. Only while a scenario runs with `allowedDomains` set, a line
  for the proxy on `127.0.0.1` appears (the port changes each time).
- `fleetest doctor` warns about leftover old bridges and about Docker's API being published on TCP. If nothing is printed,
  neither warning applies.

### 2. See that outbound traffic is narrowed to `allowedDomains`

Read this Mac's `sandbox.allowedDomains` and check that the list is the only set of destinations a scenario can reach.

#### Instruction for your AI assistant

```text
Tell me what ~/.config/fleetest/config.json has in sandbox.allowedDomains. If the file or the sandbox key does not exist, say so. Do not edit anything.
```

<details>
<summary><b>Run it manually (click to expand)</b></summary>

```bash
cat ~/.config/fleetest/config.json
```

</details>
<br>

What you should see:

- Only the destinations listed in `allowedDomains` are reachable from a scenario. If the file does not exist, or
  `allowedDomains` is missing or empty, a scenario cannot reach the outside at all. The bridge of a physical iOS device over Wi-Fi is reached through a
  relay that fleetest opens on this Mac's `localhost` (only while that scenario runs, and connected only to that device's bridge).
- Even a listed destination is not reachable by a connection the scenario makes directly with a `URLSession` it created (only
  `httpRequest` and `fleetestURLSession`, which go through the proxy, reach it). Connecting to a destination that is not listed
  returns `403 Forbidden` from the proxy. How to confirm it by actually connecting, and how to read failures, are in
  [Network access from scenarios](../reference/writing/network_access.md).
- The meaning of each key is in [Machine settings (config.json)](../reference/project/machine_settings.md). Changing a value is
  done by hand by the person at this Mac (do not have the AI write it).

### 3. Check that the closed-network setup works

On a closed network, check that either Option A (allow the destinations) or Option B (an internal mirror) goes through.

#### Instruction for your AI assistant

```text
I want to check that the closed-network setup works. Check git's insteadOf settings, a git ls-remote of foundation-tester on github.com, and HTTPS reachability (status codes) of raw.githubusercontent.com, github.com, registry.npmjs.org and dl.google.com, and tell me the results. Do not change any settings.
```

<details>
<summary><b>Run it manually (click to expand)</b></summary>

```bash
git config --global --get-regexp '^url\..*\.insteadof$'
git ls-remote https://github.com/wave1008/foundation-tester.git HEAD
for h in raw.githubusercontent.com github.com registry.npmjs.org dl.google.com; do
  curl -sS -m 10 -o /dev/null -w "$h %{http_code}\n" https://$h/
done
```

</details>
<br>

What you should see:

- (1) is the Option B setting. A line such as `url.https://<internal-mirror>/.insteadof https://github.com/` means git traffic
  to GitHub goes to the mirror. Nothing means no redirect (you run with Option A).
- (2) returns a commit hash and a `HEAD` line when fetching fleetest itself works (with Option B, through the mirror). It
  ends with `Could not resolve host` or `Connection timed out` when it does not.
- (3) prints an HTTP status code per destination. A number (such as `200` or `301`) means the destination is reachable;
  `000` with an error means it is not. With Option B, `raw.githubusercontent.com` and `github.com` need not be reachable
  (you clone first and run `Scripts/install.sh` directly). Homebrew's distribution hosts are not included here; ask your
  IT team which hosts you use.

### Link
- [index](../index.md)
