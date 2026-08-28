# Shared state for the wtako remote-RAM NVMe-oF device: 68G brd on wtako,
# exported over RDMA, holding one ext4 fs with BOTH the stripped PLE table
# (~49G) and magi's preferred swapfile (whatever space the table leaves).
# Sourced by ram-client.sh (swap side), ram-client-ple.sh (table + LLM) and
# ram-client-teardown.sh. Callers can run concurrently at boot:
# ensure_ram_fs serializes on a lock so only one connects/mkfs's.

RAM_DEV=/dev/nvme1n1
RAM_MNT=/mnt/ple-ram
RAM_MARKER=$RAM_MNT/.table-complete
RAM_SWAPFILE=$RAM_MNT/swapfile

ensure_ram_fs() {
  exec 8>/tmp/.ram-client.lock
  flock 8
  [ -b $RAM_DEV ] || sudo nvme connect -t rdma -a 192.168.0.1 -s 4420 -n nvme-ram
  local _i
  for _i in $(seq 30); do [ -b $RAM_DEV ] && break; sleep 1; done
  [ -b $RAM_DEV ] || { echo "$RAM_DEV never appeared"; return 1; }
  # A device that survived a wtako reboot is backed by nothing: a direct
  # (uncached) read tells the truth. Reset the whole path if it is dead.
  if ! sudo dd if=$RAM_DEV of=/dev/null bs=4096 count=1 iflag=direct >/dev/null 2>&1; then
    sudo swapoff $RAM_SWAPFILE 2>/dev/null || true
    sudo umount -f $RAM_MNT 2>/dev/null || true
    sudo nvme disconnect -n nvme-ram >/dev/null 2>&1 || true
    sudo nvme connect -t rdma -a 192.168.0.1 -s 4420 -n nvme-ram
    for _i in $(seq 30); do [ -b $RAM_DEV ] && break; sleep 1; done
    [ -b $RAM_DEV ] || { echo "$RAM_DEV never came back"; return 1; }
  fi
  # tiny random rows + no page-cache headroom: stop 128k readahead pollution
  echo 4 | sudo tee /sys/block/$(basename $RAM_DEV)/queue/read_ahead_kb >/dev/null
  if ! mountpoint -q $RAM_MNT; then
    sudo mkdir -p $RAM_MNT
    sudo mount -o noatime $RAM_DEV $RAM_MNT 2>/dev/null || {
      sudo mkfs.ext4 -F -m0 -O ^has_journal -T largefile4 $RAM_DEV
      sudo mount -o noatime $RAM_DEV $RAM_MNT
    }
  fi
}

ensure_swap() {
  # Swapfile fills whatever the table leaves free (~1G slack). Local SSD swap
  # stays enabled at its default (lower) priority: prio 100 here means the
  # kernel only touches the SSD when the remote fills or disappears.
  if ! sudo test -f $RAM_SWAPFILE; then
    local avail_kb swap_kb
    avail_kb=$(df --output=avail -k $RAM_MNT | tail -1)
    swap_kb=$(( avail_kb - 1048576 ))
    sudo fallocate -l ${swap_kb}K $RAM_SWAPFILE
    sudo chmod 600 $RAM_SWAPFILE
    sudo mkswap $RAM_SWAPFILE >/dev/null
  fi
  swapon --show=NAME --noheadings | grep -qF "$RAM_SWAPFILE" || sudo swapon -p 100 $RAM_SWAPFILE
}
