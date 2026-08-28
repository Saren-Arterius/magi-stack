#!/bin/bash
# Bring up the wtako remote-RAM NVMe-oF device, fill it with the fp8 PLE table
# (stripped on the fly from the NFS copy), then start vLLM. The device is
# RAM-backed on wtako: contents vanish when wtako reboots, so every run
# rebuilds whatever is missing. Swap stays on the local swap files — this
# replaces the old remote-swap role of ram-client.sh.
# Intended for crontab @reboot (after docker + NFS are up); safe to re-run by
# hand, but note it always (re)starts the qwen38-flash container at the end.
set -e

SRC="/mnt/storage@WTAKO/saren/AI/ple-table-fp8"
MNT=/mnt/ple-ram
DEV=/dev/nvme1n1
MARKER=$MNT/.table-complete

[ -b $DEV ] || sudo nvme connect -t rdma -a 192.168.0.1 -s 4420 -n nvme-ram
for _ in $(seq 30); do [ -b $DEV ] && break; sleep 1; done
[ -b $DEV ] || { echo "$DEV never appeared"; exit 1; }
echo 4 | sudo tee /sys/block/$(basename $DEV)/queue/read_ahead_kb >/dev/null  # tiny rows, no cache headroom: stop 128k readahead pollution

# The marker is a manifest (file name + size per shard, written after a full
# copy). table_ok() re-stats every shard against it on each boot, so a
# truncated/missing/extra file forces a rebuild instead of a vLLM crash loop.
table_ok() {
  sudo test -f $MARKER || return 1
  diff <(cd $MNT 2>/dev/null && stat -c '%n %s' ./*.safetensors 2>/dev/null | sort) \
       <(sudo cat $MARKER) >/dev/null 2>&1
}

# A mount that survived a wtako reboot is backed by nothing and reads EIO;
# the marker read doubles as the health probe.
if mountpoint -q $MNT && ! sudo cat $MARKER >/dev/null 2>&1; then
  sudo swapoff $MNT/swapfile 2>/dev/null || true
  sudo umount -f $MNT || true
fi
if ! mountpoint -q $MNT; then
  sudo mkdir -p $MNT
  sudo mount -o noatime $DEV $MNT 2>/dev/null || {
    sudo mkfs.ext4 -F -m0 -O ^has_journal -T largefile4 $DEV
    sudo mount -o noatime $DEV $MNT
  }
fi

if ! table_ok; then
  # Wrong or partial contents: remake the fs so the copy always has space.
  sudo swapoff $MNT/swapfile 2>/dev/null || true
  sudo umount -f $MNT 2>/dev/null || true
  sudo mkfs.ext4 -F -m0 -O ^has_journal -T largefile4 $DEV
  sudo mount -o noatime $DEV $MNT
  echo "rebuilding stripped PLE table from $SRC (~48G, a few min over NFS)..."
  ls "$SRC"/*.safetensors >/dev/null  # fail loudly if the NFS mount is absent
  # inline tools/strip_ple_table.py from the repo, to keep this self-contained
  docker run --rm -i -v "$SRC":/src:ro -v $MNT:/dst \
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
  (cd $MNT && stat -c '%n %s' ./*.safetensors | sort) | sudo tee $MARKER >/dev/null
fi

# Remote swap: fill the space left after the table with a swapfile on the
# wtako-RAM fs, preferred (prio 100) over the local SSD swap files. Created
# once per fs lifetime; the rebuild path above swapoffs + wipes it with mkfs.
SWAPFILE=$MNT/swapfile
if ! sudo test -f $SWAPFILE; then
  avail_kb=$(df --output=avail -k $MNT | tail -1)
  swap_kb=$(( avail_kb - 1048576 ))  # leave 1G slack for ext4/marker
  sudo fallocate -l ${swap_kb}K $SWAPFILE
  sudo chmod 600 $SWAPFILE
  sudo mkswap $SWAPFILE
fi
swapon --show=NAME --noheadings | grep -qF "$SWAPFILE" || sudo swapon -p 100 $SWAPFILE

# preserve the previous container's logs before serve's docker rm -f
docker logs --tail 500 qwen38-flash > /tmp/magi-stack-logs/llm-last-crash.log 2>&1 || true

"$HOME/magi-stack/llm/serve-magi.sh"
