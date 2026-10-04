# 快速上手

> 「后台通知（ntfy）」与 `shuai://` 深链接在分支 `feat/push` 中实现。若你的构建尚未合并该分支，设置里不会出现 “Background notifications”，第 9 节不适用。其余内容对应 `main`。

![shuai 主界面：侧栏、终端、审批卡片、键盘栏（演示数据）](../screens/integration.png)

## 1. 添加主机

主机列表 → “+”（或 ⌘N，New Host）。填写名称、主机/IP、端口、用户名，然后选择认证方式：

- **SSH key**：使用 App 内密钥库中的密钥。
- **Password**：保存到 Keychain。
- **Ask each time**：每次连接时询问，只保存在内存中，断开后清除；并且只会在**主机密钥校验通过之后**才询问。

### 生成或导入密钥

工具栏钥匙图标（或 Settings → Manage keys…）→ “+”：

- Generate ed25519 key / Generate ECDSA P-256 key：在 iPad 本机生成。
- Import from Files… / Paste private key…：导入已有私钥。支持 OpenSSH、PKCS#1（`-----BEGIN RSA PRIVATE KEY-----`，**AWS 下载的 `.pem` 就是这种格式**，含旧式 OpenSSL `DEK-Info` 加密）、PKCS#8（明文/加密）、SEC1（`EC PRIVATE KEY`）。有口令时会提示输入。

私钥保存在 iPadOS Keychain（仅本机、首次解锁后可用）。

### 把公钥复制到服务器

在密钥列表里复制公钥，追加到服务器的 `~/.ssh/authorized_keys`：

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<粘贴公钥>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

AWS 这类已绑定 `.pem` 的实例，直接导入该 `.pem` 即可连接，不必再复制公钥。

## 2. 首次连接：TOFU 提示

第一次连接某台主机时，App 会显示服务器主机密钥的指纹并询问是否信任（Trust On First Use）。这是在防中间人攻击：**请与服务器上 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 的指纹核对**后再接受。接受后指纹被记住；之后若指纹**变了**，App 会拒绝并单独提示，只有你明确确认才会替换旧记录（服务器重装，或确实有人在中间，都会触发）。

## 3. tmux 自动接入

默认开启 “Attach to tmux”，会话名默认 `shuai`。连接时 App 在 PTY 上执行 `tmux new -A -s '<name>'`：会话存在就接入，不存在就新建。网络断开后会自动重连并重新 attach，服务器上运行的 Claude 不受影响。

- **服务器没装 tmux**：命令返回 127（not found）时，App 在同一连接上改开普通登录 shell，并显示一条非阻塞提示。该会话后续重连不再尝试 tmux；手动重新连接会再试一次。
- 可在主机设置里关闭 tmux，或设置“启动命令”（会话创建时运行）。

## 4. 键盘栏与 Claude 条

软键盘上方有两行：

- 标准行：Esc、Ctrl、Alt（Ctrl/Alt 是粘滞修饰键）、Tab、方向键、`/ | ~ -`。
- **Claude 条**：`Yes` 发送 `1`，`Always` 发送 `2`，`No` 发送 `Esc`，`⇧Tab` 切换 Claude 模式，`Esc` 中断，`^C`，`/`。
  - Yes/Always 是对 Claude 权限对话框选第 1/2 项。在只有两个选项的对话框里第 2 项就是 No，所以点 Always 前请看清屏幕。`No` 发送 Esc（取消），永远不会误批准。
  - 不在对话框时，`1`/`2` 只是作为文字输入到提示符，可见且无害。
- 连接硬件键盘后，栏自动变为紧凑的浮动样式。Settings → Keyboard 可选 “Docked above keyboard / Floating” 以及 “Option key sends Alt”。

## 5. 硬件快捷键

终端获得焦点时由 App 优先处理，**不会同时发给远端**。默认值来自 `ShortcutMap.defaults`，菜单项来自 `ShuaiMain.swift`：

| 快捷键 | 动作 |
|---|---|
| ⌘1 … ⌘9 | 切到窗口列表中的第 N 个（按列表位置，不是 tmux 的 index，不受 `base-index` 影响） |
| ⌘T | 新建窗口 |
| ⌘⇧W | 关闭窗口（会先确认） |
| ⌘⇧[ / ⌘⇧] | 上一个 / 下一个窗口 |
| ⌘D | 向右分屏 |
| ⌘⇧D | 向下分屏 |
| ⌘⌥← ↑ ↓ → | 在 pane 间移动 |
| ⌘⇧↩ | 放大/还原当前 pane（zoom） |
| ⌘K | 快速切换器（模糊搜索，等待你的 agent 排最前） |
| ⌘⇧A | 跳到下一个需要处理的 agent（审批 > 等输入 > 失败 > 未读完成，跨主机循环） |
| ⌘N | 新建主机 |
| ⌘W | 断开当前连接（Session 菜单） |
| ⌘R | 重新连接（Session 菜单） |
| ⌘, | 打开设置 |
| ⌘+ / ⌘− 或双指捏合 | 缩放终端字体 |

绑定表支持 JSON 形式的自定义（`{"newWindow": "cmd+t", ...}`），但目前没有设置界面，以默认值为准。

## 6. 侧栏树与徽章

