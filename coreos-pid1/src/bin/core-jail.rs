#[path = "../jail.rs"]
mod jail;

use jail::{apply_jail, JailPolicy};
use std::env;
use std::os::unix::process::CommandExt;
use std::process::{self, Command};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let mut policy = JailPolicy::default();
    let mut cmd_idx: Option<usize> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--ro" if i + 1 < args.len() => {
                policy.ro_paths.push(args[i + 1].clone());
                i += 1;
            }
            "--rw" if i + 1 < args.len() => {
                policy.rw_paths.push(args[i + 1].clone());
                i += 1;
            }
            "--" if i + 1 < args.len() => {
                cmd_idx = Some(i + 1);
                break;
            }
            other if !other.starts_with('-') => {
                cmd_idx = Some(i);
                break;
            }
            _ => {}
        }
        i += 1;
    }

    let Some(start) = cmd_idx else {
        eprintln!("Usage: core-jail [--ro <path>]... [--rw <path>]... [--] <command> [args...]");
        process::exit(1);
    };

    if let Err(e) = apply_jail(&policy) {
        eprintln!("[core-jail] sandbox initialization failed: {}", e);
        process::exit(1);
    }

    let err = Command::new(&args[start]).args(&args[start + 1..]).exec();
    eprintln!("[core-jail] exec '{}' failed: {}", args[start], err);
    process::exit(127);
}
