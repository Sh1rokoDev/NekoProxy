# Third-party notices

NekoProxy 以 GPL-3.0-or-later 发布。下列组件随二进制或客户端一起分发，其版权与许可归各自作者所有。

## sing-box

- 项目：https://github.com/SagerNet/sing-box
- 版本：v1.14.4
- 许可：GPL-3.0-or-later
- 用途：唯一的代理核心，以自有 worker / gomobile 桥接方式集成。

## Flutter 与 Dart

- 项目：https://github.com/flutter/flutter
- 许可：BSD-3-Clause
- 用途：跨平台界面与运行时。

## v2fly GeoSite / GeoIP 规则集

- GeoSite 来源为 [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)，按 MIT 许可证分发。Copyright (c) 2018-2019 V2Ray.
- GeoIP 来源为 [v2fly/geoip](https://github.com/v2fly/geoip)，按 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) 分发，包含 [IP Geolocation data by DB-IP](https://db-ip.com/)（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）。
- NekoProxy 将上游完整数据库转换为 sing-box SRS 并随安装包分发。安装包中的规则清单记录上游发布版本及 SHA-256。

### GeoSite MIT 许可

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Wintun

- 项目：https://www.wintun.net/
- 版本：0.14.1（预编译 `wintun.dll`）
- 许可：见 `third_party/wintun-LICENSE.txt`
- 用途：Windows TUN 虚拟网卡。Wintun 作为独立组件随应用分发，NekoProxy 仅通过公开 API 使用它。

## Microsoft Visual C++ 运行库

- 组件：`MSVCP140.dll`、`VCRUNTIME140.dll`、`VCRUNTIME140_1.dll` 等 Visual Studio 可再发行组件。
- 来源：构建机 Visual Studio 提供的 x64 Redistributable 文件，未做修改。
- 许可：Microsoft Visual Studio 可再发行组件条款；以 app-local 方式随 Windows 包分发。
- 用途：Flutter Windows 客户端、插件与运行组件所需的 C++ 运行库，使便携包不依赖目标机器预装 VC++ Redistributable。

## Gradle / Android 依赖

Android 构建使用 AndroidX、Kotlin 与 Flutter 插件生态中的第三方库，具体版本见 `pubspec.lock` 与 Gradle 依赖解析结果。这些库按其各自许可分发。

## Dart / Flutter 运行库

完整依赖与版本见 `pubspec.lock`，应用内“开源许可证”页面会列出 Flutter 收集的全部许可。主要直接依赖包括：

- `cryptography`：Apache-2.0，用于 AES-GCM 与 PBKDF2。
- `flutter_secure_storage`：BSD-3-Clause，用于保存本机状态密钥。
- `file_picker`：MIT，用于导入导出文件。
- `image`：MIT，用于读取二维码图片。
- `zxing2`：BSD-3-Clause，用于离线二维码解码。
- `win32_registry`：MIT，用于 Windows 开机启动与系统代理设置。
- `flutter_svg`：MIT，用于本地显示厂商服务图标。

## 服务状态厂商图标

- 用途：首页与“服务状态”页仅用于标识对应网络服务。
- 来源与许可：
  - SVG Logos / Simple Icons：CC0-1.0，https://github.com/gilbarbara/logos、https://github.com/simple-icons/simple-icons
  - selfh.st/icons：CC BY 4.0，https://github.com/selfhst/icons
  - theSVG Color：MIT，https://github.com/glincker/thesvg
  - Gemini 星形标志取自 Google 官方静态资源：https://www.gstatic.com/lamda/images/gemini_sparkle_v002_d4735304ff6292a690345.svg
- Google、GitHub、YouTube、OpenAI/ChatGPT、Claude、Gemini、Netflix、Disney+、Prime Video、Spotify、TikTok、Discord、bilibili 等名称与标志的商标权归各自所有者所有。
