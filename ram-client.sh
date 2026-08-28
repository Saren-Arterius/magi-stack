#!/bin/bash
# Bring up magi's preferred swap on wtako's remote RAM (NVMe-oF). Safe to run
# any time; shares the device/fs with the PLE table (ram-client-ple.sh does
# its own ensure, so neither script depends on the other having run).
# Crontab @reboot on magi.
set -e
source "$(dirname "$(readlink -f "$0")")/ram-common.sh"
ensure_ram_fs
ensure_swap
