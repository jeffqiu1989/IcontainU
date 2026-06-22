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

## License & acknowledgements

Licensed under the Apache License 2.0 — see [LICENSE](LICENSE).

IcontainU is built on Apple's `container` and `containerization` projects; see
[NOTICE](NOTICE) for attribution.

Developed with the assistance of vibe coding (AI-assisted development).
