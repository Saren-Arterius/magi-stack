#!/bin/bash
# Bring up the remote-RAM swap device, wait for wtako's PLE RDMA daemon, then
# start vLLM. Since the 2026-08-30 cutover the PLE table is NOT copied here:
# vLLM reads rows straight out of wtako's RAM via one-sided RDMA READs
# (ple-rdma-server.service on wtako, VLLM_PLE_RDMA in serve-magi.sh). The
# NVMe-oF RAM device (now 16G) is used raw as swap — no filesystem.
# Called by magi-stack.sh whenever the LLM needs (re)creating; safe to re-run
# by hand, but note it always (re)starts the qwen38-flash container.
set -e

source "$(dirname "$(readlink -f "$0")")/ram-common.sh"

ensure_ram_swap

# vLLM aborts at boot if the table daemon is unreachable — wait here instead
# so the supervisor's warm timeout isn't burned on a crash loop.
until timeout 2 bash -c '</dev/tcp/192.168.0.1/18515' 2>/dev/null; do
  echo "waiting for ple-rdma-server on wtako:18515..."
  sleep 5
done

# preserve the previous container's logs before serve's docker rm -f
docker logs --tail 500 qwen38-flash > /tmp/magi-stack-logs/llm-last-crash.log 2>&1 || true

"$HOME/magi-stack/llm/serve-magi.sh"
