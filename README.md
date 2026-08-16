<p align="center">
  <img src="Assets/AppIcon.png" width="112" height="112" alt="Mac Resource Monitor icon">
</p>

<h1 align="center">Mac 资源监控</h1>

<p align="center">
  一款原生、离线、菜单栏常驻的 macOS 性能与存储管理工具。
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111111?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-0A84FF">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white">
  <img alt="Version" src="https://img.shields.io/badge/version-2.2.1-7C3AED">
</p>

Mac 资源监控将系统性能、硬件传感器、USB-C/Thunderbolt 端口、磁盘空间分析、安全清理和应用卸载整合到一个 SwiftUI 应用中。主窗口采用 macOS 26 原生 Liquid Glass，关闭窗口后应用仍会留在菜单栏继续采集数据。

> 当前版本：**2.2.1（Build 19）**。项目面向 macOS 26 和 Apple Silicon 构建，不提供旧系统兼容层。

## 功能概览

| 模块 | 能力 |
| --- | --- |
| 系统监控 | CPU、内存、磁盘、网络、CPU 温度、风扇、充电功率、进程排行与历史曲线 |
| 端口监测 | USB-C、MagSafe、USB4、Thunderbolt、DisplayPort、USB-PD 和线缆 E-Marker |
| 存储清理 | 磁盘概览、主要目录排行、500 MB 以上大文件、缓存/日志/Xcode/废纸篓清理 |
| 应用卸载 | 第三方应用大小排行、Finder 定位、应用本体及精确 Bundle ID 残留移入废纸篓 |

## 2.2.1 更新

- 将存储模块重构为固定首页和三张功能卡片，空间占用、大文件、安全清理分别进入独立二级页面。
- 长目录列表改为懒加载，避免扫描结果增长时拖慢首页和首屏渲染。
- 修复“大文件”入口在 macOS 26 上缺少 SF Symbol 图标的问题。
- Bundle ID 改为公开仓库身份 `io.github.svsvnm.MacResourceMonitor`，移除本机账户名痕迹。
- 保留关闭窗口后菜单栏常驻、实时传感器与充电功率采集等既有行为。

## 系统监控

- 每 2 秒刷新 CPU、内存、磁盘和主要网络接口数据。
- 显示最近约 2 分钟的 CPU 与内存趋势。
- 读取 Apple SMC 中可用的 CPU 温度传感器，展示平均值和最高值。
- 读取内置风扇数量与实时转速；低温停转时明确显示 `0 RPM`。
- 展示 CPU 占用较高的进程、PID、CPU 比例和内存占用。
- 展示电池状态、供电方式、系统热状态、开机时长和设备名称。
- 菜单栏标题直接显示 CPU 与温度，弹窗内可查看主要指标和已连接端口。

## 实时充电功率

应用读取 `AppleSmartBattery` 的本机电源遥测，并区分以下概念：

- **适配器输入功率**：电源适配器当前向整机提供的功率。
- **电池实际充入功率**：真正进入电池的实时功率。
- **系统负载**：整机当前消耗的功率。
- **USB-PD 协商上限**：端口协商能力，不会被误标为实时充电功率。

未连接电源、已充满或系统未提供对应字段时，界面会显示真实状态或“不可用”，不会使用估算值冒充测量结果。

## 端口与线缆监测

- 独立的“端口监测”模块，不与 CPU/内存页面混排。
- 识别 USB-C、MagSafe 和可用的物理端口状态。
- 展示 USB 2、USB 3、USB4、Thunderbolt 和 DisplayPort 活跃链路。
- 展示 USB-PD 协商功率、电压、电流及可能的充电瓶颈。
- macOS 实际提供数据时，展示线缆 E-Marker 的额定速率、功率、厂商和能力判断。
- 内置 WhatCable 检测引擎使用 `--json --no-usb-probe`，不会对 USB 设备执行深度控制传输。

## 空间分析与安全清理

“存储清理”页首先告诉你空间被什么占用，再提供有限、明确的清理入口。

存储首页采用三张可进入的 Liquid Glass 功能卡片，只保留磁盘概览以及“空间占用”“大文件”“安全清理”入口。详细列表和操作位于各自的二级页面，返回首页后不会保留冗长列表，后续增加更多工具也不会让首页无限增长。

### 只读空间分析

- 按实际大小列出 `/Applications`、个人目录和 `~/Library` 中的主要占用项。
- 继续拆分 `Application Support`、应用容器、共享容器和开发工具数据，避免只显示一个笼统的“Library 很大”。
- 使用本机 Spotlight 索引列出 500 MB 以上的大文件，最多显示 20 项。
- 每个目录和大文件都可以在 Finder 中定位。
- 大文件与个人目录只读展示，不会进入一键清理范围。

### 可清理项目

| 类别 | 默认选择 | 行为 |
| --- | --- | --- |
| 用户应用缓存 | 是 | 删除可重新生成的 `~/Library/Caches` 内容，并保留本应用的检测组件缓存 |
| 用户日志与崩溃报告 | 是 | 清理 `~/Library/Logs` 中的用户级日志 |
| Xcode DerivedData | 否 | 删除可重新生成的构建缓存 |
| 废纸篓 | 否 | 永久删除，界面会显示不可恢复警告并再次确认 |

文稿、照片、下载、桌面、影片、音乐和其他个人内容不会被自动清理。受 macOS 隐私保护或尚未下载的云端内容可能无法统计。

## 应用卸载

