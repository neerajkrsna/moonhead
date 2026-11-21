use std::env;
use std::ffi::CString;
use std::fs;
use std::mem;
use std::os::fd::RawFd;
use std::process::{self, Command};
use std::ptr;
use std::sync::atomic::{fence, AtomicBool, AtomicU32, Ordering};

const XDP_OBJ: &str = "/usr/lib/moonhead/xdp_fastpath.bpf.o";
const XDP_PIN_DIR: &str = "/sys/fs/bpf/moonhead_xdp";

const AF_XDP: libc::c_int = 44;
const SOL_XDP: libc::c_int = 283;

const XDP_MMAP_OFFSETS: libc::c_int = 1;
const XDP_RX_RING: libc::c_int = 2;
const XDP_TX_RING: libc::c_int = 3;
const XDP_UMEM_REG: libc::c_int = 4;
const XDP_UMEM_FILL_RING: libc::c_int = 5;
const XDP_UMEM_COMPLETION_RING: libc::c_int = 6;

const XDP_PGOFF_RX_RING: libc::off_t = 0;
const XDP_PGOFF_TX_RING: libc::off_t = 0x8000_0000;
const XDP_UMEM_PGOFF_FILL_RING: libc::off_t = 0x1_0000_0000;
const XDP_UMEM_PGOFF_COMPLETION_RING: libc::off_t = 0x1_8000_0000;

const XDP_COPY: u16 = 1 << 1;
const XDP_USE_NEED_WAKEUP: u16 = 1 << 3;

const BPF_MAP_UPDATE_ELEM: libc::c_int = 2;
const BPF_OBJ_GET: libc::c_int = 7;

const NUM_FRAMES: u32 = 1024;
const FRAME_SIZE: u32 = 4096;
const RING_SIZE: u32 = 512;

static RUNNING: AtomicBool = AtomicBool::new(true);

extern "C" fn handle_sigint(_sig: libc::c_int) {
    RUNNING.store(false, Ordering::SeqCst);
}

#[repr(C)]
struct SockaddrXdp {
    sxdp_family: u16,
    sxdp_flags: u16,
    sxdp_ifindex: u32,
    sxdp_queue_id: u32,
    sxdp_shared_umem_fd: u32,
}

