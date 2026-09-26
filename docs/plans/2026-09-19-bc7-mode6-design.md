# TargetBridge 完整帧 BC7 Mode 6 传输设计

状态：第一阶段实现完成，进入交叉 review、测试扩充和性能验证
日期：2026-09-19
基线：TargetBridge 3.3.0 (`1052e36fd1e51687d82f913550f6529d10dccb47`)

## 1. 背景

TargetBridge 当前稳定视频路径是：

```text
CGVirtualDisplay / ScreenCaptureKit
        -> NV12
        -> VideoToolbox H.264 / HEVC
        -> TCP over Thunderbolt Bridge
        -> VideoToolbox decode
        -> SDL render
```

该路径带宽低、兼容性好，但在 5K60 下 Sender 编码、Receiver 解码和帧队列都会增加延迟。项目也有实验性 raw NV12 路径，它绕过视频编解码，但 5120 x 2880、60 FPS 的理论图像载荷约为 10.62 Gbit/s，而且 Receiver 仍需上传完整 NV12 帧。

本设计增加一条显式 opt-in 的完整帧 BC7 Mode 6 路径：

```text
CGVirtualDisplay
        -> ScreenCaptureKit BGRA IOSurface
        -> Sender Metal compute BC7 Mode 6 encoder
        -> BC7 blocks over existing framed TCP connection
        -> Receiver native Metal BC7 texture upload
        -> Metal sampling and presentation
```

BC7 固定为 8 bits/pixel。5120 x 2880 一帧为 14,745,600 bytes，60 FPS 的理论图像载荷为 884,736,000 bytes/s，即约 7.08 Gbit/s。第一阶段重点是建立正确、可协商、可测试的 GPU 压缩纹理链路，不尝试复刻 RetinaRelay 的 tile skipping、flat-block collapse、adaptive index depth 或二次压缩。

## 2. 目标

### 2.1 功能目标

1. Sender 使用 Apple GPU 和 Metal compute 编码 BC7 Mode 6，不在生产路径使用 CPU BC7 encoder。
2. Receiver 不在 CPU 解码 BC7，而是将网络收到的 blocks 直接上传为 `MTLPixelFormatBC7_RGBAUnorm` texture。
3. 复用现有 Thunderbolt Bridge TCP 连接、packet framing、session lifecycle、音频、cursor 和 input channel。
4. 通过 Receiver capability negotiation 防止旧 Receiver 收到未知 packet。
5. 通过 Sender 的 `Video transport` 设置显式选择实验路径；默认 `Automatic` 保持 H.264/HEVC 不变。
6. 保留 raw NV12 诊断选项；每个 session 独立保存 transport 选择。
7. 网络拥塞时丢弃新帧，不允许视频 packet 无界积压。

### 2.2 质量目标

1. Mode 6 block 必须能被独立 decoder 解码，不能只做 encoder 自验证。
2. Receiver 必须严格拒绝 format、尺寸、block alignment、row bytes 或 payload length 不合法的 packet。
3. 新字段对旧 profile JSON 保持向后兼容。
4. Metal shader、Objective-C++ bridge、C packet parser 和 Swift protocol 层都必须由自动化测试或最小 runtime smoke 覆盖。
5. 新增 guard 必须做删除变异验证，证明测试能在 guard 缺失时失败。

### 2.3 第一阶段成功标准

1. 4 x 4 BGRA 输入可由实际 Metal kernel 编成 16-byte Mode 6 block。
2. 独立 Swift bit reader 可按 BC7 Mode 6 layout 解码该 block，颜色误差在设计容差内。
3. Receiver 可成功创建 BC7 Metal renderer，并能接受合法完整帧 payload。
4. Sender 和 Receiver 原有测试不回归。
5. 5K frame 大小低于协议 64 MiB packet cap。

## 3. 非目标

第一阶段明确不包含：

