mod hw_prober;
mod jail;
mod netplan;
mod psi_watchdog;

use jail::{apply_jail, JailPolicy, JAILED_CGROUP_PATH};
use nix::fcntl::{fcntl, FcntlArg, SealFlag};
use nix::mount::{mount, MsFlags};
use nix::sched::{unshare, CloneFlags};
use nix::sys::epoll::{Epoll, EpollCreateFlags, EpollEvent, EpollFlags, EpollTimeout};
use nix::sys::memfd::{memfd_create, MemFdCreateFlag};
use nix::sys::reboot::{reboot, RebootMode};
use nix::sys::signal::{kill, SigSet, Signal};
use nix::sys::signalfd::{SfdFlags, SignalFd};
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::unistd::{sethostname, sync, Pid};
use psi_watchdog::{PsiWatchdog, TOKEN_PSI_IO_SOME, TOKEN_PSI_MEM_FULL, TOKEN_PSI_MEM_SOME};
use serde::Deserialize;
use std::collections::HashMap;
use std::ffi::CString;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

const SERVICE_DIR: &str = "/etc/coreos/services";
const CTL_SOCK_PATH: &str = "/run/coreos/pid1.sock";
const BPF_LSM_OBJ: &str = "/usr/lib/coreos/io_uring_lsm.bpf.o";
const BPF_PIN_DIR: &str = "/sys/fs/bpf/coreos_uring";
const TOKEN_SIGNALFD: u64 = 1;
const TOKEN_CTL_SOCK: u64 = 5;

#[derive(Debug, Clone, Deserialize)]
struct ServiceSpec {
    name: String,
    exec: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    tty: Option<String>,
    #[serde(default = "default_cgroup")]
    cgroup: String,
    #[serde(default = "default_true")]
    restart: bool,
    #[serde(default)]
    jail: bool,
    #[serde(default)]
    jail_ro: Vec<String>,
    #[serde(default)]
    jail_rw: Vec<String>,
}

fn default_true() -> bool {
    true
}

fn default_cgroup() -> String {
    "foreground".to_string()
}

struct ManagedService {
    spec: ServiceSpec,
    child: Option<Child>,
    log_memfd: OwnedFd,
    last_start: Instant,
    manual_stopped: bool,
}

fn mount_api_filesystems() {
    let basic = MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC;
    let _ = mount(Some("proc"), "/proc", Some("proc"), basic, None::<&str>);
    let _ = mount(Some("sysfs"), "/sys", Some("sysfs"), basic, None::<&str>);
    let _ = mount(
        Some("devtmpfs"),
        "/dev",
        Some("devtmpfs"),
        MsFlags::MS_NOSUID,
        Some("mode=0755"),
    );

    let _ = fs::create_dir_all("/dev/pts");
    let _ = fs::create_dir_all("/dev/shm");
    let _ = fs::create_dir_all("/tmp");

    let _ = mount(
        Some("devpts"),
        "/dev/pts",
        Some("devpts"),
        MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC,
        Some("gid=5,mode=620"),
    );
    let _ = mount(
        Some("tmpfs"),
        "/dev/shm",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        None::<&str>,
    );
    let _ = mount(
        Some("tmpfs"),
        "/run",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        Some("mode=0755"),
    );
    let _ = fs::create_dir_all("/run/coreos");
    let _ = mount(
        Some("tmpfs"),
        "/tmp",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        Some("mode=1777"),
    );
    let _ = mount(
        Some("cgroup2"),
        "/sys/fs/cgroup",
        Some("cgroup2"),
        basic,
        None::<&str>,
    );
    let _ = mount(
        Some("bpffs"),
        "/sys/fs/bpf",
        Some("bpf"),
        basic,
        None::<&str>,
    );
}

fn setup_cgroup_hierarchy() {
    for ctrl in ["+cpu", "+memory", "+io"] {
        let _ = fs::write("/sys/fs/cgroup/cgroup.subtree_control", ctrl);
    }
    let _ = fs::create_dir_all("/sys/fs/cgroup/coreos.slice/foreground");
    let _ = fs::create_dir_all("/sys/fs/cgroup/coreos.slice/batch");
    let _ = fs::create_dir_all(JAILED_CGROUP_PATH);
    for ctrl in ["+cpu", "+memory", "+io"] {
        let _ = fs::write("/sys/fs/cgroup/coreos.slice/cgroup.subtree_control", ctrl);
    }
    let _ = fs::write("/sys/fs/cgroup/coreos.slice/foreground/cpu.weight", "1000");
    let _ = fs::write("/sys/fs/cgroup/coreos.slice/batch/cpu.weight", "100");
    let _ = fs::write(format!("{}/cpu.weight", JAILED_CGROUP_PATH), "100");
}

