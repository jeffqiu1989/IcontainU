<div align="center">

# IcontainU

**A native macOS GUI for Apple's [`container`](https://github.com/apple/container).**

*`I`* — Apple's lowercase‑i lineage (iOS, iPhone) · *`contain`* — container · *`U`* — UI

Built with SwiftUI. No Electron, no daemon of its own — it just drives the `container`
system you already have.

English | [中文](README_zh.md)

</div>

---

Two things make IcontainU worth your dock:

## ⚡ Smart Create — drop in an image, the form fills itself

<img src="docs/screenshots/Auto_fill.gif" width="100%" alt="Auto-fill demo" />

Pick an image and IcontainU reads it for you. `EXPOSE` becomes port rows, `VOLUME` becomes
mount rows, and the environment variables the entrypoint **actually needs** (like
`MYSQL_ROOT_PASSWORD`) are surfaced and pre‑filled — not just build‑time defaults. Stop
cross‑referencing `docker run` snippets from the registry page: the container you want is one
click away.

## 🧩 Compose — bring a whole stack up in one click

<img src="docs/screenshots/Compose_Demo.gif" width="100%" alt="Compose demo" />

Import a `compose.yaml`, preview the services, networks and volumes, and bring the whole
project up **in dependency order** — including `healthcheck` gating, so a service waits until
its dependency is genuinely ready. Projects persist on disk, so they survive `down` and a
restart; re‑Up any time. It even works around Apple `container`'s broken container‑to‑container
DNS on macOS 26, so service discovery by name just works.

## More screenshots

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

Beyond the two headliners above:

### 🐧 Machines that just work
Apple's `container machine` needs an image with an **init system** — and stock `ubuntu` /
`debian` / `fedora` images don't have one, so they silently fail to boot. IcontainU ships
presets pointing at **official, init‑ready images** (Alpine, Rocky Linux 8 / 9 / 10 UBI‑init):
pick one and it boots. CPU / memory / home‑mount mode and a default machine are all settable.

### 📦 Smart image pull
- Pulls **only your host architecture** — smaller and faster, no multi‑arch clutter (Apple's
  `container pull` fetches *every* architecture by default).
- **Registry‑mirror aware**, with a one‑click **DaoCloud preset** covering 9 common registries
  (Docker Hub, GCR, GHCR, Quay, NVIDIA, …), each toggleable individually.
- Mirrors are a pure GUI rewrite layer: the image is retagged to its canonical name, so the
  mirror **leaves no trace** on your local images.

### 🃏 Everything on a card
Each container card carries **Start / Stop / Shell / Logs / Delete**, a live **stats** tab
(CPU, memory, network, block I/O, process count), and **streaming logs** with follow + copy.

### ✨ Friction removers
Tap an IP to copy it, tap a port to copy `ip:port` (e.g. `127.0.0.1:8080`), tap a mount to open
it in Finder. Local‑image autocomplete, an **Analyze vs. Pull** button that knows whether an
image is already local, and Docker‑style auto‑naming (`brave_turing`) instead of raw UUIDs.

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

- `Shell` / `exec` opens the system Terminal.app — no embedded terminal yet.
- System configuration is **view‑only** in the app; edit it via the CLI.
- Containers are sorted by id.
- Menu bar support is under development.

## Compose reference

IcontainU supports a **practical subset** of the Compose spec. Anything unsupported is surfaced
as a warning banner at import — **never silently dropped**.

### Supported fields

| Field | Notes |
| --- | --- |
| `image` | — |
| `command` | string **or** array form |
| `ports` | numeric and `host:container/proto` |
| `environment` | list `["K=V"]` **and** map `{K: V}` |
| `volumes` | named (`vol:/data`) and bind (`/host:/data[:ro]`, incl. relative `./`) |
| `networks` | per‑service and top‑level |
| `depends_on` | start order **and** `condition: service_healthy` |
| `healthcheck` | `test`, `interval`, `timeout`, `retries`, `start_period` (see below) |
| `container_name`, `user` | — |
| top‑level `networks:` / `volumes:` | — |