- unchanged-tile detection；
- dirty rectangle 或 delta frame；
- flat-color block 的专用 wire representation；
- adaptive index depth；
- LZFSE、Zstd 或其他二次压缩；
- HDR、wide color 或 10-bit source；
- 完整系统 cursor shape 复制；
- 跨平台 Receiver；
- 对所有 Intel Mac GPU 承诺 BC7 支持；
- 保证真实 5K60 持续吞吐；
- Sender GPU buffer 到 Network.framework 的零拷贝；
- 多帧 Metal command buffer pipeline。

这些能力需要在第一阶段正确性和真实硬件测量之后单独设计。

## 4. 总体架构

```text
Sender
┌─────────────────────────────────────────────────────────────┐
│ CGVirtualDisplay / mirrored physical display                │
│                         │                                   │
│                  ScreenCaptureKit                           │
│             BGRA CVPixelBuffer / IOSurface                  │
│                         │                                   │
│                 TBVideoPipeline queue                       │
│                         │                                   │
│                TBBC7Mode6Encoder                            │
│            Metal: one thread per 4 x 4 block                │
│                         │                                   │
│       16 bytes/block, full-frame row-major block buffer     │
│                         │                                   │
│   TBMonitorProtocol: header + BC7 blocks + TCP framing      │
└─────────────────────────┬───────────────────────────────────┘
                          │ Thunderbolt Bridge / TCP
┌─────────────────────────▼───────────────────────────────────┐
│ Receiver packet parser                                     │
│                         │                                   │
│              tb_bc7_frame_parse                             │
│       exact format/dimension/stride/length validation       │
│                         │                                   │
│                 TBBC7Renderer                               │
│       replaceRegion -> BC7_RGBAUnorm Metal texture          │
│                         │                                   │
│   fullscreen triangle -> CAMetalLayer + cursor overlay      │
└─────────────────────────────────────────────────────────────┘
```

现有音频和 input packets 不改变。BC7 只替换视频 frame packet 的生产和消费方式。

## 5. 能力协商和启用条件

### 5.1 Receiver capability

Receiver 在 Bonjour TXT 和 display profile JSON 中发布：

```json
{
  "supportsBC7Mode6": true
}
```

该值必须来自实际 renderer capability，而不是仅根据操作系统或 CPU 架构推测。Receiver 只有在以下条件均成立时才应宣告支持：

1. `MTLCreateSystemDefaultDevice()` 成功；
2. Metal device 报告 `supportsBCTextureCompression`；
3. BC7 runtime shader 编译成功；
4. render pipeline 创建成功；
5. SDL Cocoa window 可提供可挂载 `CAMetalLayer` 的 `NSView`。

### 5.2 Sender gating

Sender 的选择逻辑：

```text
if receiver.supportsBC7Mode6 == true and BC7 is "1" or "true":
    use BC7 Mode 6
else if receiver.supportsRawNV12 == true and RAW is "1" or "true":
    use raw NV12
else:
    use negotiated H.264 / HEVC
```

`supportsBC7Mode6` 是 optional 字段。旧 Receiver profile 缺少该字段时解码为 `nil`，等价于不支持，不影响旧版本连接。

### 5.3 失败语义

BC7 是 session 启动前决定的 transport mode。初始化 BC7 encoder 失败时，当前第一阶段行为是拒绝启动该 capture session，而不是在 session 中途静默切换 codec。这样可以避免 Sender 和 Receiver 对 packet 类型产生不同理解。

后续如果增加 fallback，必须重新发送明确的 session configuration，不能直接从 BC7 frame 切成 HEVC frame。

## 6. Wire protocol

### 6.1 Packet type

```text
TB_PKT_BC7_FRAME = 0x24
```

外层继续使用 TargetBridge 现有 framing：

```text
[BE32 packetLengthIncludingType]
[U8 packetType]
[payload]
```

### 6.2 BC7 payload

```text
Offset  Size  Field
0       1     format, current value = 1
1       4     width, big-endian UInt32
5       4     height, big-endian UInt32
9       4     bytesPerRow, big-endian UInt32
13      N     BC7 blocks
```

BC7 block data 按 block row-major 排列。每个 4 x 4 block 固定 16 bytes：

