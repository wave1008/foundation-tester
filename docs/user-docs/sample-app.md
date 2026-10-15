# Preparing the Sample App

[in Japanese(日本語)](sample-app_ja.md)

After [Getting Started (Installation)](getting-started.md), this page takes you through preparing the sample app used
in the Quick start ([sut-ec-mobile](https://github.com/wave1008/sut-ec-mobile), a Compose Multiplatform shopping app)
and declaring its server to fleetest. The server is built with Kotlin (Ktor) and PostgreSQL.

## Prompt for the AI

```text
Clone https://github.com/wave1008/sut-ec-mobile next to this folder, then run bash ../sut-ec-mobile/fleetest/prepare.sh in this folder.
Don't modify any shell configuration files. When it finishes, report the last lines of the script's output.
```

The script (`sut-ec-mobile/fleetest/prepare.sh`) goes through these steps and skips the ones already done, so you can run it
as many times as you like.

1. Checks that this is an Apple Silicon Mac and that it runs in your work folder
2. Installs Apple Container with Homebrew if it is missing
3. Starts the container runtime (the first time, it fetches the Linux kernel)
4. Pulls the server and PostgreSQL images (the server is an image published on GitHub Container Registry, so nothing is
   built on your Mac)
5. Creates the test project `project1` if it does not exist, and puts the server declaration (`compose.yaml`) in
   `TestProjects/project1/workspace/scripts/`

- fleetest starts and stops the server on every run. Even after you restart your Mac, there is nothing to start again.
- The DB is created empty on every run, and the server seeds the initial data at startup.
- To pick up a newer server, run `git pull` in `sut-ec-mobile` and run the same script again.
- The cloned repository is also used to build the app in the [Quick start](quick-start.md).
- The declaration is in [sut-ec-mobile/fleetest/compose.yaml](https://github.com/wave1008/sut-ec-mobile/blob/main/fleetest/compose.yaml),
  and how to write one is in [Services the app depends on](reference/writing/services.md).

<details>
<summary><b>Do it manually (click to show details)</b></summary>

Run these in your work folder:

```bash
git clone https://github.com/wave1008/sut-ec-mobile.git ../sut-ec-mobile
bash ../sut-ec-mobile/fleetest/prepare.sh
```

To use a different test project name, pass it like `bash ../sut-ec-mobile/fleetest/prepare.sh <name>`.

</details>

Next: [Quick start](quick-start.md)

### Link
- [index](index.md)
- [Getting Started (Installation)](getting-started.md)
- [Quick start](quick-start.md)
