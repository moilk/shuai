use icongen::{fidelity, pipeline};
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: icongen <generate|check|fidelity> [--brand DIR]  (default DIR: ../../brand)\n       icongen trace --source PNG --out MARK_TOML";

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let cmd = args.next();
    let mut brand = PathBuf::from("../../brand");
    let (mut source, mut out): (Option<PathBuf>, Option<PathBuf>) = (None, None);
    while let Some(a) = args.next() {
        match (a.as_str(), args.next()) {
            ("--brand", Some(dir)) => brand = PathBuf::from(dir),
            ("--source", Some(p)) => source = Some(PathBuf::from(p)),
            ("--out", Some(p)) => out = Some(PathBuf::from(p)),
            _ => {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            }
        }
    }
    match cmd.as_deref() {
        Some("generate") => match pipeline::write(&brand) {
            Ok(n) => {
                println!("wrote {n} files");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::FAILURE
            }
        },
        Some("check") => match pipeline::check(&brand) {
            Ok(()) => {
                println!("generated files are up to date");
                ExitCode::SUCCESS
            }
            Err(problems) => {
                for p in problems {
                    eprintln!("{p}");
                }
                eprintln!("run `icongen generate` and commit the result");
                ExitCode::FAILURE
            }
        },
        Some("fidelity") => match fidelity::run(&brand) {
            Ok((text, ok)) => {
                print!("{text}");
                if ok {
                    ExitCode::SUCCESS
                } else {
                    ExitCode::FAILURE
                }
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::FAILURE
            }
        },
        Some("trace") => match (source, out) {
            (Some(src), Some(dst)) => match trace(&src, &dst) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::FAILURE
                }
            },
            _ => {
                eprintln!("{USAGE}");
                ExitCode::from(2)
            }
        },
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn trace(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    let bytes = std::fs::read(src).map_err(|e| format!("{}: {e}", src.display()))?;
    let toml = fidelity::trace_toml(&fidelity::load_field_png(&bytes)?)?;
    std::fs::write(dst, toml).map_err(|e| format!("{}: {e}", dst.display()))
}