```text
blocksWide  = width / 4
blockRows   = height / 4
bytesPerRow = blocksWide * 16
dataLength  = bytesPerRow * blockRows
```

### 6.3 Receiver validation

Receiver 在访问 block data 前必须完成全部检查：

1. `payload != NULL`；
2. `payloadLength >= 13`；
3. `format == 1`；
4. `width > 0 && height > 0`；
5. width 和 height 都是 4 的倍数；
6. width 和 height 不超过 8192；
7. `bytesPerRow == (width / 4) * 16`；
8. 乘法没有 `size_t` overflow；
9. `payloadLength - 13 == bytesPerRow * (height / 4)`。

长度必须精确相等。截断和尾随数据都拒绝，避免 parser 接受歧义 payload 或 renderer 读到跨 packet 数据。

### 6.4 Packet 大小

5K frame：

```text
width        = 5120
height       = 2880
blocksWide   = 1280
blockRows    = 720
bytesPerRow  = 20,480
blockBytes   = 14,745,600
payloadBytes = 14,745,613
```

加上 packet type 和 framing 后仍显著低于现有 64 MiB packet cap。

## 7. Sender Metal encoder

### 7.1 输入

BC7 session 将 `SCStreamConfiguration.pixelFormat` 设置为 `kCVPixelFormatType_32BGRA`。收到 `CVPixelBuffer` 后，通过 `CVMetalTextureCacheCreateTextureFromImage` 建立 `.bgra8Unorm` Metal texture view。

输入约束：

- width 和 height 非零；
- width 和 height 是 4 的倍数；
- pixel format 必须是 BGRA；
- pixel buffer 必须能建立 Metal texture。

### 7.2 GPU dispatch

每个 Metal thread 编码一个 4 x 4 block：

```text
grid.width  = width / 4
grid.height = height / 4
threadgroup = 8 x 8
```

每个 thread：

1. 读取 16 个 texel；
2. 将 normalized float 转为 0...255 RGBA；
3. 计算每通道 min/max endpoint；
4. 为每个 endpoint 独立选择共享 p-bit；
5. 重建量化 endpoint；
6. 为 16 个 texel 穷举 16 个 interpolation index；
7. 处理 anchor index 最高位省略规则；
8. 写出 128-bit Mode 6 block。

第一阶段 endpoint search 只使用 per-channel min/max，不做 partition、PCA、least-squares refinement 或 iterative endpoint optimization。它的目标是快速建立合法 Mode 6 block，不是最大化图像质量。

### 7.3 Mode 6 bit layout

编码顺序：

```text
7 bits   mode prefix, value 1 << 6
7 bits   R0
7 bits   R1
7 bits   G0
7 bits   G1
7 bits   B0
7 bits   B1
7 bits   A0
7 bits   A1
1 bit    endpoint 0 p-bit
1 bit    endpoint 1 p-bit
3 bits   anchor texel index
15 x 4   remaining texel indices
```

总计：

```text
7 + 8*7 + 2 + 3 + 15*4 = 128 bits
```

Mode 6 interpolation weights：

```text
0, 4, 9, 13, 17, 21, 26, 30,
34, 38, 43, 47, 51, 55, 60, 64
```

### 7.4 Endpoint quantization

每个 endpoint 只有一个 p-bit，由 RGBA 四个 channel 共享。对 `pbit in {0, 1}`：

```text
q             = clamp(round((value - pbit) / 2), 0, 127)
reconstructed = q * 2 + pbit
error         = sum((value[channel] - reconstructed[channel])^2)
```

选择总 squared error 更低的 p-bit。由于 p-bit 由 RGBA 共享，完全不透明 alpha 可能重建为 254，而不是 255。Receiver fragment shader 强制最终显示 alpha 为 1.0，避免窗口合成透明度误差。

### 7.5 Index search

对每个 texel 和每个 candidate index：

```text
interpolated =
    (endpoint0 * (64 - weight) + endpoint1 * weight + 32) >> 6
```

选择 RGBA squared error 最小的 index。

Mode 6 的 anchor texel 只存 3 bits。如果 anchor index 大于等于 8：

