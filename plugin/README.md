# plugin

Claude Code plugin for shuai. Registers hooks that run `$HOME/.shuai/bin/shuai-agent hook <Event>`
(the binary is installed there by the app over SFTP; the hooks are a silent no-op if it is missing).

- All events are `async` except `PermissionRequest` (sync, timeout 120s; the agent waits up to 110s
  for the app, then falls back silently to the normal local dialog).
- Install: `claude plugin marketplace add moilk/shuai && claude plugin install shuai@shuai`
- Validate: `claude plugin validate plugin --strict`
