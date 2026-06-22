<div align="center">

# IcontainU

**Apple [`container`](https://github.com/apple/container) 的原生 macOS 图形界面。**

*`I`* — Apple 小写 i 体系 (iOS, iPhone) · *`contain`* — container · *`U`* — UI

基于 SwiftUI 构建。没有 Electron，没有额外守护进程 — 它只驱动你已有的 `container` 系统。

[English](README.md) | 中文

</div>

---

## 截图

选择一个镜像，IcontainU 自动分析并填充创建表单：

![Auto-fill demo](docs/screenshots/Auto_fill.gif)

| 容器 | 创建容器 |
| --- | --- |
| ![Containers](docs/screenshots/Containers.png) | ![Create a container](docs/screenshots/Create_Container.png) |

| 创建虚拟机 | 镜像 |
| --- | --- |
| ![Create a machine](docs/screenshots/Create_Machine.png) | ![Images](docs/screenshots/Images.png) |

| 镜像加速 | DaoCloud 一键预设 |
| --- | --- |
| ![Registry mirrors](docs/screenshots/Mirrors.png) | ![DaoCloud preset](docs/screenshots/Mirrors_DaoCloud.png) |

## 简介

IcontainU 是一个原生 macOS 应用 (SwiftUI, Swift 6.2)，通过 XPC 与 Apple 的 `container` 系统通信。它**不包含任何容器运行时** — 只是你已安装的 `container` 的前端。基于以下项目构建：

- [`apple/container`](https://github.com/apple/container) — 运行时和 API 客户端
- [`apple/containerization`](https://github.com/apple/containerization) — OCI / 镜像处理
- [`apple/swift-log`](https://github.com/apple/swift-log)

## 功能

### 🐧 开箱即用的虚拟机
Apple 的 `container machine` 需要包含 **init 系统**的镜像 — 而标准的 `ubuntu` / `debian` / `fedora` 镜像没有，所以会静默启动失败。IcontainU 内置了指向**官方 init 就绪镜像**的预设：Alpine 和 Rocky Linux 8 / 9 / 10 (UBI‑init)。选择即启动。还可以设置 CPU / 内存 / home 挂载模式，标记默认虚拟机。

### 📦 智能镜像拉取
- 只拉取**当前主机架构**的镜像 — 更小、更快、无冗余，而 Apple 的 `container pull` 默认会拉取*所有*架构。
- **镜像加速支持**，一键 **DaoCloud 预设**覆盖 9 个常用仓库（Docker Hub、GCR、GHCR、Quay、NVIDIA 等）。可单独开关每个加速源。
- 加速是纯 GUI 重写层：镜像会被重新标记为规范名称，**不在本地镜像上留下任何痕迹**。（仅影响从应用拉取，不影响 CLI。）

### 📝 自动填充的创建表单
选择一个镜像，IcontainU 自动分析：
- `EXPOSE` → 端口行，`VOLUME` → 挂载行；
- 入口脚本**实际需要**的环境变量（如 `MYSQL_ROOT_PASSWORD`）会被提取并预填 — 不只是构建时的默认值。

还有本地镜像自动补全、**分析 vs. 拉取**按钮（知道镜像是否已本地存在）、Docker 风格的自动命名（`brave_turing`），不再面对裸 UUID。

### 🃏 卡片式管理
每个容器卡片都有 **启动 / 停止 / Shell / 日志 / 删除**，实时 **Stats** 标签页（CPU、内存、网络、块 I/O、进程数），以及**流式日志**（支持 follow 和复制）。

### ✨ 消除摩擦
- 点击 IP → 复制 IP
- 点击端口 → 复制 `ip:port`（如 `127.0.0.1:8080`）
- 点击挂载 → 在 Finder 中打开挂载目录或卷

### 🚀 无摩擦初始化
首次启动**自动安装 kernel**；应用持续监控 `container` 健康状态；如果 `container` 尚未安装，一键跳转到 releases 页面。

## 环境要求

- **Apple silicon** Mac（M 系列）
- **macOS 26** 或更新版本

### 1. 安装 Apple `container`（≥ 1.0.0）

从 GitHub releases 下载：

```bash
# https://github.com/apple/container/releases
```

### 2. 启动 container 系统并安装 kernel

建议首次从命令行启动 — 系统会提示安装 kernel：

```bash
container system start
container system status   # 应报告: running
```

> **提示：** 如果跳过此步骤直接打开 IcontainU，应用会自动安装 kernel，但下载较慢（后台约 60 MB）。命令行安装更快。

> 如果 `container` 系统未运行，应用仍可打开，但侧边栏为空。

## 下载与安装

下载 `IcontainU-v0.1.0.zip`，解压后将 `IcontainU.app` 移到 Applications。

未公证。首次启动会被 macOS 阻止 — 右键 → 打开，或系统设置 → 隐私与安全性 → 仍要打开，或 `xattr -d com.apple.quarantine /Applications/IcontainU.app`。

## 从源码构建

需要 Swift 6.2 工具链（Xcode 26）。

```bash
swift build
swift run IcontainU
```

### 打包

```bash
./scripts/package-app.sh          # → build/IcontainU.app  (ad-hoc 签名)
cd build && zip -r -y IcontainU.zip IcontainU.app
```

## 状态与已知限制

当前为 **0.1.0** — 早期版本，但日常使用已足够。

- `Shell` / `exec` 打开系统 Terminal.app（尚未内嵌终端）。
- 系统配置在应用中**只读**；请通过 CLI 编辑。
- 容器按 id 排序；更丰富的状态 / 启动时间排序在规划中。
- 菜单栏功能正在开发中。

## 许可证与致谢

基于 Apache License 2.0 开源 — 见 [LICENSE](LICENSE)。

IcontainU 基于 Apple 的 `container` 和 `containerization` 项目构建；见 [NOTICE](NOTICE) 的归属说明。

在 vibe coding（AI 辅助开发）的协助下完成开发。