1. 交换两个 quantized endpoints；
2. 交换两个 p-bits；
3. 将所有 index 替换为 `15 - index`。

该转换保持重建颜色不变，并保证 anchor index 可以用 3 bits 表示。

### 7.6 Buffer ownership

第一阶段每个 encoder 实例维护一个按当前分辨率分配的 shared `MTLBuffer`。每帧：

1. encode command 写入 buffer；
2. commit；
3. `waitUntilCompleted()`；
4. 将 buffer 内容复制进 Swift `Data`；
5. 构造 packet；
6. 交给 Network.framework。

同步等待和 CPU copy 是已知性能限制，但所有权清晰：在 packet 构造完成前不会覆盖 buffer，Network.framework 持有独立 `Data`。

后续多 buffer pipeline 必须明确处理：

- command buffer completion；
- buffer reuse generation；
- `Data`/dispatch data 的生命周期；
- connection send completion；
- session stop 时的 drain 和 cancellation。

## 8. Sender pipeline 和背压

BC7 使用现有 `TBVideoPipeline` serial queue，所有可变状态均限制在该 queue：

- encoder lifecycle；
- frame encode；
- `pendingVideoPackets`；
- first-frame ACK；
- sent-frame accounting。

发送前：

```text
if pendingVideoPackets >= preset.maxPendingVideoPackets:
    drop new frame
```

开始 send 时计数加一，在 Network.framework `.contentProcessed` completion 中回到 pipeline queue 后减一。即使发送失败也必须减一，并记录错误。

该策略保证 packet 数量有界。以 5K BC7 约 14.75 MB/frame、上限 3 packets 估算，单 session 最多约 44.2 MB 视频 payload 等待网络处理，不含 packet 和 framework overhead。

第一阶段不保留“必须发送”的 keyframe 概念，因为每个 BC7 frame 都是独立完整帧。拥塞时直接丢弃新帧不会破坏后续帧可解码性。

## 9. Receiver renderer

### 9.1 生命周期

Receiver display 初始化时创建 `TBBC7Renderer`。该对象持有：

- `MTLDevice`；
- `MTLCommandQueue`；
- render pipeline；
- 当前 BC7 texture；
- 覆盖在 SDL Cocoa content view 上的 `NSView`；
- `CAMetalLayer`；
- cursor state。

renderer 的 C API 使用 opaque pointer 暴露给 `display.c`，Objective-C++ 细节不进入纯 C 文件。

### 9.2 Texture 创建

分辨率变化时创建：

```text
pixelFormat = MTLPixelFormatBC7_RGBAUnorm
width       = frame.width
height      = frame.height
usage       = MTLTextureUsageShaderRead
storageMode = Shared on unified-memory devices, otherwise Managed
```

相同分辨率复用 texture。

### 9.3 Upload

合法 frame 使用：

```text
replaceRegion(
    region: full image,
    mipmapLevel: 0,
    withBytes: blocks,
    bytesPerRow: frame.bytesPerRow
)
```

这里仍存在一次 CPU/network buffer 到 GPU texture 的 upload，但不存在 CPU BC7 decode 或 RGBA expansion。

### 9.4 Presentation

renderer 使用 fullscreen triangle，fragment shader 线性采样 BC7 texture。输出 alpha 强制为 1.0。视频 view 位于 SDL Cocoa content view 上层：

- 收到 BC7 frame 时显示；
- 切换到 raw NV12、encoded video、connecting 或 status 页面时隐藏；
- resize 时同步更新 layer frame、contents scale 和 drawable size。

### 9.5 Cursor

BC7 path 的 cursor overlay 在 fragment shader 内绘制，并接收 cursor type、位置、source dimensions 和 output-scaled size。当前覆盖与 SDL path 对齐的类型：

- arrow/fallback；
- I-beam；
- pointing hand；
- horizontal resize；
- vertical resize；
- crosshair；
- NWSE resize；
- NESW resize。

