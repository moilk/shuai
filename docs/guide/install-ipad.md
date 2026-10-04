# 在真实 iPad 上安装（免费 Apple ID）

shuai 目前没有上架 App Store，也不需要付费开发者账号：用免费 Apple ID 从 Xcode 直接签名安装到自己的 iPad 即可。代价是免费账号签发的描述文件**只有 7 天有效期**（见下文）。

## 前置条件

| 项目 | 说明 |
|---|---|
| Mac + Xcode 27 | 作者本地使用 Xcode 27；CI 使用 Xcode 26.6。若 `xcode-select` 指向 CommandLineTools，先执行 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| iPad，iPadOS 18+ | 工程最低部署目标为 18.0，仅 iPad（`TARGETED_DEVICE_FAMILY: 2`） |
| Rust 工具链 | 通过 rustup 安装，并添加目标：`rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl` |
| xcodegen | `brew install xcodegen` |
| zig + cargo-zigbuild | 用于交叉编译服务端 `shuai-agent`：`brew install zig`，`cargo install cargo-zigbuild --locked` |
| 免费 Apple ID | 在 Xcode → Settings → Accounts 登录 |

## 步骤

在仓库根目录执行：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 1. 交叉编译服务端 agent（x86_64 与 aarch64 的 Linux musl 静态二进制），
#    输出到 apple/App/Resources/agent/（已 gitignore），会被打包进 App
scripts/build-agent.sh

# 2. 构建 Rust 核心的 xcframework 与 Swift 绑定（普通模式）
scripts/build-xcframework.sh

# 3. 生成 Xcode 工程（.xcodeproj 不入库）
cd apple/App && xcodegen generate
open Shuai.xcodeproj
```

> **警告：绝对不要用 `SHUAI_FFI_TESTKIT=1` 构建出的 xcframework 安装或分发。**
> 该模式会把一个带硬编码账号密码的进程内 SSH 服务器编进应用，仅供开发/CI 测试。
> 普通模式下 `build-xcframework.sh` 结束时会自动运行 `scripts/check-no-testkit.sh`，发现测试套件符号会直接失败。
> 如果你之前跑过 testkit 模式，重新执行不带该环境变量的 `scripts/build-xcframework.sh` 即可覆盖。

Release 配置下，若缺少 `apple/App/Resources/agent/shuai-agent-*` 二进制，构建会报错（预构建脚本检查）；Debug 配置只给警告，但此时 App 无法执行「Enable AI integration」。

### 配置签名（一次性）

签名设置放在 `apple/App/Signing.xcconfig`（入库，默认真机构建不签名）和你自己的 `apple/App/Local.xcconfig`（已 gitignore，不会被提交，也不会被 `xcodegen generate` 覆盖）里。**不要在 Xcode 的 Signing 页面里手改**：`.xcodeproj` 是生成的，下次 `xcodegen generate` 就会丢失。

1. 复制模板：
   ```bash
   cp apple/App/Local.xcconfig.example apple/App/Local.xcconfig
   ```
2. 编辑 `apple/App/Local.xcconfig`：
   - `DEVELOPMENT_TEAM`：你的 Team ID（Xcode → Settings → Accounts → 选中 Apple ID → 你的 Personal Team；免费账号即可）。
   - `SHUAI_BUNDLE_ID`：一个你自己的唯一 Bundle ID，例如 `io.github.<你的名字>.shuai`。默认的 `io.github.moilk.shuai` 已被占用，免费账号会报 “Failed to register bundle identifier”。测试 target 自动使用 `<SHUAI_BUNDLE_ID>.tests` / `.uitests`，不需要装到设备。
   - `CODE_SIGNING_ALLOWED = YES` 保持不变。
3. 重新生成工程：`cd apple/App && xcodegen generate`，打开 `Shuai.xcodeproj`，Signing 页面应显示你的 Team 且无报错。

### iPad 端设置

1. USB 或无线连接 iPad，在 Xcode 顶部选择它为运行目标。
2. **开启开发者模式**：设置 → 隐私与安全性 → 开发者模式 → 打开，按提示重启并确认。（首次连接 Xcode 后该选项才会出现。）
3. 点 Run（⌘R）安装。首次运行会提示“不受信任的开发者”：设置 → 通用 → VPN 与设备管理 → 在“开发者 App”下选择你的 Apple ID → 信任。
4. 再次从主屏幕打开 shuai。

## 7 天限制与重新签名

免费账号的描述文件 7 天后过期，过期后 App 无法启动（图标仍在）。处理方法：

- 用 Xcode 再 Run 一次即可。同一 Bundle ID 会就地更新，**主机配置与 Keychain 里的密钥会保留**。
- 重新 Run 前不需要重跑 `build-agent.sh` / `build-xcframework.sh`，除非你更新了代码。
- 免费账号对每周新注册 App ID 的数量和同时安装的自签 App 数量有限制，不要频繁改 Bundle ID。
- 删除 App 会同时删除其 Keychain 项（即已保存的私钥），删除前请备份密钥。

## 故障排查

| 现象 | 处理 |
|---|---|
| Keychain 错误 `-34018`（errSecMissingEntitlement） | 应用没有被签名。真机请确认 `apple/App/Local.xcconfig` 已设置 `DEVELOPMENT_TEAM` 且 `CODE_SIGNING_ALLOWED = YES`，并重新 `xcodegen generate`；模拟器构建由 `project.yml` 做 ad-hoc 签名，无需处理 |
| “Failed to register bundle identifier” / “No profiles for ‘io.github.moilk.shuai’ were found” | 在 `Local.xcconfig` 里把 `SHUAI_BUNDLE_ID` 改成自己的唯一值，确认 `DEVELOPMENT_TEAM` 正确，然后重新 `xcodegen generate` |
| “不受信任的开发者” / App 打不开 | 设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书 |
| Xcode 里看不到 iPad / 提示需要开发者模式 | 先连线并“信任此电脑”，再到设置中开启开发者模式并重启 |
| 7 天后 App 一启动就退出 | 描述文件过期，重新 Run 一次 |
| 构建报 `Bundled agent binaries missing` | 先运行 `scripts/build-agent.sh`（需要 zig 与 cargo-zigbuild） |
| 链接/绑定缺失 | 先运行 `scripts/build-xcframework.sh`（输出在 `apple/ShuaiKit/ShuaiCoreFFI.xcframework`，已 gitignore） |
| 命令行报 CommandLineTools 相关错误 | 设置 `DEVELOPER_DIR`，或 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |

安装完成后请继续阅读 [快速上手](getting-started.md)，并在首次真机会话中对照 [真机测试清单](device-checklist.md)。
