# 5K BC7 低延迟稳定基线

## 基线身份

- Git commit：`fba7473d2b80`
- Git tag：`bc7-5k-stable-2026-09-26`
- 分支：`2026-09-26_intel-bc7-debug`
- Sender 版本：`3.3.0`
- 验证日期：2026-09-26
- 验证环境：Apple Silicon MacBook Sender → Thunderbolt Bridge → Intel iMac Receiver
- 分辨率：`5120×2880`
- 传输：BC7 Mode 6 + 64×64 tile delta

该基线是继续进行 planner/GPU 优化之前的可恢复版本。用户在两端运行
`fba7473d2b80` 后确认窗口拖动体验“好太多了”。

## 该基线包含的关键行为

1. Sender 默认使用 Release 配置构建，不再以 Swift `-Onone` 运行生产测试。
2. ScreenCaptureKit 的 BC7 帧使用 latest-frame coalescing：
   - 一帧正在处理；
   - 最多保留一帧最新待处理帧；
   - 新帧覆盖尚未处理的旧帧，避免播放过期帧形成高延迟。
3. Metal BC7 encoder 只编码 ScreenCaptureKit dirty rect 覆盖的 64×64 tiles。
4. Delta planner 比较 candidate dirty tiles，并发送水平合并后的 tile runs。
5. Receiver 支持 sequenced keyframe/delta、checksum 验证和丢失基线恢复。
6. Sender 和 Receiver UI 均显示版本、build 和 commit。
7. Receiver 每秒把 FPS、带宽、applied sequence 和 BC7 错误计数回传给 Sender。

## 实机测量

在连续窗口运动区间：

| 指标 | 观测值 |
|---|---:|
| Sender capture FPS | 平均约 45.6，峰值 58 |
| Sender sent FPS | 平均约 45.6，峰值 58 |
| Receiver FPS | 多次达到 54–57 |
| Sender pending packets | 0–1 |
| Sender dropped/coalesced frames | 0 |
| BC7 fallback | 0 |
| Receiver BC7 invalid | 0 |
| Receiver render failures | 0 |
| Sender 网络峰值 | 2.165 Gbit/s |
| Receiver 网络峰值 | 2.126 Gbit/s |
| 大更新 BC7 encode | 约 4.4–5.2 ms/frame |
| 大更新 planner + packet assembly | 约 7.3–8.1 ms/frame |

静止画面时的 1–2 FPS 是内容驱动捕获的结果，不代表链路只能达到该帧率。

## 已知限制

- `planMs` 同时包含 tile compare/checksum、run 合并和 packet 组装，尚未拆分。
- 尚无 capture-to-present 端到端 latency。
- Sender `sentFPS` 统计发送提交，不等同于 Receiver 已显示。
- Receiver 尚未分别统计 parse、delta apply、Metal upload 和 present 时间。
- 大范围更新时 CPU planner 仍可能占用约 8 ms 帧预算。

## 恢复该基线

```bash
git fetch noone3242 --tags
git switch --detach bc7-5k-stable-2026-09-26

cd TargetBridge-Sender
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/build_targetbridge_sender_app.sh
```

iMac Receiver：

```bash
git fetch noone3242 --tags
git switch --detach bc7-5k-stable-2026-09-26
./TargetBridge-Receiver/scripts/run_tbreceiver_dev.sh --windowed
```

继续实验时应从该 tag 新建分支，不修改或移动此 tag。