drawable width 小于 5000 时使用 44-pixel 基准，大于等于 5000 时使用 58-pixel 基准。cursor packet 只更新 uniform state；视频帧持续到达时由下一次 frame render 合并显示，超过 40 ms 没有视频帧时才单独 redraw，避免 120 Hz cursor timer 额外提交完整 render。

Metal view 使用 `hitTest:` 始终返回 `nil` 的 passthrough `NSView`，因此位于 SDL view 上方时不会截获鼠标事件。

## 10. 线程模型

### 10.1 Sender

- ScreenCaptureKit callback 进入独立 capture queue；
- callback 将 frame 派发到 `TBVideoPipeline.queue`；
- Metal encode、packet 构造和 pending count 更新都在 pipeline queue；
- Network.framework completion 再派发回 pipeline queue；
- UI 只读取由 lock 保护的 frame count 和 capture timestamp。

禁止在多个 queue 同时修改 BC7 encoder output buffer 或 `pendingVideoPackets`。

### 10.2 Receiver

Receiver 主循环负责：

- socket read；
- packet parser callback；
- display dispatch；
- SDL event handling；
- Metal texture upload 和 command submission。

当前 BC7 renderer 与 SDL Cocoa view 操作都发生在 Receiver 主线程。若未来把 network parsing 移到后台线程，必须显式把 AppKit view 变更派发回 main thread。

## 11. 错误处理

### 11.1 Sender

以下情况当前帧失败并返回：

- 输入尺寸或 pixel format 不合法；
- CVMetalTexture 创建失败；
- output MTLBuffer 创建失败；
- command buffer 或 compute encoder 创建失败；
- command buffer 未以 `.completed` 结束。

command buffer 有 error 时写入日志。初始化 shader 或 pipeline 失败则 BC7 encoder 初始化失败，capture session 不启动。

Network send error 必须：

1. 减少 pending count；
2. 记录明确错误；
3. 不伪装成成功发送。

### 11.2 Receiver

畸形 packet 在 renderer 前被拒绝。renderer 创建或 frame upload 失败时：

- 不设置 `have_video_frame`；
- 不增加 frame counter；
- 输出带尺寸的错误日志；
- 保持 event loop 存活，等待后续 packet 或 teardown。

第一阶段没有向 Sender 回传 per-frame NACK。连接级错误继续由现有 session lifecycle 处理。

## 12. 兼容性

### 12.1 旧 Receiver

旧 Receiver 不发布 `supportsBC7Mode6`，Sender 不会启用 BC7，因此继续发送原 codec packet。

### 12.2 旧 Sender

新 Receiver 仍支持全部旧 packet。新增 Bonjour/profile 字段不会影响旧 Sender 对 JSON 中未知字段的处理。

### 12.3 非 BC7 GPU

Receiver 不应发布 BC7 capability。Sender 明确选择 BC7 时必须显示不支持错误并停止，不能静默回退到正常 codec selection。

### 12.4 现有视频路径

H.264、HEVC 和 raw NV12 的 packet type、payload 和 renderer 不改变。BC7 Metal view 在其他显示状态下隐藏，避免遮住 SDL renderer。

## 13. 测试设计

### 13.1 Swift protocol tests

必须覆盖：

- `bc7Frame == 0x24`；
- 新 profile 可编码/解码；
- 缺少 `supportsBC7Mode6` 的旧 JSON 可解码；
- packet header 和 big-endian fields；
- 64 MiB cap 行为不回归。

### 13.2 Metal encoder correctness

基础测试：

1. 创建 Metal-compatible 4 x 4 BGRA `CVPixelBuffer`；
2. 写入已知灰阶 ramp；
3. 调用真实 `TBBC7Mode6Encoder`；
4. 断言输出恰好 16 bytes；
5. 使用独立 Swift bit reader 解码；
6. 验证 mode prefix、128-bit consumption、RGB error 和 alpha tolerance。

需要补充的测试：

- solid black；
- solid white；
- opaque RGB primaries；
- alpha 0/255 和 mixed alpha；
- endpoint swap/anchor index >= 8；
- 4 x 8、8 x 4、8 x 8 多 block ordering；
- 非 4 倍尺寸拒绝；
- 非 BGRA pixel buffer 拒绝；
- randomized blocks 与独立 decoder 对比；
- repeated encode 检查 output buffer reuse；
- command failure 的可注入错误路径。