### Not supported

`build:` · `restart:` · `deploy.replicas` / scale · `${VAR}` interpolation / `.env` / `env_file`
· `profiles` · `secrets` · `configs` · `extends` · YAML anchors · advanced `driver_opts`.

> Because `${VAR}` interpolation, `secrets` and `build` are unsupported, official stacks that
> combine them (e.g. the TLS‑enabled Elastic stack) can be parsed and previewed, but not brought
> up as‑is.

### Project isolation & multi‑network

- **Every project is namespaced.** Containers, volumes and networks are prefixed with the project
  name (`<project>-<service>`, `<project>_<volume>`, `<project>_<network>`), so two projects that
  each declare a `db` service — or a `data` volume — run side by side without clashing. A hard
  clash only happens if you pin the **same** `container_name:` in two projects, which fails loudly
  instead of one project hijacking the other's container. Every container is also tagged with
  `com.icontainu.compose.project` / `.service` so a project lists and tears down as a unit.
- **Multi‑network is fully supported.** A service on several networks gets the right peer IP on
  each one: service‑name resolution picks the address on a network the two containers actually
  share, matching how compose networks scope connectivity.

<details>
<summary><b>Healthcheck &amp; startup gating</b> — how <code>service_healthy</code> is honored</summary>

<br>

A service's `healthcheck` (`test` as `CMD` / `CMD-SHELL`, plus `interval`, `timeout`, `retries`,
`start_period`) is honored **at Up time** to gate
`depends_on: { dep: { condition: service_healthy } }` — a dependent isn't created until its gated
dependency's probe passes.

Apple `container` 1.0.0 has **no native healthcheck** (`RuntimeStatus` is only running/stopped),
so the probe runs via `container exec` with a per‑probe timeout. The state machine (start‑period
grace, consecutive‑failure counting) lives in IcontainU and **only runs during Up** — there is no
always‑on healthy/unhealthy badge.

- If a gated dependency never becomes healthy, Up fails **but the dependency container is left
  running** so its logs can be inspected (Containers tab → Logs); fix the compose file and re‑Up.
- A `service_healthy` dependency that declares **no** healthcheck is reported as a warning and
  treated as start‑order only (it can never gate).
- `test: ["NONE"]` / `disable: true` disables a check; `start_interval` is parsed but ignored.

</details>

<details>
<summary><b>Runtime constraints</b> — Apple <code>container</code> 1.0.0 on macOS 26 (not IcontainU bugs)</summary>

<br>

- **Container‑to‑container DNS is broken on macOS 26 — IcontainU works around it.** The runtime
  resolves a service name to a reserved `28.0.0.x` address that doesn't match the container's real
  `eth0` IP (`192.168.64.x`); TCP handshakes pass but stateful protocols (MySQL, PostgreSQL, …)
  fail mid‑handshake. IcontainU injects `<service> → real IP` into each project container's
  `/etc/hosts` after Up (re‑injecting when IPs change after a restart), which is why service
  discovery by name works.
- **Use a named volume for database data dirs.** A bind from a macOS host directory refuses
  `chown` even as root (the file‑sharing layer blocks it), so images whose entrypoint must `chown`
  their data dir (mysql/mariadb, postgres) fail to start on a bind mount. Named volumes
  (e.g. `db_data:/var/lib/mysql`) work — and are the compose idiom anyway.
- **Non‑root images need `user: "0"` on a named volume.** Images that run as a non‑root user
  (e.g. prometheus as `nobody`) can't write their named‑volume data dir and crash; set `user: "0"`
  to run as root, which can write the Linux filesystem of a named volume.

</details>

## License & acknowledgements

Licensed under the Apache License 2.0 — see [LICENSE](LICENSE).

IcontainU is built on Apple's `container` and `containerization` projects; see
[NOTICE](NOTICE) for attribution.

Developed with the assistance of vibe coding (AI-assisted development).
