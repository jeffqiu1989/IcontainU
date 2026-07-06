# MCP Server Reference

Embedded Model Context Protocol server for IcontainU. Exposes Docker containers, images, machines, networks, volumes, and Compose projects as tools an AI client (Claude Code, Cursor, OpenCode, etc.) can call over Streamable HTTP.

---

## Connection

| Setting | Default | Notes |
|---|---|---|
| **Protocol** | Streamable HTTP | `POST` / `GET` / `DELETE` on a single endpoint |
| **Endpoint** | `http://localhost:3000/mcp` | Configurable port + bind address in-app |
| **Authentication** | Bearer token | `Authorization: Bearer <api-key>` |
| **Sessions** | Per-session state | `Mcp-Session-Id` header routes requests to the same session |

### Configure a Client

Add an MCP server entry to your client config:

```json
{
  "mcpServers": {
    "icontainu": {
      "type": "streamable-http",
      "url": "http://localhost:3000/mcp",
      "headers": {
        "Authorization": "Bearer <your-api-key>"
      }
    }
  }
}
```

- API keys are generated in IcontainU → MCP tab → "Generate Key". The key is shown **once** after creation.
- The default port is `3000`, bind address is `127.0.0.1`. Change either in the MCP tab — the server restarts automatically.
- If bound to `0.0.0.0`, the server accepts non-localhost Host headers.

---

## Tools Reference

All tools return a `CallTool.Result` with `content: [{ text: "..." }]` on success, or `isError: true` on failure.

### Container Tools

#### `container_list`

List all containers with their status, image reference, and attached networks.

- **Read-only**
- **Parameters:** none

```json
{"name": "container_list", "arguments": {}}
```

Response: one line per container — `[status] id — image (networks: n1, n2)` or `No containers found`.

---

#### `container_create`

Create and start a new container from an image. Blocks until the container is created.

- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `image` | string | **yes** | Image reference, e.g. `nginx:latest` |
| `name` | string | no | Container name (auto-generated if empty) |
| `command` | string[] | no | Command arguments, e.g. `["/bin/sh", "-c", "echo hi"]` |
| `ports` | string[] | no | Port mappings, e.g. `["8080:80"]` |
| `volumes` | string[] | no | Volume mounts, e.g. `["/host:/data"]` |
| `env` | string[] | no | Environment variables, e.g. `["KEY=VALUE"]` |
| `networks` | string[] | no | Network names to attach |

```json
{
  "name": "container_create",
  "arguments": {
    "image": "nginx:latest",
    "name": "web",
    "ports": ["8080:80"],
    "env": ["ENV=prod"]
  }
}
```

Response: `Container created: <id>`. Returns the container ID on success.

---

#### `container_start`

Start an existing stopped container.

- **Idempotent** — calling on an already-running container returns success.
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Container ID or name |

```json
{"name": "container_start", "arguments": {"id": "web"}}
```

Response: `Container <id> started`.

---

#### `container_stop`

Stop a running container.

- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Container ID or name |

```json
{"name": "container_stop", "arguments": {"id": "web"}}
```

Response: `Container <id> stopped`.

---

#### `container_delete`

Delete a container. Destroy the container — use `container_stop` first if running and `force` is not set.

- **Destructive**
- **Idempotent** — calling on an already-deleted container returns success.
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Container ID or name |
| `force` | boolean | no | Force delete even if running (default `false`) |

```json
{"name": "container_delete", "arguments": {"id": "web", "force": true}}
```

Response: `Container <id> deleted`.

---

### Image Tools

#### `image_list`

List all container images with their references and sizes.

- **Read-only**
- **Parameters:** none

```json
{"name": "image_list", "arguments": {}}
```

Response: one image reference per line, or `No images found`.

---

#### `image_pull`

Pull a container image from a registry (fetch + unpack). Blocks until the image is fully downloaded.

- **Idempotent** — pulling an already-present image re-verifies and returns success.
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `reference` | string | **yes** | Image reference, e.g. `nginx:latest` or `ubuntu:22.04` |

```json
{"name": "image_pull", "arguments": {"reference": "nginx:latest"}}
```

Response: `Image pulled: <reference>`.

---

#### `image_delete`

Delete a container image.

- **Destructive**
- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Image ID or reference (e.g. `nginx:latest`) |

```json
{"name": "image_delete", "arguments": {"id": "nginx:latest"}}
```

Response: `Image deleted: <reference>`.

---

### Machine Tools

#### `machine_list`

List all machines with their status and IP address.

- **Read-only**
- **Parameters:** none

```json
{"name": "machine_list", "arguments": {}}
```

Response: one line per machine — `[status] id — <IP>`, or `No machines found`.

---

#### `machine_boot`

Boot a stopped machine.

- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Machine ID |

```json
{"name": "machine_boot", "arguments": {"id": "dev-machine"}}
```

Response: `Machine <id> booted`.

---

#### `machine_stop`

Stop a running machine.

- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Machine ID |

```json
{"name": "machine_stop", "arguments": {"id": "dev-machine"}}
```

Response: `Machine <id> stopped`.

---

#### `machine_delete`

Delete a machine.

- **Destructive**
- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Machine ID |

```json
{"name": "machine_delete", "arguments": {"id": "dev-machine"}}
```

Response: `Machine <id> deleted`.

---

### Volume Tools

#### `volume_list`

List all volumes with their names and sizes.

