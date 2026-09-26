# Differential BC7 and True 5K Validation Design

状态：首版已实现，待 Intel iMac 双机实测
日期：2026-09-26
基线：`9e3614e`

## 1. 现状与问题

当前 BC7 路径每帧发送完整 texture。实测 `2560 × 1440` 约
`206–214 MB/s`（`1.65–1.71 Gbit/s`），与 full-frame BC7 的理论值
一致。`5120 × 2880 @ 60` 的纯 BC7 payload 为 `884,736,000 B/s`
（约 `7.08 Gbit/s`）。

当前 Diagnostics 的 `startBC7Test()` 还会无条件执行：

```swift
capturePreset = .standard1440p
```

因此即使 UI 已选择 5K，联合测试仍会回到 `2560 × 1440`。5K preset
本身已经存在：

- `native5k`: `5120 × 2880 @ 48`
- `native5k60Experimental`: `5120 × 2880 @ 60`

## 2. 目标

1. 静态或局部变化桌面只发送变化的 BC7 区域。
2. 画面大范围变化时自动发送完整帧，避免 delta metadata 和多次上传
   比完整帧更昂贵。
3. delta 判断必须逐 byte 精确，不能依赖可能碰撞的 hash。
4. Receiver 必须能检测基线不一致并要求下一帧 keyframe。
5. Diagnostics 必须能实际运行当前选择的 `5120 × 2880` preset。
6. UI 和日志必须同时显示 logical display size、capture size、actual
   BC7 frame size、keyframe/delta、dirty tile ratio 和实际带宽。
7. 不改变 Automatic/H.264/HEVC/Raw NV12 的现有行为。

## 3. 方案选择

采用固定 `64 × 64 pixel` tile：

- 5K 一帧为 `80 × 45 = 3600` tiles。
- 一个完整 tile 包含 `16 × 16` BC7 blocks，共 `4096 bytes`。
- 2560、3200、3840 和 5120 宽度都能被 64 整除。
- 1440 和 1800 高度的最后一行 tile 使用合法的 4-pixel 对齐高度。
- 一个 tile block row 为 `256 bytes`，适合 compressed texture 局部上传。

不采用 4×4 block sparse list，因为 metadata、CPU gather 和 Receiver
upload call 数过高。不把 ScreenCaptureKit dirty rect 作为唯一依据，
因为不同 capture source 和 macOS 版本的 dirty metadata 不能作为
wire correctness 基线。

## 4. Sender 数据流

首版 Sender Metal encoder 生成完整 BC7 `Data`，planner 保留：

```text
currentEncodedData
lastTransmittedData
```

每帧处理：

1. Metal compute 将完整 BGRA frame 编码到 `currentEncodedBuffer`。
2. pipeline serial queue 在 CPU 上按 tile 对 current 和 last-transmitted
   BC7 blocks 做精确 `memcmp`；任何 byte 不同就将 tile 标为 dirty。
3. 当前首版每帧仍执行完整 GPU→CPU copy；它先解决 wire bandwidth，
   GPU dirty bitmap/gather 留作后续性能优化。
4. 相邻的 dirty tiles 在同一 tile row 合并为 horizontal runs。
5. 如果没有 dirty tile，发送 zero-run delta，保留视频 FPS/liveness 可观测性。
6. 如果 delta wire bytes 达到完整帧的 70%，发送 full keyframe。
7. 否则只从 shared Metal buffer gather dirty runs，发送 delta packet。
8. gather payload 和 `currentEncodedBuffer → lastTransmittedBuffer` 的
   region copy 必须在同一个 pipeline serial queue critical section 内、
   `connection.send` 调用前完成。`lastTransmittedBuffer` 是独立 allocation，
   不能与可被下一帧覆盖的 current buffer 交换引用。
9. `connection.send` completion 只处理错误；错误发生时设置
   `forceKeyframeNextFrame`。被 backlog policy 丢弃的 frame 不推进基线。

首次启动、尺寸变化、pipeline generation 变化、发送错误以及周期恢复
点必须发送 full keyframe。周期 keyframe 初始值为 2 秒。

## 5. Wire protocol

Receiver 新增 capability：

```json
{
  "supportsBC7TileDelta": true
}
```

