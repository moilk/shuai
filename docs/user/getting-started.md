# Getting started

![Main window with fixture data: tmux sidebar with badges, terminal, permission card and Claude key strip](../assets/integration.webp)

## 1. Add a host

Tap **+** in the sidebar toolbar (or press ⌘N, "New Host"). Enter a name, host or IP, port and
user name, then pick an authentication method:

- **SSH key**: a key from the app's key library.
- **Password**: stored in the Keychain.
- **Ask each time**: asked on every connect, kept in memory only and cleared on disconnect. The
  prompt appears only *after* the server's host key has been verified.

Keyboard-interactive authentication (for example one-time codes) is answered in a prompt.

## 2. Keys

Open the key library with the key icon in the toolbar (or Settings > SSH > Manage keys…), then
**Add Key**:

- **Generate ed25519 key** / **Generate ECDSA P-256 key**: created on the iPad.
- **Import from Files…** / **Paste private key…**: supported formats are
  - OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`), plain or passphrase-protected;
  - PKCS#1 RSA (`-----BEGIN RSA PRIVATE KEY-----`), including legacy OpenSSL `DEK-Info`
    encryption (this is the format of AWS-generated `.pem` files);
  - PKCS#8 (`PRIVATE KEY` / `ENCRYPTED PRIVATE KEY`);
  - SEC1 (`EC PRIVATE KEY`).

  Encrypted keys ask for their passphrase once; the key is then stored decrypted in the iPad's
  Keychain (this device only, available after first unlock).

Copy or share a key's public line from the list and append it to `~/.ssh/authorized_keys` on the
server:

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<public key line>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

For a cloud instance that was created with a `.pem` key pair, importing that `.pem` is enough.

## 3. First connection: trust on first use

On the first connection to a host the app shows the server's host key fingerprint and asks
whether to trust it. Compare it with the server's own fingerprint before accepting, for example:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Accepted keys are remembered. If a host's key later **changes**, the connection is refused with a
separate warning, and the old entry is replaced only if you explicitly confirm (expected after a
server reinstall; otherwise treat it as a possible man-in-the-middle).

## 4. tmux

"Attach to tmux" is on by default with the session name `shuai`. On connect the app runs
`tmux new -A -s '<name>'` directly on the PTY channel: it attaches if the session exists and
creates it otherwise. An optional **Startup command** runs only when the session is created.

- **Reconnect**: when the network drops or the app returns from the background, shuai reconnects
  and reattaches to the same session. Programs on the server (Claude included) keep running.
- **No tmux on the server**: if `tmux` is not found, the app opens a plain login shell on the same
  connection and shows a non-blocking notice. Later automatic reconnects of that session skip
  tmux; a fresh connect tries tmux again.
- Turn tmux off per host in the host editor.

The sidebar shows host > tmux session > window > pane and stays in sync with the server through a
separate control channel; see [tmux integration](../design/tmux-integration.md). Context menus on
windows and panes offer rename, new window, split right/down and close (closing always asks).

## 5. Keyboard bars

Above the software keyboard there are two rows:

- **Standard row**: Esc, Ctrl, Alt (sticky: tap for the next key, double-tap to lock), Tab, arrow
  keys (auto-repeat), `/ | ~ -`.
- **Claude strip**: **Yes** sends `1`, **Always** sends `2`, **No** sends Esc, **⇧Tab** cycles
  Claude's mode, **Esc** interrupts, **^C**, **/**.
  - Yes/Always pick option 1/2 of Claude's permission dialog. In a two-option dialog option 2 is
    "No", so read the screen before tapping Always. **No** sends Esc, the dialog's own cancel, and
    can never approve anything.
  - Outside a dialog, `1` and `2` are typed into the prompt as visible text.

With a hardware keyboard attached the bar switches to a compact floating style automatically.
Settings > Keyboard has **Accessory bar** (Docked above keyboard / Floating) and
**Option key sends Alt (Esc prefix)** (on by default; applies to sessions opened afterwards).

Hardware shortcuts are listed in [Keyboard shortcuts](keyboard-shortcuts.md).

## 6. Terminal

- Pinch or ⌘+ / ⌘− zooms an open terminal; Settings > Terminal sets the default font size and the
  theme (Dark or Light; the terminal does not follow the system appearance).
- Inline IME composition (including Chinese pinyin), CJK and emoji, mouse reporting, bracketed
  paste, selection and copy.
- OSC 52 clipboard writes from the server ask for permission; OSC 9/777 notifications appear as
  in-app banners.

## Next

- [Claude Code integration](claude-integration.md): badges, permission cards, Codex.
- [Notifications](notifications.md): background push through ntfy.
- [Privacy & security](privacy-security.md).
