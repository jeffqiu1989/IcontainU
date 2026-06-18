# 反馈与可观测性规范

> 适用于 ContainerUI 所有页面。目标：**任何操作的进行中 / 成功 / 失败三态，用户在任何时刻都能看清，且不会因切换界面而丢失。**
>
> 本规范取代旧的 `BUTTON_INTERACTION_SPEC.md`（其内容并入第 4 节「① Busy 态」）。

---

## 1. 两个根因（先理解，再动手）

四个表面问题（启动 loading、错误一闪而过、进度条切走丢失、拉镜像黑箱）本质是两个根因：

### 根因 A：Model 生命周期绑死在 View 上

```swift
// 现状：每个页面各自 new 一个 model
@State private var model = ContainersModel()
```

切走 tab → detail View 销毁 → model 释放 → polling 取消 → **进度/错误全部蒸发**；切回来是空 model。
→ 直接导致问题 3、4。

对照：`SystemModel` 在 `ContainerUIApp` 用 `@State` 创建并 `.environment()` 注入 → 跨 tab 存活。**这是正确范式。**

### 根因 B：轮询主动清空错误

```swift
func refresh() async {
    do { containers = try await client.list(...); errorMessage = nil }  // ← 抹掉一切错误
    catch { errorMessage = error.localizedDescription }
}
```

每 2~3 秒一次。操作失败的错误最多活 2 秒——这才是"过一会就没了"的真相（不是定时淡出）。
→ 直接导致问题 2。

对照：`SystemModel.ping()` 开头 `guard !isBusy else { return }`，轮询避让操作态。

---

## 2. 架构总则

### 总则一：所有 Model 上提到 App 级

所有 `XxxModel` 像 `SystemModel` 一样，在 `ContainerUIApp` 创建、`.environment()` 注入，View 改用 `@Environment(XxxModel.self)` 读取。

```swift
// ContainerUIApp.swift
@State private var systemModel = SystemModel()
@State private var containersModel = ContainersModel()
@State private var imagesModel = ImagesModel()
@State private var machinesModel = MachinesModel()
@State private var networksModel = NetworksModel()
@State private var volumesModel = VolumesModel()

RootView()
    .environment(systemModel)
    .environment(containersModel)
    .environment(imagesModel)
    // …
```

```swift
// ContainersView.swift（及其它）
@Environment(ContainersModel.self) private var model   // 不再是 @State new
```

效果：长操作状态（`creating` / `pull`）和错误状态有了稳定的家，切 tab 不丢。**这一步同时根治问题 3 和 4。**

> 轮询的归属：`.task { await model.startPolling() }` 仍可留在各自 View（只轮询可见 tab，省资源）。长操作 Task（`Task { await model.create() }`）独立于轮询，model 长寿后它的进度落在持久属性上，切回来照常显示。

### 总则二：错误分两条通道，轮询只碰自己那条

```swift
private(set) var pollError: String?       // 列表拉取失败：轮询自己 set/clear，可自动消失
private(set) var lastError: OperationError?  // 操作失败：仅由「用户关闭」或「同类新操作开始」清除
```

**铁律：`refresh()` 永远不准碰 `lastError`。** 它只能管 `pollError`。

---

## 3. 三态可观测模型

每个页面顶部按固定优先级渲染状态条（最多同时显示进度条 + 错误条）：

| 状态 | 判定 | UI |
|------|------|-----|
| **进行中** | `creating != nil` / `pull != nil` | 持久进度条（第 3.2 节） |
| **失败** | `lastError != nil` | 持久错误条（第 3.3 节） |
| **成功 / 空闲** | 两者皆 nil | 无条，列表已刷新 = 隐式成功 |

切回页面时直接读这三个属性即可还原现场——这就是"切走再回来还能看到"的实现。

### 3.1 顶部容器布局

```swift
VStack(spacing: 0) {
    if let progress = model.creating { ProgressBar(progress) }   // 进行中
    if let err = model.lastError {                                // 失败（持久）
        ErrorBanner(error: err, onCopy: ..., onDismiss: { model.clearError() })
    }
    cardGrid
}
```

### 3.2 长操作进度条（持久内联条）