只有 Sender 与 Receiver 都支持时才启用 delta；否则继续使用现有
full-frame `0x24 format=1`。

### 5.1 Sequenced full keyframe

保留 packet type `0x24`，新增 payload format `2`：

```text
U8   format = 2
U64  frameSequence
U64  contentChecksum
U32  width
U32  height
U32  bytesPerRow
U8[] complete BC7 blocks
```

Receiver 在所有 texture upload 成功后立即将
`appliedSequence = frameSequence`；该值表示 texture 中驻留的 BC7
内容，不依赖 drawable/present 是否成功。present failure 单独计入
`bc7PresentFailures`。generation render ACK 仍要求 command buffer
真正 completed。

### 5.2 Tile delta packet

新增：

```text
TB_PKT_BC7_TILE_DELTA = 0x27
```

Header：

```text
U8   format = 1
U64  frameSequence
U64  baseSequence
U64  contentChecksum
U32  width
U32  height
U16  tileSize = 64
U16  runCount
```

每个 horizontal run：

```text
U16  tileX
U16  tileY
U16  tileCountX
U16  pixelHeight
U32  dataLength
U8[] BC7 blocks in compressed row-major layout
```

Receiver 必须先验证整个 packet，再修改 texture。检查包括：

- `baseSequence == appliedSequence`
- frame sequence 单调递增
- dimensions 与当前 texture 一致
- tile/run 坐标无越界和重叠
- pixel height 非零、≤64 且为 4 的倍数
- 每个 run 的 `dataLength` 精确匹配 BC7 block layout
- 所有整数加法和乘法无 overflow
- packet 不包含尾随数据
- runCount 不超过 256；超过时 Sender 必须选择 full keyframe

验证通过后逐 run 调用 compressed texture `replaceRegion`，同步更新
CPU BC7 shadow；所有 run 上传完成后更新 `appliedSequence`，随后只
render/present 一次。

Sender 在 full 和 delta header 中携带 incremental 64-bit content
checksum。Receiver 根据 CPU shadow 维护相同 checksum；不一致时拒绝
继续使用 delta baseline并请求 keyframe。sequence 检查负责顺序一致性，
checksum 负责内容一致性。

### 5.3 Keyframe request

新增：

```text
TB_PKT_BC7_KEYFRAME_REQUEST = 0x28
```

Receiver 在以下情况发送请求：

- 收到 delta 但尚无 keyframe；
- `baseSequence != appliedSequence`；
- texture dimensions 不一致；
- pipeline generation 重置。
- content checksum mismatch。

Sender 收到请求后清空 delta baseline，下一帧必须发送 full keyframe。
每个 capture generation 最多保持一个 outstanding request，并设置
cooldown，避免每个 in-flight delta 重复请求。
格式或长度非法仍按协议错误处理，不能先局部修改 texture 再失败。

## 6. Receiver 渲染

Receiver 的 BC7 texture 变为持久 framebuffer：

- full keyframe：创建/重建 texture，完整上传并建立 CPU BC7 shadow；
- tile delta：只更新变化 regions；
- cursor 仍是独立 overlay，不触发 BC7 texture 更新；
- 一整个 delta packet 只产生一次 Metal render command 和 present；
- generation-scoped 首帧 ACK 仍只在 Metal command buffer 成功后发送。

Receiver debug metrics 新增：

```text
bc7Keyframes
bc7DeltaFrames
bc7NoChangeFrames
dirtyTiles
totalTiles
dirtyPercent
deltaPayloadBytes
keyframeRequests
suppressedKeyframeRequests
baseSequenceMismatches
contentChecksumMismatches
bc7PresentFailures
appliedSequence
```

## 7. True 5K 测试

`startBC7Test()` 不再覆盖 `capturePreset`。联合测试使用当前 UI 选择：

- Standard：`2560 × 1440 @ 30`
- Smooth：`2560 × 1440 @ 60`
- 5K：`5120 × 2880 @ 48`
- 5K 60 Experimental：`5120 × 2880 @ 60`

按钮旁必须明确显示将要测试的 capture dimensions 和 FPS，例如：

```text
Start BC7 Test: 5120 × 2880 @ 48
```

