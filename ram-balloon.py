#!/usr/bin/env python3
"""Touch N GiB of anonymous memory, then exit. Forces the kernel to swap out
cold anon pages / evict cache NOW, so the next big allocator (voxcpm's CUDA
context on the GB10 unified pool) sees genuinely free RAM instead of
reclaimable-maybe RAM. The remote-RAM swap (prio 100, RDMA-backed) makes the
swap-out cheap; everything swapped comes back on demand.

Usage: ram-balloon.py [GiB=16]
"""
import sys

gib = int(sys.argv[1]) if len(sys.argv) > 1 else 16
# If this pressure triggers the OOM killer, die first — never the LLM.
open("/proc/self/oom_score_adj", "w").write("1000")
held = []
for i in range(gib):
    held.append(bytearray(1 << 30))  # zero-fill touches every page
    print(f"balloon {i + 1}/{gib} GiB", flush=True)
print("balloon full — exiting frees it", flush=True)
