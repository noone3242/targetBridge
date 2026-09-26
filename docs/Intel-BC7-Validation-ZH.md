# Intel Mac BC7 构建与验证

本文档说明 TargetBridge BC7 Mode 6 的硬件要求、Intel Mac 本机构建方式、
双机测试流程、debug 日志字段和通过判据。

## 1. BC7 需要的硬件能力

BC7 能否使用，不由 CPU 架构直接决定。真正的硬条件如下：

| 位置 | 必需能力 | TargetBridge 检查方式 |
|---|---|---|
| Sender | Metal compute，可运行 BC7 Mode 6 encoder | Sender 创建 Metal encoder；失败时停止 BC7 pipeline |
| Receiver | 当前默认 Metal GPU 支持 BC texture compression | `[MTLDevice supportsBCTextureCompression]` |
| Receiver | 可创建 `MTLPixelFormatBC7_RGBAUnorm` texture | 首帧创建 BC7 texture，失败时不发送 render ACK |
| 网络 | 能持续承载完整帧 BC7 流量 | Sender/Receiver Diagnostics 实测 Gbit/s |

当前实现支持 **64×64 tile 差分 BC7**：

- `4 × 4 pixels` 编码为一个 16-byte BC7 block。
- 首帧、周期恢复帧、大范围变化帧仍发送 full keyframe。
- 静态帧发送 zero-run delta；局部变化只发送对应 horizontal tile runs。
- 5K `5120 × 2880 @ 60 Hz` 的 full keyframe payload 约为 `7.08 Gbit/s`，
  但稳定桌面不再持续占用该带宽。
- 实际链路还包含 packet header、控制消息和 TCP 开销。

“Intel Mac”本身不能保证 BC7 可用。不同机型可能使用 Intel 核显或 AMD
独显，最终以 macOS 当前选择的 `MTLDevice` 返回值为准。

## 2. Intel Mac 上准备依赖

在 Intel Mac 的 Terminal 中安装：

```bash
brew install ffmpeg sdl2 pkgconf dylibbundler
```

Receiver 必须在 Intel Mac 本机 build。Apple Silicon 上构建出的默认
`arm64` app 不能直接复制到 Intel Mac 运行。

## 3. 一键预检和构建

从 repository root 执行：

```bash
TargetBridge-Receiver/scripts/intel_bc7_validation.sh
```

脚本会依次完成：

1. 确认 `uname -m` 是 `x86_64`。
2. 检查 Homebrew 和 Receiver build dependencies。
3. 保存 Mac 型号、CPU、GPU、macOS 和网络接口状态；不采集 hostname、
   用户名、序列号或 MAC 地址。
4. 调用正式 app packaging 脚本构建 Receiver。
5. 检查主程序和 bundled frameworks 是否包含 `x86_64`。
6. 执行严格 codesign verification。
7. 保存动态库依赖。
8. 运行 `--capabilities`，读取实际 Metal device 和 BC7 支持状态。

证据保存在：

```text
build/intel-validation/<timestamp>/
```

主要文件：

| 文件 | 内容 |
|---|---|
| `host.txt` | 架构、macOS、硬件型号和 CPU |
| `display-gpu.txt` | 显示 GPU 和 Metal 相关硬件信息 |
| `network.txt` | 网络接口状态和 IP，不包含 MAC 地址 |
| `build.log` | Receiver app 完整构建日志 |
| `binary.txt` | Receiver executable 架构 |
| `framework-architectures.txt` | bundled dylib 架构 |
| `codesign.txt` | codesign verification |
| `dylibs.txt` | Receiver 动态库依赖 |
| `capabilities.json` | Metal device 和 transport capability |

`capabilities.json` 示例：

```json
{
  "version": "3.3.0",
  "build": "20260926113000",
  "architecture": "x86_64",
  "metalDevice": "AMD Radeon Pro 580",
  "supportsBC7Mode6": true,
  "supportsBC7TileDelta": true,
  "supportsRawNV12": true
}
```

如果 `supportsBC7Mode6` 为 `false`，该机器当前选中的 Metal GPU 不支持
这条 BC7 texture 路径。Receiver 会向 Sender 广播
`supportsBC7Mode6=0`，显式 BC7 连接会失败，不会静默切换成其他编码。

## 4. 启动 Receiver debug 模式

预检成功后直接启动：

```bash
TargetBridge-Receiver/scripts/intel_bc7_validation.sh --launch
```

脚本启动 windowed Receiver，并自动附加 `--debug`：

```bash
TargetBridgeReceiver --windowed --debug
```

运行日志保存在同一证据目录的 `receiver.log`。按 `Ctrl-C` 停止。

Receiver 每秒输出一条结构化 metrics：

```text
[diag] event=metrics connected=true sessionActive=true transport=bc7 \
fps=59.98 networkGbps=0.012 packets=601 bc7Frames=600 \
bc7PayloadBytes=8847360000 bc7Invalid=0 renderFailures=0 \
generation=3 ackPending=false bc7Deltas=596 appliedSequence=600 \
keyframeRequests=0 ackRequests=1 acksSent=1
```

字段说明：

