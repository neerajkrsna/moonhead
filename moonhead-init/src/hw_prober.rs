use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::path::Path;
use std::time::Instant;

pub struct HardwareProfile {
    pub total_ram_bytes: u64,
    pub numa_nodes: usize,
    pub zram_bytes: u64,
}

pub fn probe_and_configure() -> HardwareProfile {
    let start = Instant::now();
    let total_ram_bytes = detect_total_ram_bytes();
    let numa_nodes = detect_numa_nodes();
    let zram_bytes = setup_zram(total_ram_bytes);

    tune_vm_sysctls(total_ram_bytes, zram_bytes > 0);
    probe_resctrl();

    let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
    println!(
        "[moonhead-hw] ram={} MiB numa_nodes={} zram={} MiB configured in {:.2}ms",
        total_ram_bytes / (1024 * 1024),
        numa_nodes,
        zram_bytes / (1024 * 1024),
        elapsed_ms
    );

    HardwareProfile {
        total_ram_bytes,
        numa_nodes,
        zram_bytes,
    }
}

fn detect_total_ram_bytes() -> u64 {
    if let Ok(meminfo) = fs::read_to_string("/proc/meminfo") {
        for line in meminfo.lines() {
            if let Some(rest) = line.strip_prefix("MemTotal:") {
                let kb: u64 = rest
                    .split_whitespace()
                    .next()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(512 * 1024);
                return kb * 1024;
            }
        }
    }
    512 * 1024 * 1024
}

fn detect_numa_nodes() -> usize {
    let Ok(entries) = fs::read_dir("/sys/devices/system/node") else {
        return 1;
    };
    let count = entries
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("node"))
        .count();
    count.max(1)
}

fn setup_zram(total_ram_bytes: u64) -> u64 {
    if !Path::new("/sys/block/zram0").exists() {
        // Trigger kernel hot_add if zram is built-in or auto-loaded
        let _ = fs::read_to_string("/sys/class/zram-control/hot_add");
    }
    if !Path::new("/sys/block/zram0").exists() {
        return 0;
    }

    // Allocate 50% of physical RAM for compressed ZRAM swap (256 MiB min, 8 GiB max)
    let disksize = (total_ram_bytes / 2).clamp(256 * 1024 * 1024, 8 * 1024 * 1024 * 1024);

    let _ = fs::write("/sys/block/zram0/reset", "1");

    // Select fastest available compressor (prefer zstd -> lz4 -> lzo-rle)
    if let Ok(algos) = fs::read_to_string("/sys/block/zram0/comp_algorithm") {
        let chosen = ["zstd", "lz4", "lzo-rle"]
            .into_iter()
            .find(|a| algos.contains(a))
            .unwrap_or("lzo-rle");
        let _ = fs::write("/sys/block/zram0/comp_algorithm", chosen);
    }

    if fs::write("/sys/block/zram0/disksize", disksize.to_string()).is_err() {
        return 0;
    }

    if write_swap_header("/dev/zram0", disksize).is_err() {
        return 0;
    }

    const SWAP_FLAG_PREFER: libc::c_int = 0x8000;
    const SWAP_FLAG_PRIO_SHIFT: libc::c_int = 0;

    let dev = CString::new("/dev/zram0").unwrap();
    let flags = SWAP_FLAG_PREFER | (100 << SWAP_FLAG_PRIO_SHIFT);
    let rc = unsafe { libc::swapon(dev.as_ptr(), flags) };

    if rc == 0 {
        disksize
    } else {
        0
    }
}

fn write_swap_header(dev_path: &str, disksize: u64) -> std::io::Result<()> {
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as usize;
    if page_size < 4096 || disksize < (page_size as u64 * 10) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "invalid page or device size",
        ));
    }

    let last_page = ((disksize / page_size as u64) - 1) as u32;
    let mut header = vec![0u8; page_size];

    // Linux swap_header_v1_2 layout at byte offset 1024
    header[1024..1028].copy_from_slice(&1u32.to_ne_bytes()); // version = 1
    header[1028..1032].copy_from_slice(&last_page.to_ne_bytes()); // last_page
    header[1032..1036].copy_from_slice(&0u32.to_ne_bytes()); // nr_badpages = 0

    // Magic signature at the final 10 bytes of page 0
    header[page_size - 10..page_size].copy_from_slice(b"SWAPSPACE2");

    let mut file = OpenOptions::new().write(true).open(dev_path)?;
    file.seek(SeekFrom::Start(0))?;
    file.write_all(&header)?;
    file.sync_all()?;
    Ok(())
}

fn tune_vm_sysctls(total_ram_bytes: u64, zram_active: bool) {
    // High swappiness + zero readahead cluster maximizes MGLRU + ZRAM efficiency
    let _ = fs::write("/proc/sys/vm/swappiness", if zram_active { "180" } else { "60" });
    let _ = fs::write("/proc/sys/vm/page-cluster", if zram_active { "0" } else { "3" });
    let _ = fs::write("/proc/sys/vm/watermark_boost_factor", "0");

    // Bound dirty writeback queues to prevent I/O stalls on large-RAM hosts
    let dirty_bg = (total_ram_bytes / 50).clamp(16 * 1024 * 1024, 64 * 1024 * 1024);
    let dirty_fg = (total_ram_bytes / 20).clamp(32 * 1024 * 1024, 256 * 1024 * 1024);
    let _ = fs::write("/proc/sys/vm/dirty_background_bytes", dirty_bg.to_string());
    let _ = fs::write("/proc/sys/vm/dirty_bytes", dirty_fg.to_string());
}

fn probe_resctrl() {
    let Ok(filesystems) = fs::read_to_string("/proc/filesystems") else {
        return;
    };
    if !filesystems.contains("resctrl") {
        return;
    }
    let _ = fs::create_dir_all("/sys/fs/resctrl");
    let src = CString::new("resctrl").unwrap();
    let dst = CString::new("/sys/fs/resctrl").unwrap();
    let rc = unsafe {
        libc::mount(
            src.as_ptr(),
            dst.as_ptr(),
            src.as_ptr(),
            0,
            std::ptr::null(),
        )
    };
    if rc == 0 {
        if let Ok(cbm) = fs::read_to_string("/sys/fs/resctrl/info/L3/cbm_mask") {
            println!("[moonhead-hw] resctrl mounted (L3 cbm_mask={})", cbm.trim());
        }
    }
}
