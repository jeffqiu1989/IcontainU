# IcontainU MCP Server

IcontainU ships a built-in MCP (Model Context Protocol) server so a remote AI client (Claude Code, OpenCode, and other MCP clients) can operate containers, images, machines, volumes, networks, and Compose projects over MCP.

## Overview

| Item | Detail |
|------|--------|
| Protocol | MCP over Streamable HTTP (`StatefulHTTPServerTransport`) |
| Transport | swift-nio HTTP server (not Hummingbird) |
| Endpoint | `/mcp` |
| Auth | Bearer API key, validated in the NIO handler |
| Config storage | UserDefaults (`mcpSettings`) |
| Session timeout | 3600 s (idle sessions reaped by `MCPSessionManager`) |
| Request body limit | 1 MB |
| Default port | 3000 |
| Default bind | `127.0.0.1` |

## Configuration

MCP Server is embedded in the main app and toggled/configured manually from the **MCP** panel.

### MCPSettings

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `isEnabled` | Bool | `false` | Whether the MCP server is running |
| `port` | Int | `3000` | Listen port |
| `bindAddress` | String | `"127.0.0.1"` | Bind address (`0.0.0.0` = all interfaces) |
| `apiKeys` | `[APIKey]` | `[]` | API key list |

### API key management

- **Generate key**: `generateKey(name:)` — 32-byte random hex key, saved to UserDefaults
- **Delete key**: `deleteKey(id:)`
- **Validate key**: `validateKey(_:)` — constant-time comparison of the incoming Bearer token against stored keys

### Client configuration

After generating a key in the MCP panel, paste this into your client's `.mcp.json` (Claude Code). The server name in the config is **`containers`**:

```json
{
  "mcpServers": {
    "containers": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:3000/mcp",
      "headers": {
        "Authorization": "Bearer <your-api-key>"
      }
    }
  }
}
```

### Binding notes

- `127.0.0.1`: localhost only, uses the default `OriginValidator`
- `0.0.0.0`: all interfaces, uses `OriginValidator.disabled` (otherwise the localhost validator rejects non-localhost Hosts)
- After changing port or bind address, call `restart()` (= stop + start)

---

## Limitations (read first)

MCP is a thin wrapper that fails gracefully — it is **not** feature-equivalent to the app. These come from real testing; know them before calling:

- **No host-path bind mounts.** Any host-path mount in `container_create`'s `volumes` or `compose_up`'s YAML (e.g. `/host:/data`, Compose `type: bind`, or `- ./file:/target`) is rejected with an `isError` listing the offenders. **Named volumes only.** To mount a host directory, use the app UI.
- **Compose does not resolve relative paths / `.env`.** `compose_up` receives raw YAML text with no baseDirectory, so:
  - `.env` in the YAML's directory is **not loaded** (`${VAR}` interpolates to the empty string).
  - `./relative` volume / config paths do not resolve. Use named volumes in the YAML, or Up from the app.
- **`container_logs` is capped.** Defaults to the last `tail=200` lines; `tail=0` means all but is always capped at **256 KB** (only the last 256 KB of the file is seeked, avoiding loading multi-GB logs into memory).
- **1 MB request body limit.** Requests over `maxRequestBodyBytes` (1 MB) are rejected — trim large compose YAML.
- **Machines don't persist containers across stop/boot.** Stopping a machine that hosts containers drops those containers (not stopped, gone); re-Up after boot.
- **No `machine_create`.** Machine creation (image preset, home mount, CPU/memory) is app-UI only; MCP doesn't expose it.
- **No `build:` / `secrets:` / `configs:`.** Image builds, secrets, and config injection in Compose are unsupported (platform limits).
- **`restart:` is parsed but not executed.** The restart key is recognized but no restart logic exists; services that crash on start may be reclaimed and leave no stopped record.
- **Write operations can be briefly inconsistent.** State reads immediately after a mutation (up/create/delete) may lag; read-only tools (list/exec/logs/inspect) refresh before returning, writes do not.

