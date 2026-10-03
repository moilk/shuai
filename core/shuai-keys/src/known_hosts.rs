use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use hmac::{Hmac, KeyInit, Mac};
use rand::Rng;
use sha1::Sha1;
use ssh_key::{HashAlg, PublicKey};

/// Result of checking a host key against a [`KnownHosts`] list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyStatus {
    /// The presented key matches a recorded key for this host.
    Trusted,
    /// No entry for this host (trust-on-first-use decision needed).
    Unknown,
    /// The host has recorded keys but none equals the presented one.
    Mismatch {
        /// SHA256 fingerprints of the keys recorded for this host.
        expected_fingerprints: Vec<String>,
    },
    /// The presented key is marked `@revoked` for this host.
    Revoked,
}

/// An OpenSSH `known_hosts` file held as text.
///
/// Supports plain hosts, `[host]:port`, comma-separated lists, `*`/`?` wildcards, `!negation`,
/// hashed `|1|salt|hash` entries and the `@revoked` marker. `@cert-authority` entries are
/// ignored. Comments, blank and unparseable lines are preserved verbatim for round-tripping.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KnownHosts {
    lines: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Marker {
    None,
    Revoked,
}

struct Entry<'a> {
    marker: Marker,
    hosts: &'a str,
    key: PublicKey,
}

fn parse_entry(line: &str) -> Option<Entry<'_>> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let mut it = line.split_whitespace();
    let mut first = it.next()?;
    let marker = if first.starts_with('@') {
        let m = match first {
            "@revoked" => Marker::Revoked,
            _ => return None, // @cert-authority and unknown markers are ignored
        };
        first = it.next()?;
        m
    } else {
        Marker::None
    };
    let alg = it.next()?;
    let data = it.next()?;
    let key = PublicKey::from_openssh(&format!("{alg} {data}")).ok()?;
    Some(Entry {
        marker,
        hosts: first,
        key,
    })
}

/// The string OpenSSH matches/hashes: bare host on port 22, otherwise `[host]:port`.
fn host_string(host: &str, port: u16) -> String {
    let host = host.to_ascii_lowercase();
    if port == 22 {
        host
    } else {
        format!("[{host}]:{port}")
    }
}

fn is_plain_host(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with(['|', '@', '#', '!'])
        && !s
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || matches!(c, ',' | '*' | '?'))
}