- 常驻发起操作的那个 tab 顶部，**只要 `creating/pull != nil` 就在**，不自动消失。
- 有确定 total → `ProgressView(value:)` 显示百分比 + `已下载/总量`；未知 total → 不确定态 `ProgressView()`。
- 显示当前阶段描述（`Pulling… / Unpacking… / Preparing…`）。
- 失败时进度条消失、错误条接管（见总则二的状态机）。

### 3.3 操作错误条（持久 + 复制 + 关闭）

替换现有 `ErrorBanner`，新增能力：

- **标题 + 详情**：一行标题（如「启动容器失败」），下方完整 `error.localizedDescription`，**不截断**（可换行/可滚动，去掉 `lineLimit(2)`）。
- **复制按钮**：复制完整 `标题 + 详情` 到剪贴板。
- **关闭按钮**：调 `model.clearError()` 清掉 `lastError`。
- **不自动消失、不被轮询清除。**

```swift
struct OperationError: Identifiable, Equatable {
    let id = UUID()
    let title: String     // "启动容器失败" / "拉取镜像失败"
    let detail: String     // error.localizedDescription 全文
    var copyText: String { "\(title)\n\(detail)" }
}
```

### 3.4 ① Busy 态（短操作，沿用并补全旧规范）

短操作（start/stop/delete、boot/stop、toggle）= 卡片级 busy 遮罩，不进进度条/错误条以外的全局态。

- **遮罩**：覆盖整张卡片，`.fill(.background.opacity(0.7))` + 居中 `ProgressView()`，无文字。
- **禁点**：`.disabled(isBusy)`，所有按钮禁用，防重复点击。
- **状态**：`private(set) var busyItemIDs: Set<String>`，Card 判 `model.busyItemIDs.contains(item.id)`。
- 模板见第 6 节。
- 失败时 busy 解除 + 错误进 `lastError`（持久条）。

---

## 4. 错误归口规则

| 错误来源 | 写入 | 清除时机 |
|----------|------|----------|
| 列表轮询失败 (`refresh`) | `pollError` | 下次轮询成功 / 操作错误条出现时让位 |
| 操作失败 (start/stop/delete/create/pull/openShell) | `lastError` | **仅** 用户点关闭 / 同类新操作开始 |

实现要点（每个 Model）：

```swift
func start(_ c: ContainerSnapshot) async {
    lastError = nil                 // 同类新操作开始，清旧错
    busyItemIDs.insert(c.id); defer { busyItemIDs.remove(c.id) }
    do { … ; await refresh() }
    catch { lastError = OperationError(title: "启动容器失败", detail: error.localizedDescription) }
}

func refresh() async {
    do { containers = try await client.list(...); pollError = nil }   // ← 只动 pollError
    catch { pollError = error.localizedDescription }                  // ← 绝不碰 lastError
}

func clearError() { lastError = nil }
```

---

## 5. 改造清单

### Model 层（上提 + 双错误通道 + clearError）

- [ ] `ContainersModel` — start/stop/delete/create/openShell/analyze → `lastError`；`refresh` → `pollError`
- [ ] `ImagesModel` — pull/delete → `lastError`；`refresh` → `pollError`
- [ ] `MachinesModel` — boot/stop/delete/create
- [ ] `NetworksModel` — create/delete
- [ ] `VolumesModel` — create/delete
- [ ] `SystemModel` — 已合规（`actionError` 即 lastError 语义，`ping` 已避让）；统一命名即可

### App / View 层

- [ ] `ContainerUIApp` — 创建并注入全部 model
- [ ] 各 `XxxView` — `@State new` 改 `@Environment`
- [ ] 各 `XxxView` 顶部 — 按 3.1 渲染进度条 + 新错误条

### 组件层

- [ ] `ErrorBanner` — 重写：标题 + 完整详情 + 复制 + 关闭
- [ ] 抽 `ProgressBar` 共享组件（Containers/Images/Machines 共用，消除重复）
- [ ] 卡片 busy 遮罩补全：`MachineCard` / `ImageCard` / `NetworkCard` / `VolumeCard`（`ContainerCard` 已有）

### 暂不改

- 同步操作（Add Port/Variable/Mount、Toggle）— 无需 spinner
- `SystemUnavailableOverlay` — 已有完整模式

---

## 6. 代码模板

### Model