- **Read-only**
- **Parameters:** none

```json
{"name": "volume_list", "arguments": {}}
```

Response: one volume name per line, or `No volumes found`.

---

#### `volume_create`

Create a new volume.

- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | **yes** | Volume name |
| `size` | string | no | Volume size, e.g. `10G`. Blank uses server default |

```json
{"name": "volume_create", "arguments": {"name": "data", "size": "10G"}}
```

Response: `Volume created: <name>`.

---

#### `volume_delete`

Delete a volume.

- **Destructive**
- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | **yes** | Volume name to delete |

```json
{"name": "volume_delete", "arguments": {"name": "data"}}
```

Response: `Volume deleted: <name>`.

---

### Network Tools

#### `network_list`

List all networks with their IDs, names, and modes.

- **Read-only**
- **Parameters:** none

```json
{"name": "network_list", "arguments": {}}
```

Response: one line per network — `id — name (mode)`, or `No networks found`.

---

#### `network_create`

Create a new network.

- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | **yes** | Network name |
| `hostOnly` | boolean | no | Host-only network (no NAT), default `false` |
| `subnet` | string | no | IPv4 subnet in CIDR notation, e.g. `10.0.1.0/24`. Blank for auto |

```json
{
  "name": "network_create",
  "arguments": {
    "name": "backend",
    "hostOnly": false,
    "subnet": "10.0.1.0/24"
  }
}
```

Response: `Network created: <name>`.

---

#### `network_delete`

Delete a network.

- **Destructive**
- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | **yes** | Network ID to delete |

```json
{"name": "network_delete", "arguments": {"id": "abc123def456"}}
```

Response: `Network deleted: <id>`.

---

### Compose Tools

#### `compose_list`

List all Compose projects with their services and status.

- **Read-only**
- **Parameters:** none

```json
{"name": "compose_list", "arguments": {}}
```

Response: one line per project — `name — runningCount/totalCount running (stored: true/false)`, or `No compose projects found`.

---

#### `compose_up`

Create and start a Compose project from YAML content. Parses the YAML, builds specs, and blocks until the project is fully up.

- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `yaml` | string | **yes** | Full Compose YAML content |
| `projectName` | string | no | Project name (default `mcp-project`) |

```json
{
  "name": "compose_up",
  "arguments": {
    "projectName": "myapp",
    "yaml": "services:\n  web:\n    image: nginx:latest\n    ports:\n      - \"8080:80\"\n"
  }
}
```

Response: `Compose project '<name>' is up`.

> **Note:** `compose_up` re-parses the YAML to capture declared networks and volumes, so a later `compose_down` with `removeNetworks: true` and `removeVolumes: true` can clean them up.

---

#### `compose_down`

Stop and remove all containers in a Compose project. Optionally remove associated volumes and networks.

- **Destructive**
- **Idempotent**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `projectName` | string | **yes** | Project name to bring down |
| `removeVolumes` | boolean | no | Also remove volumes (default `false`) |
| `removeNetworks` | boolean | no | Also remove networks (default `false`) |

```json
{
  "name": "compose_down",
  "arguments": {
    "projectName": "myapp",
    "removeVolumes": true,
    "removeNetworks": true
  }
}
```

Response: `Compose project '<name>' brought down`.

---

#### `compose_status`

Get the status of a Compose project's services.

- **Read-only**
- **Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `projectName` | string | **yes** | Project name |

```json
{"name": "compose_status", "arguments": {"projectName": "myapp"}}
```

Response: a summary — project name, running/total count, and per-service status.

---

## Error Handling

When a tool fails (network error, permission denied, resource not found, invalid input, etc.) the MCP response contains `isError: true` with the error message in the text content. The tool name and error are also logged in the request log (visible in the MCP tab of IcontainU).

If the client sends a request without an `Mcp-Session-Id` header after initialization, a `404 Not Found` is returned. If a request lacks the `Authorization` header, a `401 Unauthorized` is returned.

---

## Tool Summary Table

| Tool | Read | Destructive | Idempotent | Parameters |
|---|---|---|---|---|
| `container_list` | ✅ | | | — |
| `container_create` | | | | `image`, `name?`, `command?`, `ports?`, `volumes?`, `env?`, `networks?` |
| `container_start` | | | ✅ | `id` |
| `container_stop` | | | ✅ | `id` |
| `container_delete` | | ✅ | ✅ | `id`, `force?` |
| `image_list` | ✅ | | | — |
| `image_pull` | | | ✅ | `reference` |
| `image_delete` | | ✅ | ✅ | `id` |
| `machine_list` | ✅ | | | — |
| `machine_boot` | | | ✅ | `id` |
| `machine_stop` | | | ✅ | `id` |
| `machine_delete` | | ✅ | ✅ | `id` |
| `volume_list` | ✅ | | | — |
| `volume_create` | | | | `name`, `size?` |
| `volume_delete` | | ✅ | ✅ | `name` |
| `network_list` | ✅ | | | — |
| `network_create` | | | | `name`, `hostOnly?`, `subnet?` |
| `network_delete` | | ✅ | ✅ | `id` |
| `compose_list` | ✅ | | | — |
| `compose_up` | | | | `yaml`, `projectName?` |
| `compose_down` | | ✅ | ✅ | `projectName`, `removeVolumes?`, `removeNetworks?` |
| `compose_status` | ✅ | | | `projectName` |
