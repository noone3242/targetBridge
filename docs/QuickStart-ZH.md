# TargetBridge 快速上手（中文）

## 软件包内容

- `TargetBridge-Sender`（发送端，运行在 Apple Silicon Mac 上）
- `TargetBridge-Receiver`（接收端，运行在 Intel iMac 上）

## 构建发送端

```bash
cd TargetBridge-Sender
./scripts/build_targetbridge_sender_app.sh
```

生成的应用：

- `build/TargetBridge.app`

## 构建接收端

构建之前，先在 iMac 上安装所需依赖：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install ffmpeg sdl2 pkgconf
```

然后开始构建：

> 说明：构建脚本会自动把 FFmpeg 和 SDL2 打包进 `.app` 内，运行时无需 Homebrew。

```bash
cd TargetBridge-Receiver
./scripts/build_tbreceiver_c_app.sh
```

生成的应用：

- `build/TargetBridge Receiver.app`

注意：

- 在 Intel iMac 上请直接在该 iMac 上构建接收端，这样产出的二进制才是 `x86_64`。
- 可用以下脚本完成 Intel 架构、依赖、GPU BC7 capability、构建和证据采集：

```bash
TargetBridge-Receiver/scripts/intel_bc7_validation.sh --launch
```

- 结果保存在 `build/intel-validation/<时间戳>/`。如果
  `supportsBC7Mode6` 为 `false`，该 Intel Mac 的当前 Metal GPU 不支持
  BC7 texture 路径，Sender 会明确拒绝 BC7，而不会静默回退。

## 启动

### MacBook（发送端）

打开：

- `build/TargetBridge.app`

首次启动时，请授予以下权限：

- `屏幕录制（Screen Recording）`

### iMac（接收端）

打开：

- `build/TargetBridge Receiver.app`

记下启动窗口中显示的 IP 地址。

## 连接

1. 先在 iMac 上启动 `TargetBridge Receiver`
2. 读取接收端显示的 Thunderbolt Bridge IP 地址
3. 在 MacBook 上打开 `TargetBridge`
4. 选择 `Extended display`（扩展显示，把 iMac 当作独立桌面）或 `Mirror MacBook`（镜像 MacBook 屏幕）
5. 在 `Receiver IP` 字段中输入上述 IP
6. 点击 `Connect`

测试 BC7 时，在发送端把 `Video transport` 设为
`BC7 Mode 6 (Experimental)`，或在 Diagnostics 点击
`开始 BC7 联合测试`。联合测试固定使用 1440p，只有 Receiver 完成
Metal texture 上传和 render command 后才显示通过。

当第一帧画面到达时，接收端会自动切换为全屏。

如果使用扩展桌面模式，连接成功后请在发送端 Mac 上打开 **系统设置 → 显示器 → 排列**，把 TargetBridge 外接显示器拖到你想要的位置。如果 iMac 画面没有铺满屏幕或显示比例异常，请在显示器设置中选中该 TargetBridge 外接显示器，并选择对应的分辨率。对于 27 寸 5K iMac，建议使用 `5K` 流配置，并把外接显示器设为对应的 5120 × 2880 / 2560 × 1440 HiDPI 模式。

## 流配置（Stream profiles）

- `Standard · 2560 × 1440`
  - 保守的基准配置
  - 兼容性最高

- `Smooth · 2560 × 1440 @ 60`
  - 更低的运动延迟

- `Smooth+ · 3200 × 1800 @ 60`
  - 更锐利的运动画面

- `Crisp · 3840 × 2160 @ 48`
  - 文字更清晰
  - 使用 `HEVC` 编码
  - 比原生 5K 更轻量

- `5K · 5120 × 2880 @ 48`
  - 原生 iMac 5K 流
  - 使用 `HEVC` 编码
  - 负载最高

## 接收端开机自启

在 iMac 上让接收端跟随用户登录自动启动：

```bash
cd TargetBridge-Receiver
./scripts/install_tbreceiverc_launch_agent.sh
```

移除自启：

```bash
cd TargetBridge-Receiver
./scripts/uninstall_tbreceiverc_launch_agent.sh
```

## 实用提示

- 接收端必须先于发送端启动
- 扩展桌面模式下需要在发送端的「系统设置 → 显示器」中排列新显示器位置
- 发送端可以选择显示或隐藏菜单栏图标
- 如果 5K 卡顿不流畅，可以切换回 `Crisp` 或 `Smooth+`
- 发送端构建脚本使用本地的 DerivedData 目录：`TargetBridge-Sender/.build/DerivedData`
