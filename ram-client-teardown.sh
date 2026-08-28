#!/bin/bash
# Detach from wtako's remote RAM BEFORE wtako goes down: swapoff pages the
# remote swap back (local SSD swap stays enabled as the fallback), then drop
# the table fs and the fabric. wtako's magi-teardown.service runs this over
# ssh at shutdown (/usr/local/sbin/magi-detach). The LLM is expected to die
# with the table; it self-heals later via ram-client-ple.sh (supervisor).
sudo swapon /swap*.img 2>/dev/null
sudo swapoff /mnt/ple-ram/swapfile 2>/dev/null
sudo umount -f /mnt/ple-ram 2>/dev/null
sudo nvme disconnect -n nvme-ram
