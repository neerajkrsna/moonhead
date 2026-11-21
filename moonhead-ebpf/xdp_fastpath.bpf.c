// SPDX-License-Identifier: GPL-2.0
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

char LICENSE[] SEC("license") = "GPL";

#define ETH_P_IP    0x0800
#define IPPROTO_UDP 17
#define DEFAULT_XDP_PORT 9999

/* Queue ID -> AF_XDP socket FD map populated by moonhead-xdp */
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __uint(max_entries, 64);
    __type(key, __u32);
    __type(value, __u32);
} xsks_map SEC(".maps");

/* Key 0 = target UDP port (host byte order); 0 defaults to 9999 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u32);
} xdp_config SEC(".maps");

/* Per-CPU telemetry: [0]=passed_packets, [1]=redirected_packets, [2]=redirected_bytes */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 3);
    __type(key, __u32);
    __type(value, __u64);
} xdp_stats SEC(".maps");

static __always_inline void bump_stat(__u32 idx, __u64 delta)
{
    __u64 *val = bpf_map_lookup_elem(&xdp_stats, &idx);
    if (val)
        __sync_fetch_and_add(val, delta);
}

SEC("xdp")
int moonhead_xdp_fastpath(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != bpf_htons(ETH_P_IP)) {
        bump_stat(0, 1);
        return XDP_PASS;
    }

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    if (ip->protocol != IPPROTO_UDP || ip->ihl < 5) {
        bump_stat(0, 1);
        return XDP_PASS;
    }

    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end) {
        bump_stat(0, 1);
        return XDP_PASS;
    }

    __u32 zero = 0;
    __u32 target_port = DEFAULT_XDP_PORT;
    __u32 *cfg_port = bpf_map_lookup_elem(&xdp_config, &zero);
    if (cfg_port && *cfg_port > 0)
        target_port = *cfg_port;

    if (bpf_ntohs(udp->dest) != (__u16)target_port) {
        bump_stat(0, 1);
        return XDP_PASS;
    }

    __u32 rx_queue = ctx->rx_queue_index;
    if (bpf_map_lookup_elem(&xsks_map, &rx_queue)) {
        __u64 pkt_len = (__u64)((long)data_end - (long)data);
        bump_stat(1, 1);
        bump_stat(2, pkt_len);
        return bpf_redirect_map(&xsks_map, rx_queue, XDP_PASS);
    }

    bump_stat(0, 1);
    return XDP_PASS;
}
