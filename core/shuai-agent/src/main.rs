use clap::{Parser, Subcommand, ValueEnum};
use shuai_agent::state::State;
use shuai_agent::{doctor, hook, ntfy, respond, watch};
use shuai_proto::Behavior;
use std::io::Read;
use std::process::ExitCode;
use std::time::Duration;

/// Hook payloads beyond this are cut (the event is then dropped as invalid JSON).
const MAX_STDIN: u64 = 32 * 1024 * 1024;

#[derive(Parser)]
#[command(
    name = "shuai-agent",
    version,
    about = "Helper for the shuai iPad terminal"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Clone, Copy, ValueEnum)]
enum Decision {
    Allow,
    Deny,
}

#[derive(Subcommand)]
enum Cmd {
    /// Claude Code hook entry point: reads the hook JSON on stdin.
    Hook {
        event: String,
        /// Seconds a PermissionRequest waits for the app.
        #[arg(long, default_value_t = 110.0)]
        timeout: f64,
    },
    /// Stream events as JSONL (replay after --since, then follow).
    Watch {
        #[arg(long, default_value_t = 0)]
        since: u64,
        #[arg(long, default_value_t = 5.0)]
        heartbeat_secs: f64,
    },
    /// Answer a pending permission request.
    Respond {
        request_id: String,
        #[arg(value_enum)]
        decision: Decision,
        #[arg(long)]
        message: Option<String>,
    },
    /// Send a push notification through ntfy.
    Notify {
        #[arg(long)]
        title: String,
        #[arg(long)]
        body: String,
        #[arg(long)]
        click: Option<String>,
        #[arg(long)]
        priority: Option<String>,
        #[arg(long)]
        tags: Option<String>,
    },
    /// Codex `notify` program entry: one JSON argument.
    CodexNotify { json: String },
    /// Print an environment report as JSON.
    Doctor,
}

fn main() -> ExitCode {
    let state = State::from_env();
    let is_hook = std::env::args().nth(1).as_deref() == Some("hook");
    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(e) if is_hook && e.use_stderr() => {
            // Hooks must never fail Claude (exit 2 would block it).
            state.log(&format!("bad hook arguments: {e}"));
            return ExitCode::SUCCESS;
        }
        Err(e) => e.exit(),
    };
    match cli.cmd {
        Cmd::Hook { event, timeout } => {
            let r = std::panic::catch_unwind(|| {
                // Bounded read: a hook must never balloon in memory on a giant payload.
                let mut input = String::new();
                std::io::stdin()
                    .take(MAX_STDIN)
                    .read_to_string(&mut input)
                    .map_err(|e| format!("stdin: {e}"))?;
                // Drain the rest so the writer never sees EPIPE.
                let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
                let st = State::from_env();
                hook::run(
                    &st,
                    &event,
                    Duration::from_secs_f64(timeout.clamp(0.0, 3600.0)),
                    &input,
                )
            });
            match r {
                Ok(Ok(Some(out))) => {
                    use std::io::Write;
                    let _ = writeln!(std::io::stdout(), "{out}"); // EPIPE must not panic
                }
                Ok(Ok(None)) => {}
                Ok(Err(e)) => state.log(&format!("hook {event}: {e}")),
                Err(_) => state.log(&format!("hook {event}: panic")),
            }
            ExitCode::SUCCESS
        }
        Cmd::CodexNotify { json } => {
            if let Err(e) = hook::codex_notify(&state, &json) {
                state.log(&format!("codex-notify: {e}"));
            }
            ExitCode::SUCCESS
        }
        Cmd::Watch {
            since,
            heartbeat_secs,
        } => {
            let hb = Duration::from_secs_f64(heartbeat_secs.clamp(0.05, 3600.0));
            let mut out = std::io::stdout().lock();
            match watch::run(&state, since, hb, &mut out) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&format!("watch: {e}")),
            }
        }
        Cmd::Respond {
            request_id,
            decision,
            message,
        } => {
            let b = match decision {
                Decision::Allow => Behavior::Allow,
                Decision::Deny => Behavior::Deny,
            };
            match respond::respond(&state, &request_id, b, message) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&format!("respond: {e}")),
            }
        }
        Cmd::Notify {
            title,
            body,
            click,
            priority,
            tags,
        } => {
            let Some(cfg) = state.config().ntfy else {
                return fail("notify: no [ntfy] section in config.toml");
            };
            let m = ntfy::Message {
                title: &title,
                body: &body,
                click: click.as_deref(),
                priority: priority.as_deref(),
                tags: tags.as_deref(),
            };
            match ntfy::send(&cfg, &m) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&format!("notify: {}", ntfy::redact(&cfg, &e.to_string()))),
            }
        }
        Cmd::Doctor => {
            println!(
                "{}",
                serde_json::to_string_pretty(&doctor::report(&state)).unwrap()
            );
            ExitCode::SUCCESS
        }
    }
}

fn fail(msg: &str) -> ExitCode {
    eprintln!("shuai-agent: {msg}");
    ExitCode::from(1)
}