Destructive operations (delete / down) are marked **Reversible: yes (destructive)** below.

---

## Tools

**25 tools** across 6 resource groups. All tool schemas live in `Sources/ContainerUI/MCP/Tools/*.swift`.

### 1. Container — 8 tools

#### `container_list`
List all containers with their status, image, and network info.

| Property | Value |
|----------|-------|
| Parameters | (none) |
| Read-only | Yes |
| Example | `[running] abc123 — docker.io/library/nginx:latest (networks: default)` |

#### `container_create`
Create and start a new container from an image.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `image` | String | **Yes** | Image reference, e.g. `nginx:latest` |
| `name` | String | No | Container name (auto-generated if empty) |
| `command` | `[String]` | No | Command arguments |
| `ports` | `[String]` | No | Port mappings, e.g. `["8080:80"]` |
| `volumes` | `[String]` | No | Volume mounts, e.g. `["myvol:/data"]` (**named volumes only; no host bind mounts**) |
| `env` | `[String]` | No | Environment variables, e.g. `["KEY=VALUE"]` |
| `networks` | `[String]` | No | Network names to attach |

Reversible: no · Idempotent: no · Returns: `Container created: <id>`

#### `container_start`
Start a stopped container.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Container ID or name |

Reversible: no · Idempotent: yes

#### `container_stop`
Stop a running container.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Container ID or name |

Reversible: no · Idempotent: yes

#### `container_delete`
Delete a container.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Container ID or name |
| `force` | Boolean | No | Force delete even if running |

Reversible: yes (destructive) · Idempotent: yes

#### `container_exec`
Run a command inside a running container; returns stdout, stderr, and the exit code. **A non-zero exit is the command's result, not a tool error** (returned normally so the caller can judge).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Container ID or name |
| `command` | String | **Yes** | Executable to run, e.g. `"redis-cli"` or `"sh"` |
| `args` | `[String]` | No | Arguments to the command |
| `user` | String | No | Run as this user |

Read-only: no · Example: `exit=0\n--- stdout ---\nPONG`

#### `container_logs`
Fetch a container's logs. By default returns the workload stdout/stderr (`stdio.log`); `boot=true` returns the vminitd boot log.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Container ID or name |
| `tail` | Integer | No | Lines to return from the end (default 200; `0` = all, capped at 256 KB) |
| `boot` | Boolean | No | Return the vminitd boot log instead of workload logs |

Read-only: yes

#### `container_inspect`
Show a container's detailed configuration and runtime state (image, status, networks/IPs, ports, command, labels, mounts, resources).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Container ID or name |

Read-only: yes · Data from a cached snapshot (no exit code; stopped shown as n/a)

---

### 2. Image — 3 tools

#### `image_list`
List all container images with their references and sizes.

| Property | Value |
|----------|-------|
| Parameters | (none) |
| Read-only | Yes |

#### `image_pull`
Pull an image from a registry. Pulls only the host architecture, registry-mirror aware (transient errors auto-retry up to 3×; 403/401/404 translated to readable messages).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `reference` | String | **Yes** | Image reference, e.g. `nginx:latest` or `ubuntu:22.04` |

Reversible: no · Idempotent: yes

#### `image_delete`
Delete an image.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Image ID or reference (name matching supported) |

Reversible: yes (destructive) · Idempotent: yes

---

### 3. Machine — 4 tools

