// SPDX-License-Identifier: GPL-2.0
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

#define DSQ_FOREGROUND      0x1001ULL
#define DSQ_BATCH           0x1002ULL
#define DSQ_JAILED          0x1003ULL

#define TIER_FOREGROUND     1U
#define TIER_BATCH          2U
#define TIER_JAILED         3U

#define SLICE_FOREGROUND_NS 5000000ULL   /* 5 ms low-latency quantum */
#define SLICE_BATCH_NS      10000000ULL  /* 10 ms throughput quantum */
#define SLICE_JAILED_NS     2000000ULL   /* 2 ms bounded sandbox quantum */

#define STARVATION_LIMIT    16U

/* Maps cgroup v2 inode ID -> scheduling tier (1=foreground, 2=batch, 3=jailed) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u64);
    __type(value, __u32);
} cgroup_tiers SEC(".maps");

/* Per-CPU dispatch counters: [0]=local_fastpath, [1]=fg, [2]=batch, [3]=jailed */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} scx_stats SEC(".maps");

/* Per-CPU streak counter to prevent batch/jailed starvation */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u32);
} cpu_starve_streak SEC(".maps");

static __always_inline void bump_stat(__u32 idx)
{
    __u64 *cnt = bpf_map_lookup_elem(&scx_stats, &idx);
    if (cnt)
        __sync_fetch_and_add(cnt, 1);
}

static __always_inline __u32 lookup_task_tier(struct task_struct *p)
{
    __u64 cgid = BPF_CORE_READ(p, cgroups, dfl_cgrp, kn, id);
    __u32 *tier = bpf_map_lookup_elem(&cgroup_tiers, &cgid);
    if (tier)
        return *tier;
    return TIER_FOREGROUND;
}

static __always_inline __u64 tier_slice(__u32 tier)
{
    if (tier == TIER_JAILED)
        return SLICE_JAILED_NS;
    if (tier == TIER_BATCH)
        return SLICE_BATCH_NS;
    return SLICE_FOREGROUND_NS;
}

SEC("struct_ops.s/scx_moonhead_init")
s32 BPF_PROG(scx_moonhead_init)
{
    s32 err;

    err = scx_bpf_create_dsq(DSQ_FOREGROUND, -1);
    if (err)
        return err;

    err = scx_bpf_create_dsq(DSQ_BATCH, -1);
    if (err)
        return err;

    return scx_bpf_create_dsq(DSQ_JAILED, -1);
}

SEC("struct_ops/scx_moonhead_select_cpu")
s32 BPF_PROG(scx_moonhead_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
    bool is_idle = false;
    s32 cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);

    if (is_idle) {
        __u32 tier = lookup_task_tier(p);
        scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, tier_slice(tier), 0);
        bump_stat(0);
    }
    return cpu;
}

SEC("struct_ops/scx_moonhead_enqueue")
void BPF_PROG(scx_moonhead_enqueue, struct task_struct *p, u64 enq_flags)
{
    __u32 tier = lookup_task_tier(p);

    if (tier == TIER_JAILED) {
        scx_bpf_dsq_insert(p, DSQ_JAILED, SLICE_JAILED_NS, enq_flags);
    } else if (tier == TIER_BATCH) {
        scx_bpf_dsq_insert(p, DSQ_BATCH, SLICE_BATCH_NS, enq_flags);
    } else {
        scx_bpf_dsq_insert(p, DSQ_FOREGROUND, SLICE_FOREGROUND_NS, enq_flags);
    }
}

SEC("struct_ops/scx_moonhead_dispatch")
void BPF_PROG(scx_moonhead_dispatch, s32 cpu, struct task_struct *prev)
{
    __u32 zero = 0;
    __u32 *streak = bpf_map_lookup_elem(&cpu_starve_streak, &zero);

    /* Guarantee bounded forward progress for batch/jailed tasks */
    if (streak && *streak >= STARVATION_LIMIT) {
        *streak = 0;
        if (scx_bpf_dsq_move_to_local(DSQ_BATCH)) {
            bump_stat(2);
            return;
        }
        if (scx_bpf_dsq_move_to_local(DSQ_JAILED)) {
            bump_stat(3);
            return;
        }
    }

    if (scx_bpf_dsq_move_to_local(DSQ_FOREGROUND)) {
        if (streak)
            (*streak)++;
        bump_stat(1);
        return;
    }

    if (scx_bpf_dsq_move_to_local(DSQ_BATCH)) {
        if (streak)
            (*streak)++;
        bump_stat(2);
        return;
    }

    if (scx_bpf_dsq_move_to_local(DSQ_JAILED)) {
        if (streak)
            *streak = 0;
        bump_stat(3);
    }
}

SEC(".struct_ops.link")
struct sched_ext_ops scx_moonhead_ops = {
    .select_cpu = (void *)scx_moonhead_select_cpu,
    .enqueue    = (void *)scx_moonhead_enqueue,
    .dispatch   = (void *)scx_moonhead_dispatch,
    .init       = (void *)scx_moonhead_init,
    .flags      = SCX_OPS_KEEP_BUILTIN_IDLE | SCX_OPS_ENQ_LAST,
    .name       = "scx_moonhead",
};
