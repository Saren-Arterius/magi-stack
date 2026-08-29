#!/bin/bash
# magi-stack: single supervisor for the LLM -> ASR -> VoxCPM chain.
#
# Boot:    ram-client-ple.sh (NVMe-oF table + qwen38-flash) -> LLM warm
#          -> gpu clock lock -> vllm-q3asr -> ASR warm (dora.wav)
#          -> voxcpm -> voxcpm warm
# The WTAKO-ASR-IME proxy (:8001) is NOT managed here: it is CPU-only, 501s
# harmlessly while its backend is down, and keeps its own crontab screen loop.
# Monitor: LLM unhealthy  -> kill vllm-q3asr+voxcpm immediately (free memory
#          before the LLM's reload spike), hold them down, wait for LLM warm,
#          re-sequence ASR -> voxcpm.
#          ASR unhealthy  -> restart vllm-q3asr only.
#          voxcpm dead    -> restart voxcpm only.
#
# Replaces: watchdog.sh (RAM heuristics), the asr/voxcpm @reboot screen loops,
# and the standalone clock-lock crontab line. Nothing else may own restart
# loops for these services. Intended crontab (it puts itself inside screen):
#   @reboot /home/saren/magi-stack/magi-stack.sh
# Safe to re-run by hand: adopts a healthy LLM without restarting it.

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"  # uv lives in ~/.local/bin
DIR=/home/saren/magi-stack
LOGDIR=/tmp/magi-stack-logs
LOG=$LOGDIR/magi-stack.log
DORA=$DIR/dora.wav
POLL=10           # monitor interval, seconds
WARM_TIMEOUT=1200 # max seconds to wait for LLM to come back before re-kicking
STABLE_SECS=10    # one extra poll after warm before spending dependents boot

mkdir -p "$LOGDIR"

# Re-exec inside a detached screen session.
if [ -z "$STY" ] && [ "${1:-}" != --no-screen ]; then
  exec screen -dmS magi-stack bash "$0" --no-screen
fi

# Hard single-instance guard: whoever holds the flock is THE supervisor;
# any other copy (double launch, stale screen, ghost) exits immediately.
exec 9>"$DIR/.supervisor.lock"
flock -n 9 || { echo "another magi-stack holds the lock; exiting"; exit 1; }

VOX_PGID=

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
ts() { while IFS= read -r l; do printf '%s %s\n' "$(date '+%F %T')" "$l"; done; }

# ---------------------------------------------------------------- probes
llm_healthy() {
  [ "$(docker inspect -f '{{.State.Status}}' qwen38-flash 2>/dev/null)" = running ] &&
  curl -sf -o /dev/null --max-time 3 http://localhost:8000/health
}

llm_warm() {  # real completion: proves warmup done, not just port open
  curl -sf -o /dev/null --max-time 120 http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen","messages":[{"role":"user","content":"ok"}],"max_tokens":8,"chat_template_kwargs":{"enable_thinking":false}}'
}

asr_container_up() {
  [ "$(docker inspect -f '{{.State.Status}}' vllm-q3asr 2>/dev/null)" = running ] &&
  curl -sf -o /dev/null --max-time 3 http://localhost:8003/health
}

asr_warm() {  # start.sh's dora.wav probe, stdlib only
  python3 - "$DORA" <<'EOF'
import base64, json, sys, urllib.request
audio = base64.b64encode(open(sys.argv[1], "rb").read()).decode()
body = json.dumps({
    "model": "Qwen/Qwen3-ASR-1.7B",
    "messages": [{"role": "user", "content": [
        {"type": "input_audio", "input_audio": {"data": audio, "format": "wav"}}]}],
    "extra_body": {"chat_template_kwargs": {"language": "Cantonese"}},
}).encode()
req = urllib.request.Request("http://localhost:8003/v1/chat/completions",
                             body, {"Content-Type": "application/json"})
json.load(urllib.request.urlopen(req, timeout=60))
EOF
}

vox_healthy() {
  { [ -z "$VOX_PGID" ] || kill -0 -- -"$VOX_PGID" 2>/dev/null; } &&
  curl -sf -o /dev/null --max-time 3 http://localhost:8004/docs
}

vox_warm() {  # real zero-shot generation (the app has no /v1/audio/speech route)
  curl -sf -o /dev/null --max-time 120 -X POST http://localhost:8004/generate \
    -H 'Content-Type: application/json' \
    -d '{"target_text":"おめでとう"}'
}

# ---------------------------------------------------------------- actions
kill_pgid() { [ -n "$1" ] && { kill -TERM -- -"$1" 2>/dev/null; sleep 2; kill -KILL -- -"$1" 2>/dev/null; }; }

stop_vox()     { kill_pgid "$VOX_PGID"; VOX_PGID=; pkill -f 'magi-stack/voxcpm' 2>/dev/null; pkill -f 'deployment/app/main.py' 2>/dev/null; }

stop_dependents() {
  log "stopping dependents (vllm-q3asr, voxcpm)"
  stop_vox
  docker stop -t 5 vllm-q3asr >/dev/null 2>&1
}

start_vox() {
  drop_page_cache  # GB10: CUDA ctx creation OOMs when free RAM is all page cache
  setsid bash -c 'cd ~/magi-stack/voxcpm/deployment && NANOVLLM_SERVERPOOL_GPU_MEMORY_UTILIZATION=0.075 NANOVLLM_MODEL_PATH=openbmb/VoxCPM2 exec uv run fastapi run app/main.py --host 0.0.0.0 --port 8004' \
    >>"$LOGDIR/voxcpm.log" 2>&1 9>&- &
  VOX_PGID=$!
  log "voxcpm started (pgid $VOX_PGID)"
}

