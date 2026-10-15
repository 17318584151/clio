# Clio 开发说明

## 本地构建

需要 Apple Silicon Mac 和 Apple Command Line Tools。构建脚本直接调用 Swift 编译器，生成应用包及原生 CodexHelper，并将辅助程序资源打包至应用内。

```bash
git clone https://github.com/UreMySunshine/clio.git
cd clio
bash Scripts/build.sh
```

构建产物为 `build/Clio.app`。`Package.swift` 提供 SwiftPM 项目配置；仅安装 Command Line Tools 时，清单编译可能因工具链环境失败，优先使用构建脚本。脚本会在当前 SDK 需要 SwiftUI 宏插件、但工具链未提供该插件时选择可用的旧 SDK。

若默认编译缓存目录不可写，可将缓存设在项目内：

```bash
CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" \
SWIFT_MODULECACHE_PATH="$PWD/build/ModuleCache" \
bash Scripts/build.sh
```

## 打包与签名

```bash
bash Scripts/package.sh
```

安装包为 `build/Clio-<版本>.dmg`，版本取自 `Resources/Info.plist`。默认使用临时签名，不包含 Apple 开发者公证。

使用 Apple Developer Program 账号进行分发签名与公证：

```bash
export CLIO_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)"
xcrun notarytool store-credentials clio --apple-id <邮箱> --team-id <TEAMID> --password <应用专用密码>
export CLIO_NOTARY_PROFILE=clio
bash Scripts/package.sh
```

`CLIO_SIGN_IDENTITY` 指定分发签名身份，`CLIO_NOTARY_PROFILE` 指定公证凭据。构建脚本签名应用及辅助程序，打包脚本提交安装包公证并装订票据。

## 回归测试

| 命令 | 验证范围 |
| --- | --- |
| `bash Scripts/test-usage-periods.sh` | 自然日周期和合并统计 |
| `bash Scripts/test-refresh.sh` | 刷新请求合并、统计缓存失效、额度重置及日志变更 |
| `bash Scripts/test-usage.sh` | 历史每日记录恢复、日志读取、双来源额度冲突、窗口重置、用量聚合及里程碑 |
| `bash Scripts/test-codex-usage.sh` | Codex 额度与重置次数、登录状态、只读协议及超时 |
| `bash Scripts/test-quota-ring.sh` | 菜单栏额度比例 |
| `bash Scripts/test-menubar.sh` | 菜单栏资源与截图 |
| `bash Scripts/test-ccusage-alignment.sh` | 日志去重、累计差值及周一边界 |
| `bash Scripts/test-codex-helper.sh` | 辅助服务安装、修复、升级、移除与回滚 |
| `bash Scripts/test-codex-helper-state.sh` | 辅助服务操作入口的状态判断 |

CodexHelper 测试使用临时文件与随机本机端口，不修改系统安装实例。

`bash Scripts/test-codex-usage.sh --live` 额外使用本机 Codex 的现有登录状态验证只读额度查询。

## 截图与数据检查

```bash
build/Clio.app/Contents/MacOS/Clio --dump
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots --sample-only -usageScope combined
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots/claude --sample-only -usageScope claudeCode
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots/codex --sample-only -usageScope codex
build/Clio.app/Contents/MacOS/Clio --snapshot build/screenshots/menubar --menubar-only
```

常规截图模式读取本机数据并检测辅助服务状态；`--sample-only` 使用内置示例数据，跳过数据刷新和服务检测。`sample-light.png`、`sample-dark.png` 为示例主面板，`panel-light.png`、`panel-dark.png` 为当前数据主面板。设置截图包含完整内容，不受实际窗口高度限制。离屏截图采用背景填充，不能体现实时桌面上的玻璃折射效果。

README 主面板使用示例图；设置使用常规模式生成的图片，以保持服务状态和按钮一致。使用应用包内可执行文件生成图片，可读取随包提供的图标。

## CodexHelper 版本与安装资源

辅助程序的独立版本定义在 `Tools/CodexHelper/Info.plist` 的 `CFBundleVersion`，使用整数。需要发布辅助程序更新时递增该值；仅修改 Clio 界面、安装脚本或重新构建时保留该值。

更新判断比较已安装与内置辅助程序版本，仅内置版本更高时提示更新。可识别的旧式服务保留迁移入口。文件摘要、文件权限及应用签名用于识别安装实例和验证完整性，不用于判断新版本。

安装涉及 Codex 用户目录中的 `.env`、系统 `hosts` 的受管理区块，以及 `local.codex.backend-relay` 后台服务。原生辅助程序安装在 `/Library/Application Support/CodexBackendRelay/CodexHelper.app`，仅监听本机 IPv4、IPv6 地址的 443 端口。系统 Python 用于安装、检测及移除，常驻转发由原生程序执行。

安装记录和备份位于服务目录。`helper-build.json` 保存文件摘要；安装失败时恢复本次变更，移除时保留用户后来修改的配置。Clio 支持目录中的 `codex-helper-result.txt` 保存最近一次操作结果。

## 统计与更新边界

用量解析按本机 ccusage 20.0.26 的源码核对：Claude Code 按消息与请求去重，Codex 优先使用请求增量，缺失时读取累计量的非负差值。统计仅包含现存本地日志。

自动更新校验 GitHub 提供的文件摘要、应用标识和版本号。未使用开发者签名的分发包，其来源可信度依赖发布仓库。
