# IcontainU MCP Server 接口文档

IcontainU 内置的 MCP (Model Context Protocol) Server，让远程 AI 客户端（Claude Code、OpenCode 等）通过 MCP 协议操作容器、镜像、虚拟机、存储卷、网络和 Compose 项目。

## 概述

| 项目 | 说明 |
|------|------|
| 协议 | MCP over Streamable HTTP (`StatefulHTTPServerTransport`) |
| 传输 | swift-nio HTTP server（非 Hummingbird） |
| 端点 | `/mcp` |
| 认证 | Bearer API Key，在 NIO handler 中校验 |
| 配置存储 | UserDefaults (`mcpSettings`) |
| Session 超时 | 3600 秒（由 `MCPSessionManager` 后台 reaper 驱逐） |
| 请求体限制 | 1 MB |
| 默认端口 | 3000 |
| 默认绑定地址 | `127.0.0.1` |

## 配置

MCP Server 嵌入主 App，在 **MCPView** 界面手动开关和配置。

### MCPSettings

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `isEnabled` | Bool | `false` | 是否启用 MCP Server |
| `port` | Int | `3000` | 监听端口 |
| `bindAddress` | String | `"127.0.0.1"` | 绑定地址（`0.0.0.0` 表示所有接口） |
| `apiKeys` | `[APIKey]` | `[]` | API Key 列表 |

### API Key 管理

- **生成 Key**：`generateKey(name:)` — 生成 32 字节随机 hex key（格式如 `mc-xxxxxxxx...`），保存到 UserDefaults
- **删除 Key**：`deleteKey(id:)`
- **校验 Key**：`validateKey(_:)` — 比较传入的 Bearer token 是否匹配任一已存 Key

### 绑定说明

- `127.0.0.1`：仅本机访问，使用默认 `OriginValidator`（localhost）
- `0.0.0.0`：所有接口访问，使用 `OriginValidator.disabled`（否则 localhost validator 会拒绝非 localhost Host）
- 端口或绑定地址变更后需调用 `restart()`（= stop + start）

---

## Tools 列表

共 **19** 个 Tool，分 6 个资源组。

### 1. Container（容器）— 5 个

#### `container_list`
列出所有容器及其状态、镜像、网络信息。

| 属性 | 值 |
|------|-----|
| 参数 | 无 |
| 只读 | 是 |
| 返回示例 | `[Running] abc123 — nginx:latest (networks: docker0)` |

#### `container_create`
创建并启动一个新容器。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `image` | String | **是** | 镜像引用，如 `nginx:latest` |
| `name` | String | 否 | 容器名（为空则自动生成） |
| `command` | `[String]` | 否 | 命令参数 |
| `ports` | `[String]` | 否 | 端口映射，如 `["8080:80"]` |
| `volumes` | `[String]` | 否 | 卷挂载，如 `["/host:/data"]` |
| `env` | `[String]` | 否 | 环境变量，如 `["KEY=VALUE"]` |
| `networks` | `[String]` | 否 | 要附加的网络名 |
| 可逆 | 否 | 幂等 | 否 |

#### `container_start`
启动一个已停止的容器。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 容器 ID 或名称 |
| 可逆 | 否 | 幂等 | 是 |

#### `container_stop`
停止一个运行中的容器。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 容器 ID 或名称 |
| 可逆 | 否 | 幂等 | 是 |

#### `container_delete`
删除一个容器。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 容器 ID 或名称 |
| `force` | Boolean | 否 | 是否强制删除（容器运行中时） |
| 可逆 | **是（破坏性）** | 幂等 | 是 |

---

### 2. Image（镜像）— 3 个

#### `image_list`
列出所有容器镜像及其引用和大小。

| 属性 | 值 |
|------|-----|
| 参数 | 无 |
| 只读 | 是 |

#### `image_pull`
从注册表拉取镜像。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `reference` | String | **是** | 镜像引用，如 `nginx:latest` 或 `ubuntu:22.04` |
| 可逆 | 否 | 幂等 | 是 |

#### `image_delete`
删除一个镜像。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 镜像 ID 或引用（支持名称匹配） |
| 可逆 | **是（破坏性）** | 幂等 | 是 |

---

### 3. Machine（虚拟机）— 3 个

#### `machine_list`
列出所有虚拟机及其状态和配置。

| 属性 | 值 |
|------|-----|
| 参数 | 无 |
| 只读 | 是 |
| 返回示例 | `[Running] vm1 — 192.168.64.10` |

#### `machine_boot`
启动一个已停止的虚拟机。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 虚拟机 ID |
| 可逆 | 否 | 幂等 | 是 |

#### `machine_stop`
停止一个运行中的虚拟机。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 虚拟机 ID |
| 可逆 | 否 | 幂等 | 是 |

