//! State directory (`$SHUAI_HOME`, default `~/.shuai`), tunables and config.

use serde::Deserialize;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Debug, Clone)]
pub struct State {
    pub dir: PathBuf,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Config {
    /// Id of this host in deep links (`shuai://open?host=<id>&pane=<%N>`); defaults to the hostname.
    pub host_id: Option<String>,
    /// Human-readable host name shown in pushes (the app's host profile name).
    pub host_name: Option<String>,
    pub ntfy: Option<Ntfy>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Ntfy {
    pub server: String,
    pub topic: String,
    pub token: Option<String>,
    /// Include tmux's window name in pushes. Off by default: automatic-rename turns it into the
    /// running command line, which is not status.
    #[serde(default)]
    pub window_names: bool,
}

fn env_f64(name: &str, default: f64) -> f64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Create `dir` (and parents) and make sure it is `0700`: the state holds prompts, commands
/// and the permission-response files, which must not be writable by other users.
pub fn private_dir(dir: &Path) -> std::io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    if fs::metadata(dir)?.permissions().mode() & 0o777 != 0o700 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// `OpenOptions` that create files as `0600`.
pub fn private_open() -> OpenOptions {
    let mut o = OpenOptions::new();
    o.mode(0o600);
    o
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn hostname() -> String {
    if let Ok(h) = std::env::var("SHUAI_HOSTNAME")
        && !h.is_empty()
    {
        return h;
    }
    rustix::system::uname()
        .nodename()
        .to_string_lossy()
        .into_owned()
}

impl State {
    pub fn from_env() -> State {
        let dir = match std::env::var_os("SHUAI_HOME") {
            Some(d) if !d.is_empty() => PathBuf::from(d),
            _ => {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| ".".into())).join(".shuai")
            }
        };
        State { dir }
    }

    pub fn at(dir: &Path) -> State {
        State {
            dir: dir.to_path_buf(),
        }
    }

    pub fn ensure(&self) -> std::io::Result<()> {
        private_dir(&self.dir)
    }

    pub fn events_path(&self) -> PathBuf {
        self.dir.join("events.jsonl")
    }
    pub fn rotated_path(&self) -> PathBuf {
        self.dir.join("events.jsonl.1")
    }
    pub fn lock_path(&self) -> PathBuf {
        self.dir.join("events.lock")
    }
    pub fn seq_path(&self) -> PathBuf {
        self.dir.join("seq")
    }
    pub fn presence_path(&self) -> PathBuf {
        self.dir.join("presence")
    }
    pub fn responses_dir(&self) -> PathBuf {
        self.dir.join("responses")
    }
    pub fn config_path(&self) -> PathBuf {
        self.dir.join("config.toml")
    }
    pub fn log_path(&self) -> PathBuf {
        self.dir.join("agent.log")
    }

    /// Rotate `events.jsonl` once it grows beyond this many bytes.
    pub fn max_log_bytes(&self) -> u64 {
        env_f64("SHUAI_MAX_LOG_BYTES", 5.0 * 1024.0 * 1024.0) as u64
    }

    /// How long a `watch` heartbeat keeps the app "present".
    pub fn presence_ttl(&self) -> Duration {
        Duration::from_secs_f64(env_f64("SHUAI_PRESENCE_TTL_SECS", 30.0).max(0.0))
    }

    /// Minimum seconds between two non-approval pushes of one session.
    pub fn push_min_interval(&self) -> Duration {
        Duration::from_secs_f64(env_f64("SHUAI_PUSH_MIN_INTERVAL_SECS", 10.0).max(0.0))
    }

    pub fn push_gate_path(&self) -> PathBuf {
        self.dir.join("push.json")
    }
    pub fn push_lock_path(&self) -> PathBuf {
        self.dir.join("push.lock")
    }

    pub fn poll_interval(&self) -> Duration {
        Duration::from_millis(env_f64("SHUAI_POLL_MS", 50.0).max(1.0) as u64)
    }

    /// Is an app currently watching (presence file touched within the TTL)?
    pub fn present(&self) -> bool {
        let Ok(m) = fs::metadata(self.presence_path()).and_then(|m| m.modified()) else {
            return false;
        };
        SystemTime::now()
            .duration_since(m)
            .map(|age| age <= self.presence_ttl())
            .unwrap_or(true)
    }

    pub fn touch_presence(&self) -> std::io::Result<()> {
        self.ensure()?;
        let mut f = private_open()
            .write(true)
            .create(true)
            .truncate(true)
            .open(self.presence_path())?;
        write!(f, "{}", now_ms())
    }

    /// Best-effort append to `agent.log`; never fails.
    pub fn log(&self, msg: &str) {
        let _ = (|| -> std::io::Result<()> {
            self.ensure()?;
            if fs::metadata(self.log_path()).map(|m| m.len()).unwrap_or(0) > 512 * 1024 {
                let _ = fs::rename(self.log_path(), self.dir.join("agent.log.1"));
            }
            let mut f = private_open()
                .create(true)
                .append(true)
                .open(self.log_path())?;
            writeln!(f, "{} {}", now_ms(), msg.replace('\n', " "))
        })();
    }

    /// Parse `config.toml`. It can hold the ntfy topic and token, so a pre-existing file and
    /// directory are tightened to 0600/0700 here, and a parse error is logged by position only
    /// (toml's own message quotes the offending line, i.e. possibly the secrets).
    pub fn config(&self) -> Config {
        let path = self.config_path();
        let Ok(text) = fs::read_to_string(&path) else {
            return Config::default();
        };
        let _ = private_dir(&self.dir);
        if fs::metadata(&path).is_ok_and(|m| m.permissions().mode() & 0o777 != 0o600) {
            let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
        }
        toml::from_str(&text).unwrap_or_else(|e| {
            let line = e
                .span()
                .map(|s| text[..s.start.min(text.len())].matches('\n').count() + 1);
            match line {
                Some(l) => self.log(&format!("config.toml: parse error at line {l}")),
                None => self.log("config.toml: parse error"),
            }
            Config::default()
        })
    }
}