fn setup_ebpf_gatekeeper() {
    if !Path::new(BPF_LSM_OBJ).exists() {
        return;
    }


    let ok = Command::new("/usr/sbin/bpftool")
        .args([
            "prog",
            "loadall",
            BPF_LSM_OBJ,
            BPF_PIN_DIR,
            "pinmaps",
            BPF_PIN_DIR,
            "autoattach",
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if !ok {
        eprintln!("[coreos-ebpf] warning: failed to attach BPF LSM io_uring gatekeeper");
        return;
    }

    // Register the jailed cgroup inode ID in the pinned jailed_cgroups BPF hash map
    if let Ok(meta) = fs::metadata(JAILED_CGROUP_PATH) {
        let cgid = meta.ino();
        let key_bytes = cgid.to_ne_bytes();
        let val_bytes = 1u32.to_ne_bytes();

        let mut args = vec![
            "map".to_string(),
            "update".to_string(),
            "pinned".to_string(),
            format!("{}/jailed_cgroups", BPF_PIN_DIR),
            "key".to_string(),
            "hex".to_string(),
        ];
        args.extend(key_bytes.iter().map(|b| format!("{:02x}", b)));
        args.push("value".to_string());
        args.push("hex".to_string());
        args.extend(val_bytes.iter().map(|b| format!("{:02x}", b)));


        let updated = Command::new("/usr/sbin/bpftool")
            .args(&args)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);

        if updated {
            println!(
                "[coreos-ebpf] BPF LSM io_uring gatekeeper active (jailed cgroup_id={})",
                cgid
            );
        }
    }
}

fn configure_hostname_and_loopback() {
    if let Ok(raw) = fs::read_to_string("/etc/hostname") {
        let host = raw.trim();
        if !host.is_empty() {
            let _ = sethostname(host);
        }
    }

    unsafe {
        let sock = libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0);
        if sock >= 0 {
            let mut ifr: libc::ifreq = std::mem::zeroed();
            let lo = b"lo\0";
            std::ptr::copy_nonoverlapping(
                lo.as_ptr() as *const libc::c_char,
                ifr.ifr_name.as_mut_ptr(),
                lo.len(),
            );
            if libc::ioctl(sock, libc::SIOCGIFFLAGS, &mut ifr) == 0 {
                ifr.ifr_ifru.ifru_flags |= (libc::IFF_UP | libc::IFF_RUNNING) as i16;
                let _ = libc::ioctl(sock, libc::SIOCSIFFLAGS, &ifr);
            }
            libc::close(sock);
        }
    }
}

fn create_log_ring(name: &str) -> nix::Result<OwnedFd> {
    let cname = CString::new(format!("coreos-log-{}", name)).unwrap();
    let fd = memfd_create(
        &cname,
        MemFdCreateFlag::MFD_CLOEXEC | MemFdCreateFlag::MFD_ALLOW_SEALING,
    )?;
    let _ = fcntl(fd.as_raw_fd(), FcntlArg::F_ADD_SEALS(SealFlag::F_SEAL_SHRINK));
    Ok(fd)
}