Diagnostics 分开显示：

```text
Logical display: 2560 × 1440 HiDPI
Capture request: 5120 × 2880 @ 48
Actual captured frame: 5120 × 2880
Receiver texture: 5120 × 2880
```

5K 测试还必须读取被采集 display 的
`CGDisplayCopyDisplayMode(displayID).pixelWidth/pixelHeight`。仅
ScreenCaptureKit 输出 `5120 × 2880` 不足以证明 native 5K，因为
`scalesToFit = true` 可以把较小 framebuffer upscale 到 5K。

5K preset 默认使用 `extendedDesktop` 并启用 `matchRenderToStream`；
如果 source framebuffer 小于 `5120 × 2880` 或宽高比不匹配，测试明确
失败。Diagnostics 新增 `Source framebuffer`。Receiver render ACK 的
width/height 也必须与 `5120 × 2880` 一致。

## 8. 错误与恢复

- 首个视频 packet 必须是 full keyframe。
- delta baseline 永远基于最后已提交发送的 texture 状态。
- backlog 丢帧只丢 current candidate，不改变 baseline。
- connection/send error 后下一次 session 从 keyframe 开始。
- Receiver base mismatch 不应用该 delta，并请求 keyframe。
- resolution change 清空双方 baseline。
- dirty ratio ≥70% 直接发送 keyframe。
- delta run count >256 直接发送 keyframe。
- 连续 2 秒没有 keyframe时发送周期 keyframe。
- 任一 Metal compare/copy failure 明确记录并终止当前 BC7 pipeline，
  不静默发送可能损坏的 delta。

## 9. 测试

### Protocol/parser

- full format 1 向后兼容；
- sequenced full format 2；
- 单 tile、edge tile、horizontal run、多 run；
- truncated、trailing、overflow、out-of-range、overlap；
- base mismatch 触发 keyframe request，texture 不变化。

### Sender

- 相同帧产生 zero-run liveness delta（约 24 bytes，不完全静默）；
- 单个 4×4 block 变化只标记一个 64×64 tile；
- 跨 tile 边界变化标记两个 tiles；
- 70% threshold 两侧分别选择 delta/full；
- dropped frame 不推进 baseline；
- send error 强制下一帧 keyframe；
- resolution/generation change 清空 baseline；
- 删除 exact compare guard 后测试必须失败。
- non-trivial per-tile fixture 必须保证删除 compare guard 后失败。

### Receiver

- 新增 pure-C `bc7_delta.c/.h`，负责 parse、完整 validation、run
  enumeration、shadow apply 和 checksum；Metal renderer 只消费已验证
  regions；
- keyframe 后 delta 得到预期完整 BC7 shadow；
- 多个 delta sequence 累积正确；
- 错误 base sequence 不产生局部 texture mutation；
- edge-height tile 的 bytes-per-row 和 region 正确；
- 一个 delta packet 只 present 一次；
- render ACK 只在 command buffer completed 后发送。

### 真实双机

- 1440p 静止桌面、局部鼠标、窗口拖动、网页滚动、全屏视频；
- 5K48 和 5K60；
- 记录 keyframe/delta 比例、dirty ratio、实际 Gbit/s、FPS、drops、
  Sender CPU/GPU 和 Receiver CPU/GPU；
- Sender 新增 dependency-free `TBBC7DeltaPlanner`，输入 dirty bitmap、
  dimensions、drop/send-error/generation state，输出
  keyframe/delta/no-change 与 baseline advance instructions。
- 5K 测试只有在 source framebuffer、Sender actual capture、Receiver
  texture 和 ACK 四处都报告 `5120 × 2880` 时通过。
- 5K48/60 还必须记录持续 actual FPS 和 GPU encode ms/frame；尺寸正确
  但帧率显著低于 preset 不算通过。

## 10. 第一版边界

第一版不实现：

- 跨 tile 二次压缩；
- 可变 tile size；
- 只编码 dirty source regions；
- UDP、不可靠传输或 forward error correction；
- 多帧乱序；
- HDR/10-bit；
- Receiver 端 tile cache eviction。

这些能力不影响先解决静态桌面带宽和真实 5K 验证两个当前问题。
