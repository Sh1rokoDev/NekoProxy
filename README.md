<p align="center">
  <img src="assets/icons/app_icon.png" width="96" height="96" alt="NekoProxy">
</p>

<h1 align="center">NekoProxy</h1>

<p align="center">
  面向 Android、Windows 和 Linux 的 <a href="https://github.com/SagerNet/sing-box">sing-box</a> 图形客户端。
</p>

## 功能

- 支持 sing-box JSON、Base64 订阅、分享链接与二维码图片导入，提供分组管理、测速自动选点及订阅流量统计
- 规则 / 全局 / 直连分流，支持域名、IP、进程名与应用包名规则，内置 v2fly GeoSite / GeoIP 并支持应用内更新
- 独立 WireGuard 出站，或作为前置跳点与 sing-box 节点组成双跳链式代理（`WireGuard -> sing-box`）
- 实时速率、活动连接、运行日志、完整 sing-box 配置预览与加密备份
- 常用服务连通性检测与出口 IP 归属查询，使用包括 [IPQuery](https://ipquery.io/developers/api) 在内的查询服务

## 支持协议

- **代理协议**：Shadowsocks、VMess、VLESS（含 REALITY）、Trojan、Hysteria 2（`hysteria2://` / `hy2://` / `hy://`）、TUIC、AnyTLS、SOCKS5、HTTP / HTTPS
- **WireGuard**：支持通过 `.conf`、表单或二维码导入，并可导出完整 `.conf`

## 安装

从 [GitHub Releases](https://github.com/Sh1rokoDev/NekoProxy/releases) 获取对应平台产物。

| 平台 | 构建产物 | 说明 |
| :--- | :--- | :--- |
| **Android (ARM64)** | `*-android-arm64.apk` | Android 7.0（API 24）及以上 |
| **Windows (x64)** | `*-windows-x64-setup.exe` / `*-windows-x64.zip` | 安装版需管理员权限安装，安装版与便携版均需管理员权限运行 |
| **Linux (x64)** | `*-linux-x64.deb` | 基于 Ubuntu 24.04 LTS 构建。用 APT 安装后，从应用菜单启动 |

## 平台与流量接管

核心运行时，系统代理可热切换，切换 TUN / VPN 会重启核心并短暂中断连接。核心停止时，切换仅保存设置。规则模式内置可编辑的私网直连规则。

- **Android**：单 VPN 实例接管流量，支持按应用过滤；关闭 VPN 时仅保留本地代理端口。
- **Windows**：系统代理与 TUN 独立控制。仅开启系统代理时，绕过列表仅保留回环地址，分流统一由规则引擎处理。
- **Linux**：
  - 默认提供回环 HTTP / SOCKS5 混合端口；GNOME 与 KDE Plasma 5/6 支持切换系统代理。
  - 启用 TUN 需将当前用户加入 `nekoproxy-tun` 组并重新登录：
    ```bash
    sudo usermod -aG nekoproxy-tun "$(id -un)"
    ```
  - 使用 `systemd-resolved` 时需确保 `polkitd` 运行，以授权配置和恢复链路 DNS。

## WireGuard 与链式代理

WireGuard 节点独立分组，不参与 sing-box 自动选点。开启链式代理时，第一跳为手动选定的 WireGuard 节点，第二跳沿用 sing-box 手动或自动选点。首页显示第一跳的对端地址和地区，以及最终出口地区。

- **路由与故障处理**：链式模式下，直连目标 IP 与第二跳服务器 IP 均按 WireGuard 的 `AllowedIPs` 决定是否入隧道；命中地址在隧道异常时不会回退到物理网络。
- **局域网直连**：链式模式下，TUN 的「局域网直连」仅排除未被 `AllowedIPs` 覆盖的网段。
- **Windows TUN 断网保护**：独立 WireGuard 开启 TUN 时按 `AllowedIPs` 写入系统路由，单对端 `/0` 配置自动启用会话断网保护；链式模式不启用该保护，以保留未命中 `AllowedIPs` 的物理网络直连。
- **IPv6** 独立 WireGuard 接管 TUN / VPN 时，纯 IPv6 配置会自动接管 IPv6。Android 双栈配置的 IPv6 接管由「启用 IPv6」开关控制。

## 从源码构建

### 环境要求

- Flutter `3.50.1`
- Go `1.26.9+`
- PowerShell `7`

```bash
git submodule update --init --recursive
flutter pub get
```

### 平台打包

| 目标平台 | 依赖 | 打包命令 |
| :--- | :--- | :--- |
| **Windows x64** | 在 Windows 构建。需要 Visual Studio（使用 C++ 的桌面开发工作负载）、Windows SDK、NSIS 3.x，并启用开发者模式 | `pwsh ./scripts/package-windows.ps1` |
| **Android ARM64** | 在 Windows 构建并启用开发者模式。需要 JDK 21+（`JAVA_HOME`）、Android SDK Platform 36（`ANDROID_HOME`）、Build Tools `36.0.0`、NDK `28.2.13676358` | `pwsh ./scripts/package-android.ps1` |
| **Linux x64** | 在 x86_64 Linux 构建，CI 使用 Ubuntu 24.04 LTS。需要 Clang、CMake、Ninja、pkg-config、`libgtk-3-dev`、`libsecret-1-dev`、`libstdc++-12-dev` 和 `dpkg-deb` | `pwsh ./scripts/package-linux.ps1` |

- 打包脚本使用最新稳定版 sing-box 官方 Go 模块构建核心，并同步最新 GeoSite 与 GeoIP。开发用的 sing-box 子模块供本地运行时开发与测试使用。Android 构建会从同一套 Go 依赖编译 `gomobile` 和 `gobind`。
- 打包产物及 SHA-256 校验文件默认输出至 `dist/`。正式发布应从已提交的干净工作区构建。本地 Android Release 构建默认使用调试签名，正式 APK 由发布工作流签名。[GitHub Actions 发布工作流](.github/workflows/release.yml)

## 问题反馈

提交 Issue 时请附带应用与系统版本、接管方式（VPN / 系统代理 / TUN）、复现步骤以及脱敏后的运行日志。

## 许可证

本项目按 GPL-3.0-or-later 开源。第三方组件与规则集的许可见随附声明。[项目许可证](LICENSE) · [第三方许可声明](third_party/THIRD_PARTY_NOTICES.md)
