# IcontainU Roadmap

本文件记录版本规划与尚未动工的功能的技术分析，供后续研究与决策。**不是已承诺的路线图**——标注为「待研究」的部分需要进一步评估后再决定是否做、怎么做。

---

## 版本规划

| 版本 | 主题 | 内容 | 状态 |
|---|---|---|---|
| **0.1.0** | 首个可用版本 | 容器/镜像/机器管理、智能创建、镜像加速、Compose 子集 | 已发布 |
| **0.2.0** | Compose 兼容性增强 | env `${VAR}` 插值 + `.env`；（可选）ports/volumes 长语法 | 开发中（Phase 1a 已完成，env_file / 长语法待定） |
| **0.3.0** | MCP server | Swift native MCP server，复用现有引擎，界面菜单启动/查看 | 待研究（Phase 3） |

health/restart 常驻监控（Phase 2）未定归属版本，视 0.2.0 之后的情况再排。

---

## Phase 1 —— Compose 兼容性增强（0.2.0，计划中）

**目标**：解锁大量因变量插值而无法直接 Up 的真实 compose 文件。纯解析层改动，不碰 orchestration 引擎，零结构破坏。

### 1a. 环境变量插值（`.env` + `${VAR}`）—— ✅ 已完成

- 在 YAML 解析**之前**做字符串预处理：加载 `.env`（compose 文件同目录）→ 建变量表 → 对整个 compose 文本做
  `${VAR}` / `${VAR:-default}` / `${VAR:?err}` / 裸 `$VAR` / `$$` 替换。
- 实现：`Sources/ContainerUI/Compose/EnvInterpolator.swift`（纯 pre-parse 文本层，复刻 `CommandTokenizer` 风格）。
  接入 `ComposeModel` 的 `analyze` / `analyzeWithFile` / `_up` 三个入口；record 仍存原始 YAML，每次从持久化的
  baseDirectory 重读 `.env` 再插值（不把密码烘焙进磁盘副本）。
- 未定义变量策略：`${VAR}` 无定义 → 替换空串 + 导入 warning；仅 `${VAR:?msg}` 显式要求时报错。
- 测试：`EnvInterpolatorTests`（16 例）+ `ComposeParserTests` 的 4 个真实例子端到端（postgresql-pgadmin /
  pihole-cloudflared-DoH / plex / wireguard，全 IMAGE 不需 build）。

**认知纠正**：`.env` 与 `env_file` 是**两个不同语义**，不能混为一张变量表——
- **`.env`**（compose 同目录）：喂 `${VAR}` 文本插值，不进容器。（本项已做）
- **`env_file:`**（per-service）：把文件内容注入**容器环境**，**不**参与 `${VAR}` 插值。（仍未做，见下）

### 1a-bis. `env_file`（未做，留待后续）

- `env_file` 是独立特性：需在解析后按 baseDirectory 加载各 service 的文件、合并进容器 env（`environment:` 优先），
  与插值不共用一条路径。awesome-compose 里**零样本**，只能靠自造 fixture 测。
- 当前状态：`env_file` 仍在 `ComposeSpec.swift` 的 `ignored` 告警列表里。做完要从中移除。


### 1b. ports / volumes 长语法（可选，捎带）

- 现状：长语法（`- target: 80\n published: 8080`、`- type: bind\n source: …`）被 `droppedSyntax` 丢弃并告警（`ComposeSpec.swift` 的 `unsupportedSyntax`）。
- 改动：加一个 map 形态的 decoder，归一化到已有的 `host:container` / `source:target[:ro]` 字符串。约半天，纯解析层。
- **认知纠正**：长语法不是「docker 早期写法」，恰恰是后来引入的更明确写法，现代文件（尤其 bind/named/`:ro` 混用）用得越来越多。是否做由维护者决定，但不应基于「过时」判断。

---

## Phase 2 —— restart + health 常驻监控（待研究，未定版本）

**破坏性评估：低-中。** 关键发现：`ComposeModel` **已有一个常驻轮询循环**（`startPolling` 每 2 秒 `refresh()`），`refresh()` 已经拿到每个 service 的 `RuntimeStatus`、已在 UI 显示、已做 hosts 重注入。所以「常驻监控骨架」已存在，restart/health 是挂在上面，不是新建一套。

### 唯一的结构性改动：轮询提升到 app 级

- 现状：轮询只在打开 Compose 标签页时跑（`ComposeView.swift:45` 的 `.task { await model.startPolling() }`），关掉页面就停。
- restart 要「一直生效」必须把轮询提升到 app 级常驻（移到 `RootView` 或 app 启动时）。
- 这是本阶段唯一「打破现有设计约束」的地方（现有设计是「compose 状态机只在页面/Up 期间活」），可控但需要决策。

### 2a. restart 策略（~2-3 天，难度中）