> No `machine_create`: machine creation is app-UI only (see [Limitations](#limitations-read-first)).

#### `machine_list`
List all machines with their status and IP.

| Property | Value |
|----------|-------|
| Parameters | (none) |
| Read-only | Yes |
| Example | `[running] dev — 192.168.64.10` |

#### `machine_boot`
Boot a stopped machine.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Machine ID |

Reversible: no · Idempotent: yes · Returns: `Machine <id> booted`

#### `machine_stop`
Stop a running machine. **Note**: drops containers on it (see Limitations).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Machine ID |

Reversible: no · Idempotent: yes · Returns: `Machine <id> stopped`

#### `machine_delete`
Delete a machine.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Machine ID |

Reversible: yes (destructive) · Idempotent: yes

---

### 4. Volume — 3 tools

#### `volume_list`
List all volumes with their name and size.

| Property | Value |
|----------|-------|
| Parameters | (none) |
| Read-only | Yes |

#### `volume_create`
Create a new volume.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | String | **Yes** | Volume name |
| `size` | String | No | Size, e.g. `"10G"` (server default if empty) |

Reversible: no · Idempotent: no · Returns: `Volume created: <name>`

#### `volume_delete`
Delete a volume.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | String | **Yes** | Volume name |

Reversible: yes (destructive) · Idempotent: yes

---

### 5. Network — 3 tools

#### `network_list`
List all networks with their ID, name, and mode.

| Property | Value |
|----------|-------|
| Parameters | (none) |
| Read-only | Yes |
| Example | `net123 — my-net (NAT)` |

#### `network_create`
Create a new network.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | String | **Yes** | Network name |
| `hostOnly` | Boolean | No | Host-only network (no NAT) |
| `subnet` | String | No | IPv4 CIDR subnet, e.g. `"10.0.1.0/24"` (auto-assigned if empty) |

Reversible: no · Idempotent: no

#### `network_delete`
Delete a network.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | String | **Yes** | Network ID |

Reversible: yes (destructive) · Idempotent: yes

---

### 6. Compose — 4 tools

#### `compose_list`
List all Compose projects with their status.

| Property | Value |
|----------|-------|
| Parameters | (none) |
| Read-only | Yes |
| Example | `my-app — 2/3 running (stored: true)` |

#### `compose_up`
Create and start a Compose project from YAML. **Named volumes only; relative paths / `.env` not resolved** (see Limitations).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `yaml` | String | **Yes** | Compose YAML content |
| `projectName` | String | No | Project name (default `"mcp-project"`) |
| `wait` | Integer | No | Seconds to wait for services to exit. `0` (default) returns as soon as containers start; a one-shot/init service that exits within the window reports its exit code; a long-running server reports as running |

Reversible: no · Idempotent: no

> `upAndWait` re-parses the YAML to populate `declaredNetworks/Volumes` so a later `compose_down` can reclaim resources. A non-zero exit in any service marks the result `isError`.

#### `compose_down`
Stop and delete all containers of a Compose project.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `projectName` | String | **Yes** | Project name |
| `removeVolumes` | Boolean | No | Also delete volumes |
| `removeNetworks` | Boolean | No | Also delete networks |

Reversible: yes (destructive) · Idempotent: yes

> Deletes containers and resources, **but not the project record** (`compose_list` still shows `stored: true, down`). To remove the record, use the Compose panel in the app.

#### `compose_status`
Get the per-service status of a Compose project.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `projectName` | String | **Yes** | Project name |

Read-only: yes · Example: `Project: my-app\nRunning: 2/3\n\nweb: running\napi: running\ndb: stopped (exit 0)`

---

## Usage examples

```json
// container_create (named volumes only)
{
  "name": "container_create",
  "arguments": {
    "image": "nginx:latest",
    "name": "my-nginx",
    "ports": ["8080:80"],
    "volumes": ["web-data:/usr/share/nginx/html"],
    "env": ["FOO=bar"]
  }
}
```

```json
// container_exec
{
  "name": "container_exec",
  "arguments": {
    "id": "my-cache",
    "command": "redis-cli",
    "args": ["PING"]
  }
}
```

```json
// compose_up (wait for init service exit, report exit code)
{
  "name": "compose_up",
  "arguments": {
    "projectName": "my-app",
    "wait": 10,
    "yaml": "services:\n  web:\n    image: nginx:latest\n    ports:\n      - \"8080:80\""
  }
}
```