#### `machine_delete`
删除一个虚拟机。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 虚拟机 ID |
| 可逆 | **是（破坏性）** | 幂等 | 是 |

---

### 4. Volume（存储卷）— 3 个

#### `volume_list`
列出所有存储卷及其名称和大小。

| 属性 | 值 |
|------|-----|
| 参数 | 无 |
| 只读 | 是 |

#### `volume_create`
创建一个新的存储卷。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `name` | String | **是** | 卷名 |
| `size` | String | 否 | 卷大小，如 `"10G"`（为空则使用服务器默认） |
| 可逆 | 否 | 幂等 | 否 |

#### `volume_delete`
删除一个存储卷。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `name` | String | **是** | 卷名 |
| 可逆 | **是（破坏性）** | 幂等 | 是 |

---

### 5. Network（网络）— 3 个

#### `network_list`
列出所有网络及其 ID、名称和模式。

| 属性 | 值 |
|------|-----|
| 参数 | 无 |
| 只读 | 是 |
| 返回示例 | `net123 — my-net (NAT)` |

#### `network_create`
创建一个新网络。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `name` | String | **是** | 网络名 |
| `hostOnly` | Boolean | 否 | 是否 Host-only 网络（无 NAT） |
| `subnet` | String | 否 | IPv4 子网 CIDR，如 `"10.0.1.0/24"`（为空则自动分配） |
| 可逆 | 否 | 幂等 | 否 |

#### `network_delete`
删除一个网络。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `id` | String | **是** | 网络 ID |
| 可逆 | **是（破坏性）** | 幂等 | 是 |

---

### 6. Compose（Compose 项目）— 4 个

#### `compose_list`
列出所有 Compose 项目及其服务数和状态。

| 属性 | 值 |
|------|-----|
| 参数 | 无 |
| 只读 | 是 |
| 返回示例 | `my-app — 2/3 running (stored: true)` |

#### `compose_up`
从 YAML 内容创建并启动一个 Compose 项目。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `yaml` | String | **是** | Compose YAML 内容 |
| `projectName` | String | 否 | 项目名称（默认 `"mcp-project"`） |
| 可逆 | 否 | 幂等 | 否 |

> `upAndWait` 会重新解析 YAML 填充 `declaredNetworks/Volumes`，以便后续 `compose_down` 能回收资源。

#### `compose_down`
停止并删除一个 Compose 项目的所有容器。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `projectName` | String | **是** | 项目名称 |
| `removeVolumes` | Boolean | 否 | 是否同时删除卷 |
| `removeNetworks` | Boolean | 否 | 是否同时删除网络 |
| 可逆 | **是（破坏性）** | 幂等 | 是 |

#### `compose_status`
获取 Compose 项目各服务的状态。

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `projectName` | String | **是** | 项目名称 |
| 只读 | 是 |
| 返回示例 | `Project: my-app\nRunning: 2/3\n\nweb: Running\napi: Running\ndb: Stopped` |

---

## 调用示例

```json
// 调用 container_create
{
  "name": "container_create",
  "arguments": {
    "image": "nginx:latest",
    "name": "my-nginx",
    "ports": ["8080:80"],
    "env": ["FOO=bar"]
  }
}
```

```json
// 调用 compose_up
{
  "name": "compose_up",
  "arguments": {
    "projectName": "my-app",
    "yaml": "services:\n  web:\n    image: nginx:latest\n    ports:\n      - \"8080:80\""
  }
}
```

---

## 内部架构

| 组件 | 文件 | 职责 |
|------|------|------|
| `MCPServerManager` | `MCPServerManager.swift` | 持有 `MultiThreadedEventLoopGroup`，管理 HTTP server 生命周期 |
| `MCPHTTPHandler` | `MCPServerManager.swift` | NIO `ChannelInboundHandler`，认证 + 路由到 transport |
| `MCPSessionManager` | `MCPSessionManager.swift` | Actor，管理 MCP session，后台 reaper 驱逐 idle session |
| `MCPToolRegistry` | `MCPToolRegistry.swift` | 注册所有 Tool 定义和 handler 分发 |
| `MCPModelBridge` | `MCPModelBridge.swift` | 桥接 MCP → 各 Model 的 throwing core 方法 |
| `MCPRequestLog` | `MCPRequestLog.swift` | 请求日志（区分成功/失败/取消） |
| `MCPConstants` | `MCPConstants.swift` | 默认端口、超时、端点等常量 |

### 错误处理

- Tool handler 通过 `try await` 调用 throwing core 方法
- 失败返回 `isError: true` 的 `CallTool.Result`
- 区分 cancellation（客户端主动取消）和普通错误：cancellation 不污染日志的错误统计
- 校验错误通过 `OperationError`（可 throw）传递

### 后续可扩展

- 按 Key 调用统计、rate limiting、只读模式
- `image_inspect`（plan 中列出但未实现）