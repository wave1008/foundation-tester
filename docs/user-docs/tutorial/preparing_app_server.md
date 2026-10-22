# Preparing the servers your app depends on

[in Japanese(日本語)](preparing_app_server_ja.md)

Put the servers, DBs and stubs your own app uses into containers and declare them to fleetest. Once declared, the servers
start automatically on every `fleetest run` and stop when it ends. If you only connect to an existing server, you do not
need this page. The details are in [Services the app depends on](../reference/writing/services.md); a worked example is
[sut-ec-mobile/fleetest/compose.yaml](https://github.com/wave1008/sut-ec-mobile/blob/main/fleetest/compose.yaml).

## 1. Declare the server and check it

### Prompt for the AI

```text
Build the image myapp-server:local from the Dockerfile in <server folder> and declare it in
TestProjects/myshop/workspace/scripts/compose.yaml of the fleetest test project myshop. If there is no Dockerfile, create one
(split a build stage from a run stage, and include bash in the run stage for the healthcheck). Publish the port on 127.0.0.1:8080. Write a healthcheck.
If you use Apple Container, first set the builder VM to 3 GB of memory.
Make the app's server address switchable in the build settings: http://127.0.0.1:8080 for the iOS Simulator build and http://10.0.2.2:8080 for the Android Emulator build.
Rebuild both and update the paths in the app profile.
Check the start-up with fleetest services up --project myshop --profile ios-run, confirm that /health returns ok, then services down and report the result.
```

What you'll see: `services up` prints the published port and returns after the `healthcheck` passes.

## 2. Ask step by step (optional)

The prompts of step 1, split up.

### ① Dockerfile

```text
Create a Dockerfile for the server in <server folder>. Split a build stage from a run stage so the run image stays small.
Include bash in the run stage for the healthcheck.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```dockerfile
FROM gradle:8-jdk17 AS build
WORKDIR /src
COPY . .
RUN gradle --no-daemon installDist

FROM eclipse-temurin:17-jre
COPY --from=build /src/build/install/app /app
EXPOSE 8080
CMD ["/app/bin/app"]
```

</details>

### ② Build the image

```text
Build the image myapp-server:local from the Dockerfile in <server folder>. If you use Apple Container, first set the builder VM to 3 GB of memory.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
container builder stop && container builder start --cpus <N> --memory 3g
container build -t myapp-server:local .
```

CPUs: the Mac's core count (`sysctl -n hw.ncpu`) divided by 4, rounded up. With Docker, run `docker build -t myapp-server:local .`.

</details>
<br>

What you'll see: `myapp-server:local` appears in `container image list` (`docker images` for Docker).

### ③ compose.yaml

```text
In TestProjects/myshop/workspace/scripts/compose.yaml of the fleetest test project myshop, declare a server using the image myapp-server:local and a PostgreSQL.
Publish the port on 127.0.0.1:8080. Write a healthcheck for both, and start the server only after the DB has finished starting.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: dev
      # An Apple Container volume has lost+found at its root, so use a subdirectory
      PGDATA: /var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
  server:
    image: myapp-server:local
    depends_on:
      db:
        condition: service_healthy
    ports: ["127.0.0.1:8080:8080"]
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && grep -q ok <&3"]
      interval: 3s
      retries: 60
```

</details>

### ④ Point the app at the server

```text
Make My Shop's server address switchable in the build settings: http://127.0.0.1:8080 for the iOS Simulator build and http://10.0.2.2:8080 for the Android Emulator build. Rebuild both and update the paths in the app profile of the fleetest test project myshop.
```

A physical device points at this Mac's LAN address (the machine setting `services.publishForPhysicalDevices` is also needed;
a worked example is in steps 2-3 of [Measuring the app's responsiveness](../response/measuring_app_response.md)).

### ⑤ Check the start-up

```text
Start the server with fleetest services up --project myshop --profile ios-run and confirm that /health returns ok. When confirmed, run services down.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest services up --project myshop --profile ios-run
curl http://127.0.0.1:8080/health     # at the published port that was printed
../foundation-tester/.build/debug/fleetest services down --project myshop --profile ios-run
```

</details>

## When you fix the server

```text
I fixed the server, so rebuild the image myapp-server:local under the same name from <server folder>.
```

Things you write yourself (do not have the AI assistant write them):

- Put secrets such as passwords and tokens in `~/.config/fleetest/secrets/<project>.env`.
- Containers cannot reach external networks. Write the domains they may reach in `sandbox.allowedDomains` in the machine settings.

Related: [Services the app depends on](../reference/writing/services.md) / [Network access from scenarios](../reference/writing/network_access.md) / [Extending](../reference/writing/extending.md)

Next: [Testing an app that needs a login](logging_in.md)

### Link
- [index](../index.md)