fn spawn_service(svc: &mut ManagedService) -> std::io::Result<()> {
    let log_fd = svc.log_memfd.as_raw_fd();
    let tty_cstr = svc.spec.tty.as_ref().and_then(|t| CString::new(t.as_str()).ok());
    let use_jail = svc.spec.jail;
    let mut policy = JailPolicy::default();
    policy.ro_paths.extend(svc.spec.jail_ro.clone());
    policy.rw_paths.extend(svc.spec.jail_rw.clone());

    let mut cmd = Command::new(&svc.spec.exec);
    cmd.args(&svc.spec.args)
        .env("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        .env("TERM", "vt100");

    unsafe {
        cmd.pre_exec(move || {
            if let Some(ref tty) = tty_cstr {
                libc::setsid();
                let tfd = libc::open(tty.as_ptr(), libc::O_RDWR);
                if tfd >= 0 {
                    libc::ioctl(tfd, libc::TIOCSCTTY, 0);
                    libc::dup2(tfd, libc::STDIN_FILENO);
                    libc::dup2(tfd, libc::STDOUT_FILENO);
                    libc::dup2(tfd, libc::STDERR_FILENO);
                    if tfd > 2 {
                        libc::close(tfd);
                    }
                }
            } else {
                libc::dup2(log_fd, libc::STDOUT_FILENO);
                libc::dup2(log_fd, libc::STDERR_FILENO);
            }

            if use_jail {
                apply_jail(&policy)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::PermissionDenied, e))?;
            }
            Ok(())
        });
    }

    let child = cmd.spawn()?;
    let pid = child.id();

    let slice = if svc.spec.jail {
        "jailed"
    } else if svc.spec.cgroup == "batch" {
        "batch"
    } else {
        "foreground"
    };
    let _ = fs::write(
        format!("/sys/fs/cgroup/coreos.slice/{}/cgroup.procs", slice),
        pid.to_string(),
    );

    println!(
        "[coreos-pid1] started '{}' (pid={}, cgroup={}, jail={})",
        svc.spec.name, pid, slice, svc.spec.jail
    );
    svc.child = Some(child);
    svc.last_start = Instant::now();
    svc.manual_stopped = false;
    Ok(())
}

fn load_services() -> Vec<ManagedService> {
    let mut services = Vec::new();
    let Ok(entries) = fs::read_dir(SERVICE_DIR) else {
        return services;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        if let Ok(content) = fs::read_to_string(&path) {
            if let Ok(spec) = toml::from_str::<ServiceSpec>(&content) {
                if let Ok(log_memfd) = create_log_ring(&spec.name) {
                    services.push(ManagedService {
                        spec,
                        child: None,
                        log_memfd,
                        last_start: Instant::now() - Duration::from_secs(10),
                        manual_stopped: false,
                    });
                }
            }
        }
    }
    services
}

fn read_log_slice(fd: i32, offset: u64) -> (u64, Vec<u8>) {
    let mut buf = vec![0u8; 65536];
    let n = unsafe {
        libc::pread(
            fd,
            buf.as_mut_ptr() as *mut libc::c_void,
            buf.len(),
            offset as libc::off_t,
        )
    };
    if n <= 0 {
        (offset, Vec::new())
    } else {
        let len = n as usize;
        buf.truncate(len);
        (offset + len as u64, buf)
    }
}