提供 `RUN_BC7_BENCHMARK=1` opt-in XCTest，对 5120 x 2880 输入预热后连续编码 10 帧，报告当前同步 Metal encode 加 `MTLBuffer` 到 `Data` copy 的平均 ms/frame 和有效 BC7 output Gbit/s。正常测试默认 skip，避免未经明确授权运行重型 GPU benchmark。

### 13.3 Receiver payload tests

纯 C validator 覆盖：

- 最小合法 4 x 4 frame；
- unknown format；
- zero dimension；
- 非 4 对齐；
- 超过 8192；
- 错误 bytesPerRow；
- truncated payload；
- trailing payload；
- null input/output；
- 大尺寸合法长度计算；
- overflow guard。

对 exact-length guard 做删除变异时，truncated 和 trailing tests 必须失败。

### 13.4 Renderer tests

由于 Metal/AppKit renderer 不适合纯 POSIX CI，分成三层：

1. pure C payload validator；
2. macOS runtime smoke：创建 window、device、shader 和 pipeline；
3. Apple Silicon integration：上传已知 BC7 block，readback 或截图验证像素。

需要补充第三层自动化，至少验证：

- 4 x 4 solid-color block；
- texture resize/reuse；
- video view show/hide；
- alpha 强制为 opaque；
- cursor visible/hidden；
- malformed input 不调用 texture upload。

### 13.5 端到端测试

同机 loopback：

1. 启动 windowed Receiver；
2. 在 Sender Diagnostics 运行 `Start BC7 Test`；
3. 确认 capability negotiation；
4. 确认 session card 显示 `BC7 Mode 6`；
5. 确认 frame counter 增长；
6. 检查 Receiver stderr 无 shader/upload error；
7. 停止 session，确认资源释放并回到 waiting state。

双机测试增加：

- Thunderbolt 3/4/5 link；
- Apple Silicon 和 Intel Receiver；
- 1440p、4K、5K48、5K60；
- cursor、audio、input；
- resize/reconnect；
- cable unplug；
- Receiver restart；
- network slowdown 和 packet backlog。

## 14. 性能预算和测量

### 14.1 理论数据量

| 分辨率 / FPS | 每帧 BC7 | 图像载荷 |
|---|---:|---:|
| 2560 x 1440 @ 60 | 3,686,400 bytes | 1.77 Gbit/s |
| 3840 x 2160 @ 60 | 8,294,400 bytes | 3.98 Gbit/s |
| 5120 x 2880 @ 48 | 14,745,600 bytes | 5.66 Gbit/s |
| 5120 x 2880 @ 60 | 14,745,600 bytes | 7.08 Gbit/s |

以上不含 13-byte BC7 header、5-byte outer framing、TCP/IP overhead、音频和控制 packets。

### 14.2 必须测量的阶段

Sender 每帧拆分计时：

1. ScreenCaptureKit delivery latency；
2. CVMetalTexture creation；
3. Metal command encoding；
4. GPU execution；
5. `waitUntilCompleted()` stall；
6. MTLBuffer -> `Data` copy；
7. packet construction；
8. Network.framework content processing。

Receiver 每帧拆分计时：

1. socket receive；
2. parser assembly；
3. payload validation；
4. `replaceRegion` upload；
5. command encoding；
6. drawable acquisition；
7. GPU present。

同时记录：

- FPS；
- frame drop count；
- pending packet high-water mark；
- resident memory；
- CPU utilization；
- GPU utilization；
- thermal state；
- link throughput；
- input latency；
- audio underrun。

### 14.3 第一阶段风险

当前每帧同步等待 GPU，然后复制约 14.75 MB 到 `Data`。即使 kernel 本身足够快，GPU/CPU synchronization、内存带宽和 packet allocation 也可能阻止 5K60。只有真实测量可以判断瓶颈，不能仅根据 7.08 Gbit/s 小于 Thunderbolt 标称带宽推断成功。

