<div align="center">

# IcontainU

**A native macOS GUI for Apple's [`container`](https://github.com/apple/container).**

*`I`* — Apple's lowercase‑i lineage (iOS, iPhone) · *`contain`* — container · *`U`* — UI

Built with SwiftUI. No Electron, no daemon of its own — it just drives the `container`
system you already have.

English | [中文](README_zh.md)

</div>

---

## Screenshots

Pick an image and IcontainU analyzes it and fills the create form for you:

![Auto-fill demo](docs/screenshots/Auto_fill.gif)

| Containers | Create a container |
| --- | --- |
| ![Containers](docs/screenshots/Containers.png) | ![Create a container](docs/screenshots/Create_Container.png) |

| Create a machine | Images |
| --- | --- |
| ![Create a machine](docs/screenshots/Create_Machine.png) | ![Images](docs/screenshots/Images.png) |

| Registry mirrors | DaoCloud one-click preset |
| --- | --- |
| ![Registry mirrors](docs/screenshots/Mirrors.png) | ![DaoCloud preset](docs/screenshots/Mirrors_DaoCloud.png) |

## What it is

IcontainU is a native macOS app (SwiftUI, Swift 6.2) that talks to Apple's `container`
system over XPC. It ships **no container runtime of its own** — it's a front-end for the
`container` you install separately. It builds on:

- [`apple/container`](https://github.com/apple/container) — the runtime and API client
- [`apple/containerization`](https://github.com/apple/containerization) — OCI / image plumbing
- [`apple/swift-log`](https://github.com/apple/swift-log)

## Features

### 🐧 Machines that just work
Apple's `container machine` needs an image that contains an **init system** — and stock
`ubuntu` / `debian` / `fedora` images don't have one, so they silently fail to boot. IcontainU
ships built‑in presets that point at **official, init‑ready images**: Alpine and Rocky Linux
8 / 9 / 10 (UBI‑init). Pick one and it boots. You can also set CPU / memory / home‑mount mode,
mark a default machine.

### 📦 Smart image pull
- Pulls **only your host architecture** — smaller, faster, no multi‑arch clutter — unlike
  Apple's `container pull` which fetches *every* architecture by default.
- **Registry‑mirror aware**, with a one‑click **DaoCloud preset** covering 9 common registries
  (Docker Hub, GCR, GHCR, Quay, NVIDIA, …). Enable / disable each mirror individually.
- Mirrors are a pure GUI rewrite layer: the image is retagged to its canonical name, so the
  mirror **leaves no trace** on your local images. (Affects pulls from the app, not the CLI.)

### 📝 Create form that fills itself
Select an image and IcontainU analyzes it for you:
- `EXPOSE` → port rows, `VOLUME` → mount rows;
- the environment variables the entrypoint script **actually expects** (e.g.
  `MYSQL_ROOT_PASSWORD`) are surfaced and pre‑filled — not just build‑time defaults.

Plus local‑image autocomplete, an **Analyze vs. Pull** button that knows whether the image is
already local, and Docker‑style auto‑naming (`brave_turing`) so you never stare at a raw UUID.

### 🃏 Everything on a card
Each container card carries **Start / Stop / Shell / Logs / Delete**, a live **stats** tab
(CPU, memory, network, block I/O, process count), and **streaming logs** with follow + copy.

### ✨ Friction removers
- Tap an IP → copy IP
- Tap a port → copy `ip:port` (e.g. `127.0.0.1:8080`)
- Tap a mount → open the mount directory or volume in Finder

### 🧩 Compose (multi‑service orchestration)
Import a `compose.yaml`, preview the services and shared networks/volumes, then bring
the whole project up in dependency order. Projects persist on disk, so a project survives
`down` and a restart — re‑Up it any time.

A practical subset of compose is supported — `image`, `command`, `ports`, `environment`
(list **and** map form), `volumes` (named **and** bind), `networks`, `depends_on` (start
order **and** `condition: service_healthy`), `healthcheck`, `container_name`, `user`, and
top‑level `networks:` / `volumes:`. Unsupported fields (`build:`, `restart:`, `${VAR}`
interpolation, `profiles`, `secrets`, …) are surfaced as a warning banner instead of
failing silently.

See **Compose — supported subset & limitations** below for the exact field matrix and the
runtime constraints (especially around DNS and bind mounts).

### 🚀 Frictionless setup
First start **auto‑installs the kernel**; the app continuously monitors `container` health; and
if `container` isn't installed yet, one click takes you to the releases page.

## Requirements

- **Apple silicon** Mac (M‑series)
- **macOS 26** or newer

### 1. Install Apple `container` (≥ 1.0.0)

Download from GitHub releases:

```bash
# https://github.com/apple/container/releases
```

### 2. Start the container system & install kernels

First launch from the command line — it will prompt you to install kernels:

```bash
container system start
container system status   # should report: running
```

> **Tip:** If you skip this step and open IcontainU directly, the app will auto-install kernels
> for you, but the download is slow (~60 MB in the background). Command-line install is faster.

> Without a running `container` system the app still opens, but the sidebar stays empty.

## Download & install

Download `IcontainU-v0.1.0.zip` below, unzip, and move `IcontainU.app` to Applications.

Not notarized. On first launch macOS will block it — right-click → Open, or System Settings → Privacy & Security → Open Anyway, or `xattr -d com.apple.quarantine /Applications/IcontainU.app`.

## Build & run from source

Requires the Swift 6.2 toolchain (Xcode 26).

```bash
swift build
swift run IcontainU
```

### Package

```bash
./scripts/package-app.sh          # → build/IcontainU.app  (ad-hoc signed)
cd build && zip -r -y IcontainU.zip IcontainU.app
```

## Status & known limitations

This is **0.1.0** — early, but already useful day to day.

- `Shell` / `exec` opens the system Terminal.app (no embedded terminal yet).
- System configuration is **view‑only** in the app; edit it via the CLI.
- Containers are sorted by id; richer status / start‑time ordering is on the roadmap.
- Menu bar support is under development.

### Compose — supported subset & limitations

**Supported fields.** `image`, `command` (string **or** array), `ports` (numeric and
`host:container/proto`), `environment` (list `["K=V"]` **and** map `{K: V}`), `volumes`
(named `vol:/data` and bind `/host:/data[:ro]`, incl. relative `./`), `networks`,
`depends_on` (start order **and** `condition: service_healthy`), `healthcheck`,
`container_name`, `user`, and top‑level `networks:` / `volumes:`.

**Healthcheck & startup gating.** A service's `healthcheck` (`test` as `CMD` / `CMD-SHELL`,
plus `interval`, `timeout`, `retries`, `start_period`) is honored **at Up time** to gate
`depends_on: { dep: { condition: service_healthy } }`: a dependent is not created until its
gated dependency's probe passes. Apple `container` 1.0.0 has **no native healthcheck**
(`RuntimeStatus` is only running/stopped), so the probe runs via `container exec` with a
per‑probe timeout; the state machine (start‑period grace, consecutive‑failure counting)
lives in IcontainU and only runs during Up — there is no always‑on healthy/unhealthy badge.
If a gated dependency never becomes healthy, Up fails but the dependency container is left
running so its logs can be inspected (Containers tab → Logs); fix the compose file and
re‑Up. A `service_healthy` dependency that declares **no** healthcheck is reported as a
warning and treated as start‑order only (it can never gate). `test: ["NONE"]` /
`disable: true` disables a check; `start_interval` is parsed but ignored (no real‑world use).

**Not supported** (reported as a warning banner, never silently dropped):
`build:`, `restart:`, `deploy.replicas` / scale, `${VAR}` interpolation / `.env` /
`env_file`, `profiles`, `secrets`, `configs`, `extends`, YAML anchors, and advanced
`driver_opts`. (Because `${VAR}` interpolation and `secrets`/`build` are unsupported, the
official multi‑service stacks that combine them — e.g. the TLS‑enabled Elastic stack — can
be parsed and previewed but not brought up as‑is.)

**Runtime constraints** (from Apple `container` 1.0.0 on macOS 26 — not bugs in IcontainU):

- **Container‑to‑container DNS is broken on macOS 26.** The runtime resolves a service name
  to a reserved `28.0.0.x` address that does **not** match the container's real `eth0` IP
  (`192.168.64.x`); TCP handshakes pass but stateful protocols (MySQL, PostgreSQL, …) fail
  mid‑handshake. IcontainU works around this by injecting `<service> → real IP` into each
  project container's `/etc/hosts` after Up (and re‑injecting when IPs change after a
  restart). This is why service discovery by name works in IcontainU.
- **Host bind‑mounted data directories cannot be `chown`ed.** A bind from a macOS host
  directory refuses `chown` even as root (the file‑sharing layer blocks it), so database
  images whose entrypoint must `chown` their data dir (mysql/mariadb `…/mysql`,
  postgres `…/postgresql/data`) **fail to start on a bind mount.** Use a **named volume**
  for database data dirs (e.g. `db_data:/var/lib/mysql`), which is the compose idiom anyway.
- **Non‑root images can't write their named‑volume data dir.** Images that run as a
  non‑root user (e.g. prometheus as `nobody`) crash on a named volume. Set `user: "0"` in
  the compose file to run as root — this works because named volumes are a Linux filesystem
  that root can write.
- **No project‑level service isolation.** Container names are global; two projects with a
  service of the same name (e.g. both `db`) cannot run at the same time. IcontainU tags
  every container with a `com.icontainu.compose.project` / `.service` label so a project is
  listed and torn down as a unit.
- **Multi‑network is supported** but DNS is **not** isolated per network — a container can
  resolve peers on any of the project's networks.

## License & acknowledgements

Licensed under the Apache License 2.0 — see [LICENSE](LICENSE).

IcontainU is built on Apple's `container` and `containerization` projects; see
[NOTICE](NOTICE) for attribution.

Developed with the assistance of vibe coding (AI-assisted development).
