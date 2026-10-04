use icongen::pipeline;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: icongen <generate|check> [--brand DIR]  (default DIR: ../../brand)";

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let cmd = args.next();
    let mut brand = PathBuf::from("../../brand");
    while let Some(a) = args.next() {
        match (a.as_str(), args.next()) {
            ("--brand", Some(dir)) => brand = PathBuf::from(dir),
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
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}