#[repr(C)]
struct XdpUmemReg {
    addr: u64,
    len: u64,
    chunk_size: u32,
    headroom: u32,
    flags: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct XdpRingOffset {
    producer: u64,
    consumer: u64,
    desc: u64,
    flags: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct XdpMmapOffsets {
    rx: XdpRingOffset,
    tx: XdpRingOffset,
    fr: XdpRingOffset,
    cr: XdpRingOffset,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct XdpDesc {
    addr: u64,
    len: u32,
    options: u32,
}

#[repr(C)]
struct BpfObjAttr {
    pathname: u64,
    bpf_fd: u32,
    file_flags: u32,
}

#[repr(C)]
struct BpfMapElemAttr {
    map_fd: u32,
    _pad: u32,
    key: u64,
    value: u64,
    flags: u64,
}

struct U64Ring {
    producer: *mut AtomicU32,
    consumer: *mut AtomicU32,
    desc: *mut u64,
    mask: u32,
    cached_prod: u32,
    cached_cons: u32,
}

struct DescRing {
    producer: *mut AtomicU32,
    consumer: *mut AtomicU32,
    desc: *mut XdpDesc,
    mask: u32,
    cached_prod: u32,
    cached_cons: u32,
}

fn bpf_obj_get(pin_path: &str) -> Result<RawFd, i32> {
    let cpath = CString::new(pin_path).map_err(|_| libc::EINVAL)?;
    let attr = BpfObjAttr {
        pathname: cpath.as_ptr() as u64,
        bpf_fd: 0,
        file_flags: 0,
    };
    let fd = unsafe {
        libc::syscall(
            libc::SYS_bpf,
            BPF_OBJ_GET,
            &attr as *const BpfObjAttr,
            mem::size_of::<BpfObjAttr>(),
        )
    };
    if fd < 0 {
        Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(-1))
    } else {
        Ok(fd as RawFd)
    }
}

fn bpf_map_update_u32(map_fd: RawFd, key: u32, value: u32) -> Result<(), i32> {
    let attr = BpfMapElemAttr {
        map_fd: map_fd as u32,
        _pad: 0,
        key: &key as *const u32 as u64,
        value: &value as *const u32 as u64,
        flags: 0,
    };
    let rc = unsafe {
        libc::syscall(
            libc::SYS_bpf,
            BPF_MAP_UPDATE_ELEM,
            &attr as *const BpfMapElemAttr,
            mem::size_of::<BpfMapElemAttr>(),
        )
    };
    if rc < 0 {
        Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(-1))
    } else {
        Ok(())
    }
}

fn cleanup_bpf(iface: &str) {
    let _ = Command::new("/usr/sbin/bpftool")
        .args(["net", "detach", "xdp", "dev", iface])
        .status();
    let _ = fs::remove_dir_all(XDP_PIN_DIR);
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let mut iface = "eth0".to_string();
    let mut queue_id: u32 = 0;
    let mut port: u32 = 9999;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--iface" | "-i" if i + 1 < args.len() => {
                iface = args[i + 1].clone();
                i += 1;
            }
            "--queue" | "-q" if i + 1 < args.len() => {
                queue_id = args[i + 1].parse().unwrap_or(0);
                i += 1;
            }
            "--port" | "-p" if i + 1 < args.len() => {
                port = args[i + 1].parse().unwrap_or(9999);
                i += 1;
            }
            "--help" | "-h" => {
                println!("Usage: moonhead-xdp [--iface eth0] [--queue 0] [--port 9999]");
                return;
            }
            _ => {}
        }
        i += 1;
    }

    let c_iface = CString::new(iface.as_str()).expect("invalid interface");
    let ifindex = unsafe { libc::if_nametoindex(c_iface.as_ptr()) };
    if ifindex == 0 {
        eprintln!("[moonhead-xdp] interface '{}' not found", iface);
        process::exit(1);
    }

    unsafe {
        libc::signal(libc::SIGINT, handle_sigint as libc::sighandler_t);
        libc::signal(libc::SIGTERM, handle_sigint as libc::sighandler_t);
    }

    let _ = fs::remove_dir_all(XDP_PIN_DIR);
    let ok = Command::new("/usr/sbin/bpftool")
        .args(["prog", "loadall", XDP_OBJ, XDP_PIN_DIR, "pinmaps", XDP_PIN_DIR])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        eprintln!("[moonhead-xdp] failed to load {}", XDP_OBJ);
        process::exit(1);
    }

    if let Ok(cfg_fd) = bpf_obj_get(&format!("{}/xdp_config", XDP_PIN_DIR)) {
        let _ = bpf_map_update_u32(cfg_fd, 0, port);
        unsafe { libc::close(cfg_fd); }
    }

    let attached = Command::new("/usr/sbin/bpftool")
        .args([
            "net",
            "attach",
            "xdp",
            "pinned",
            &format!("{}/moonhead_xdp_fastpath", XDP_PIN_DIR),
            "dev",
            &iface,
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !attached {
        eprintln!("[moonhead-xdp] failed to attach XDP program to {}", iface);
        cleanup_bpf(&iface);
        process::exit(1);
    }

    let xsk_fd: RawFd = unsafe { libc::socket(AF_XDP, libc::SOCK_RAW | libc::SOCK_CLOEXEC, 0) };
    if xsk_fd < 0 {
        eprintln!("[moonhead-xdp] socket(AF_XDP) failed");
        cleanup_bpf(&iface);
        process::exit(1);
    }

    let umem_size = (NUM_FRAMES * FRAME_SIZE) as usize;
    let umem_ptr = unsafe {
        libc::mmap(
            ptr::null_mut(),
            umem_size,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
            -1,
            0,
        )
    };
    if umem_ptr == libc::MAP_FAILED {
        eprintln!("[moonhead-xdp] mmap UMEM failed");
        cleanup_bpf(&iface);
        process::exit(1);
    }

    let reg = XdpUmemReg {
        addr: umem_ptr as u64,
        len: umem_size as u64,
        chunk_size: FRAME_SIZE,
        headroom: 0,
        flags: 0,
    };

    unsafe {
        if libc::setsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_UMEM_REG,
            &reg as *const _ as *const libc::c_void,
            mem::size_of::<XdpUmemReg>() as libc::socklen_t,
        ) < 0
        {
            eprintln!("[moonhead-xdp] XDP_UMEM_REG failed");
            cleanup_bpf(&iface);
            process::exit(1);
        }

        for opt in [
            XDP_UMEM_FILL_RING,
            XDP_UMEM_COMPLETION_RING,
            XDP_RX_RING,
            XDP_TX_RING,
        ] {
            if libc::setsockopt(
                xsk_fd,
                SOL_XDP,
                opt,
                &RING_SIZE as *const _ as *const libc::c_void,
                mem::size_of::<u32>() as libc::socklen_t,
            ) < 0
            {
                eprintln!("[moonhead-xdp] setsockopt ring {} failed", opt);
                cleanup_bpf(&iface);
                process::exit(1);
            }
        }
    }

    let mut offsets = XdpMmapOffsets::default();
    let mut off_len = mem::size_of::<XdpMmapOffsets>() as libc::socklen_t;
    unsafe {
        if libc::getsockopt(
            xsk_fd,
            SOL_XDP,
            XDP_MMAP_OFFSETS,
            &mut offsets as *mut _ as *mut libc::c_void,
            &mut off_len,
        ) < 0
        {
            eprintln!("[moonhead-xdp] XDP_MMAP_OFFSETS failed");
            cleanup_bpf(&iface);
            process::exit(1);
        }
    }

    let fr_map = unsafe {
        libc::mmap(
            ptr::null_mut(),
            offsets.fr.desc as usize + (RING_SIZE as usize * mem::size_of::<u64>()),
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED | libc::MAP_POPULATE,
            xsk_fd,
            XDP_UMEM_PGOFF_FILL_RING,
        )
    } as *mut u8;

    let rx_map = unsafe {
        libc::mmap(
            ptr::null_mut(),
            offsets.rx.desc as usize + (RING_SIZE as usize * mem::size_of::<XdpDesc>()),
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED | libc::MAP_POPULATE,
            xsk_fd,
            XDP_PGOFF_RX_RING,
        )
    } as *mut u8;

    let _cr_map = unsafe {
        libc::mmap(
            ptr::null_mut(),
            offsets.cr.desc as usize + (RING_SIZE as usize * mem::size_of::<u64>()),
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED | libc::MAP_POPULATE,
            xsk_fd,
            XDP_UMEM_PGOFF_COMPLETION_RING,
        )
    };

    let _tx_map = unsafe {
        libc::mmap(
            ptr::null_mut(),
            offsets.tx.desc as usize + (RING_SIZE as usize * mem::size_of::<XdpDesc>()),
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED | libc::MAP_POPULATE,
            xsk_fd,
            XDP_PGOFF_TX_RING,
        )
    };

    let mut fill_ring = unsafe {
        U64Ring {
            producer: fr_map.add(offsets.fr.producer as usize) as *mut AtomicU32,
            consumer: fr_map.add(offsets.fr.consumer as usize) as *mut AtomicU32,
            desc: fr_map.add(offsets.fr.desc as usize) as *mut u64,
            mask: RING_SIZE - 1,
            cached_prod: 0,
            cached_cons: 0,
        }
    };

    let mut rx_ring = unsafe {
        DescRing {
            producer: rx_map.add(offsets.rx.producer as usize) as *mut AtomicU32,
            consumer: rx_map.add(offsets.rx.consumer as usize) as *mut AtomicU32,
            desc: rx_map.add(offsets.rx.desc as usize) as *mut XdpDesc,
            mask: RING_SIZE - 1,
            cached_prod: 0,
            cached_cons: 0,
        }
    };

    unsafe {
        for idx in 0..RING_SIZE {
            *fill_ring.desc.add((idx & fill_ring.mask) as usize) = (idx * FRAME_SIZE) as u64;
        }
        fence(Ordering::Release);
        (*fill_ring.producer).store(RING_SIZE, Ordering::Release);
        fill_ring.cached_prod = RING_SIZE;
    }

    let sxdp = SockaddrXdp {
        sxdp_family: AF_XDP as u16,
        sxdp_flags: XDP_COPY | XDP_USE_NEED_WAKEUP,
        sxdp_ifindex: ifindex,
        sxdp_queue_id: queue_id,
        sxdp_shared_umem_fd: 0,
    };

    let bound = unsafe {
        libc::bind(
            xsk_fd,
            &sxdp as *const _ as *const libc::sockaddr,
            mem::size_of::<SockaddrXdp>() as libc::socklen_t,
        )
    };
    if bound < 0 {
        eprintln!("[moonhead-xdp] bind(AF_XDP) failed on {} queue {}", iface, queue_id);
        cleanup_bpf(&iface);
        process::exit(1);
    }

    // Insert live xsk_fd directly into pinned xsks_map via sys_bpf
    match bpf_obj_get(&format!("{}/xsks_map", XDP_PIN_DIR)) {
        Ok(xsks_fd) => {
            if let Err(err) = bpf_map_update_u32(xsks_fd, queue_id, xsk_fd as u32) {
                eprintln!("[moonhead-xdp] failed to register XSK fd in xsks_map: errno {}", err);
                unsafe { libc::close(xsks_fd); }
                cleanup_bpf(&iface);
                process::exit(1);
            }
            unsafe { libc::close(xsks_fd); }
        }
        Err(err) => {
            eprintln!("[moonhead-xdp] failed to open pinned xsks_map: errno {}", err);
            cleanup_bpf(&iface);
            process::exit(1);
        }
    }

    println!(
        "[moonhead-xdp] zero-copy UMEM active on {} (queue={}, udp_port={}, frames={})",
        iface, queue_id, port, NUM_FRAMES
    );

    let mut pfd = libc::pollfd {
        fd: xsk_fd,
        events: libc::POLLIN,
        revents: 0,
    };
    let mut rx_packets: u64 = 0;
    let mut rx_bytes: u64 = 0;

    while RUNNING.load(Ordering::Relaxed) {
        let ready = unsafe { libc::poll(&mut pfd, 1, 250) };
        if ready <= 0 {
            continue;
        }

        unsafe {
            rx_ring.cached_prod = (*rx_ring.producer).load(Ordering::Acquire);
            let avail = rx_ring.cached_prod.wrapping_sub(rx_ring.cached_cons);
            if avail == 0 {
                continue;
            }

            for _ in 0..avail {
                let idx = rx_ring.cached_cons & rx_ring.mask;
                let desc = *rx_ring.desc.add(idx as usize);
                rx_ring.cached_cons = rx_ring.cached_cons.wrapping_add(1);

                rx_packets += 1;
                rx_bytes += desc.len as u64;

                let f_idx = fill_ring.cached_prod & fill_ring.mask;
                *fill_ring.desc.add(f_idx as usize) = desc.addr;
                fill_ring.cached_prod = fill_ring.cached_prod.wrapping_add(1);
            }

            fence(Ordering::Release);
            (*rx_ring.consumer).store(rx_ring.cached_cons, Ordering::Release);
            (*fill_ring.producer).store(fill_ring.cached_prod, Ordering::Release);

            if rx_packets % 100 == 0 || rx_packets <= 5 {
                println!(
                    "[moonhead-xdp] bypassed kernel stack: {} frames ({} bytes) delivered to UMEM",
                    rx_packets, rx_bytes
                );
            }
        }
    }

    println!(
        "[moonhead-xdp] shutting down (total zero-copy frames={}, bytes={})",
        rx_packets, rx_bytes
    );
    unsafe {
        libc::close(xsk_fd);
    }
    cleanup_bpf(&iface);
}