fn hmac_sha1(salt: &[u8], data: &str) -> Vec<u8> {
    let mut mac =
        <Hmac<Sha1> as KeyInit>::new_from_slice(salt).expect("HMAC accepts any key length");
    mac.update(data.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

fn hashed_matches(pattern: &str, target: &str) -> bool {
    let mut parts = pattern.strip_prefix("|1|").unwrap_or("").splitn(2, '|');
    let (Some(salt), Some(hash)) = (parts.next(), parts.next()) else {
        return false;
    };
    let (Ok(salt), Ok(hash)) = (B64.decode(salt), B64.decode(hash)) else {
        return false;
    };
    hmac_sha1(&salt, target) == hash
}

/// Glob match with `*` and `?` (both sides pre-lowercased by caller). Iterative with
/// single-point backtracking, so hostile patterns cannot cause exponential blow-up.
fn glob(pattern: &[u8], text: &[u8]) -> bool {
    let (mut p, mut t) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while t < text.len() {
        match pattern.get(p) {
            Some(b'*') => {
                star = Some((p, t));
                p += 1;
            }
            Some(b'?') => {
                p += 1;
                t += 1;
            }
            Some(&c) if c == text[t] => {
                p += 1;
                t += 1;
            }
            _ => match star {
                Some((sp, st)) => {
                    p = sp + 1;
                    t = st + 1;
                    star = Some((sp, st + 1));
                }
                None => return false,
            },
        }
    }
    pattern[p..].iter().all(|&c| c == b'*')
}

fn hosts_match(hosts: &str, target: &str) -> bool {
    if hosts.starts_with("|1|") {
        return hashed_matches(hosts, target);
    }
    let mut matched = false;
    for pat in hosts.split(',').filter(|p| !p.is_empty()) {
        if let Some(neg) = pat.strip_prefix('!') {
            if glob(neg.to_ascii_lowercase().as_bytes(), target.as_bytes()) {
                return false;
            }
        } else if glob(pat.to_ascii_lowercase().as_bytes(), target.as_bytes()) {
            matched = true;
        }
    }
    matched
}

impl KnownHosts {
    /// Parses `known_hosts` text. Never fails; unparseable lines are skipped when checking
    /// but preserved by [`KnownHosts::to_text`].
    pub fn parse(text: &str) -> Self {
        Self {
            lines: text.lines().map(str::to_string).collect(),
        }
    }

    /// Serializes back to `known_hosts` text (one `\n`-terminated line per entry).
    pub fn to_text(&self) -> String {
        let mut s = String::new();
        for l in &self.lines {
            s.push_str(l);
            s.push('\n');
        }
        s
    }

    /// Checks the key presented by `host:port`.
    ///
    /// `Revoked` wins over everything. Otherwise `Trusted` if any entry for the host holds this
    /// key, `Mismatch` if the host has entries but none holds this key (any key type — the safe
    /// choice), else `Unknown`.
    pub fn check(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus {
        let target = host_string(host, port);
        let mut trusted = false;
        let mut expected = Vec::new();
        for line in &self.lines {
            let Some(e) = parse_entry(line) else { continue };
            if !hosts_match(e.hosts, &target) {
                continue;
            }
            let same = e.key.key_data() == key.key_data();
            match e.marker {
                Marker::Revoked if same => return HostKeyStatus::Revoked,
                Marker::Revoked => {}
                Marker::None => {
                    trusted |= same;
                    expected.push(e.key.fingerprint(HashAlg::Sha256).to_string());
                }
            }
        }
        if trusted {
            HostKeyStatus::Trusted
        } else if expected.is_empty() {
            HostKeyStatus::Unknown
        } else {
            HostKeyStatus::Mismatch {
                expected_fingerprints: expected,
            }
        }
    }

    /// Removes the plain (non-marker) entries that are specific to `host:port`: a single
    /// literal host pattern or a hashed host that matches. Wildcard, negated, multi-host and
    /// `@revoked` lines are never edited (they may cover other hosts). Returns the number of
    /// lines removed.
    pub fn remove_host(&mut self, host: &str, port: u16) -> usize {
        let target = host_string(host, port);
        let before = self.lines.len();
        self.lines.retain(|line| {
            let Some(e) = parse_entry(line) else {
                return true;
            };
            let specific = if e.hosts.starts_with("|1|") {
                hashed_matches(e.hosts, &target)
            } else {
                is_plain_host(e.hosts) && e.hosts.eq_ignore_ascii_case(&target)
            };
            !(matches!(e.marker, Marker::None) && specific)
        });
        before - self.lines.len()
    }

    /// Appends an entry (see [`add_entry`]) and returns the line added.
    pub fn add(&mut self, host: &str, port: u16, key: &PublicKey, hashed: bool) -> String {
        let line = add_entry(host, port, key, hashed);
        self.lines.push(line.clone());
        line
    }
}

/// Builds a `known_hosts` line (no trailing newline) for `host:port`, without the key comment.
///
/// Port 22 is written as the bare host, other ports as `[host]:port`. Hosts that are not safe to
/// write in plain text (whitespace, `,*?!`, leading `|@#`) are always hashed. With `hashed`, the host
/// field is `|1|salt|HMAC-SHA1` with a fresh random salt, like `ssh-keygen -H`.
pub fn add_entry(host: &str, port: u16, key: &PublicKey, hashed: bool) -> String {
    let target = host_string(host, port);
    // A host containing whitespace, list/pattern syntax or a leading marker would inject
    // extra lines/wildcards into the file; hashing makes any string safe.
    let hashed = hashed || !is_plain_host(&target);
    let field = if hashed {
        let mut salt = [0u8; 20];
        rand::rng().fill_bytes(&mut salt);
        format!(
            "|1|{}|{}",
            B64.encode(salt),
            B64.encode(hmac_sha1(&salt, &target))
        )
    } else {
        target
    };
    let mut key = key.clone();
    key.set_comment("");
    format!(
        "{field} {}",
        key.to_openssh().unwrap_or_default().trim_end()
    )
}
