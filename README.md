<p align="center">
  <img src="assets/icons/app_icon.png" width="96" height="96" alt="NekoProxy">
</p>

<h1 align="center">NekoProxy</h1>

<p align="center">
  面向 Android 与 Windows 的 <a href="https://github.com/SagerNet/sing-box">sing-box</a> 图形客户端。
</p>

## 特性

- 订阅与节点管理：支持 sing-box JSON、Base64 订阅、分享链接及二维码导入（Android 支持相机扫码），提供分组、筛选排序、测速自动选点与订阅流量统计
- 路由分流：支持规则 / 全局 / 直连模式，可按域名、IP、进程或应用包名自定义规则；内置 v2fly GeoSite / GeoIP，支持应用内更新
- WireGuard 出站：支持独立出站，或作为前置跳点与 sing-box 节点组成双跳链式代理
- 监控与备份：实时速率、活动连接、日志、完整 sing-box 配置预览与加密备份导出；Material 3 界面，支持明暗主题
- 连通性检测：检测常用服务延迟与可用性，服务与出口 IP 归属通过 [IPQuery](https://ipquery.io/developers/api) 查询

## 安装

从 Releases 下载对应平台的构建产物：

- **Android (ARM64)**：`*-android-arm64.apk`
- **Windows (x64)**：`*-windows-x64-setup.exe`（安装版）或 `*-windows-x64.zip`（便携版），安装与运行均需**管理员权限**

## 支持协议

| 协议 | URI 前缀 / 导入方式 |
| :--- | :--- |
| Shadowsocks | `ss://` |
| VMess | `vmess://` |
| VLESS (含 REALITY) | `vless://` |
| Trojan | `trojan://` |
| Hysteria 2 | `hysteria2://`、`hy2://`、`hy://` |
| TUIC | `tuic://` |
| AnyTLS | `anytls://` |
| SOCKS5 | `socks://`、`socks5://` |
| HTTP / HTTPS | `http://`、`https://` |
| WireGuard | `.conf` 文件 / 表单 / 二维码（支持导出含密钥 `.conf`） |

## 流量接管与路由

- **Android**：使用单个系统 VPN 接管流量，支持按应用过滤；关闭 VPN 时可仅使用本地代理端口。
- **Windows**：系统代理与 TUN 独立控制。仅开启系统代理时，出站默认遵循系统路由且代理绕过列表仅包含回环地址，其余流量交由规则引擎处理。
- **运行时切换**：核心运行期间，系统代理支持热切换；变更 TUN / VPN 会重启核心（现有连接将短暂中断）。核心停止时切换仅保存配置。
- **默认规则**：规则模式内置可编辑的「私网地址直连」规则，规则页同步展示核心生成的接管规则与默认出站。

## WireGuard 与链式代理

WireGuard 节点独立分组，不参与 sing-box 自动选点。除单独使用外，支持开启链式代理（`WireGuard -> sing-box`）：第一跳为手动选择的 WireGuard 节点，第二跳仍由 sing-box 手动或自动选点，连接后首页通过 IPQuery 分别展示第一跳对端 IP 与最终出口地区。

- **路由与故障策略**：链式模式下，直连目标 IP 与第二跳代理服务器 IP 均按 WireGuard 的 `AllowedIPs` 决定是否进入隧道；命中地址在隧道故障时不会回退到物理网络。
- **局域网直连**：链式模式下，TUN 的「局域网直连」仅排除未被 `AllowedIPs` 覆盖的局域网段，其余地址仍由规则与 WireGuard 处理。
- **Windows TUN 与断网保护**：独立 WireGuard 开启 TUN 时按 `AllowedIPs` 写入系统路由，单对端 `/0` 配置自动启用会话断网保护；关闭 TUN 则仅接管系统代理或本地端口流量。链式模式不启用该保护，以便未命中 `AllowedIPs` 的流量继续走物理网络。
- **IPv6 接管**：双栈配置遵循 TUN 的 IPv6 开关；纯 IPv6 配置会自动接管 IPv6。

## 从源码构建

### 环境要求

- Flutter `3.50.0`
- Go `1.26+`
- PowerShell `7`

```powershell
git submodule update --init --recursive
flutter pub get
```

### 平台打包

| 目标平台 | 平台依赖 | 打包命令 |
| :--- | :--- | :--- |
| **Windows x64** | Visual Studio（C++ 桌面开发工作负载）、Windows SDK、NSIS 3.x、开启开发者模式 | `pwsh ./scripts/package-windows.ps1` |
| **Android ARM64** | JDK 21+ (`JAVA_HOME`)、Android SDK 36 (`ANDROID_HOME`)、NDK `28.2.13676358`、`gomobile` / `gobind` | `pwsh ./scripts/package-android.ps1` |

安装 `gomobile` 与 `gobind`：

```powershell
$mobileVersion = 'v0.0.0-20261011034528-197770444867'
go install "golang.org/x/mobile/cmd/gomobile@$mobileVersion"
go install "golang.org/x/mobile/cmd/gobind@$mobileVersion"
```

### 构建说明

- 打包脚本每次均从 GitHub Releases 拉取最新稳定版 `sing-box`、GeoSite 与 GeoIP，在临时目录基于官方 Go 模块编译核心，不改动开发用子模块与依赖锁文件；上游版本确认或拉取失败时中止构建。
- 规则集仅在上游标签、文件大小、校验值及转换核心版本完全一致时复用缓存。
- 安装包及 SHA-256 校验文件统一输出至 `dist/`，Release 构建要求工作区干净（无未提交变更）。
- 本地 Android 构建默认使用调试签名，正式版由 [GitHub Actions](.github/workflows/release.yml) 签名发布。

## 问题反馈

提交 Issue 时请附带应用与系统版本、流量接管方式（VPN / 系统代理 / TUN）、复现步骤及**脱敏后**的运行日志。

## 许可证

本项目基于 [GPL-3.0-or-later](LICENSE) 开源，第三方组件与规则集授权见 [THIRD_PARTY_NOTICES.md](third_party/THIRD_PARTY_NOTICES.md)。