```swift
@Observable @MainActor
final class FooModel {
    private(set) var items: [Foo] = []
    private(set) var busyItemIDs: Set<String> = []
    private(set) var pollError: String?
    private(set) var lastError: OperationError?

    func refresh() async {
        do { items = try await client.list(); pollError = nil }
        catch { pollError = error.localizedDescription }   // 不碰 lastError
    }

    func act(_ item: Foo) async {
        lastError = nil
        busyItemIDs.insert(item.id); defer { busyItemIDs.remove(item.id) }
        do { try await client.act(item.id); await refresh() }
        catch { lastError = OperationError(title: "操作失败", detail: error.localizedDescription) }
    }

    func clearError() { lastError = nil }
}
```

### Card busy 遮罩

```swift
.overlay {
    if isBusy {
        RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.7))
        ProgressView().controlSize(.regular)
    }
}
.disabled(isBusy)
```

---

## 7. 验收标准（逐条对应你提的四个问题）

1. **启动 loading**：点 start → 卡片立刻遮罩转圈、按钮禁用；成功后列表刷新、遮罩消失；失败 → 顶部持久错误条。✅ 全页面一致。
2. **错误**：操作失败 → 顶部错误条显示**完整内容**，可复制、可关闭，**轮询不会把它清掉**，不手动关不消失。
3. **进度条跨界面**：拉/建进行中切走再切回 → 进度条还在、还在动；若期间失败 → 切回看到错误条；若成功 → 列表已更新。**不再出现"啥也没有不知道死活"。**
4. **拉镜像可观测**：create/pull 全程进度可见，失败有持久可复制错误条——不再黑箱。

---

## 8. 设计决策问答（Q&A / 踩坑记录）

实现过程中遇到的关键决策与约束，存档以免重复讨论。

### Q1：进度条为什么"一上来就 100%、条不动只有数字动"？

底层镜像 fetch 的事件顺序是**先下小东西、后宣布大东西**：先下 index/platform manifest（几 KB）→ `current/total` 瞬间到 100%，**之后**才 `addTotalSize(大层)` 宣布真实总量。

第一版用了纯"只进不退"`max()`，把那个**虚假的早期 100%** 锁死了，后续真实总量进来也下不来。

**结论：纯粹的"只进不退"在这种数据下做不到。** 最终方案（见 `OperationProgress`）：
- **总量 < 1 MiB（determinateFloor）时显示不确定流动线**，不渲染那个虚假百分比；
- **总量不变时才只进不退**（吸收并发下载抖动）；**总量变大时如实重算**（分母变了，诚实跟上）。

因为大层总量通常一次性宣布，实际几乎不会出现回退。

### Q2：进度条为什么没有"停止"按钮？

**底层下载不在 app 进程里跑，而在独立的 XPC 守护进程里。** app 只是发 RPC 然后干等返回。经源码调研确认：

- 取消 app 侧的 `Task` **完全停不了** daemon 的下载；
- 整条下载链路（`RegistryClient.fetchBlob` 读循环、`ImportOperation.import`）**零取消检查**；
- daemon **没有暴露任何 cancel RPC** 端点。

真做"中断下载"需要改 `.build/checkouts` 里 Apple 的 container/containerization 框架源码（加 cancel RPC + ingest session 跟踪 + 取消检查），跨多个依赖包，且依赖更新即被覆盖——超出本 app 范围。

**结论：不加停止按钮。** 给一个停不了真实下载的"停止"会误导用户，违背"可观测、不骗人"的原则。

### Q3：错误条为什么用 popover 看详情，而不是内联展开 / modal 弹框？

- **内联展开**会把错误条在 NavigationSplitView detail 顶部原地撑高，长错误把卡片网格挤出可视区、布局回流时连侧栏都被压缩（实测 bug）。
- **modal 弹框**打断性强、点掉就没——正好回到最初"报错一闪而过、看不清"的痛点。
- **popover 浮层**是正确原语：浮在所有内容上方、不动底层布局，可滚动/选中/复制，醒目但不打断。

错误条本体永远保持紧凑（标题 + 最多 3 行），长错误点右侧"详情"开 popover 看全文。

### Q4：错误的两条通道为什么必须分开？

`refresh()` 每 2~3 秒一次且成功时会清错误。若操作错误和轮询错误共用一个字段，操作失败的提示最多活 2 秒（这正是最初"过一会就没了"的真相）。

**铁律：`refresh()` 只能动 `pollError`，永不碰 `lastError`。** `lastError` 只由用户关闭或同类新操作开始时清除。