fn handle_ctl_client(
    mut stream: UnixStream,
    services: &mut Vec<ManagedService>,
    pid_map: &mut HashMap<i32, usize>,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return;
    }

    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.is_empty() {
        return;
    }

    match parts[0] {
        "LIST" => {
            for svc in services.iter() {
                let (state, pid_str) = match &svc.child {
                    Some(c) => ("running", c.id().to_string()),
                    None => ("stopped", "-".to_string()),
                };
                let slice = if svc.spec.jail {
                    "jailed"
                } else {
                    svc.spec.cgroup.as_str()
                };
                let _ = writeln!(stream, "{}\t{}\t{}\t{}", svc.spec.name, state, pid_str, slice);
            }
        }
        "STATUS" if parts.len() >= 2 => {
            let name = parts[1];
            if let Some(svc) = services.iter().find(|s| s.spec.name == name) {
                match &svc.child {
                    Some(c) => {
                        let _ = writeln!(
                            stream,
                            "ACTIVE\t{} is running (pid={}, cgroup={}, jail={})",
                            name,
                            c.id(),
                            svc.spec.cgroup,
                            svc.spec.jail
                        );
                    }
                    None => {
                        let _ = writeln!(stream, "INACTIVE\t{} is stopped", name);
                    }
                }
            } else {
                let _ = writeln!(stream, "UNKNOWN\tservice '{}' not found", name);
            }
        }
        "START" if parts.len() >= 2 => {
            let name = parts[1];
            if let Some((idx, svc)) = services
                .iter_mut()
                .enumerate()
                .find(|(_, s)| s.spec.name == name)
            {
                if svc.child.is_some() {
                    let _ = writeln!(stream, "OK\t{} already running", name);
                } else if let Err(e) = spawn_service(svc) {
                    let _ = writeln!(stream, "ERR\tfailed to start {}: {}", name, e);
                } else {
                    if let Some(ref c) = svc.child {
                        pid_map.insert(c.id() as i32, idx);
                    }
                    let _ = writeln!(stream, "OK\tstarted {}", name);
                }
            } else {
                let _ = writeln!(stream, "ERR\tservice '{}' not found", name);
            }
        }
        "STOP" if parts.len() >= 2 => {
            let name = parts[1];
            if let Some(svc) = services.iter_mut().find(|s| s.spec.name == name) {
                svc.manual_stopped = true;
                if let Some(ref c) = svc.child {
                    let _ = kill(Pid::from_raw(c.id() as i32), Signal::SIGTERM);
                    let _ = writeln!(stream, "OK\tsent SIGTERM to {}", name);
                } else {
                    let _ = writeln!(stream, "OK\t{} already stopped", name);
                }
            } else {
                let _ = writeln!(stream, "ERR\tservice '{}' not found", name);
            }
        }
        "RESTART" if parts.len() >= 2 => {
            let name = parts[1];
            if let Some((idx, svc)) = services
                .iter_mut()
                .enumerate()
                .find(|(_, s)| s.spec.name == name)
            {
                if let Some(ref mut c) = svc.child {
                    let raw = c.id() as i32;
                    pid_map.remove(&raw);
                    let _ = kill(Pid::from_raw(raw), Signal::SIGTERM);
                    let _ = c.wait();
                    svc.child = None;
                }
                if let Err(e) = spawn_service(svc) {
                    let _ = writeln!(stream, "ERR\tfailed to restart {}: {}", name, e);
                } else {
                    if let Some(ref c) = svc.child {
                        pid_map.insert(c.id() as i32, idx);
                    }
                    let _ = writeln!(stream, "OK\trestarted {}", name);
                }
            } else {
                let _ = writeln!(stream, "ERR\tservice '{}' not found", name);
            }
        }
        "LOGS" if parts.len() >= 2 => {
            let name = parts[1];
            let offset: u64 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
            if let Some(svc) = services.iter().find(|s| s.spec.name == name) {
                let (next_off, data) = read_log_slice(svc.log_memfd.as_raw_fd(), offset);
                let _ = writeln!(stream, "OFFSET\t{}\t{}", next_off, data.len());
                let _ = stream.write_all(&data);
            } else {
                let _ = writeln!(stream, "ERR\tservice '{}' not found", name);
            }
        }
        "NETPLAN_APPLY" => match netplan::apply_all() {
            Ok(summary) => {
                let _ = writeln!(stream, "OK\t{}", summary);
            }
            Err(e) => {
                let _ = writeln!(stream, "ERR\t{}", e);
            }
        },
        _ => {
            let _ = writeln!(stream, "ERR\tunknown command");
        }
    }
    reload_new_services(services);
}

fn shutdown_system(services: &mut [ManagedService], mode: RebootMode) -> ! {
    println!("[coreos-pid1] shutting down supervised services...");
    for svc in services.iter_mut() {
        if let Some(ref child) = svc.child {
            let _ = kill(Pid::from_raw(child.id() as i32), Signal::SIGTERM);
        }
    }
    std::thread::sleep(Duration::from_millis(250));
    while let Ok(WaitStatus::Exited(_, _)) | Ok(WaitStatus::Signaled(_, _, _)) =
        waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG))
    {}
    sync();
    let _ = reboot(mode);
    loop {
        std::thread::park();
    }
}

