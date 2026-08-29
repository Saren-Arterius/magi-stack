#!/bin/bash
# Release the remote-RAM swap device (e.g. before wtako maintenance).
sudo swapoff /dev/nvme1n1 2>/dev/null
sudo nvme disconnect -n nvme-ram
