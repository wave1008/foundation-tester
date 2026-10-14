# Services the app depends on (compose.yaml)

[in Japanese(日本語)](services_ja.md)

If the app under test needs a database, an API or a stub server, declare it in
`TestProjects/<project>/workspace/scripts/compose.yaml` (next to `run-setup.sh`). fleetest **starts the services for each
run and stops them afterwards**. It waits until they are up (the `healthcheck`) before `run-setup.sh` runs, and stops them
after `run-teardown.sh`. If the file is not there, nothing happens.

It works with `fleetest run`, a run from the VS Code extension and the MCP tool `ft_start_run`. It does not start with
`ft_run_scenario` (a single scenario) or `--dry-run`; to have the services up while you explore, use
`fleetest services up` ([Starting and stopping by hand](#starting-and-stopping-by-hand)). For a run sent to a
[remote runner](../../fleet/remote_runners.md), the services start **on the runner machine** (with that machine's
runtime and settings).

## Runtime

fleetest uses Docker (Rancher Desktop, Docker Desktop and so on, through the unix socket) or Apple Container (the
`container` command). To fix the choice, set it in `~/.config/fleetest/config.json` on this Mac:

```json
{
  "services": { "runtime": "docker" }
}
```

`runtime` is `"docker"` or `"apple"`. When it is not set, fleetest uses Docker if Docker is available and Apple
Container otherwise (it starts Apple's system service automatically only when Docker is not available).

## Example

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      # Apple Container's volumes have lost+found at their root, which initdb refuses; use a subdirectory
      PGDATA: /var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
    volumes:
      - dbdata:/var/lib/postgresql/data
  api:
    image: example/api:latest
    depends_on:
      db:
        condition: service_healthy
    ports: ["127.0.0.1:8080:8080"]
    environment:
      API_TOKEN: ${API_TOKEN}

volumes:
  dbdata:
```

The app and the scenarios reach `api` at `127.0.0.1:8080`.

## What you can write

The syntax is the same as compose.

- Under `services.<name>`: `image` or `build`, `command`, `entrypoint`, `environment`, `env_file`, `ports`,
  `volumes`, `depends_on` (`condition`: `service_started` / `service_healthy` / `service_completed_successfully`),
  `healthcheck`, `stop_grace_period`, `working_dir`, `user`, `mem_limit`, `cpus`, `tmpfs`, `init`, `platform`,
  `labels`, `networks`.
- Top level: `networks` and `volumes`. `version` and `x-*` are ignored (fleetest prints one line saying so).
- **What you cannot write**: `restart`, `privileged`, `cap_add`, `network_mode`, `extra_hosts`, a bind of an arbitrary
  host path (you can bind only below `scripts/` and `data/`; `scripts/` is read-only) and external networks. An
  unknown key or type is refused with the offending part named, and the run does not start.

## Rules

- **Containers cannot reach the outside network.** The exception is the domains listed in `sandbox.allowedDomains` in
  this Mac's settings, reached through fleetest's proxy (the containers receive `HTTP_PROXY` / `HTTPS_PROXY` /
  `NO_PROXY`). See [Network access from scenarios](network_access.md) for the entries.
- **Published ports (`ports`) are bound to `127.0.0.1` only** (physical devices: see below).
- **An image is pulled only when it is not on this Mac.** The runtime pulls it directly, so the first pull needs
  outside network access.
- **`build:`** The context must be below `scripts/`, or in a place you list in this Mac's settings with
  `"services": {"buildSources": ["<dir>", …]}` (mounted read-only for the build). A build whose inputs have not
  changed is not repeated. **Apple Container builds inside a builder VM that starts with 2 CPUs and 2 GB of memory**;
  a Gradle or Maven build can crawl or stall there. Give it more once, before the run:
  `container builder stop && container builder start --cpus 6 --memory 8g` (fleetest does not change it).
- **Write a `healthcheck`.** Without one, a service is considered usable as soon as it has started.
- **A service that another one waits for with `service_completed_successfully`** (an initialisation container) runs in
  the foreground, and its exit code decides: non-zero and the run does not start.
- **Named volumes remain between runs.** Delete them with `fleetest services reset`.
- **If a service fails to start or its healthcheck fails, the run stops without executing any scenario** and prints
  the tail of the failed service's log.
- **When `run-setup.sh` fails or the run ends red, the tail of each service's log is saved** under the run's results
  directory (`results/runs/<month>/<runID>/services/<service>.log`).
- **Docker's API must not be published on TCP** (`0.0.0.0:2375` / `2376`): containers could reach it and mount this
  Mac's files. While it is so, the services refuse to start, and `fleetest doctor` warns.

## Secrets

Put secrets in `~/.config/fleetest/secrets/<project>.env` on this Mac, as `KEY=value` lines, and refer to them in
the `environment` values of compose.yaml with `${NAME}` (only the values of `environment` can refer to them). Only the
names you refer to are also passed to `run-setup.sh` / `run-teardown.sh` as environment variables. The values are masked in
fleetest's output (console and logs). Scenarios and scripts cannot read this file.

For substitutions that are not secret, write them in `scripts/.env` (same `${NAME}` notation).

## Physical devices

A run that includes a lane of a physical device (a real iPhone or Android phone) requires this in this Mac's settings:

```json
{
  "services": { "publishForPhysicalDevices": "<this Mac's LAN IPv4 address>" }
}
```

Without it the run does not start, and the message says how to write it.

- **With a physical-device lane, both runtimes publish the ports on every interface (0.0.0.0)**, so the Simulators
  on this Mac still reach `127.0.0.1` and the physical devices reach the LAN address. Apple Container cannot bind one
  host port to two addresses, and Docker cannot bind to a single IP. The setting is your consent to that exposure and
  the address the physical devices use; runs without a physical device stay on `127.0.0.1`.
- **Android physical devices**: for each published TCP port, fleetest sets up `adb reverse tcp:<port> tcp:<port>`, so
  the app on the device reaches the service at `127.0.0.1:<port>`. If the device already forwards that port, fleetest
  leaves it alone when the destination is the same (`tcp:<port>` → `tcp:<port>`; `down` does not remove it either) and
  stops the run when the destination differs (the app would reach that other server and verify the wrong thing). Any
  other failure to set it up is a warning. fleetest removes the forwards it set when it finishes; one it could not remove
  (adb not responding, for example) stays on the device. The next run leaves it alone when the destination is the same,
  and says nothing about it once you change the published port. Check with `adb -s <serial> reverse --list` and remove
  it with `adb -s <serial> reverse --remove tcp:<port>`.
- **iOS physical devices**: use a build with the LAN address built in, as described in
  [Adding physical devices](../../fleet/adding_physical_devices.md).
- **Exposure**: while the ports are published on the LAN, anyone on the same LAN can reach the service. Give the
  service its own authentication, and publish only for the run (and from `services up --physical` until `down`).

## UDP

If `ports` has a `/udp` entry, fleetest checks the UDP path once after startup (an echo, 1 second, 3 times). If it does
not arrive, **the run stops before any scenario** and says why (an app whose UDP never arrives would otherwise fail in
ways that look like app bugs). When Rancher Desktop's port forwarding is SSH, UDP does not pass, and the message names
that setting and how to switch it. Warnings that do not stop a run (a failed `adb reverse`) are recorded in its
`run.json` as `servicesWarnings`.

## Images on a machine without registry access

Images are pulled by the runtime when they are missing, so the first run needs access to the registry. To prepare
ahead of time, or on a machine without that access:

| Command | What it does |
|---|---|
| `fleetest services pull [--project <p>] [--profile <pf>] [--refresh]` | Pulls the images compose.yaml declares (and builds fleetest's relay image on first use) without starting anything. `--refresh` pulls them again even when they are present |
| `fleetest services load <file>` | Loads images from a tar archive made with `docker save` or `container image save` into this Mac's runtime |

## Operating the containers from the scripts

The only way for `run-setup.sh` / `run-teardown.sh` to operate the containers is the relay command `fleetest-services` (it is on
`PATH`). Only the services you declared are targeted.

```sh
fleetest-services exec db -- psql -U app < "$FT_WORKSPACE/data/seed.sql"   # standard input is passed too
fleetest-services logs api --tail 100
fleetest-services status
fleetest-services port api 8080            # prints the published host:port (/udp for UDP)
```

| Command | What it does |
|---|---|
| `fleetest-services exec <service> -- <command…>` | Runs a command in the service's container |
| `fleetest-services logs <service> [--tail N]` | Prints the log |
| `fleetest-services status` | Prints the state of the services |
| `fleetest-services port <service> <containerPort>[/udp]` | Prints the published `host:port` |

The scripts themselves run in their own sandbox ([Running scripts before and after a run](extending.md#running-scripts-before-and-after-a-run)).

## Starting and stopping by hand

For exploring, live operation and writing scenarios, a person can start the services before a run.

| Command | What it does |
|---|---|
| `fleetest services up [--project <p>] [--profile <pf>] [--physical] [--serial <adb serial>…]` | Starts the services, **waits until they are up**, prints the published ports and returns. The services keep running afterwards (a resident owner process holds them; the log is `.fleetest/services/<prefix>.log`). `--profile` can be omitted when the project has only one profile |
| `fleetest services down` | Stops them |
| `fleetest services status` | Shows the record, the lock and the resources on the runtime, with the size of each named volume and of the images fleetest built (the `build:` images of this workspace and the relay image). Nothing is deleted automatically; use `reset` when they have grown |
| `fleetest services reset [--force]` | Deletes this workspace's containers, networks, **volumes** and record. `--force` is needed while an `up` holds them (it stops that `up` first). While a run holds them, even `--force` deletes nothing (wait for the run to finish) |

**A real run (`fleetest run` / `ft_start_run`) takes over services started with `up`**: it prints a warning, stops them,
starts them again itself and stops them itself (so that the result is reproducible). While a run holds the services,
`services down` is refused.

From MCP, `ft_services` does the same: `action` is `up` / `down` / `status`, `profile` is required for `up` / `down`,
and `project`, `physical` and `androidSerials` (an array of strings) are optional. Like `ft_start_run`, it asks for approval
([MCP server](../tools/mcp_server.md#sandbox-and-approval)).

## When a run dies halfway

If a run dies without cleaning up (an ssh disconnection, SIGKILL), the next run on that machine or
`fleetest hooks reap` removes the containers and networks using the IDs it recorded. On a runner machine, use
`fleetest remote clean`.

### Link
- [index](../../index.md)
