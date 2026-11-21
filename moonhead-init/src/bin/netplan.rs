use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{self, Command};

const CTL_SOCK: &str = "/run/moonhead/pid1.sock";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let subcmd = args.first().map(String::as_str).unwrap_or("help");

    match subcmd {
        "apply" => match UnixStream::connect(CTL_SOCK) {
            Ok(mut stream) => {
                let _ = stream.write_all(b"NETPLAN_APPLY\n");
                let mut resp = String::new();
                let _ = stream.read_to_string(&mut resp);
                let trimmed = resp.trim();
                if let Some(msg) = trimmed.strip_prefix("OK\t") {
                    println!("Netplan applied: {}", msg);
                } else {
                    eprintln!("Netplan error: {}", trimmed.trim_start_matches("ERR\t"));
                    process::exit(1);
                }
            }
            Err(e) => {
                eprintln!("failed to reach PID 1 control socket: {}", e);
                process::exit(1);
            }
        },
        "status" => {
            let _ = Command::new("ip").args(["-br", "addr"]).status();
            let _ = Command::new("ip").args(["route"]).status();
        }
        _ => {
            eprintln!("Usage: netplan <apply|status>");
            process::exit(1);
        }
    }
}
