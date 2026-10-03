//! Test-only exports (cargo feature `testkit`): an in-process SSH server so Swift host tests
//! can run a real SSH round trip. Never enabled for the iOS slices.

use std::sync::Arc;

use shuai_testkit::{PASSWORD, ServerOpts, USER};

#[derive(uniffi::Object)]
pub struct TestServer {
    inner: shuai_testkit::TestServer,
}

#[uniffi::export]
impl TestServer {
    pub fn port(&self) -> u16 {
        self.inner.port
    }
    pub fn host_public_key_line(&self) -> String {
        shuai_keys::authorized_keys_line(&self.inner.host_key)
    }
    pub fn username(&self) -> String {
        USER.to_string()
    }
    pub fn password(&self) -> String {
        PASSWORD.to_string()
    }
}

/// Starts the server on 127.0.0.1 (random port); it stops when the object is dropped.
#[uniffi::export(async_runtime = "tokio")]
pub async fn start_test_ssh_server() -> Arc<TestServer> {
    let inner = shuai_testkit::start(ServerOpts::default()).await;
    Arc::new(TestServer { inner })
}
