# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/moilk/shuai/security/advisories/new)
and do not open a public issue. Include the affected component (app, Rust core, `shuai-agent`,
plugin), the version or commit, and steps to reproduce. Do not include real private keys, passwords,
tokens or server names.

## Scope

shuai handles SSH credentials, untrusted server output and permission decisions, so reports in these
areas are especially welcome: host key verification, key and password storage, parsing of terminal
or agent data from the server, `shuai://` links, and anything that leaks prompts, commands, paths or
secrets through logs or push notifications.

## Supported versions

Only the latest commit on `main` is supported; fixes land there. The threat model and mitigations are
described in [Security model](docs/design/security-model.md) and
[Privacy and security](docs/user/privacy-security.md).
