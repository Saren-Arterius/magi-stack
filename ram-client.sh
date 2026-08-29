#!/bin/bash
# Bring up magi's preferred swap on wtako's remote RAM (NVMe-oF, raw device).
# Safe to run any time. Crontab @reboot on magi.
set -e
source "$(dirname "$(readlink -f "$0")")/ram-common.sh"
ensure_ram_swap
