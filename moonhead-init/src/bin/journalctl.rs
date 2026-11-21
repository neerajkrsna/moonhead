use std::env;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::process;
use std::thread;
use std::time::Duration;

const CTL_SOCK: &str = "/run/moonhead/pid1.sock";

fn fetch_chunk(unit: &str, offset: u64) -> Result<(u64, Vec<u8>), String> {
    let mut stream = UnixStream::connect(CTL_SOCK)
        .map_err(|e| format!("failed to connect to {}: {}", CTL_SOCK, e))?;
    stream
        .write_all(format!("LOGS {} {}\n", unit, offset).as_bytes())
        .map_err(|e| e.to_string())?;

    let mut reader = BufReader::new(stream);
    let mut header = String::new();
    reader.read_line(&mut header).map_err(|e| e.to_string())?;

    let trimmed = header.trim();
    if let Some(err) = trimmed.strip_prefix("ERR\t") {
        return Err(err.to_string());
    }

    let parts: Vec<&str> = trimmed.split('\t').collect();
    if parts.len() < 3 || parts[0] != "OFFSET" {
        return Err(format!("invalid response: {}", trimmed));
    }

    let next_offset: u64 = parts[1].parse().map_err(|_| "bad offset")?;
    let byte_len: usize = parts[2].parse().map_err(|_| "bad length")?;
    let mut data = vec![0u8; byte_len];
    reader.read_exact(&mut data).map_err(|e| e.to_string())?;
    Ok((next_offset, data))
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let mut unit: Option<String> = None;
    let mut follow = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-u" | "--unit" if i + 1 < args.len() => {
                unit = Some(args[i + 1].clone());
                i += 1;
            }
            "-f" | "--follow" => follow = true,
            other if !other.starts_with('-') && unit.is_none() => {
                unit = Some(other.to_string());
            }
            _ => {}
        }
        i += 1;
    }

    let Some(unit_name) = unit else {
        eprintln!("Usage: journalctl -u <service> [-f]");
        process::exit(1);
    };

    let mut offset = 0u64;
    let mut stdout = std::io::stdout();
    loop {
        match fetch_chunk(&unit_name, offset) {
            Ok((next_off, data)) => {
                if !data.is_empty() {
                    let _ = stdout.write_all(&data);
                    let _ = stdout.flush();
                }
                offset = next_off;
            }
            Err(e) => {
                eprintln!("journalctl: {}", e);
                process::exit(1);
            }
        }

        if !follow {
            break;
        }
        thread::sleep(Duration::from_millis(200));
    }
}
