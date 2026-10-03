# shuai

开源 (MIT)、iPad 优先、直连无中转的「agent 感知 SSH 终端」。

## 定位

- 真终端 + tmux 原生化窗口管理，充分利用 iPad 大屏、硬件键盘与 Stage Manager。
- 不包装 CLI：通过 Claude Code plugin + hooks 感知会话，用户照常在 tmux 里运行 `claude` / `codex`。
- Agent 会话仪表盘：每个 tmux pane 的状态（工作中 / 等审批 / 等输入 / 完成）、一键跳转、原生审批。
- 数据不经第三方云；后台推送 v1 使用 ntfy。

## 架构

- `core/`：Rust workspace（平台无关）。`shuai-proto`、`shuai-keys`、`shuai-ssh`、`shuai-tmux`、`shuai-agentkit`、`shuai-ffi`（UniFFI 导出层）、`shuai-agent`（服务端 musl 静态二进制）。
- `apple/ShuaiKit`：Swift Package，封装 `ShuaiCoreFFI.xcframework` 与生成的 Swift 绑定。
- `apple/App`：iPad App（XcodeGen）。
- `plugin/`：Claude Code plugin。`android/`：预留。`docs/`：ADR 与里程碑计划。

## 构建

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cargo test --workspace --manifest-path core/Cargo.toml   # Rust 测试
scripts/build-xcframework.sh                              # 生成 xcframework + Swift 绑定
(cd apple/ShuaiKit && swift test)                         # Swift 包测试 (macOS)
(cd apple/App && xcodegen generate && xcodebuild test -scheme Shuai \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)')
```

## English summary

shuai is an open-source (MIT), iPad-first, direct-connect (no relay) SSH terminal that is aware of AI coding agents (Claude Code / Codex) running inside tmux. A shared Rust core (russh, UniFFI) powers native UI per platform (SwiftUI/UIKit on iPad, Compose on Android later). A small static Rust binary, `shuai-agent`, runs on the server and is driven by Claude Code plugin hooks. See the build instructions above.
