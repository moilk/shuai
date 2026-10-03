fn main() {
    let arg = std::env::args().nth(1);
    match arg.as_deref() {
        Some("--version") | Some("-V") => println!("shuai-agent {}", shuai_proto::version()),
        _ => {
            eprintln!("usage: shuai-agent --version");
            std::process::exit(2);
        }
    }
}
