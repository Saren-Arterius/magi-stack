#!/bin/bash
# Fill wtako's remote-RAM device with the fp8 PLE table (stripped on the fly
# from the NFS copy), activate the shared swapfile, then start vLLM. The
# device is RAM-backed on wtako: contents vanish when wtako reboots, so every
# run rebuilds whatever is missing (ensure_ram_fs in ram-common.sh handles
# connect/stale-path/mkfs; this script owns the table and the serve).
# Called by magi-stack.sh whenever the LLM needs (re)creating; safe to re-run
# by hand, but note it always (re)starts the qwen38-flash container.
set -e

SRC="/mnt/storage@WTAKO/saren/AI/ple-table-fp8"
source "$(dirname "$(readlink -f "$0")")/ram-common.sh"

ensure_ram_fs

# The marker is a manifest (file name + size per shard, written after a full
# copy). table_ok() re-stats every shard against it on each boot, so a
# truncated/missing/extra file forces a rebuild instead of a vLLM crash loop.
table_ok() {
  sudo test -f $RAM_MARKER || return 1
  diff <(cd $RAM_MNT 2>/dev/null && stat -c '%n %s' ./*.safetensors 2>/dev/null | sort) \
       <(sudo cat $RAM_MARKER) >/dev/null 2>&1
}

if ! table_ok; then
  # Wrong or partial contents: remake the fs so the copy always has space.
  # The swapfile lives on this fs too -- release it first, recreate after.
  sudo swapoff $RAM_SWAPFILE 2>/dev/null || true
  sudo umount -f $RAM_MNT 2>/dev/null || true
  sudo mkfs.ext4 -F -m0 -O ^has_journal -T largefile4 $RAM_DEV
  sudo mount -o noatime $RAM_DEV $RAM_MNT
  echo "rebuilding stripped PLE table from $SRC (~49G, a few min over NFS)..."
  ls "$SRC"/*.safetensors >/dev/null  # fail loudly if the NFS mount is absent
  # inline tools/strip_ple_table.py from the repo, to keep this self-contained
  docker run --rm -i -v "$SRC":/src:ro -v $RAM_MNT:/dst \
    --entrypoint python3 qwen38-flash-dgx - <<'EOF'
import glob, os
from safetensors.torch import safe_open, save_file
files = sorted(glob.glob("/src/*.safetensors"))
for i, p in enumerate(files):
    out = {}
    with safe_open(p, framework="pt", device="cpu") as f:
        for k in f.keys():
            if "ngram_embedding.shard_" in k or "ngram_embedding.weight_scale" in k:
                out[k] = f.get_tensor(k)
    if out:
        save_file(out, os.path.join("/dst", os.path.basename(p)))
    print(f"[{i+1}/{len(files)}] {os.path.basename(p)}: {len(out)} tensors", flush=True)
EOF
  (cd $RAM_MNT && stat -c '%n %s' ./*.safetensors | sort) | sudo tee $RAM_MARKER >/dev/null
fi

ensure_swap

# preserve the previous container's logs before serve's docker rm -f
docker logs --tail 500 qwen38-flash > /tmp/magi-stack-logs/llm-last-crash.log 2>&1 || true

"$HOME/magi-stack/llm/serve-magi.sh"