fn main() {
    if std::process::id() != 1 {
        eprintln!("coreos-pid1 must run as PID 1");
        std::process::exit(1);
    }

    mount_api_filesystems();
    mount_writable_overlays();
    let _ = unshare(CloneFlags::CLONE_FS);
    configure_hostname_and_loopback();
    setup_cgroup_hierarchy();
    setup_ebpf_gatekeeper();
    let hw = hw_prober::probe_and_configure();
    let _ = netplan::apply_all();

    println!(
        "[coreos-pid1] Linux 7.3 LTS boot complete ({} MiB RAM, {} NUMA, {} MiB ZRAM) — zero systemd active",
        hw.total_ram_bytes / (1024 * 1024),
        hw.numa_nodes,
        hw.zram_bytes / (1024 * 1024)
    );

    let mut mask = SigSet::empty();
    mask.add(Signal::SIGCHLD);
    mask.add(Signal::SIGTERM);
    mask.add(Signal::SIGINT);
    mask.thread_block().expect("failed to block signals");

    let sfd = SignalFd::with_flags(&mask, SfdFlags::SFD_NONBLOCK | SfdFlags::SFD_CLOEXEC)
        .expect("failed to create signalfd");
    let epoll = Epoll::new(EpollCreateFlags::EPOLL_CLOEXEC).expect("failed to create epoll");
    epoll
        .add(&sfd, EpollEvent::new(EpollFlags::EPOLLIN, TOKEN_SIGNALFD))
        .expect("failed to register signalfd");

    let _ = fs::remove_file(CTL_SOCK_PATH);
    let ctl_listener =
        UnixListener::bind(CTL_SOCK_PATH).expect("failed to bind /run/coreos/pid1.sock");
    ctl_listener
        .set_nonblocking(true)
        .expect("failed to set ctl_listener nonblocking");
    epoll
        .add(
            &ctl_listener,
            EpollEvent::new(EpollFlags::EPOLLIN, TOKEN_CTL_SOCK),
        )
        .expect("failed to register ctl_listener");

    let mut psi = PsiWatchdog::register(&epoll);
    let mut services = load_services();
    let mut pid_map: HashMap<i32, usize> = HashMap::new();

    for (idx, svc) in services.iter_mut().enumerate() {
        if let Ok(()) = spawn_service(svc) {
            if let Some(ref c) = svc.child {
                pid_map.insert(c.id() as i32, idx);
            }
        }
    }

    let mut events = [EpollEvent::empty(); 16];
    loop {
        let ready = epoll
            .wait(&mut events, EpollTimeout::from(1000u16))
            .unwrap_or(0);

        for ev in &events[..ready] {
            match ev.data() {
                TOKEN_SIGNALFD => {
                    while let Ok(Some(siginfo)) = sfd.read_signal() {
                        match Signal::try_from(siginfo.ssi_signo as i32) {
                            Ok(Signal::SIGTERM) => {
                                shutdown_system(&mut services, RebootMode::RB_POWER_OFF)
                            }
                            Ok(Signal::SIGINT) => {
                                shutdown_system(&mut services, RebootMode::RB_AUTOBOOT)
                            }
                            Ok(Signal::SIGCHLD) => loop {
                                match waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG)) {
                                    Ok(WaitStatus::Exited(pid, code)) => {
                                        handle_exit(pid.as_raw(), code, &mut services, &mut pid_map);
                                    }
                                    Ok(WaitStatus::Signaled(pid, sig, _)) => {
                                        handle_exit(
                                            pid.as_raw(),
                                            128 + sig as i32,
                                            &mut services,
                                            &mut pid_map,
                                        );
                                    }
                                    Ok(WaitStatus::StillAlive) | Err(_) => break,
                                    _ => {}
                                }
                            },
                            _ => {}
                        }
                    }
                }
                TOKEN_CTL_SOCK => {
                    while let Ok((stream, _)) = ctl_listener.accept() {
                        handle_ctl_client(stream, &mut services, &mut pid_map);
                    }
                }
                token @ (TOKEN_PSI_MEM_SOME | TOKEN_PSI_MEM_FULL | TOKEN_PSI_IO_SOME) => {
                    psi.handle_event(token);
                }
                _ => {}
            }
        }

        psi.tick_recovery();
    }
}

fn handle_exit(
    raw_pid: i32,
    status: i32,
    services: &mut [ManagedService],
    pid_map: &mut HashMap<i32, usize>,
) {
    let Some(idx) = pid_map.remove(&raw_pid) else {
        return;
    };
    let svc = &mut services[idx];
    svc.child = None;
    println!(
        "[coreos-pid1] '{}' (pid={}) exited with status {}",
        svc.spec.name, raw_pid, status
    );

    if svc.spec.restart && !svc.manual_stopped {
        if svc.last_start.elapsed() < Duration::from_millis(500) {
            std::thread::sleep(Duration::from_millis(500));
        }
        if spawn_service(svc).is_ok() {
            if let Some(ref c) = svc.child {
                pid_map.insert(c.id() as i32, idx);
            }
        }
    }
}

