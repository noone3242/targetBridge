# Sender 本机物理显示器亮度控制设计

日期：2026-09-29

状态：已实现并完成本机硬件验证

## 1. 目标与边界

在 TargetBridge Sender 主窗口顶部增加“本机显示器”区域，逐个控制连接到
Sender Mac 的物理显示器亮度，从而替代单独运行 MonitorControl 的主要用途。

现有 session 亮度功能必须完整保留：

```text
Session brightness slider
→ TB_PKT_BRIGHTNESS
→ Receiver
→ Receiver displays
```

新功能是另一条完全独立的本机链路：

```text
Sender physical monitor slider
→ local brightness backend
→ MacBook built-in panel or external DDC monitor
```

首版范围：

- 支持 Sender 内建显示器。
- 支持 Sender 外接、可通过 DDC/CI 调节亮度的物理显示器。
- 每个显示器有独立 slider、名称、当前百分比和能力状态。
- 不控制 TargetBridge 创建的虚拟显示器。
- 不修改 Receiver 协议。
- 不移除或改变 session brightness slider。
- 不实现音量控制。
- 不实现软件调暗 fallback；不支持硬件亮度的屏幕显示为“不支持”并禁用 slider。

本机验证设备：

```text
Color LCD：     native，读取和写入成功
DELL P2725QE： DDC/CI，读取和写入成功
DELL P3225QE： DDC/CI，读取和写入成功
```

不使用软件调暗的原因是软件遮罩会改变颜色语义，并可能影响截图、ScreenCaptureKit
或虚拟显示内容。首版 slider 必须表示真实面板亮度。

## 2. 方案比较

### 方案 A：TargetBridge 内部实现显示器服务

在 Sender 内新增显示器枚举、能力探测和亮度 backend。内建屏使用 macOS
brightness API；外接屏使用 DDC/CI。

优点：

- 不依赖另一个常驻 app。
- UI、状态和错误处理可与 TargetBridge 一致。
- 可明确排除 TargetBridge 虚拟显示器。
- 可以用 protocol + mock 做硬件无关测试。

代价：

- Apple Silicon 和 Intel 的外接显示器访问路径不同，需要分别验证。
- DDC 写入必须限流，不能在 slider 每个像素移动时无限发送 I2C。

### 方案 B：直接嵌入 MonitorControl 大量实现

优点是功能覆盖广；代价是引入较大的显示器管理子系统、更多私有 API 和长期同步成本。
在完成源码/许可证边界审查前，不直接复制其实现。

### 方案 C：调用已安装的 MonitorControl

不能达到“少开一个 app”的目标，并且运行状态、错误和版本仍由外部 app 管理。

首版采用方案 A。MonitorControl只作为交互和能力覆盖参考。

## 3. 组件设计

新增：

```text
TBPhysicalDisplayBrightnessService
TBPhysicalDisplayBrightnessDevice
TBDisplayBrightnessBackend
TBNativeDisplayBrightnessBackend
TBDDCDisplayBrightnessBackend
TBPhysicalDisplayBrightnessView
```

`TBPhysicalDisplayBrightnessDevice`保存：

```text
stableID
CGDirectDisplayID
displayName
isBuiltIn
isVirtual
capability
currentBrightness
lastConfirmedBrightness
status
```

能力状态不能用静默默认值：

```text
probing
supported
unsupported
temporarilyUnavailable(error)
```

`TBDisplayBrightnessBackend`提供可测试边界：

```swift
func enumerate() async -> [Device]
func readBrightness(for device: Device) async throws -> Double
func writeBrightness(_ value: Double, for device: Device) async throws
```

生产 backend：

- 内建显示器：通过本机显示器亮度接口读取和设置。
- Apple Silicon 外接显示器：通过 IOAVService/DDC I2C。
- Intel 外接显示器：通过对应 IOKit DDC通道。

仓库 Bridging Header 已有 IOAVService I2C declaration，但当前没有生产调用者。
实现前需要验证显示器到 IOKit service 的可靠映射，不能把第一个 service 错配给其他屏幕。

## 4. 显示器枚举和身份

枚举使用当前在线的物理显示器，并监听现有 CGDisplay reconfiguration callback。

必须排除：

