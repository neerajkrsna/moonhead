use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process;

const CTL_SOCK: &str = "/run/coreos/pid1.sock";

fn send_cmd(cmd: &str) -> Result<String, String> {
    let mut stream = UnixStream::connect(CTL_SOCK)
        .map_err(|e| format!("failed to connect to {}: {}", CTL_SOCK, e))?;
    stream
        .write_all(format!("{}\n", cmd).as_bytes())
        .map_err(|e| e.to_string())?;
    let mut resp = String::new();
    stream.read_to_string(&mut resp).map_err(|e| e.to_string())?;
    Ok(resp)
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("Usage: service <name> <start|stop|restart|status> | service --status-all");
        process::exit(1);
    }

    if args[0] == "--status-all" {
        match send_cmd("LIST") {
            Ok(out) => {
                for line in out.lines() {
                    let cols: Vec<&str> = line.split('\t').collect();
                    if cols.len() >= 4 {
                        let badge = if cols[1] == "running" { "+" } else { "-" };
                        println!(" [ {} ]  {} (pid={}, cgroup={})", badge, cols[0], cols[2], cols[3]);
                    }
                }
            }
            Err(e) => {
                eprintln!("{}", e);
                process::exit(1);
            }
        }
        return;
    }

    if args.len() < 2 {
        eprintln!("Usage: service <name> <start|stop|restart|status>");
        process::exit(1);
    }

    let name = &args[0];
    let action = args[1].to_uppercase();
    match send_cmd(&format!("{} {}", action, name)) {
        Ok(resp) => {
            let trimmed = resp.trim();
            if let Some(msg) = trimmed.strip_prefix("ACTIVE\t") {
                println!("{}", msg);
                process::exit(0);
            } else if let Some(msg) = trimmed.strip_prefix("INACTIVE\t") {
                println!("{}", msg);
                process::exit(3);
            } else if let Some(msg) = trimmed.strip_prefix("OK\t") {
                println!("{}", msg);
                process::exit(0);
            } else {
                eprintln!("{}", trimmed.trim_start_matches("ERR\t").trim_start_matches("UNKNOWN\t"));
                process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("{}", e);
            process::exit(1);
        }
    }
}
