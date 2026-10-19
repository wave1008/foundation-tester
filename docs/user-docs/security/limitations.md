# Notes and limitations

[in Japanese(日本語)](limitations_ja.md)

## What the sandbox does not stop

The sandbox exists to protect this Mac. It does not stop the following.

| Not stopped | Description |
|---|---|
| Operations on the app under test and its accounts | Deleting, purchasing, sending and so on are the test itself, so they are not blocked. Check the contents of scenarios you received from others before running them |
| Services on this Mac's localhost | To reach the bridges, every localhost port is open (only the adb server, the Emulator and Docker's TCP API ports are closed). If a service listening there has weak authentication, a scenario can go through it to run things outside the sandbox (see the list below) |
| Bridges of other devices | Bridges of other devices on the same Mac are reachable too, so a scenario can read and drive other devices' screens |
| Outbound traffic in runs that use a physical iOS device over Wi-Fi | The port numbers of the device's bridge (those in use within the default 8123–8154) are open to any destination host. A scenario can connect to a server on the internet listening on that number without going through `allowedDomains`. Run untrusted scenarios on a physical device over USB (iproxy) or a Simulator |
| Exfiltration through the device | Contents of files a scenario could read can be sent to the device as input to the app. Nothing stops the app from sending it out |
| Reading secrets that are not in the list | The read denial is a list of the usual places and is not exhaustive. Add places to `sandbox.denyRead` |
| What runs outside the sandbox | fleetest itself, evaluating `Package.swift` and building dependencies, the containers of the compose.yaml services, the app under test |

**On a Mac that runs untrusted scenarios, do not leave the following running.**

- Endpoints that run code without authentication (browser or Node.js debug ports, Jupyter, Docker exposed over TCP,
  and so on): a scenario can run code outside the sandbox
- Local proxies (traffic analysis tools, corporate proxy agents, SSH port forwarding, and so on): a scenario can
  bypass `allowedDomains` and reach any destination
- Docker's API published on TCP (`0.0.0.0:2375` / `2376`): the containers started for a run's services
  ([compose.yaml](../reference/writing/services.md)) could reach it and mount this Mac's files. fleetest refuses to
  start services while it is so, and `fleetest doctor` warns

What scenarios cannot do (writing to the temporary folder, reading environment variables and so on) and what to use instead you can try step by step in [Checking the sandbox and opening the holes you need](sandbox.md).

## Operational notes

- **Do not put production credentials in scenarios, profiles or datasets.** Use test accounts. Even with
  `redactAccountValues` on, text captured in screenshots and recordings is not redacted.
- **Writing the port in `allowedDomains` is recommended.** A line without a port reaches every port of the host,
  including other services such as databases.
- **Use `allowDirectAdb` only when needed.** Once open, a scenario can reach the outside through the shell inside an
  Emulator and reach every connected Android device. Speed is almost the same as with delegation.
- **`sandbox.disabled` is for temporarily isolating a cause.** If a scenario works without the sandbox, it is doing
  something the sandbox refuses; rewrite it with the fixed doors in steps 3 and 4 of [Checking the sandbox and opening the holes you need](sandbox.md) and restore the setting.
- **Runs from MCP go through approval.** In Claude Code, the installer writes settings that ask for confirmation only
  for `ft_start_run` (the full run, including the scripts before and after it) and `ft_services` (starting the services). How to choose the approval scope is in
  [MCP server](../reference/tools/mcp_server.md).
- **macOS updates can change the behavior.** The `sandbox-exec` fleetest uses is marked deprecated by Apple, and its
  syntax is not officially documented. If scenarios start failing with permission errors after a macOS update,
  update fleetest.

- **Using a physical iOS device on a runner machine puts a development signing key in a keychain without a password**
  ([Adding physical devices](../fleet/adding_physical_devices.md)). Anyone who can log in to that runner machine can sign with this key.

## When things do not work

| What happens | Where to look |
|---|---|
| Writing a file fails with "You don’t have permission" | Only the two `TestLog` folders are writable |
| Outbound requests time out or return `403 Forbidden` | The troubleshooting table in [Network access from scenarios](../reference/writing/network_access.md) |
| The scenario does not start and an error about the settings file appears | The JSON in `~/.config/fleetest/config.json` and whether it has unknown keys |
| An environment variable looks empty | Only the variables fleetest uses are passed to scenarios ([Sandbox defaults (writable places, unreadable places, destinations)](../reference/running/sandbox_access.md)) |

## Related

- [Network Exposure and Security](network_security.md) — the ports fleetest opens, outbound traffic, and running on a closed network
- [Checking the sandbox and opening the holes you need](sandbox.md)
- [Sandbox defaults (writable places, unreadable places, destinations)](../reference/running/sandbox_access.md)

### Link
- [index](../index.md)
