# Release notes

## 0.3.0 — July 2026

**Biggest headline: a built-in MCP server.** IcontainU now ships a native
Model Context Protocol server that exposes every container, image, machine,
volume, network, and Compose operation as a tool — 25 tools across 6 groups.
Drive IcontainU from Claude Code, OpenCode, or any MCP-compatible client over
HTTP with Bearer API key auth.

Everything else in this release hardens the existing experience: a polished
Compose card, image export/import, tighter bind-mount handling, and a proper
Samples directory with verified multi-service stacks.

### Built-in MCP server

A native MCP server over Streamable HTTP, embedded in the app. 25 tools
covering containers (list/create/start/stop/delete/exec/logs/inspect), images
(list/pull/delete), machines (list/boot/stop/delete), volumes, networks, and
Compose (list/up/down/status).

- Bearer API key auth with constant-time comparison; keys generated in the app's
  **MCP** panel, exportable as a ready-to-paste `.mcp.json` snippet.
- Session management with idle reaping (3600 s timeout).
- Host-path bind mounts are **rejected by default** — named volumes only.
  Rationale: a remote agent mounting an arbitrary host path is a foot-gun; the
  app UI is the right place for bind mounts.
- Compose `up` / `down` over MCP, with an optional `wait` parameter that reports
  init-service exit codes.
- Compose `up` via MCP does **not** resolve relative paths or `.env` files
  (the YAML is raw text with no baseDirectory).
- Full per-tool schema, parameters, and examples: [docs/mcp_server.md](mcp_server.md).

### Compose card polish

The Compose project card now reads like the rest of the app: looser vertical
rhythm, a divider between the tag area and the actions, a centered action row,
and 24pt button chrome that matches the Containers card. Tap anywhere on the
card except the buttons to expand; the Up button is disabled once every service
is already running.

### Image export / import

Containers can be exported to an OCI image tarball and imported back —
useful for capturing a container's state and moving it elsewhere.

### Bind-mount hardening

- The create-container sheet now **validates bind-mount paths before creation**.
- A complete guide in the README explains the macOS bind-mount chown problem
  and the fix (point data directories at a subdirectory via `--datadir` /
  `PGDATA`), with ready-to-use templates in `samples/`.

### Compose fixes

- `${PWD}` in a compose file now resolves to the **file's directory**, not the
  process working directory — fixes relative `./` mounts that broke for files
  imported from deep paths.
- Multi-line `command:` values and existing bind-mount sources are preserved
  through the import → record → re-Up round-trip.

### Samples

Thirteen verified Compose templates shipped in `samples/` — from single-service
databases to a 3-master / 3-replica Redis cluster behind an Envoy proxy, a
Kafka KRaft cluster, and an ELK stack. Each one has been tested to run on
IcontainU.

### Under the hood

- **Container create** no longer fakes success — real errors propagate back to
  the caller.
- **MCP lifecycle ops** (boot, stop, delete) are serialized so concurrent calls
  don't race.
- **Read tools** refresh before returning to avoid stale state after mutations.
- The **compose service list collapses** by default; a wider window makes the
  app start at a larger size.
- READMEs, samples table, and the full MCP API reference were rewritten in
  English.

### Requirements

- Apple silicon Mac (M-series), **macOS 26** or newer.
- Apple [`container`](https://github.com/apple/container/releases) ≥ 1.0.0.

### Known limitations

- `Shell` opens Terminal.app — no embedded terminal yet.
- System configuration is view-only; edit it via the CLI.
- MCP: no `machine_create`, no `build:` / `secrets:` / `configs:`, no host bind
  mounts, no relative-path / `.env` resolution in Compose. Full details in the
  [MCP server doc](mcp_server.md).

---

## 0.2.0

(See the tag on GitHub / Gitea. Highlights: Compose subset, smart create with
image-prefilled forms, smart image pull with registry mirrors, container cards
with stats/logs/shell, machine presets, and the compose DNS-28.x workaround.)

## 0.1.0

(See the tag on GitHub / Gitea. First usable release: container/image/machine
management, smart create, and the Compose subset.)