| 字段 | 含义 |
|---|---|
| `connected` | TCP client 是否仍连接 |
| `sessionActive` | 是否已收到正式 streaming session packet |
| `transport` | `bc7`、`rawNV12`、`encoded` 或 `none` |
| `fps` | Receiver 最近一个统计周期实际完成的帧数 |
| `networkGbps` | Receiver socket 实际接收速率 |
| `packets` | 当前连接累计解析 packet 数 |
| `bc7Frames` | 成功完成 Metal render 的 BC7 帧数 |
| `bc7PayloadBytes` | 成功处理的 full/delta BC7 wire payload bytes |
| `bc7Deltas` | 成功应用的 tile delta 帧数 |
| `appliedSequence` | 当前 texture 已应用的 BC7 frame sequence |
| `keyframeRequests` | 因 baseline/sequence/checksum/upload 异常请求恢复帧的次数 |
| `bc7Invalid` | 被严格 wire validator 拒绝的 BC7 帧 |
| `renderFailures` | BC7 texture upload/draw/command completion 失败次数 |
| `generation` | 当前 Sender pipeline generation |
| `ackPending` | 当前 generation 是否仍等待首帧 render ACK |
| `ackRequests` | Receiver 收到的 generation-scoped ACK 请求数 |
| `acksSent` | Metal command buffer 成功完成后发出的 ACK 数 |

关键事件：

```text
[diag] event=startup ... metalDevice="..." supportsBC7=true
[diag] event=bc7-ack-request generation=3
[diag] event=bc7-render-ack generation=3 width=2560 height=1440
[diag] event=bc7-invalid payloadBytes=... count=...
[diag] event=disconnect ...
```

## 5. Sender 与 Intel Receiver 联合测试

1. 使用 Thunderbolt cable 连接两台 Mac。
2. 两端确认 Thunderbolt Bridge 接口已获得 IP。
3. 在 Intel Mac 运行：

   ```bash
   TargetBridge-Receiver/scripts/intel_bc7_validation.sh --launch
   ```

4. 在 Sender 的 Output 页面选择该 Receiver。
5. 把 `Video transport` 设为 `BC7 Mode 6 (Experimental)`。
6. 打开 Diagnostics，点击 `Start BC7 Test`。
7. 联合测试使用当前选中的 preset，不再强制回退到 1440p。
8. 测试 5K 时选择 `5K` 或 `5K 60 Experimental`；推荐使用
   `Extended Desktop` 并开启 `Match render to stream`。
9. Sender 会同时检查 source display mode 和首个实际 capture frame：
   两者都必须达到 `5120×2880`，否则明确失败，不把 upscale 当成 native 5K。

在接入真实 Sender 前，可以先在 Receiver 本机验证 Metal BC7
texture upload 和 generation ACK：

```bash
cd TargetBridge-Receiver/TBReceiverC
make
./tbreceiver --windowed --debug

# 另一个 Terminal
uv run python tests/mock_sender.py --mode bc7
uv run python tests/mock_sender.py --mode bc7-delta
```

full-frame mock 必须输出 `BC7 render ACK verified`；delta mock 必须输出
`BC7 delta apply and stale-base recovery verified`。Receiver 必须记录同一
generation 的 `bc7-render-ack`，并在 stale base 后记录
`bc7-keyframe-request`。

## 6. 通过判据

1440p 联合测试通过必须同时满足：

- Sender 识别到 `supportsBC7Mode6=true`。
- Sender 的 selected transport 和 actual stream 都是 BC7。
- Receiver 收到 `bc7-ack-request`。
- Receiver 完成对应 generation 的首帧 Metal command buffer。
- Receiver 发出相同 generation 和正确尺寸的 `bc7-render-ack`。
- Sender 在 watchdog timeout 前收到并接受该 ACK。
- `bc7Invalid=0`。
- `renderFailures=0`。
- `ackPending=false`。

5K sustained run 还需要记录：

- Sender FPS、Gbit/s、pending、in-flight 和 dropped。
- Receiver FPS、network Gbit/s 和累计 BC7 frames。
- 两端 CPU/GPU 使用率。
- 是否发生断流、重连、ACK timeout 或画面损坏。

## 7. 常见失败定位

| 现象 | 首先检查 |
|---|---|
| 脚本提示不是 `x86_64` | 脚本没有在 Intel Mac 本机运行 |
| `supportsBC7Mode6=false` | `metalDevice` 和 `system-profiler.txt` 中的实际 GPU |
| Sender 看不到 Receiver | Thunderbolt Bridge IP、Bonjour、TCP 5959、防火墙 |
| Sender 拒绝显式 BC7 | Receiver discovery capability 是否为 true |
| `ackPending=true` 持续不变 | generation、`renderFailures`、Metal drawable/command completion |
| `bc7Invalid>0` | frame width/height、bytes-per-row、payload length 和协议版本 |
| Receiver FPS 低但 Gbit/s 足够 | Metal render/present、display refresh、同步等待 |
| Gbit/s 明显低于目标 | Sender encode/send backlog、TCP 链路或 Thunderbolt Bridge 配置 |
| 连接约 10 秒后断开 | Receiver idle watchdog 未收到 frame/heartbeat |

## 8. 当前验证边界

已在 Apple Silicon 开发机验证：

- Sender XCTest。
- Receiver 115 项 parser/BC7/delta/shadow/cursor checks。
- Receiver build。
- `--capabilities` 输出和 Metal BC7 探测。
- Intel validation script 在非 Intel 主机上的拒绝路径。

尚未完成、必须在目标 Intel Mac 上执行：

- 原生 `x86_64` app 和所有 bundled dylib 的实际构建验证。
- 目标 GPU 的 `supportsBCTextureCompression` 实测。
- Intel Receiver 的真实 BC7 texture render。
- 差分 BC7 的 Intel Receiver 实机联合测试。
- 5K60 sustained throughput、CPU/GPU 和端到端延迟测量。
