#!/bin/bash
# (Re)create the vllm-q3asr container — Qwen3-ASR-1.7B backend for the
# WTAKO-ASR-IME proxy (:8001), serving on :8003 (host network).
# Extracted from 20260408-q35-122b-optimized/docker-compose.yml; the image was
# built there (Dockerfile.vllmaudio — copy kept in this dir for rebuilds:
#   docker build -f Dockerfile.vllmaudio -t 20260408-q35-122b-optimized-vllm-q3asr .)
# Restart policy stays "no": magi-stack.sh owns this container's lifecycle.
set -e
cd "$(dirname "$0")"
# secrets live in magi-stack/.env (gitignored): HF_TOKEN=...
source ../.env
docker rm -f vllm-q3asr >/dev/null 2>&1 || true
docker run -d --name vllm-q3asr --restart no \
  --gpus all --privileged --network host --ipc host \
  -v "/mnt/storage@WTAKO/saren/AI/huggingface:/root/.cache/huggingface" \
  -v "$PWD/templates:/templates:ro" \
  -v "$PWD/vllm-cache:/root/.cache/vllm" \
  -e VLLM_SLEEP_WHEN_IDLE=1 \
  -e HF_TOKEN="$HF_TOKEN" \
  20260408-q35-122b-optimized-vllm-q3asr \
  bash -c "vllm serve Qwen/Qwen3-ASR-1.7B \
    --host 0.0.0.0 --port 8003 \
    --gpu_memory_utilization 0.01 --kv-cache-memory-bytes 0.5g \
    --max-model-len 4096 --enable-chunked-prefill \
    --load-format fastsafetensors \
    --chat-template /templates/qwen3-asr-lang.jinja"
