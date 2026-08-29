# Shared state for the wtako remote-RAM NVMe-oF device: 16G brd on wtako,
# exported over RDMA, used raw as magi's preferred swap (prio 100; the local
# SSD swap files stay enabled at lower priority as fallback). The PLE table
# moved off this device 2026-08-30 — vLLM reads it via one-sided RDMA from
# wtako's ple-rdma-server instead, so no filesystem lives here anymore.
# Sourced by ram-client.sh (boot) and ram-client-ple.sh (LLM launch); callers
# can run concurrently — ensure_ram_swap serializes on a lock.

RAM_DEV=/dev/nvme1n1

ensure_ram_swap() {
  exec 8>/tmp/.ram-client.lock
  flock 8
  [ -b $RAM_DEV ] || sudo nvme connect -t rdma -a 192.168.0.1 -s 4420 -n nvme-ram
  local _i
  for _i in $(seq 30); do [ -b $RAM_DEV ] && break; sleep 1; done
  [ -b $RAM_DEV ] || { echo "$RAM_DEV never appeared"; return 1; }
  # A device that survived a wtako reboot is backed by nothing: a direct
  # (uncached) read tells the truth. Reset the whole path if it is dead.
  if ! sudo dd if=$RAM_DEV of=/dev/null bs=4096 count=1 iflag=direct >/dev/null 2>&1; then
    sudo swapoff $RAM_DEV 2>/dev/null || true
    sudo nvme disconnect -n nvme-ram >/dev/null 2>&1 || true
    sudo nvme connect -t rdma -a 192.168.0.1 -s 4420 -n nvme-ram
    for _i in $(seq 30); do [ -b $RAM_DEV ] && break; sleep 1; done
    [ -b $RAM_DEV ] || { echo "$RAM_DEV never came back"; return 1; }
  fi
  [ "$(sudo blkid -o value -s TYPE $RAM_DEV 2>/dev/null)" = swap ] || sudo mkswap $RAM_DEV >/dev/null
  swapon --show=NAME --noheadings | grep -qF "$RAM_DEV" || sudo swapon -p 100 $RAM_DEV
}
