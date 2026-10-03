#![cfg(feature = "testkit")]

use std::sync::Arc;

use shuai_ffi::*;

struct AcceptKey(std::sync::Mutex<Option<String>>);

#[async_trait::async_trait]
impl HostKeyVerifierCallback for AcceptKey {
    async fn verify(&self, _host: String, _port: u16, public_key_line: String) -> bool {
        *self.0.lock().unwrap() = Some(public_key_line);
        true
    }
}

#[tokio::test]
async fn exported_test_server_is_connectable_and_reports_its_host_key() {
    let server = start_test_ssh_server().await;
    let v = Arc::new(AcceptKey(Default::default()));
    let conn = SshConnection::connect(
        FfiConnectConfig {
            host: "127.0.0.1".into(),
            port: server.port(),
            username: server.username(),
            auth: vec![FfiAuth::Password {
                password: server.password(),
            }],
            keepalive_secs: 15,
            connect_timeout_secs: 5,
            auth_timeout_secs: 10,
        },
        v.clone(),
    )
    .await
    .unwrap();
    assert_eq!(
        v.0.lock().unwrap().clone().unwrap(),
        server.host_public_key_line()
    );
    assert_eq!(conn.exec("ok".into()).await.unwrap().exit_status, Some(0));
}
