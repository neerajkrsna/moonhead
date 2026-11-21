use nix::sys::epoll::{Epoll, EpollEvent, EpollFlags};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::time::{Duration, Instant};

pub const TOKEN_PSI_MEM_SOME: u64 = 2;
pub const TOKEN_PSI_MEM_FULL: u64 = 3;
pub const TOKEN_PSI_IO_SOME: u64 = 4;

const BATCH_CGROUP: &str = "/sys/fs/cgroup/moonhead.slice/batch";
const BATCH_MEM_FLOOR: u64 = 32 * 1024 * 1024; // 32 MiB minimum floor

pub struct PsiWatchdog {
    _mem_some_fd: Option<File>,
    _mem_full_fd: Option<File>,
    _io_some_fd: Option<File>,
    last_action: Instant,
    last_pressure: Instant,
    throttled: bool,
}

impl PsiWatchdog {
    pub fn register(epoll: &Epoll) -> Self {
        // Kernel PSI trigger syntax: "<some|full> <stall_us> <window_us>" (window >= 500,000 us)
        let mem_some = open_psi_trigger(
            "/proc/pressure/memory",
            "some 50000 500000",
            epoll,
            TOKEN_PSI_MEM_SOME,
        );
        let mem_full = open_psi_trigger(
            "/proc/pressure/memory",
            "full 100000 500000",
            epoll,
            TOKEN_PSI_MEM_FULL,
        );
        let io_some = open_psi_trigger(
            "/proc/pressure/io",
            "some 100000 500000",
            epoll,
            TOKEN_PSI_IO_SOME,
        );

        let active = [mem_some.is_some(), mem_full.is_some(), io_some.is_some()]
            .into_iter()
            .filter(|&x| x)
            .count();
        println!("[moonhead-psi] registered {}/3 microsecond EPOLLPRI pressure triggers", active);

        let past = Instant::now() - Duration::from_secs(10);
        Self {
            _mem_some_fd: mem_some,
            _mem_full_fd: mem_full,
            _io_some_fd: io_some,
            last_action: past,
            last_pressure: past,
            throttled: false,
        }
    }

    pub fn handle_event(&mut self, token: u64) {
        let now = Instant::now();
        self.last_pressure = now;

        // Rate-limit interventions to once per 250ms to prevent thrashing
        if now.duration_since(self.last_action) < Duration::from_millis(250) {
            return;
        }
        self.last_action = now;
        self.throttled = true;

        match token {
            TOKEN_PSI_MEM_SOME => {
                let current = read_u64(&format!("{}/memory.current", BATCH_CGROUP))
                    .unwrap_or(BATCH_MEM_FLOOR * 2);
                let target = ((current * 3) / 4).max(BATCH_MEM_FLOOR);
                let _ = fs::write(format!("{}/memory.high", BATCH_CGROUP), target.to_string());
                println!(
                    "[moonhead-psi] memory.some trigger -> clamped batch memory.high to {} MiB",
                    target / (1024 * 1024)
                );
            }
            TOKEN_PSI_MEM_FULL => {
                let _ = fs::write(
                    format!("{}/memory.high", BATCH_CGROUP),
                    BATCH_MEM_FLOOR.to_string(),
                );
                // Reclaim clean page cache immediately without blocking on dirty writeback
                let _ = fs::write("/proc/sys/vm/drop_caches", "1");
                println!(
                    "[moonhead-psi] memory.full critical trigger -> clamped batch to 32 MiB & shed clean pagecache"
                );
            }
            TOKEN_PSI_IO_SOME => {
                let _ = fs::write(format!("{}/cpu.weight", BATCH_CGROUP), "10");
                let _ = fs::write(format!("{}/io.weight", BATCH_CGROUP), "10");
                println!("[moonhead-psi] io.some trigger -> throttled batch cpu/io weight to 10");
            }
            _ => {}
        }
    }

    pub fn tick_recovery(&mut self) {
        if self.throttled && self.last_pressure.elapsed() >= Duration::from_secs(5) {
            let _ = fs::write(format!("{}/memory.high", BATCH_CGROUP), "max");
            let _ = fs::write(format!("{}/cpu.weight", BATCH_CGROUP), "100");
            let _ = fs::write(format!("{}/io.weight", BATCH_CGROUP), "100");
            self.throttled = false;
            println!("[moonhead-psi] pressure subsided for 5s -> restored batch cgroup limits");
        }
    }
}

fn open_psi_trigger(path: &str, rule: &str, epoll: &Epoll, token: u64) -> Option<File> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .ok()?;

    file.write_all(rule.as_bytes()).ok()?;
    // Kernel signals PSI trigger threshold crossings via POLLPRI (EPOLLPRI)
    epoll
        .add(&file, EpollEvent::new(EpollFlags::EPOLLPRI, token))
        .ok()?;
    Some(file)
}

fn read_u64(path: &str) -> Option<u64> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}
