# BC7 + LZ4 Receiver 初步 Follow-up

## 1. 基线

冻结 checkpoint：

```text
tag:    bc7-5k-lz4-low-bandwidth-checkpoint-2026-09-27
commit: 52b4ece57f1a4f5e934bd8a483b1ed84a6a3c2e5
```

历史桌面拖拽样本：

```text
Sender:                 53.90 Hz
Receiver:               36.37 FPS
平均/峰值带宽:          0.417 / 0.518 Gbit/s
Sender LZ4 p95:         3.83 ms
Receiver LZ4 p95:       3.15 ms
Receiver packet p95:    31.7 ms
```

该checkpoint的低带宽数据来自较容易压缩的桌面变化，不代表视频内容。

## 2. Follow-up 分支

```text
branch: 2026-09-27_bc7-lz4-receiver-opt
```

提交：

```text
7f43943  Preserve Sender screen recording permission
9925ddd  Reuse BC7 LZ4 decode buffers
0f78676  Add BC7 automation selectors
```

`9925ddd`保持原BC7 wire protocol不变，Receiver改动包括：

- 持久复用BC7 supercompression scratch buffers；
- Raw BC7 + LZ4直接解压到最终blocks buffer；
- 取消`transformed -> blocks_copy`完整复制；
- 保留LZFSE byte-plane inverse transform路径；
- 保留严格LZ4 stream结束、输入完全消费和精确输出长度校验；
- 新增`compressedTotalP50/P95/P99`，覆盖compressed packet进入Receiver到delta apply完成的完整路径。

`0f78676`增加Sender自动化参数：

```text
--codec bc7
--bc7-compression lz4
```

用于避免硬件实验继承旧UI状态或误用NV12。

验证：

```text
Sender XCTest:           passed
Receiver parser tests:   172 checks passed
Receiver full build:     passed
invalid/render errors:   0
```

## 3. 视频播放 + 窗口拖拽实测

采集了114个约一秒窗口，筛选条件：

```text
commit == 0f7867661327
networkGbps >= 0.1
```

结果：

| 指标 | 实测 |
|---|---:|
| Sender capture | 38.32 Hz |
| Sender sent/completed | 34.35 / 34.35 Hz |
| Receiver present | 31.82 FPS |
| 平均/峰值带宽 | 0.789 / 1.761 Gbit/s |
| Sender GPU encode p95窗口平均 | 10.34 ms |
| Sender tile plan p95窗口平均 | 3.11 ms |
| Sender LZ4 p95窗口平均 | 8.07 ms |
| Sender send p95窗口平均 | 4.15 ms |
| Receiver packet interval p95窗口平均 | 68.62 ms |
| Receiver LZ4 p95窗口平均 | 3.76 ms |
| Receiver compressed total p95窗口平均 | 23.85 ms |
| Receiver apply p95窗口平均 | 11.19 ms |
| Receiver upload p95窗口平均 | 1.93 ms |
| Receiver present p95窗口平均 | 0.096 ms |
| Receiver present interval p95窗口平均 | 71.27 ms |
| compressed/raw blocks | 56.9% |
| invalid/render/keyframe requests | 0 / 0 / 0 |

## 4. 与NV12 tile-run历史样本对照

不同实验的内容和时间不完全相同，因此不是严格同动作A/B。

| 路径 | Sender | Receiver | 平均带宽 | 峰值带宽 |
|---|---:|---:|---:|---:|
| BC7 + LZ4视频+拖拽 follow-up | 34.35 Hz | 31.82 FPS | 0.789 Gbit/s | 1.761 Gbit/s |
| NV12 64×64 tile runs历史样本 | 55.04 Hz | 53.33 FPS | 0.812 Gbit/s | 1.780 Gbit/s |

在这次视频负载下，两条路径的带宽接近，但BC7 + LZ4的Sender和Receiver帧率明显更低。

BC7 blocks已经经过固定8 bpp纹理编码。视频内容下blocks熵较高，LZ4二次压缩率从历史桌面负载约15.7%下降到56.9%。因此视频负载中没有重现checkpoint的显著低带宽优势。

## 5. 阶段结论和暂停点

第一阶段确认：

- reusable scratch和Raw-LZ4直解保持协议正确；
- 新telemetry正常回传；
- 无invalid、render failure或keyframe recovery；
- 完整Receiver路径p95仍为23.85 ms；
- 纯LZ4解压只占其中3.76 ms，legacy重建、validation/shadow、upload和cadence仍有明显成本；
- Sender GPU encode、tile planning和LZ4合计同样超过16.67 ms帧预算；
- 视频负载带宽与NV12 tile runs接近。

用户基于主观体验和实测带宽决定暂停该follow-up，不继续以下阶段：

- 取消legacy delta重建；
- validation/shadow独立优化；
- 批量Metal BC7 upload；
- Sender packet/checksum/run布局配合修改；
- 新checkpoint tag。

未提交的第二阶段direct-delta草稿已保存在会话废弃归档：

```text
files/废弃/2026-09-27-bc7-direct-delta-stage2-rejected.patch
files/废弃/2026-09-27-bc7-direct-delta-stage2-rejected.txt
```

原始checkpoint tag保持不变，follow-up分支保留已完成的第一阶段代码和metrics，供后续回溯。
