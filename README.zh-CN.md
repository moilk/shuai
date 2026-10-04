# shuai

[English](README.md)

**感知 AI 编程的 iPad SSH 终端。** shuai 是一个带原生 tmux 导航的真终端，并且知道服务器上各个 Claude Code
会话在做什么：哪个在工作、哪个在等你审批、哪个已完成。App 通过 SSH 直连你的服务器，没有中转，也没有
shuai 云服务。以 MIT 许可证开源。

![shuai（演示数据）：带 agent 徽章的 tmux 侧栏、终端、原生审批卡片、Claude 快捷键条](docs/assets/integration.png)

## 特点

- **感知 agent，而不是包装 CLI**：你照常在 tmux 里运行 `claude`。Claude Code 插件把 hook 事件交给服务器上的
  小程序 `shuai-agent`，App 据此显示徽章、跳转到需要处理的会话，并提供原生审批卡片。
- **iPad 优先**：libghostty 渲染、内联输入法（含中文拼音）、硬件键盘快捷键、台前调度、Claude 对话框快捷键条。
- **SSH 直连，无中转**：iPad 与服务器之间没有任何第三方。可选的后台通知走 ntfy，且只包含状态。
- **MIT**：App、Rust 核心、服务端 agent 与插件全部开源。

## 功能

- 主机管理：密码 / 密钥 / 键盘交互认证；生成 ed25519 / ECDSA 密钥；导入 OpenSSH、PKCS#1（含 AWS `.pem`）、
  PKCS#8、SEC1 私钥；私钥存于 Keychain。
- 首次信任（TOFU）主机密钥校验（密钥变化须明确确认）、keepalive、断线自动重连。
- tmux：自动 `tmux new -A -s <name>`，无 tmux 时回落到普通 shell；侧栏实时显示会话 / 窗口 / pane 树；
  ⌘K 快速切换器与硬件快捷键。
- 终端：内联输入法、CJK 与 emoji、鼠标、bracketed paste、OSC 52（需确认）与 OSC 9/777、捏合与 ⌘± 缩放、
  Option 当 Alt、深浅主题。
- 键盘栏与 Claude 条（Yes = `1`、Always = `2`、No = Esc、⇧Tab、中断），接入硬件键盘时自动切换为浮动样式。
- 一键 **Enable AI integration**：通过 SSH 安装 `shuai-agent`、Claude Code 插件和 tmux 配置块，并可完整卸载。
- 每个 pane 的 agent 徽章；⌘⇧A 跳到下一个需要你处理的 agent。
- 原生审批卡片（Allow / Deny，可附消息）；没有 App 在线时 Claude 立即回落到自己的本地对话框。
- 通过 `notify` 支持 Codex（回合完成）。
- 经 ntfy 的仅状态后台推送，点击通过 `shuai://` 深链接跳到对应 pane。

## 工作原理

终端是运行在 PTY 通道里的 tmux；第二条通道以控制模式运行 tmux，使侧栏与服务器保持同步。Claude Code 的
hook 把事件追加到 `~/.shuai/events.jsonl`，App 在同一条 SSH 连接上用 `shuai-agent watch` 读取事件，并用
`shuai-agent respond` 回答审批请求。详见 [Architecture](docs/design/architecture.md)（英文）。

## 从源码构建

shuai 尚未上架 App Store。可以用免费 Apple ID 构建并安装到自己的 iPad（7 天后需在 Xcode 中重新签名）：

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin \
  x86_64-unknown-linux-musl aarch64-unknown-linux-musl
brew install xcodegen zig && cargo install cargo-zigbuild --locked

scripts/build-agent.sh            # 服务端 agent 二进制，打包进 App
scripts/build-xcframework.sh      # Rust 核心与 Swift 绑定
cp apple/App/Local.xcconfig.example apple/App/Local.xcconfig   # 填写你的 Team 与 Bundle ID
cd apple/App && xcodegen generate && open Shuai.xcodeproj
```

完整步骤、iPad 设置与故障排查见 [Installation](docs/user/installation.md)，之后阅读
[Getting started](docs/user/getting-started.md)。

## 文档

全部文档（目前为英文）见 [docs/README.md](docs/README.md)。

## 状态与路线

v1 功能已完成，真机验证（输入法、硬件键盘、后台推送）待进行。接下来：图片上传粘贴、SFTP 浏览、Secure
Enclave 密钥、主机 iCloud 同步、快捷键自定义。之后：APNs 中继与 Live Activities、clean-room mosh 兼容传输、
原生 tmux 分屏、Android App。见 [Roadmap](docs/roadmap.md)。

## 参与贡献

欢迎提交 issue 与 PR，请先阅读 [Contributing](docs/development/contributing.md)。

## 许可

[MIT](LICENSE)