## 15. 后续优化阶段

### Phase 2：流水线和复制控制

- 2-3 个 rotating MTLBuffer；
- command buffer completion 驱动 send；
- 避免 pipeline queue 同步等待；
- 使用 dispatch data 或可控生命周期的 no-copy buffer；
- 记录每阶段 latency 和 buffer high-water mark。

### Phase 3：dirty tiles

- GPU tile hash 或 change detection；
- frame sequence 和 tile coordinates；
- Receiver persistent texture；
- keyframe/full refresh；
- packet loss/reconnect 后状态恢复；
- cursor 独立更新。

### Phase 4：内容自适应

- unchanged-tile skipping；
- flat-color block representation；
- 对 tile payload 做可选二次压缩；
- 根据 link pressure 调整更新粒度；
- 保持协议版本化和 capability negotiation。

每个阶段都必须有独立 wire version 或 feature flag，不能让旧 Receiver 猜测 payload。

## 16. 安全性和鲁棒性

- 所有网络尺寸均视为不可信输入；
- 在分配和乘法前检查上限与 overflow；
- 不接受近似 row bytes；
- 不接受多余 payload；
- Renderer 只接收 validator 输出；
- 不根据 packet 宣称的尺寸创建超过 8192 x 8192 的 texture；
- 不记录 frame 内容；
- 不在日志输出用户屏幕数据；
- 不因单个坏 frame 执行越界访问或退出进程。

## 17. 当前实现状态

已实现：

- `0x24` BC7 frame packet；
- optional Receiver capability；
- `Video transport` UI、per-session persistence 和 capability gating；
- Diagnostics 中的 1440p BC7 联合测试入口；
- Sender 每次启动或软重启 BC7 pipeline 时发送 `0x26` acknowledgment request；
- Receiver 仅在对应首帧的 Metal command buffer 完成且无错误后发送 `0x25` acknowledgment；联合测试在收到该确认后才显示通过；
- ScreenCaptureKit BGRA capture；
- Metal Mode 6 encoder；
- bounded pending video packets；
- Receiver strict payload validator；
- native Metal BC7 texture renderer；
- BC7 cursor overlay；
- passthrough Metal overlay，不拦截 SDL mouse input；
- cursor type、44/58-pixel sizing 和 40 ms redraw coalescing；
- protocol compatibility tests；
- independent Mode 6 decode test；
- malformed payload tests；
- runtime shader/window smoke；
- README 和 testing documentation。

已验证：

- Sender XCTest：85 tests executed，84 passed，1 个 opt-in 5K benchmark 默认 skipped；
- Receiver parser/validator/cursor policy：90 checks passed；
- Receiver AddressSanitizer/UndefinedBehaviorSanitizer：90 checks passed；
- Receiver clean build 成功；
- Receiver windowed startup 成功；
- exact payload length guard 删除后，相应测试会失败。

尚未验证：

- 真实双机 BC7 frame 显示；
- 目标 Intel iMac 的 `supportsBCTextureCompression`；
- 5K48/5K60 sustained throughput；
- 长时间内存稳定性；
- thermal behavior；
- cable interruption 和 reconnect；
- pixel-accurate Receiver GPU render readback，尤其是各 cursor shape；
- 多 session 并发 BC7。

## 18. 发布条件

BC7 在满足以下条件前保持 experimental：

1. 至少一台 Apple Silicon Sender 和一台目标 Intel iMac 完成端到端显示；
2. 1440p60、4K60 和 5K48 持续 30 分钟无 crash、无无界内存增长；
3. 5K60 的实际 FPS、drop rate、encode latency、upload latency 和 link throughput 有测量结果；
4. disconnect/reconnect、Receiver restart、Sender stop 的资源生命周期通过；
5. randomized Mode 6 tests 和 Receiver render readback tests 完成；
6. 独立 code review 的高置信度 findings 已关闭；
7. 默认 codec 路径的回归测试保持通过。

BC7 已进入正式 UI，但仍标记为 experimental；上述条件决定该标记何时移除。
