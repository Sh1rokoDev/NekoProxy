<p align="center">
  <img src="assets/icons/app_icon.png" width="96" height="96" alt="NekoProxy 图标">
</p>

<h1 align="center">NekoProxy</h1>

<p align="center">
  面向 Android 与 Windows 的 <a href="https://github.com/SagerNet/sing-box">sing-box</a> 图形客户端，采用 Material 3 设计，兼顾开箱即用与灵活分流。
</p>

## 功能特性

- **节点与订阅管理**：支持分组管理节点，提供搜索、筛选、排序及按延迟自动选点功能，并可直观查看订阅流量用量。
- **灵活规则分流**：支持在**直连**、**规则**与**全局**模式间一键切换；可编辑内置分流规则，按域名、IP 或进程等条件指定代理、直连或阻断策略；内置 v2fly GeoSite 与 GeoIP 规则集，支持应用内直接更新。
- **连接监控与配置备份**：实时展示流量速率、活动连接与运行日志；支持预览最终生成的 sing-box 配置文件，并提供加密备份导出功能。界面遵循 Material 3 规范，支持浅色与深色主题切换。
- **服务状态**：检测常用服务的可用性和延迟，并将解析到的服务 IP 交由 [IPQuery](https://ipquery.io/developers/api) 查询地区和运营商。归属信息仅供参考。

## 安装指南

请根据设备平台选择对应的安装包，也可参考下方说明从源码自行构建。

| 平台                 | 安装包                                           | 安装与运行说明                                                                       |
| :------------------- | :----------------------------------------------- | :----------------------------------------------------------------------------------- |
| **Android（ARM64）** | `*-android-arm64.apk`                            | 直接安装 APK；首次开启连接时请按系统提示授予 VPN 权限。                              |
| **Windows（x64）**   | `*-windows-x64-setup.exe` 或 `*-windows-x64.zip` | 运行安装程序，或解压便携压缩包后启动 `nekoproxy.exe`。安装与运行均需**管理员权限**。 |

## 兼容协议

| 协议                | 节点链接前缀                                              |
| :------------------ | :-------------------------------------------------------- |
| Shadowsocks         | `ss://`                                                   |
| VMess               | `vmess://`                                                |
| VLESS（含 REALITY） | `vless://`                                                |
| Trojan              | `trojan://`                                               |
| Hysteria 2          | `hysteria2://`、`hy2://`、`hy://`（均按 Hysteria 2 解析） |
| TUIC                | `tuic://`                                                 |
| AnyTLS              | `anytls://`                                               |
| SOCKS5              | `socks://`、`socks5://`                                   |
| HTTP / HTTPS 代理   | `http://`、`https://`                                     |

## 快速开始

1. **导入配置**：在「**节点**」页面导入订阅链接、分享链接、本地配置文件或二维码图片（支持标准 sing-box JSON 配置与 Base64 节点列表）。
2. **配置节点与分流**：选择目标节点或切换为自动选择模式，并在「**规则**」页面按需调整流量的代理与分流策略。
3. **开启流量接管**：返回「**首页**」启动连接，也可在「规则模式」卡片快捷切换直连、规则和全局：
   - **Android**：通过系统 VPN 服务接管流量，支持按应用配置分应用代理或排除名单。
   - **Windows**：支持独立开启**系统代理**与 **TUN 模式**。仅开启系统代理时，出站流量默认遵循 Windows 系统路由。

## WireGuard 出站

在「节点 → 添加」创建 WireGuard 分组，组内可用表单或手写 `.conf` 创建节点，也可从剪贴板、文件或二维码图片导入。点击 WireGuard 节点可单独使用；WireGuard 分组不参与 sing-box 自动选点。

「节点 → 高级」可以启用链式代理。第一级是手动选择的 WireGuard，第二级仍在节点页手动或自动选择 sing-box 节点。直连目标 IP 和代理服务器 IP 各自按 WireGuard 的 `AllowedIPs` 决定是否进隧道；隧道故障时，命中的地址不会回退到物理网络。关闭链式后恢复原来的单独出站类型。

Android 也支持相机扫码。节点菜单可导出含密钥的 `.conf`。

链式代理开启时，TUN 的「局域网直连」仅排除 WireGuard 的 `AllowedIPs` 未覆盖的局域网地址。被覆盖的地址仍交给 sing-box 规则和 WireGuard 出站处理。

「私网地址直连」是规则模式中的默认可编辑规则，可以改动作、排序、关闭或删除。规则页同时显示核心生成的接管规则和默认出站。Windows 系统代理默认仅绕过回环地址；其他地址交由规则处理。

单独使用 WireGuard 时按配置决定 IPv4／IPv6。Windows 可在首页选择是否开启 TUN：开启后按 `AllowedIPs` 安装系统路由，单对端 `/0` 配置启用会话断网保护；关闭后只处理通过系统代理或本地代理端口进入的流量。链式代理不启用此项保护，以便未命中的地址仍能使用物理网络。Android 使用 NekoProxy 已有的单个系统 VPN。

## 从源码构建

### 环境准备

构建前请确保系统已安装 **Flutter 3.50.0**、**Go 1.26+** 与 **PowerShell 7**。在仓库根目录下拉取 Flutter 依赖；直接在 `runtime/` 下开发或运行 Go 测试时，还需初始化仓库固定的 `sing-box` 子模块：

```powershell
git submodule update --init --recursive
flutter pub get
```

### 平台打包

| 目标平台          | 平台依赖与环境要求                                                                                              | 打包命令                             |
| :---------------- | :-------------------------------------------------------------------------------------------------------------- | :----------------------------------- |
| **Windows x64**   | Visual Studio（「使用 C++ 的桌面开发」工作负载）、Windows SDK、NSIS 3.x，并启用 Windows 开发者模式              | `pwsh ./scripts/package-windows.ps1` |
| **Android ARM64** | JDK 17+（配置 `JAVA_HOME`）、Android SDK 36（配置 `ANDROID_HOME`）、NDK `28.2.13676358`、`gomobile` 与 `gobind` | `pwsh ./scripts/package-android.ps1` |

**安装 Android 构建工具（`gomobile` 与 `gobind`）：**

```powershell
$mobileVersion = 'v0.0.0-20261011034528-197770444867'
go install "golang.org/x/mobile/cmd/gomobile@$mobileVersion"
go install "golang.org/x/mobile/cmd/gobind@$mobileVersion"
```

### 构建产物与签名说明

- Windows 和 Android 的构建与打包脚本每次都从 GitHub Releases 确认最新的稳定版 sing-box、GeoSite 和 GeoIP。核心在临时目录使用官方 Go 模块构建，不改动开发用子模块和依赖锁定文件。规则只有在上游标签、大小、校验值及转换所用核心版本都一致时才复用；无法确认或获取最新上游时，构建会停止。
- 构建完成的安装包及对应的 SHA-256 校验文件统一输出至 `dist/` 目录，正式发布说明会记录各平台实际打包的上游版本。
- 构建正式发布版本时，请确保工作区处于干净状态（无未提交更改）。
- 本地 Android 构建默认使用调试签名。正式 APK 由 GitHub Actions 签名并随 Windows 安装版和便携版发布，见[发布工作流](.github/workflows/release.yml)。

## 反馈与贡献

欢迎提交 Issue 报告问题或发起 Pull Request 参与改进。提交问题反馈时，建议附上以下信息以便快速定位：

- 应用版本与操作系统版本
- 当前使用的流量接管方式（VPN / 系统代理 / TUN）
- 清晰的复现步骤与**脱敏后**的运行日志

## 许可证

NekoProxy 采用 [GPL-3.0-or-later](LICENSE) 许可证发布。项目所包含的第三方组件与规则集授权信息请参阅 [第三方许可声明](third_party/THIRD_PARTY_NOTICES.md)。
