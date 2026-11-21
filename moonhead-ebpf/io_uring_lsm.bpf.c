#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

char LICENSE[] SEC("license") = "GPL";

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u64);   // cgroup_id from bpf_get_current_cgroup_id()
    __type(value, __u32); // 1 = block privileged/raw io_uring ops
} jailed_cgroups SEC(".maps");

static __always_inline bool is_jailed_cgroup(void)
{
    __u64 cgid = bpf_get_current_cgroup_id();
    __u32 *policy = bpf_map_lookup_elem(&jailed_cgroups, &cgid);
    return policy && (*policy == 1);
}

SEC("lsm/uring_sqpoll")
int BPF_PROG(moonhead_uring_sqpoll)
{
    if (is_jailed_cgroup())
        return -1; // -EPERM: deny kernel SQPOLL thread creation for jailed tasks
    return 0;
}

SEC("lsm/uring_override_creds")
int BPF_PROG(moonhead_uring_override_creds, const struct cred *new_cred)
{
    if (is_jailed_cgroup())
        return -1; // -EPERM: deny credential switching inside io_uring SQEs
    return 0;
}

SEC("lsm/uring_cmd")
int BPF_PROG(moonhead_uring_cmd, struct io_uring_cmd *cmd)
{
    if (is_jailed_cgroup())
        return -1; // -EPERM: deny raw passthrough device commands via io_uring
    return 0;
}
