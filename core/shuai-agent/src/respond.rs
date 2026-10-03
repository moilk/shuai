//! `shuai-agent respond`: answer a pending permission request.

use crate::state::{Result, State};
use shuai_proto::{Behavior, PermissionResponse, is_valid_request_id};
use std::fs;
use std::time::{Duration, SystemTime};

/// Write `responses/<id>.json` atomically (tmp file + rename).
pub fn respond(state: &State, id: &str, behavior: Behavior, message: Option<String>) -> Result<()> {
    if !is_valid_request_id(id) {
        return Err(format!("invalid request id {id:?}").into());
    }
    let dir = state.responses_dir();
    fs::create_dir_all(&dir)?;
    prune(&dir);
    let body = serde_json::to_vec(&PermissionResponse {
        request_id: id.to_string(),
        behavior,
        message,
    })?;
    let tmp = dir.join(format!(".{id}.{}.tmp", std::process::id()));
    fs::write(&tmp, body)?;
    fs::rename(&tmp, dir.join(format!("{id}.json")))?;
    Ok(())
}

/// Drop answers nobody consumed (hook gave up) after an hour.
fn prune(dir: &std::path::Path) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let old = e
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| SystemTime::now().duration_since(m).ok())
            .is_some_and(|age| age > Duration::from_secs(3600));
        if old {
            let _ = fs::remove_file(e.path());
        }
    }
}
