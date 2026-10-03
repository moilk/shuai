//! Test helpers for shuai-ssh: the in-process server lives in `shuai-testkit`.
#![allow(dead_code)]

use std::sync::Mutex;
use std::time::Duration;

use async_trait::async_trait;
use russh::keys::PublicKey;
use shuai_ssh::HostKeyVerifier;

pub use shuai_testkit::*;

/// Accepts everything, remembering what it was asked about.
#[derive(Default)]
pub struct AcceptAll {
    pub seen: Mutex<Vec<(String, u16, PublicKey)>>,
}

#[async_trait]
impl HostKeyVerifier for AcceptAll {
    async fn verify(&self, host: &str, port: u16, key: &PublicKey) -> bool {
        self.seen
            .lock()
            .unwrap()
            .push((host.into(), port, key.clone()));
        true
    }
}

pub struct RejectAll;

#[async_trait]
impl HostKeyVerifier for RejectAll {
    async fn verify(&self, _host: &str, _port: u16, _key: &PublicKey) -> bool {
        false
    }
}

pub fn cfg(server: &TestServer, auth: Vec<shuai_ssh::AuthMethod>) -> shuai_ssh::ConnectConfig {
    let mut c = shuai_ssh::ConnectConfig::new("127.0.0.1", USER);
    c.port = server.port;
    c.auth = auth;
    c.connect_timeout = Duration::from_secs(5);
    c
}
