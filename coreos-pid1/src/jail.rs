use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

const SYS_LANDLOCK_CREATE_RULESET: libc::c_long = 444;
const SYS_LANDLOCK_ADD_RULE: libc::c_long = 445;
const SYS_LANDLOCK_RESTRICT_SELF: libc::c_long = 446;

const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1 << 0;
const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;

// Landlock filesystem access flags (ABI v1 - v5)
const LANDLOCK_ACCESS_FS_EXECUTE: u64 = 1 << 0;
const LANDLOCK_ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
const LANDLOCK_ACCESS_FS_READ_FILE: u64 = 1 << 2;
const LANDLOCK_ACCESS_FS_READ_DIR: u64 = 1 << 3;
const LANDLOCK_ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
const LANDLOCK_ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
const LANDLOCK_ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
const LANDLOCK_ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
const LANDLOCK_ACCESS_FS_MAKE_REG: u64 = 1 << 8;
const LANDLOCK_ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
const LANDLOCK_ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
const LANDLOCK_ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
const LANDLOCK_ACCESS_FS_MAKE_SYM: u64 = 1 << 12;
const LANDLOCK_ACCESS_FS_REFER: u64 = 1 << 13;
const LANDLOCK_ACCESS_FS_TRUNCATE: u64 = 1 << 14;
const LANDLOCK_ACCESS_FS_IOCTL_DEV: u64 = 1 << 15;

pub const JAILED_CGROUP_PATH: &str = "/sys/fs/cgroup/coreos.slice/jailed";

#[repr(C)]
struct LandlockRulesetAttr {
    handled_access_fs: u64,
}

#[repr(C, packed)]
struct LandlockPathBeneathAttr {
    allowed_access: u64,
    parent_fd: i32,
}

pub struct JailPolicy {
    pub ro_paths: Vec<String>,
    pub rw_paths: Vec<String>,
}

impl Default for JailPolicy {
    fn default() -> Self {
        Self {
            // Minimal runtime linker & shared library paths required to exec dynamically linked binaries
            ro_paths: vec![
                "/bin".into(),
                "/sbin".into(),
                "/usr".into(),
                "/lib".into(),
                "/lib64".into(),
                "/etc/ld.so.cache".into(),
                "/dev/null".into(),
                "/dev/zero".into(),
                "/dev/urandom".into(),
            ],
            rw_paths: Vec::new(),
        }
    }
}

fn handled_fs_mask_for_abi(abi: i64) -> u64 {
    let mut mask = LANDLOCK_ACCESS_FS_EXECUTE
        | LANDLOCK_ACCESS_FS_WRITE_FILE
        | LANDLOCK_ACCESS_FS_READ_FILE
        | LANDLOCK_ACCESS_FS_READ_DIR
        | LANDLOCK_ACCESS_FS_REMOVE_DIR
        | LANDLOCK_ACCESS_FS_REMOVE_FILE
        | LANDLOCK_ACCESS_FS_MAKE_CHAR
        | LANDLOCK_ACCESS_FS_MAKE_DIR
        | LANDLOCK_ACCESS_FS_MAKE_REG
        | LANDLOCK_ACCESS_FS_MAKE_SOCK
        | LANDLOCK_ACCESS_FS_MAKE_FIFO
        | LANDLOCK_ACCESS_FS_MAKE_BLOCK
        | LANDLOCK_ACCESS_FS_MAKE_SYM;

    if abi >= 2 {
        mask |= LANDLOCK_ACCESS_FS_REFER;
    }
    if abi >= 3 {
        mask |= LANDLOCK_ACCESS_FS_TRUNCATE;
    }
    if abi >= 5 {
        mask |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
    }
    mask
}

pub fn apply_jail(policy: &JailPolicy) -> Result<(), String> {
    // 1. Move calling process into the BPF-monitored jailed cgroup slice
    let _ = fs::write(
        format!("{}/cgroup.procs", JAILED_CGROUP_PATH),
        std::process::id().to_string(),
    );

    // 2. Query active kernel Landlock ABI version
    let abi = unsafe {
        libc::syscall(
            SYS_LANDLOCK_CREATE_RULESET,
            std::ptr::null::<libc::c_void>(),
            0usize,
            LANDLOCK_CREATE_RULESET_VERSION,
        )
    };
    if abi < 1 {
        return Err(format!("Landlock LSM not enabled in kernel (rc={})", abi));
    }

    let handled_fs = handled_fs_mask_for_abi(abi);
    let ro_access = (LANDLOCK_ACCESS_FS_EXECUTE
        | LANDLOCK_ACCESS_FS_READ_FILE
        | LANDLOCK_ACCESS_FS_READ_DIR)
        & handled_fs;
    let rw_access = handled_fs & !LANDLOCK_ACCESS_FS_REFER;

    let attr = LandlockRulesetAttr {
        handled_access_fs: handled_fs,
    };
    let ruleset_fd = unsafe {
        libc::syscall(
            SYS_LANDLOCK_CREATE_RULESET,
            &attr as *const LandlockRulesetAttr,
            std::mem::size_of::<LandlockRulesetAttr>(),
            0u32,
        )
    } as i32;
    if ruleset_fd < 0 {
        return Err("landlock_create_ruleset failed".into());
    }

    // 3. Grant FD-backed PATH_BENEATH rules only for explicitly allowlisted paths
    for p in &policy.ro_paths {
        let _ = add_path_rule(ruleset_fd, p, ro_access);
    }
    for p in &policy.rw_paths {
        let _ = add_path_rule(ruleset_fd, p, rw_access);
    }

    // 4. Drop privilege escalation capability and enforce Landlock ruleset on self
    let rc_nnp = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    if rc_nnp != 0 {
        unsafe { libc::close(ruleset_fd) };
        return Err("prctl(PR_SET_NO_NEW_PRIVS) failed".into());
    }

    let rc_restrict = unsafe { libc::syscall(SYS_LANDLOCK_RESTRICT_SELF, ruleset_fd, 0u32) };
    unsafe { libc::close(ruleset_fd) };
    if rc_restrict != 0 {
        return Err("landlock_restrict_self failed".into());
    }

    Ok(())
}

fn add_path_rule(ruleset_fd: i32, path: &str, allowed_access: u64) -> Result<(), ()> {
    let p = Path::new(path);
    if !p.exists() {
        return Err(());
    }
    let cpath = CString::new(p.as_os_str().as_bytes()).map_err(|_| ())?;
    let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(());
    }

    let rule = LandlockPathBeneathAttr {
        allowed_access,
        parent_fd: fd,
    };
    let rc = unsafe {
        libc::syscall(
            SYS_LANDLOCK_ADD_RULE,
            ruleset_fd,
            LANDLOCK_RULE_PATH_BENEATH,
            &rule as *const LandlockPathBeneathAttr,
            0u32,
        )
    };
    unsafe { libc::close(fd) };
    if rc == 0 {
        Ok(())
    } else {
        Err(())
    }
}