- 底层无 restart 概念：`apple/container` 1.0.0 的 `RuntimeStatus` 只有 `unknown/stopped/running/stopping`，无 restart policy，`create` 也不接受策略。**必须 IcontainU 层自己实现**。
- ✅ **`always` 好做**：轮询发现 service `stopped` → `bootstrap+start`（`ComposeEngine.up` 里已有这个 idempotent 模式），加 crash-loop 退避计数（连续快速崩溃时拉长重启间隔，避免疯狂重启）。
- ⚠️ **`on-failure` / `unless-stopped` 难以精确实现**：底层拿不到 exit code，无法精确「只在非零退出时重启」；`unless-stopped` 要靠 IcontainU 自己记录「用户是否手动 stop 过」来近似。
- **建议范围**：先只做 `always` + 退避，`on-failure`/`unless-stopped` 降级为告警（「已按 always 处理」或「不支持」）。困难的精确语义不做。
- 解析：`restart:` 现在在 `ComposeSpec.swift` 的 `ignored` 列表里告警，要新增字段解析。

### 2b. health 常驻轮询 + UI 角标（~3-4 天，难度中）

- ✅ 探针逻辑 `ComposeProbe.swift` **已经写好**（start_period 宽限、连续失败计数、超时），现在只在 Up 期间一次性门控用完就丢（注释里叫 "Scope B 未来"）。
- 新增：
  - per-service 健康状态表（starting / healthy / unhealthy），发布到 `ComposeModel` 供 UI 显示。
  - 按各自 `interval` 调度探针——**不能**每 2 秒对所有容器 `exec`（太重），需要独立的按间隔节流调度。
  - UI：project card / service 行加 healthy/unhealthy 角标。
- 难点只在调度节流，核心探针逻辑复用。
- 结构注意：这会让 `ComposeProbe` 从「Up 期间一次性」变成「常驻」，需处理生命周期（app 关闭停止、重启恢复、per-container 探针任务管理）。

### 2c. 合计

restart + health ≈ **1 周**，破坏性可接受（挂在已有轮询上，唯一新增是轮询提升到 app 级 + 探针调度器）。

---

## Phase 3 —— MCP server（0.3.0，方向 B：Swift native 自研）

**决策：走方向 B（自研 Swift native），不接第三方 Python server。**

### 为什么是 B 不是 A

- 开源方案（ACMS / gattjoe、AppleContainerMCP / joeshirey，均 Apache-2.0）都是 **Python**，走裸 `container` CLI。
- 接第三方（方向 A）的问题：
  1. 引入 Python + uv 依赖，破坏 IcontainU「native、无 Electron、无额外守护进程」的核心卖点。
  2. 走裸 CLI，**拿不到 IcontainU 的任何特色**：无智能填充、无 compose DNS 28.x 绕过、无项目命名空间隔离、拉镜像是全架构（非只拉当前架构）。
  3. IcontainU 退化成一个第三方进程的 launcher，无自身价值。
- 方向 B 把 MCP 从「通用工具」变成「IcontainU 的独家能力」：agent 操作天然带上所有特色，且仍是 native、零外部依赖。

### 可行性（已核实）

- ✅ orchestration 逻辑**已与 UI 完全解耦**：`ComposeEngine` / `ComposeParser` / `ContainerCreateEngine` / `ContainerExec` / `ContainerClient` 全是纯 Swift，不依赖 SwiftUI，MCP server 可直接复用，几乎零重写。
- ✅ 底层是 XPC API 客户端（`ContainerClient`：list/create/delete/stop/logs/stats/boot…），返回结构化数据，天然适合 MCP，不是脆弱的 CLI 抓屏。
- ✅ Swift 有官方 MCP SDK（`modelcontextprotocol/swift-sdk`）：加 Package 依赖 + 新 executable target 即可起 stdio server。

### 工作量

- **MVP（~1 周）**：新增 `IcontainU-mcp` executable target，包装 8-10 个 tool（`list_containers`、`container_logs`、`container_stats`、`create_container`、`start`/`stop`/`delete`、`list_images`）。复用现有引擎，主要工作是 tool schema 定义 + 参数校验。
- **完整（~2-3 周）**：加 compose tool（`compose_up`/`compose_down`/`compose_status`），复用 `ComposeEngine`。

### 待决策（真正动工时再定）

1. **架构**：MCP server 独立进程（推荐，直接调 XPC API + 现有引擎，不依赖 GUI 是否运行，最健壮）vs 嵌入 GUI 进程（agent 操作实时反映到界面，但需 GUI 运行、IPC 更复杂）。
2. **界面集成**：菜单「启动 MCP server / 查看请求」的具体形态。
3. **写配置**：是否顺带提供「一键写入 Claude Desktop / Cursor config」的便利功能。

---

## 明确不做（暂定）

- **`build:`** — 底层有 build 能力（`ContainerBuild` 模块），但要新做一条重的 build 子流程 + 进度/日志 UI，工作量 1 周+。暂不做。
- **`secrets` / `configs`** — 底层无对应原语，要用 bind/tmpfs 模拟，语义易偏。注：底层 keychain 仅用于 registry 登录（存仓库账号密码），与 compose secrets（密钥当文件注入容器）无关——目前**并未**支持 secrets。未来若做，可复用 keychain 模式存 secret 值。
- **`deploy.replicas` / scale** — 开发场景无人用。
- **`profiles`** — 无必要。
- **`extends` / YAML anchors** — 合并语义边界多。

`build` + `secrets` 是解锁 TLS Elastic 全家桶那类栈的两块硬骨头，短期不碰。