fn find_device_by_partname(target: &str) -> Option<String> {
    let entries = fs::read_dir("/sys/class/block").ok()?;
    for entry in entries.flatten() {
        let uevent_path = entry.path().join("uevent");
        if let Ok(content) = fs::read_to_string(&uevent_path) {
            for line in content.lines() {
                if line.strip_prefix("PARTNAME=") == Some(target) {
                    return Some(format!("/dev/{}", entry.file_name().to_string_lossy()));
                }
            }
        }
    }
    None
}

fn lookup_uid(username: &str) -> Option<u32> {
    let passwd = fs::read_to_string("/etc/passwd").ok()?;
    for line in passwd.lines() {
        let mut cols = line.split(':');
        if cols.next() == Some(username) {
            let _pw = cols.next()?;
            return cols.next()?.parse().ok();
        }
    }
    None
}

fn mount_writable_overlays() {
    let has_overlay = fs::read_to_string("/proc/filesystems")
        .map(|s| s.contains("overlay"))
        .unwrap_or(false);
    if !has_overlay {
        eprintln!("[coreos-pid1] warning: kernel lacks overlayfs; /, /etc, and /var remain read-only");
        return;
    }

    let backing = if let Some(dev) = find_device_by_partname("COREOS_DATA") {
        if mount(
            Some(dev.as_str()),
            "/mnt/data",
            Some("ext4"),
            MsFlags::MS_NOATIME,
            None::<&str>,
        )
        .is_ok()
        {
            format!("persistent {}", dev)
        } else {
            let _ = mount(
                Some("tmpfs"),
                "/mnt/data",
                Some("tmpfs"),
                MsFlags::MS_NOATIME,
                Some("mode=0755"),
            );
            "ephemeral tmpfs".to_string()
        }
    } else {
        let _ = mount(
            Some("tmpfs"),
            "/mnt/data",
            Some("tmpfs"),
            MsFlags::MS_NOATIME,
            Some("mode=0755"),
        );
        "ephemeral tmpfs".to_string()
    };

    let mut mounted = Vec::new();
    for dir in ["home", "etc", "var", "usr", "root"] {
        let upper = format!("/mnt/data/{}_upper", dir);
        let work = format!("/mnt/data/{}_work", dir);
        let target = format!("/{}", dir);
        let _ = fs::create_dir_all(&upper);
        let _ = fs::create_dir_all(&work);
        let opts = format!("lowerdir={},upperdir={},workdir={}", target, upper, work);
        if mount(
            Some("overlay"),
            target.as_str(),
            Some("overlay"),
            MsFlags::MS_NOATIME,
            Some(opts.as_str()),
        )
        .is_ok()
        {
            mounted.push(target);
        }
    }

    let apt_uid = lookup_uid("_apt").unwrap_or(100);
    for partial in ["/var/lib/apt/lists/partial", "/var/cache/apt/archives/partial"] {
        let _ = fs::create_dir_all(partial);
        if let Ok(cpath) = CString::new(partial) {
            unsafe {
                libc::chown(cpath.as_ptr(), apt_uid, 0);
                libc::chmod(cpath.as_ptr(), 0o700);
            }
        }
    }

    println!(
        "[coreos-pid1] mounted writable overlayfs ({}) on [{}]",
        backing,
        mounted.join(", ")
    );
}

fn reload_new_services(services: &mut Vec<ManagedService>) {
    let Ok(entries) = fs::read_dir(SERVICE_DIR) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        if let Ok(content) = fs::read_to_string(&path) {
            if let Ok(spec) = toml::from_str::<ServiceSpec>(&content) {
                if !services.iter().any(|s| s.spec.name == spec.name) {
                    if let Ok(log_memfd) = create_log_ring(&spec.name) {
                        services.push(ManagedService {
                            spec,
                            child: None,
                            log_memfd,
                            last_start: Instant::now() - Duration::from_secs(10),
                            manual_stopped: false,
                        });
                    }
                }
            }
        }
    }
}
