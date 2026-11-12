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
3. **开启流量接管**：返回「**首页**」启动连接：
   - **Android**：通过系统 VPN 服务接管流量，支持按应用配置分应用代理或排除名单。
   - **Windows**：支持独立开启**系统代理**与 **TUN 模式**。仅开启系统代理时，出站流量默认遵循 Windows 系统路由。

## 从源码构建

### 环境准备

构建前请确保系统已安装 **Flutter 3.47.x**、**Go 1.26+** 与 **PowerShell 7**。在仓库根目录下初始化 `sing-box` 子模块并拉取 Flutter 依赖：

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

- 打包脚本会自动同步规则集，构建完成的安装包及对应的 SHA-256 校验文件统一输出至 `dist/` 目录。
- 构建正式发布版本时，请确保工作区处于干净状态（无未提交更改）。
- Android 构建脚本默认使用调试签名（Debug Key），在公开分发前请配置你自己的正式签名。

## 反馈与贡献

欢迎提交 Issue 报告问题或发起 Pull Request 参与改进。提交问题反馈时，建议附上以下信息以便快速定位：

- 应用版本与操作系统版本
- 当前使用的流量接管方式（VPN / 系统代理 / TUN）
- 清晰的复现步骤与**脱敏后**的运行日志

## 许可证

NekoProxy 采用 [GPL-3.0-or-later](LICENSE) 许可证发布。项目所包含的第三方组件与规则集授权信息请参阅 [第三方许可声明](third_party/THIRD_PARTY_NOTICES.md)。