侧栏结构：主机 → tmux 会话 → 窗口 → pane，与服务器上的 tmux 实时一致（通过第二条 `tmux -C` 控制通道，不会移动你的终端）。每个节点右侧有 agent 状态徽章，会话/窗口取其下 pane 中最高优先级者：

| 图标 | 含义 | 优先级 |
|---|---|---|
| 手 | needs approval，等待审批 | 最高 |
| 问号气泡 | needs input，等待输入 | |
| 警告三角 | failed，失败 | |
| 齿轮 | working，工作中 | |
| 对勾 | done，完成 | |
| 月亮 | idle，空闲 | 最低 |

主机行右侧的橙色数字是“正在等你”的数量。主机行还显示 AI integration 的版本；显示未安装或过旧时，见下一节。

## 7. 启用 AI 集成（Enable AI integration…）

不启用时 shuai 仍是完整的 tmux SSH 终端；启用后才有徽章与原生审批。主机列表中长按主机 → **Enable AI integration…**（需已连接）。先预览，再逐步执行，在服务器上做这些事：

1. 探测 `uname -sm` 与 tmux 版本，上传匹配架构的 `shuai-agent` 到 `~/.shuai/bin/shuai-agent` 并设为可执行。
2. 安装 Claude Code 插件：`claude plugin marketplace add moilk/shuai && claude plugin install shuai@shuai`。主机访问不了 GitHub 时，退回到上传本地 marketplace 到 `~/.shuai/plugin-marketplace`；没有 `claude` 命令时，把 hooks 合并进 `~/.claude/settings.json`（不会覆盖你自己的 hooks，并保留 `.shuai-bak` 备份）。
3. 向 `~/.tmux.conf` 追加一个带标记的块，按 tmux 版本包含：`set -g allow-passthrough on`（>= 3.3）、`set -g set-titles on`、`set -g extended-keys on`（>= 3.2），tmux 服务器在运行时会 `source-file`。
4. 检测到 Codex 时配置其 `notify`（已有其他 notify 会询问是否替换，原文件备份为 `config.toml.shuai-bak`）。
5. 运行 `shuai-agent doctor` 自检。

**卸载**：同一菜单的 **Remove AI integration…**。会移除 Claude 插件及 hooks、`~/.tmux.conf` 中带标记的块（移除后文件为空则删除该文件）、Codex 的 notify，停止 agent，并删除整个 `~/.shuai`（含运行时状态）和 Claude 的 shuai 插件缓存。你自己的其它配置不动。

## 8. 审批卡片

Claude 请求权限（如 Bash 命令、编辑文件）时：

- **App 在线并连接着该主机**：右上角出现审批卡片，显示工具名、命令/diff 预览和工作目录，可附一条给 Claude 的消息，点 Allow 或 Deny，Claude 立刻继续。
- **App 不在线**（没有 shuai 在监视这台主机）：agent 发现无人在场，**立即退出且无输出**，Claude 照常弹出自己的本地对话框，不会卡住。App 在线但你一直没响应时，agent 最多等待约 110 秒，之后同样回落到本地对话框。
- 你始终可以用键盘栏的 Yes/Always/No 直接回答终端里的对话框。

## 9. 后台通知（ntfy）

> 需要包含 `feat/push` 的构建。

iOS 不允许 App 在后台长期保持 SSH 连接，所以 v1 用 [ntfy](https://ntfy.sh) 做后台推送，**设计上只推送状态**：

1. Settings → Background notifications → 打开 “Push notifications (ntfy)”。默认服务器 `https://ntfy.sh`，并自动生成随机私密 topic（`shuai-` + 26 位，128 bit，存在 Keychain）。
2. 从 App Store 安装官方 **ntfy** iOS App（免费），在 shuai 里点 “Open in ntfy app” 订阅该 topic（或手动订阅）。
3. 点 “Send test notification” 验证。
4. 让主机拿到配置：连接时自动同步；改动后可点 “Sync to connected hosts”，或在主机菜单选 “Sync notification settings”。

行为：没有 shuai 窗口在监视时，服务器上的 agent 发出 “Claude needs approval / Claude is waiting for input / Claude finished” 之类的推送，正文只有主机名与 tmux `会话 › 窗口序号`。点击通知会打开 `shuai://open?host=<id>&pane=<%N>`，App 连接对应主机并跳到那个 pane。

- **窗口名默认不发送**：tmux 自动重命名会把窗口名设成正在运行的命令（如 `vim secrets.env`、`ssh prod-db`），可能泄露内容。需要时在设置里打开 “Include tmux window names”。
- 在公共 ntfy.sh 上，**知道 topic 的人就能读到这些状态消息**，所以 topic 要保密；“New topic” 可轮换（需在 ntfy App 重新订阅）。也可填自建服务器和 access token。使用 `http://` 时会有明文警告。
- 同一次审批的两条事件在 60 秒内合并为一条推送；其它推送每会话至多每 10 秒一条。

## 10. 隐私说明

- App 与服务器之间是**直连 SSH，没有任何中转服务器**。
- shuai 本身不上传数据，没有遥测。
- 唯一的第三方是 ntfy，且只在你开启后台通知时使用；它只会收到上述状态文本（标题 + 主机名 + 会话/窗口序号），**从不包含命令、提示词、助手消息或路径**。可改用自建 ntfy。
- 私钥与密码存在 iPadOS Keychain（仅本机）；“Ask each time” 的密码只在内存中。
