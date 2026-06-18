# 分发与安装说明 (IcontainU)

IcontainU 是 Apple `container` CLI 的图形前端。它通过 XPC 连接本机的
`container-apiserver`,**自己不包含容器运行时**——所以每台要运行它的 Mac
都必须先装好并启动 `container`。

## 同事机器的前置条件（缺一不可）

1. **Apple silicon Mac**（M 系列）
2. **macOS 26 或更高**
3. 已安装 Apple `container`：https://github.com/apple/container
4. 已启动容器系统：在终端执行
   ```bash
   container system start
   ```
   用 `container system status` 应看到 `status  running`。

> 如果上面任意一条不满足，IcontainU 能打开但连不上数据（侧栏为空）。

## 打包（开发者一侧）

```bash
./scripts/package-app.sh
# 产物: build/IcontainU.app
```

打成压缩包再发（zip 能保留签名和符号链接）：
```bash
cd build && zip -r -y IcontainU.zip IcontainU.app
```

## 安装（同事一侧）

本 app 使用 **ad-hoc 签名**（未经 Apple 公证），所以首次打开会被
Gatekeeper 拦截。这是预期行为，按下面任一方式放行即可：

**方式一（推荐）**：把 `IcontainU.app` 拖到「应用程序」或任意目录，然后
**右键点击图标 → 打开 → 在弹窗里再点「打开」**。只需做这一次，以后可正常双击。

**方式二**：直接双击被拦后，去 **系统设置 → 隐私与安全性**，
往下找到「已阻止 IcontainU」一行，点 **「仍要打开」**。

**方式三（终端，适合批量/脚本）**：移除隔离属性后即可直接双击：
```bash
xattr -dr com.apple.quarantine /path/to/IcontainU.app
```

## 常见问题

- **打开后侧栏空白 / 转圈连不上**：多半是 `container system start` 没执行，
  或机器不满足前置条件。先在终端确认 `container system status` 为 running。
- **「IcontainU 已损坏，无法打开」**：通常是隔离属性导致，用上面方式三的
  `xattr -dr com.apple.quarantine` 清掉即可（ad-hoc 签名 + 网络传输常见）。
- **想要双击零提示**：需要改用付费 Apple Developer 账号做 Developer ID 签名
  + 公证（notarization），本说明的 ad-hoc 流程不涉及。