- TargetBridge `CGVirtualDisplay`。
- 离线 display。
- mirror set 中重复代表同一物理面板的逻辑 entry。
- 无法映射到物理设备且不支持原生亮度的 display。

稳定身份优先使用显示器 UUID，并附带：

```text
vendor
product
serial
display name
```

显示器重连后，slider应恢复对应设备，而不是按临时 `CGDirectDisplayID`误配。

内建显示器名称使用系统名称。外接显示器优先使用 EDID/系统报告名称，例如：

```text
Color LCD
DELL P2725QE
DELL P3225QE
```

## 5. 写入调度

DDC/I2C 不应直接绑定 SwiftUI slider 的每一个连续 value change。

每个显示器使用独立串行写入状态：

```text
用户拖动 slider
→ UI 立即显示目标值
→ coalesce 最新目标
→ 约 30–50 ms debounce
→ backend 写一次
→ 成功后更新 lastConfirmedBrightness
```

同一显示器最多：

```text
一个正在执行的硬件写入
+ 一个最新 pending value
```

旧 pending value 被新值替代，避免 DDC backlog。

写入失败：

- UI恢复到最近确认值，或明确保留目标值并显示失败状态。
- 显示具体错误，不伪装成功。
- 不影响其他显示器。
- 不影响 TargetBridge session、capture 或 transport。

## 6. UI

位置：

```text
Sender header
→ 本机显示器 card
→ 连接 card
→ session cards
```

卡片沿用 Sender 当前紧凑原生风格，不复制 MonitorControl 的浮动大面板。

每行：

```text
[display icon]  DELL P3225QE                  72%
                [sun.min] ───── slider ───── [sun.max]
```

内建显示器可使用 `display` 或 `laptopcomputer`。
外接显示器使用 `display`。

不支持时：

```text
DELL ...
硬件亮度不可用
[disabled slider]
```

顶部区域支持折叠；默认展开。没有可控制物理显示器时仍显示内建屏，或显示明确空状态。

现有 session brightness card 保持原位置和含义，并在标题中明确是 Receiver 亮度，避免与
“本机显示器”混淆。

## 7. 生命周期和性能

服务启动时：

1. 枚举一次物理显示器。
2. 并发读取每个设备亮度，但每个 backend 保持设备级串行访问。
3. 注册 display reconfiguration observer。

不使用高频轮询。

重新读取时机：

- app启动；
- display add/remove/mode reconfiguration；
- app从sleep恢复；
- 用户点击刷新；
- 写入失败后的有限重试。

断线、连接或视频streaming不会反复重建显示器 backend。

亮度服务不得：

- 启动持续忙循环；
- 增加 ScreenCaptureKit frame path 工作；
- 阻塞 MainActor；
- 修改虚拟显示器排列；
- 影响 Sender/Receiver build identity。

## 8. 测试

硬件无关单元测试：

- 排除 TargetBridge 虚拟显示器。
- UUID身份在临时 display ID变化后保持稳定。
- supported/unsupported/probing/error 状态。
- slider值 clamp 到 `0...1`。
- 同一显示器连续目标只保留最新 pending value。
- 不同显示器写入互不阻塞。
- 写失败不更新 confirmed value。
- display移除时取消 pending write。
- session brightness packet行为保持原测试结果。

Mutation tests：

- 删除虚拟显示器过滤后，测试必须失败。
- 禁用 write coalescing 后，测试必须失败。
- 写失败仍更新 confirmed value时，测试必须失败。
- 把一个显示器的 backend错误复用于另一个显示器时，identity测试必须失败。

硬件验证：

- MacBook内建屏读写。
- 每台Dell独立读写，不联动其他显示器。
- 快速拖动 slider 无DDC backlog。
- unplug/replug后名称和亮度对应正确。
- sleep/wake后恢复能力。
- streaming 5K 时调节亮度不影响 FPS、bandwidth 或 Receiver状态。

## 9. 成功标准

- Sender顶部能看到每个本机物理显示器。
- 每台支持的显示器可独立调整真实硬件亮度。
- TargetBridge虚拟显示器不出现在列表中。
- 不支持的屏幕明确禁用，不静默使用软件遮罩。
- session brightness功能和Receiver协议完全保持。
- 不连接Receiver时不产生新的持续CPU负载。
- DDC错误不会导致Sender崩溃、卡住或影响streaming。