run_ram_client() {
  ( set -o pipefail; bash "$DIR/ram-client-ple.sh" 2>&1 | ts >>"$LOG" )
}

wait_for() {  # wait_for <probe_fn> <name> <timeout_secs>
  local fn=$1 name=$2 timeout=$3 t=0
  until $fn; do
    t=$((t + POLL))
    if [ $t -ge "$timeout" ]; then log "$name: not healthy after ${timeout}s"; return 1; fi
    sleep $POLL
  done
  log "$name: healthy"
}

wait_llm_warm() {
  # LLM reloads take ~8 min; docker's unless-stopped does the restarting of a
  # crashed container, so an EXISTING unhealthy container just needs waiting
  # (up to WARM_TIMEOUT). A MISSING container will never come back on its
  # own — re-kick ram-client-ple.sh immediately. Dependents stay down.
  local t=0
  while :; do
    if ! docker inspect qwen38-flash >/dev/null 2>&1; then
      log "LLM container missing — running ram-client-ple.sh"
      run_ram_client || log "ram-client-ple.sh failed; retrying"
      t=0
    fi
    if llm_healthy && llm_warm; then
      log "LLM: warm (real completion ok)"
      # flap guard: require it to stay healthy before spending dependents' boot
      sleep $STABLE_SECS
      llm_healthy && return 0
      log "LLM: died within ${STABLE_SECS}s of warmup — waiting again"
      t=0
    fi
    sleep $POLL
    t=$((t + POLL))
    if [ $t -ge "$WARM_TIMEOUT" ]; then
      log "LLM: not healthy after ${WARM_TIMEOUT}s — re-kicking ram-client-ple.sh"
      run_ram_client || log "ram-client-ple.sh failed; retrying"
      t=0
    fi
  done
}

drop_page_cache() {
  # GB10 unified memory: after the LLM load, ~all free RAM is clean page
  # cache and CUDA context creation fails with OOM instead of reclaiming it.
  sync
  echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  log "page cache dropped ($(free -g | awk '/Mem/{print $7}')G available)"
}

llm_gone() {  # abort guard for sequencing waits
  llm_healthy && return 1
  log "LLM died mid-sequencing — aborting (monitor will cascade)"
  return 0
}

sequence_dependents() {
  [ -e /tmp/magi-stack-no-deps ] && { log "deps held (/tmp/magi-stack-no-deps) — not starting ASR/voxcpm"; return 0; }
  log "sequencing dependents: vllm-q3asr -> voxcpm"
  drop_page_cache
  docker start vllm-q3asr >/dev/null 2>&1 || bash "$DIR/asr/run-q3asr.sh" 2>&1 | ts >>"$LOG"
  local t=0
  until asr_container_up; do
    llm_gone && return 1
    t=$((t + POLL))
    [ $t -ge 600 ] && { log "vllm-q3asr: not healthy after 600s"; return 1; }
    sleep $POLL
  done
  log "vllm-q3asr: healthy"
  until asr_warm; do
    llm_gone && return 1
    log "vllm-q3asr: dora.wav probe not ready"; sleep $POLL
  done
  log "vllm-q3asr: warm (dora.wav ok)"
  start_vox
  until vox_warm; do
    llm_gone && return 1
    kill -0 -- -"$VOX_PGID" 2>/dev/null || { log "voxcpm: process died — retrying"; start_vox; }
    log "voxcpm: speech probe not ready"; sleep $POLL
  done
  log "voxcpm: warm — full stack up"
}

# ---------------------------------------------------------------- main
log "=== magi-stack starting ==="
# Take over from any previous owners (old screen loops, old watchdog, stale us)
screen -S voxcpm2 -X quit 2>/dev/null
screen -S watchdog -X quit 2>/dev/null
pkill -f 'bash watchdog.sh' 2>/dev/null
stop_dependents

if llm_healthy && llm_warm; then
  log "LLM: already healthy — adopting without restart"
else
  log "LLM: not healthy — running ram-client-ple.sh"
  run_ram_client || log "ram-client-ple.sh failed; monitor will retry"
  wait_llm_warm
fi
sudo nvidia-smi --lock-gpu-clocks 0,2150 >/dev/null 2>&1 && log "gpu clocks locked"
sequence_dependents

while :; do
  sleep $POLL
  # Benchmark hold: `touch /tmp/magi-stack-no-deps` keeps ASR+voxcpm down so
  # LLM perf tests get the GPU pool to themselves; `rm` it to restore (the
  # normal unhealthy branches below bring them back). LLM stays managed.
  if [ -e /tmp/magi-stack-no-deps ]; then
    if asr_container_up || vox_healthy; then
      log "hold file present — stopping dependents"
      stop_dependents
    fi
    if ! llm_healthy; then
      log "LLM: UNHEALTHY — reloading (dependents held)"
      wait_llm_warm
    fi
    continue
  fi
  if ! llm_healthy; then
    log "LLM: UNHEALTHY — cascading"
    stop_dependents
    wait_llm_warm
    sequence_dependents
  elif ! asr_container_up; then
    log "ASR: unhealthy — restarting vllm-q3asr"
    drop_page_cache
    docker restart vllm-q3asr >/dev/null 2>&1
    wait_for asr_container_up vllm-q3asr 600
  elif ! vox_healthy; then
    log "voxcpm: unhealthy — restarting"
    stop_vox
    start_vox
  fi
done