- 扫描 `/Applications` 和 `~/Applications` 中的第三方应用，并按大小排序。
- 排除系统应用、符号链接和 Mac 资源监控自身。
- 应用本体通过 macOS 废纸篓机制移除，正常情况下可恢复。
- 只处理与应用 Bundle ID 精确匹配的缓存、偏好、容器、WebKit、HTTPStorage、日志和启动项。
- 不按模糊名称批量删除文件，也不会重置全局登录项、隐私或后台项目数据库。
- 系统级或受保护应用可能需要管理员权限；应用会保留未获授权的内容并报告失败。

## Liquid Glass 界面

- macOS 26 原生 `glassEffect` 卡片和 `.glass` / `.glassProminent` 按钮。
- `GlassEffectContainer` 统一相邻玻璃元素的采样与渲染。
- 常驻侧边栏承载四个一级模块，模块切换自动返回内容顶部。
- 内容区使用环境光晕和系统自适应玻璃材质，支持浅色与深色外观。
- 隐藏式标题栏保留原生窗口控制按钮。

## 菜单栏与窗口行为

- 关闭主窗口不会退出应用，Dock 图标会隐藏，菜单栏监控继续运行。
- 菜单栏弹窗可重新打开主面板、暂停/继续监控或退出程序。
- 主面板提供“收起到菜单栏”按钮，与关闭主窗口行为一致。
- 只有选择“退出”或按下 `Command + Q` 才会结束进程。

## 隐私与安全边界

- 所有数据都在本机读取和处理，不需要账号，也没有遥测上传。
- Bundle ID 使用与公开仓库对应的 `io.github.svsvnm.MacResourceMonitor`，不包含本机账户名、设备名或绝对用户路径。
- 公开仓库不提交本机构建产物、扫描结果或包含个人文件路径的运行截图。
- 系统监控、SMC、端口和电源采集均为只读操作。
- 应用不会控制风扇、修改充电策略、调整端口配置或改变网络设置。
- 清理操作只针对界面明确列出的路径，并在执行前二次确认。
- 应用卸载使用废纸篓；废纸篓清理本身属于永久删除，默认不选择。
- 无法读取的受保护目录会被跳过，不会通过降低系统安全设置来绕过权限。

## 系统要求

- macOS 26.0 或更高版本。
- Apple Silicon（当前构建目标为 `arm64-apple-macos26.0`）。
- Xcode 26 Command Line Tools 或完整 Xcode 26，用于从源码构建。
- 温度、风扇、线缆和电源字段取决于具体 Mac 型号与 macOS 是否公开对应数据。

## 从源码构建

项目不依赖 Xcode 工程、Swift Package Manager 或第三方包管理器，构建脚本直接调用系统 Swift 编译器。

```zsh
git clone https://github.com/svsvnm/MacResourceMonitor.git
cd MacResourceMonitor
chmod +x build.sh
./build.sh
```

构建成功后会在项目根目录生成：

```text
Mac资源监控.app
```

启动本地构建：

```zsh
open "Mac资源监控.app"
```

安装到“应用程序”目录：

```zsh
ditto "Mac资源监控.app" "/Applications/Mac资源监控.app"
open "/Applications/Mac资源监控.app"
```

`build.sh` 会执行以下步骤：

1. 创建标准 `.app` Bundle 目录。
2. 复制 `Info.plist`、应用图标、第三方声明和 WhatCable 运行资源。
3. 使用 Swift 编译器链接 SwiftUI、AppKit、IOKit 和 SystemConfiguration。
4. 对 WhatCable helper 和最终 App 执行本机 ad-hoc 签名。

验证签名：

```zsh
codesign --verify --deep --strict --verbose=2 "Mac资源监控.app"
```

> 仓库不提交构建生成的 `.app`。从 GitHub 下载源码后在本机运行 `build.sh`，可避免将未经公证的预编译程序作为发布包分发。

## 项目结构

```text
MacResourceMonitor/
├── Assets/
│   ├── AppIcon.icns
│   ├── AppIcon.png
│   ├── AppIcon.iconset/
│   └── WhatCableHelper/
├── Scripts/
│   └── make-rounded-icon.swift
├── Sources/
│   ├── CableMonitor.swift
│   ├── MacResourceMonitor.swift
│   └── StorageManager.swift
├── Info.plist
├── THIRD_PARTY_NOTICES.md
└── build.sh
```

- `MacResourceMonitor.swift`：系统采集、SMC、电源遥测、Liquid Glass 主界面、菜单栏和应用生命周期。
- `CableMonitor.swift`：WhatCable helper 的安全暂存、执行、JSON 解析和端口快照。
- `StorageManager.swift`：磁盘占用、目录/大文件分析、清理分类和应用卸载。
- `build.sh`：可重复执行的 arm64 App Bundle 构建与签名脚本。

## 已知限制

- SMC 键和硬件传感器随机型变化；无法读取时会显示“不可用”。
- 普通 3A 线缆、仅充电线缆或某些转接器可能不提供 E-Marker 信息。
- Spotlight 未索引、隐私受限或纯云端文件可能不会进入大文件列表。
- `du` 只能统计当前用户有权限读取的目录。
- 当前仅构建 arm64，不支持 Intel Mac。

## 第三方组件

- Apple SMC 读取结构和访问方式参考 [Stats](https://github.com/exelban/stats)。
- USB-C、USB-PD、E-Marker、DisplayPort 与 Thunderbolt 诊断使用 [WhatCable](https://github.com/darrylmorley/whatcable) 的只读命令行引擎，固定源修订为 `82fded6f428ddfc79dfb204bf0b8e049ef6a8c32`。

完整版权和 MIT 许可文本见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。这些声明仅覆盖相应第三方组件。

## 版本信息

- App 版本：2.2.1
- Build：19
- Bundle ID：`io.github.svsvnm.MacResourceMonitor`
- 最低系统版本：macOS 26.0
- 构建架构：arm64
