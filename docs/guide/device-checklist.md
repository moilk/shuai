# 真机首次测试清单

给第一次在真实 iPad 上跑 shuai 的人，也覆盖 [ADR 0001](../adr/0001-terminal-engine.md) 中 “Pending manual IME test” 的中文输入法验证。每项包含：怎么测、预期、复选框。建议准备：装有 tmux 与 Claude Code 的 Linux 服务器、Magic Keyboard 或 Smart Keyboard、已装的 ntfy App。

先按 [安装指南](install-ipad.md) 装好，按 [快速上手](getting-started.md) 连上主机并进入 tmux。

## A. 中文拼音输入法（IME）

终端处于焦点（先点一下终端），**软键盘**和**硬件键盘**各测一遍。切到「简体拼音」。

- [ ] **A1 候选窗位置**：输入 `nihao`。预期：带下划线的 `ni hao` 预编辑内联出现在光标处（至少紧邻光标）；候选栏/弹窗不遮挡光标，也不停在屏幕角落。
- [ ] **A2 选词提交**：用空格 / 数字键 / 点选候选。预期：`你好` 只上屏一次并在终端回显；远端收到 UTF-8 `e4 bd a0 e5 a5 bd`（可用 DEBUG 包的 `-debugByteTap` 核对，见文末）。
- [ ] **A3 组合中退格**：输入 `nihao` 不选词，按 Backspace。预期：删除的是拼音字母，不是之前已提交的文字；Esc 取消组合。
- [ ] **A4 回车上屏**：输入长句拼音（如 `woxihuanshiyongzhongduan`），按 Enter 提交。预期：Enter 只上屏，**不会**向远端发送 `\r`（`-debugByteTap` 日志中没有多余的 `0d`）。
- [ ] **A5 组合态下的控制键**（硬件键盘）：输入法激活时按 Ctrl-C、方向键、Tab、Esc、Shift+方向键。预期：远端字节正确；Caps Lock/Shift 切换中英文不丢字。
- [ ] **A6 其它输入方式**：如果你用：Apple Pencil 手写（Scribble）、五笔/双拼；Globe 键表情选择器插入 😀。预期：不丢字、不重复，表情只插入一次。
- [ ] **A7 听写与粘贴中文**：听写一句话；粘贴一段中文。预期：文字正确到达；开启 bracketed paste 的程序（vim、Claude 等）收到括起来的粘贴。

## B. 硬件键盘

- [ ] **B1 快捷键全部生效**：终端聚焦时依次试 ⌘1–9、⌘T、⌘⇧W、⌘⇧[ / ⌘⇧]、⌘D、⌘⇧D、⌘⌥ 四个方向键、⌘⇧↩、⌘K、⌘⇧A，以及 ⌘N、⌘W、⌘R、⌘,。预期：每个都执行对应动作（列表见快速上手）；**远端没有收到对应字符**（在服务器上运行 `cat -v` 观察，或用 `-debugByteTap`）。
- [ ] **B2 Option 当 Alt**：Settings → Keyboard 打开 “Option key sends Alt”，在 shell 里按 Option+B / Option+F（readline 按词移动），在 vim 里试 Option+字母。预期：等同 Esc 前缀的 Alt；该设置对新开的会话生效。关闭后 Option 输出特殊字符。
- [ ] **B3 复制粘贴**：选中终端文字按 ⌘C，再按一次 ⌘V。预期：复制成功；粘贴**只出现一次**。
- [ ] **B4 缩放**：双指捏合，以及 ⌘+ / ⌘−。预期：字号平滑变化，行列数随之重算，tmux 重绘无错位。
- [ ] **B5 停靠/浮动栏切换**：软键盘弹出时键盘栏停靠在键盘上方；连接硬件键盘后变为紧凑浮动栏；断开后恢复。预期：切换不抖动、不丢焦点、不遮挡终端内容。

## C. 窗口与生命周期

- [ ] **C1 Stage Manager / 旋转**：调整窗口大小、横竖屏旋转。预期：网格列数合理，tmux 重绘，无乱码、无崩溃。
- [ ] **C2 后台与重连**：按 Home 键回主屏（或锁屏）等 1–2 分钟再返回。预期：自动重连并重新 attach 到同一 tmux 会话，之前运行的 Claude 仍在；屏幕重绘后内容正确。
- [ ] **C3 断网恢复**：开飞行模式 20 秒再关。预期：显示重连状态，网络恢复后自动恢复。

## D. Claude 集成与通知

前提：已对该主机执行 “Enable AI integration…”，并在服务器 tmux 里运行 `claude`。

- [ ] **D1 审批卡片 Allow**：让 Claude 做一件需要权限的事（如创建文件）。预期：右上角出现卡片；点 Allow，Claude 继续执行。
- [ ] **D2 审批卡片 Deny**：同上，点 Deny（可附消息）。预期：Claude 收到拒绝，不执行该操作。
- [ ] **D3 App 离线回落**：退出并杀掉 shuai，再让 Claude 请求权限。预期：Claude 立即在终端弹出自己的本地对话框，不卡住。
- [ ] **D4 徽章与跳转**：观察侧栏徽章随 工作/等待/完成 变化；⌘K、⌘⇧A 能跳到等待中的 pane。
- [ ] **D5 ntfy 推送**（需 `feat/push` 构建）：Settings 开启 Push，在 ntfy App 订阅 topic，“Send test notification” 能收到。然后把 shuai 切到后台或锁屏，让 Claude 请求权限。预期：几秒内收到 “Claude needs approval”；正文只有主机与 `会话 › 窗口序号`，默认不含窗口名。
- [ ] **D6 点击通知跳转**：点击上一条通知。预期：shuai 打开、连接该主机并选中正确的 pane。

## 如何反馈

- 通过的项打勾；失败的项请写明：设备型号与 iPadOS 版本、键盘类型（软键盘 / Magic Keyboard / 其他）、输入法、复现步骤、预期与实际（丢字/重复字符请写出具体内容）。
- **录屏**：用控制中心的屏幕录制。IME 与快捷键问题尤其需要录屏，要能看到候选窗位置。
- **字节级证据（仅 DEBUG 构建）**：以 Debug 配置从 Xcode 安装，并在 scheme 的 Arguments Passed On Launch 里加启动参数 `-debugByteTap`。它会用 NSLog 记录每次通道写入(W)/读取(R)的时间、长度与十六进制，用于核对 A2、A4、B1。Release 构建由 `scripts/check-no-debug-launch.sh` 保证不含该参数。日志可在 Xcode 的 Devices and Simulators 窗口查看；**它记录了你输入的字节，分享前请去掉敏感内容**。
- 问题提交到 GitHub issues：https://github.com/moilk/shuai/issues
