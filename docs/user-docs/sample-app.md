# Preparing the Sample App

[in Japanese(日本語)](sample-app_ja.md)

After [Getting Started (Installation)](getting-started.md), this page takes you through putting the server of the
sample app used in the Quick start
([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile), a Compose Multiplatform shopping app) into a
container and declaring it to fleetest. The server is built with Kotlin (Ktor) and PostgreSQL.

## 1. Build the server image

### Prompt for the AI

```text
Clone https://github.com/wave1008/sut-ec-mobile next to this folder.
Use Apple Container as the container runtime. If it is missing, install it with Homebrew and run container system start --enable-kernel-install once.
Before building, run container builder stop && container builder start --cpus <N> --memory 3g, where <N> is a quarter of the value of sysctl -n hw.ncpu, rounded up.
In the root of sut-ec-mobile, build the server image sut-ec-mobile-server:local from server/Dockerfile.
Also run container image pull postgres:16.
Don't modify any shell configuration files. There's no need to build the app.
Check that container image ls lists sut-ec-mobile-server and postgres, report, and stop.
```

- **Give the builder VM 3 GB of memory.** Apple Container builds inside a builder VM, and with the default 2 CPUs /
  2 GB the server's build (Gradle) stalls (it failed after 25 minutes without output). The build succeeded with
  2.5 GB and 3 GB, so 3 GB leaves 1 GB over the failing 2 GB and 0.5 GB over the passing 2.5 GB.
- **CPUs: a quarter of the Mac's core count, rounded up** (see `sysctl -n hw.ncpu`: 2 for 8 cores, 3 for 10 cores,
  4 for 16 cores).
- Expect about 2.5 minutes with 2 CPUs. The build reaches the outside network to fetch dependencies.
- When the build finishes you may stop the builder VM with `container builder stop` (the image stays).
- `postgres:16` is pulled beforehand so the first run does not wait for the image.

<details>
<summary><b>Do it manually (click to show details)</b></summary>

```bash
brew install container
container system start --enable-kernel-install    # fetches the Linux kernel; once only
sysctl -n hw.ncpu                                  # core count; <N> is a quarter of it, rounded up

container builder stop && container builder start --cpus <N> --memory 3g

cd ..                                              # clone next to your work folder
git clone https://github.com/wave1008/sut-ec-mobile.git
cd sut-ec-mobile
container build -t sut-ec-mobile-server:local -f server/Dockerfile .

container image pull postgres:16
container image ls
```

</details>

## 2. Declare the server to fleetest

Servers are declared in `TestProjects/<project>/workspace/scripts/compose.yaml`.

### Prompt for the AI

````text
Create TestProjects/project1/workspace/scripts/compose.yaml with the following content (create the folder if it does not exist; if the test project project1 does not exist, first create it with fleetest project create project1). Report the path of the file you created and stop.

```yaml
# Backend of sut-ec-mobile (PostgreSQL + server). fleetest starts it on every run, waits for the healthchecks, runs the scenarios, then stops it.
# server is the image built in "Preparing the Sample App" (it is on this Mac, so it is not pulled).
# The app's endpoint is baked into the build (iOS Simulator = 127.0.0.1:8090 / Android Emulator = 10.0.2.2:8090).
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: sutec
      POSTGRES_USER: sutec
      POSTGRES_PASSWORD: sutec
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sutec"]
      interval: 2s
      timeout: 3s
      retries: 30

  server:
    image: sut-ec-mobile-server:local
    depends_on:
      db:
        condition: service_healthy
    environment:
      DATABASE_URL: jdbc:postgresql://db:5432/sutec
      DB_USER: sutec
      DB_PASSWORD: sutec
      JWT_SECRET: dev-secret-change-me
      IMAGES_DIR: /app/mock-server/images
    ports:
      - "127.0.0.1:8090:8090"
    healthcheck:
      # The JRE image has no curl, so read /health with bash's /dev/tcp
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8090 && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && grep -q '\"status\":\"ok\"' <&3"]
      interval: 3s
      timeout: 5s
      retries: 60
      start_period: 10s
```
````

- fleetest starts and stops the server on every run. Even after you restart your Mac, there is nothing to start again.
- The DB is created empty on every run, and the server seeds the initial data at startup.
- When you update the server, build it again under the same name (fleetest uses the image on this Mac).
- See [Services the app depends on](reference/writing/services.md) for how to write the declaration.

<details>
<summary><b>Do it manually (click to show details)</b></summary>

In your work folder, create the folder and write the file:

```bash
mkdir -p TestProjects/project1/workspace/scripts
```

Write the YAML from the prompt above to `TestProjects/project1/workspace/scripts/compose.yaml`.
If the test project `project1` does not exist, first create it with `../foundation-tester/.build/debug/fleetest project create project1`
(the VSCode extension also creates it on startup after Reload Window).

</details>

Next: [Quick start](quick-start.md)

### Link
- [index](index.md)
- [Getting Started (Installation)](getting-started.md)
- [Quick start](quick-start.md)
