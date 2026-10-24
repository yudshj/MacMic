# MacMic for Mac (非官方原生客户端)

语言：[English](README.md) | **简体中文**

**MacMic** 是一款专为 Apple Silicon 芯片打造的非官方 macOS 原生音频客户端，兼容 WO Mic 通信协议。软件基于纯 Swift 与 SwiftUI 编写，具备体积小巧、冷启动迅速的特点，配合 BlackHole 驱动可将 iPhone 或 Android 手机作为 Mac 的无线或有线麦克风使用。

> **📌 架构说明**  
> 当前预编译程序包仅支持 **Apple Silicon (M1/M2/M3/M4 系列芯片)**。如果您使用的是 Intel 芯片的 Mac 并需要 Intel 版本，请随时联系作者或提交 issue。

> **💻 Windows 用户说明**  
> 本项目**不会**提供 Windows 版本。Windows 用户请支持并使用 Wolicheng Tech 开发的官方原版软件：[https://wolicheng.com/womic/](https://wolicheng.com/womic/)。

> **免责声明与致原作者声明**  
>
> 1. **非官方移植**：本项目为独立开发的非官方开源移植版本，与 WO Mic 官方团队 Wolicheng Tech 没有任何从属、赞助或商业关联。**请勿因本项目的任何使用或兼容性问题向 WO Mic 官方开发者寻求帮助。**  
> 2. **致 WO Mic 官方开发者**：衷心感谢并高度赞赏 Wolicheng Tech 创作的优秀软件 WO Mic。本项目仅出于 macOS 协议互操作性技术研究与个人学习便利而开源。如果官方团队不认可此移植行为或认为有任何不妥，请随时联系作者邮箱 `maghsk2017@gmail.com`，收到反馈后将第一时间停止公开此仓库并关停相关下载。  
> 3. **版权说明**：WO Mic 相关商标及协议版权均归原作者 Wolicheng Tech 所有。请勿将本项目用于任何商业变现或侵权用途。

---

## 解决的痛点

WO Mic 官方长期未提供 macOS 原生客户端。以往在 Mac 上通过 Wine、虚拟机或旧版脚本串联，配置过程繁琐，且容易出现音频延迟、爆音与断流现象。

MacMic 直接使用 Swift 实现了底层网络通信与 CoreAudio 播放管线，并静态链接了 `libopus` 解码库，无需安装复杂的 Python 环境或额外依赖包。

---

## 主要功能

- **三种连接模式**：
  - **Wi-Fi**：局域网无线连接，支持 iOS 与 Android 手机。
  - **USB (ADB)**：Android 手机插入数据线后自动完成端口转发，具备超低延迟。
  - **Wi-Fi Direct**：手机开启热点直连。
- **实时 AI 降噪**（三档可选）：
  - **无降噪**：完全旁路，零延迟、零额外开销。
  - **RNNoise**（默认）：xiph 开源模型，额外延迟约 20 ms，实测约占 5~6% 单核 CPU（M5 Pro，含整个音频管线）。
  - **Apple 内置人声隔离**：调用系统 FaceTime 同款 `AUSoundIsolation`，降噪更强、CPU 更低（实测约 4%），代价是额外约 56 ms 延迟，且不增加安装体积。
  - 强度滑杆按比例混合原声与降噪结果；原声经过等长延迟对齐，不会产生梳状失真。
  - 所有降噪运算在后台音频线程完成，不占用实时播放线程。
- **音频路由与处理**：
  - 自动识别并输出至 **BlackHole 2ch** 虚拟音频设备。
  - 平滑电平条（-60 ~ 0 dBFS 刻度），带峰值保持。
  - 支持 0% ~ 200% 音量增益调节与一键静音功能。
- **全方位多语言支持（9 种主流语言）** 🌐：
  - 内置完整国际化（i18n），支持即时动态切换：
    - 🇨🇳 **简体中文** (Simplified Chinese)
    - 🇭🇰 **繁體中文** (Traditional Chinese)
    - 🇺🇸 **English**
    - 🇯🇵 **日本語** (Japanese)
    - 🇰🇷 **한국어** (Korean)
    - 🇪🇸 **Español** (Spanish)
    - 🇫🇷 **Français** (French)
    - 🇷🇺 **Русский** (Russian)
    - 🇩🇪 **Deutsch** (German)
  - 默认自动跟随 macOS 操作系统语言，亦可在“偏好设置”中自由切换。
- **macOS 原生深度整合**：
  - 菜单栏常驻图标与快捷交互弹窗（一键连接、快速静音与偏好设置）。
  - 支持跟随系统 / 浅色模式 / 深色模式三种外观主题。
  - 支持开机自动启动（基于 Apple 现代化 `SMAppService`）。
- **轻量原生**：单一可执行文件，无后台残留守护进程，随开随关。

---

## 使用方式

手机端的操作与原版连接方式完全一致。以下是具体的使用步骤：

### 1. 准备虚拟音频驱动 (BlackHole)
macOS 系统本身不允许软件直接将声音注入到其他应用程序的麦克风输入中，因此需要配合虚拟音频驱动 **BlackHole 2ch** 使用。

使用 Homebrew 安装：
```bash
brew install blackhole-2ch
```
或者前往 [BlackHole 官网](https://existential.audio/blackhole/) 下载安装包。

### 2. 手机端准备

#### iOS
1. 在 App Store 下载并打开 **WO Mic**。
2. 确保 iPhone 与 Mac 连接在同一个局域网 Wi-Fi 下。
3. 打开应用程序设置，连接方式选择 **Wi-Fi**（*注：WO Mic iOS 版本官方仅支持 Wi-Fi 一种连接方式*）。
4. 点击顶部的启动按钮，记下屏幕上显示的 IP 地址（例如 `192.168.1.105`）。

#### Android
- **Wi-Fi 模式**：操作步骤与 iOS 完全一致。
- **USB 模式**：
  1. 在 Android 手机的开发者选项中开启 USB 调试。
  2. 使用数据线连接 Mac，手机端连接方式选择 **USB** 并点击启动。
  3. 在 MacMic 客户端中选择 **USB (ADB)** 模式（默认模式）。客户端会列出所有已授权的 ADB 设备，多台设备时可在下拉框中选择，然后点击连接（系统将自动为所选设备转发 8125 端口）。
     > 若连接失败，请确认：手机上 WO Mic 已点击启动并停留在等待连接界面；`adb devices` 能看到你的设备且状态为 `device`；手机上已允许 USB 调试授权。

### 3. Mac 客户端操作与连接

1. 下载 release 页面中的 `MacMic.app` 移至应用程序目录，双击打开。
2. 在 **音频输出目标** 下拉菜单中，选择 **`BlackHole 2ch [虚拟麦克风]`**：
   
   ![MacMic 客户端主界面](assets/main_ui.png)

3. 输入手机上显示的 IP 地址（或选择对应的连接模式），点击 **连接** 按钮。
4. **⚠️ 系统权限弹窗说明**：首次点击连接时，macOS 系统将相继弹出图 1 与图 2 所示的两个权限授权弹窗，**请务必通通点击“Allow (允许)”**。如果选择拒绝，系统的防火墙或隐私机制将拦截网络数据接收及麦克风音频输出：

   | 图 1：局域网设备查找权限 | 图 2：麦克风访问权限 |
   | :---: | :---: |
   | ![图1 局域网权限](assets/permission_local_network.png) | ![图2 麦克风权限](assets/permission_microphone.png) |

### 4. 设置输入源与全局管理

- **基础设置**：打开微信、腾讯会议、Zoom、OBS 或 macOS 系统设置中的声音选项，将麦克风输入设备选择为 **BlackHole 2ch**。
- **推荐进阶工具 (FineTune)**：  
  如果您希望在全局更方便地管理 Mac 的音频输入输出源、或者针对单个应用程序独立指定麦克风输入，推荐配合开源音频管理软件 **FineTune** 使用。FineTune 是一款基于 SwiftUI 开发的免费开源 macOS 菜单栏音频控制工具，能够轻松管理全局音频路由。  
  - 仓库地址：[https://github.com/ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune)

---

## 降噪使用建议

- **默认使用 RNNoise**：延迟最低（约 20 ms），适合需要低延迟的场景。
- **Apple 内置人声隔离**：实测降噪更强、CPU 反而更低，代价是多约 56 ms 延迟。在嘈杂环境、或想让电脑更省电时优先选它。

### 性能实测（M5 Pro，USB 推流，窗口打开）

| 降噪模式 | CPU（单核占比） | 额外延迟 |
| --- | --- | --- |
| 无降噪 | 0.7% | 0 |
| RNNoise | 5.9% | 约 20 ms |
| Apple 内置人声隔离 | 4.3% | 约 56 ms |

> 表中包含完整音频管线（收包、Opus 解码、降噪、电平表、AUHAL 输出）。窗口隐藏时数值基本相同，说明界面本身几乎不占 CPU。
- **强度滑杆**：100% 为全降噪。若觉得人声发闷、或被削得太干净，可降到 60%~80%。
- **避免两层降噪叠加**：开启 MacMic 降噪后，建议把 Zoom、腾讯会议、微信等软件自带的降噪调到“低”或关闭，否则容易出现“水下声”、吞字等失真。
- **先试手机端音源模式**：WO Mic 手机端有多个“Mic mode”，其中 mode 3 官方说明适合嘈杂环境，可以先在手机上切换对比。

---

## 本地编译

如果希望自行从源码进行编译：

### 依赖要求
- macOS 12.0 或更高版本 (Apple Silicon)
- Xcode 命令行工具 (`xcode-select --install`)
- libopus 解码库 (`brew install opus`)

> RNNoise 无需手动安装：首次执行 `build_app.sh` 时会由 `scripts/build_rnnoise.sh` 自动拉取指定 commit 的 xiph/rnnoise 源码与模型权重（按 sha256 校验），并静态编译到 `third_party/rnnoise/lib/librnnoise.a`。

### 构建命令
```bash
git clone https://github.com/yudshj/MacMic.git
cd MacMic
./build_app.sh
```
构建成功后将在根目录生成独立的 `MacMic.app` 应用程序包。

---

## 源码结构

```text
swift-src/
├── main.swift                 # 程序入口与窗口样式控制
├── ContentView.swift          # SwiftUI 界面与电平绘制
├── ViewModel.swift            # 状态驱动与事件分发
├── MacMicClient.swift         # 核心通信协议实现
├── AudioEngine.swift          # CoreAudio / AudioQueue 播放引擎、环形缓冲与电平表
├── Denoiser.swift             # 实时降噪：RNNoise / Apple 人声隔离 / 旁路
├── OpusDecoder.swift          # C-Opus 解码桥接封装
├── AudioDeviceManager.swift   # macOS 系统音频输出设备枚举
├── ADBHelper.swift            # Android USB 调试与端口映射助手
├── MenuBarManager.swift       # 菜单栏常驻图标与快捷交互菜单
├── SettingsView.swift         # 多语言切换与开机自启偏好设置面板
├── Localization.swift         # 多语言国际化 (i18n) 本地化资源
└── LaunchAtLoginHelper.swift  # 基于 SMAppService 的开机自启管理器

scripts/
└── build_rnnoise.sh           # 拉取并静态编译 RNNoise（含模型校验）
```

---

## 开源协议

本项目采用 [MIT 许可证](LICENSE) 开源。

## 致谢

- 本项目基于 [luanyufei/MacMic](https://github.com/luanyufei/MacMic)（MIT）继续开发，感谢原作者的开创性工作。
- [xiph/rnnoise](https://github.com/xiph/rnnoise)：BSD-3-Clause 许可的降噪模型。
- [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole)：虚拟音频驱动。
- WO Mic 相关商标与协议版权归 Wolicheng Tech 所有。

## 维护者

- GitHub：[@yudshj](https://github.com/yudshj)
- 项目主页：[github.com/yudshj/MacMic](https://github.com/yudshj/MacMic)
- 联系邮箱：`maghsk2017@gmail.com`
