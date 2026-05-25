#!/bin/bash
# Adnan Clone Studio — LatentSync pod entrypoint
# Bulletproof version after iterating on disk-quota issues:
# - ALL caches forced to /workspace volume (HF_HOME, HF_HUB_CACHE, TMPDIR, XDG_CACHE_HOME)
# - Explicitly rm -rf the checkpoints dir before symlinking so we don't end up with a nested dir
# - local_dir_use_symlinks=False so HF doesn't double-store (cache + local_dir)
# - Diagnostic df -h + ls -la so we can see what's happening in the pod logs
set -e

# --- 1. SSH key setup (so Next.js can SCP files in) ---
if [ -n "$PUBLIC_KEY" ]; then
  echo "[entrypoint] Setting up SSH key from PUBLIC_KEY env"
  echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
else
  echo "[entrypoint] WARNING: PUBLIC_KEY env not set"
fi
/usr/sbin/sshd
echo "[entrypoint] sshd started"

# --- 2. Diagnostic — print disk state so we know what's mounted ---
echo "[entrypoint] === Disk state ==="
df -h
echo "[entrypoint] === /workspace ==="
ls -la /workspace 2>/dev/null || echo "[entrypoint] WARN: /workspace not accessible!"
echo "[entrypoint] === /code/LatentSync ==="
ls -la /code/LatentSync 2>/dev/null | head -20

# --- 3. Force EVERY cache to /workspace volume (50 GB) so nothing fills container disk ---
mkdir -p /workspace/tmp \
         /workspace/.cache/huggingface \
         /workspace/.cache/huggingface/hub \
         /workspace/latentsync_checkpoints \
         /workspace/.insightface
export TMPDIR=/workspace/tmp
export HF_HOME=/workspace/.cache/huggingface
export HF_HUB_CACHE=/workspace/.cache/huggingface/hub
export XDG_CACHE_HOME=/workspace/.cache
echo "[entrypoint] TMPDIR=$TMPDIR  HF_HOME=$HF_HOME"

# Insightface stores its face-detection models under ~/.insightface — symlink to volume.
rm -rf /root/.insightface
ln -s /workspace/.insightface /root/.insightface

# --- 4. Force LatentSync checkpoints dir to be a symlink to /workspace ---
# Critical: remove ANY existing dir/symlink first. ln -sfn alone fails if a non-empty dir exists.
rm -rf /code/LatentSync/checkpoints
ln -s /workspace/latentsync_checkpoints /code/LatentSync/checkpoints
echo "[entrypoint] checkpoints symlink: $(ls -la /code/LatentSync/checkpoints)"

# --- 5. Download LatentSync weights if not already cached on volume ---
CKPT_FILE=/workspace/latentsync_checkpoints/latentsync_unet.pt
if [ ! -f "$CKPT_FILE" ]; then
  echo "[entrypoint] First boot: downloading LatentSync weights (~5 GB) to /workspace..."
  python -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='ByteDance/LatentSync-1.6',
    local_dir='/workspace/latentsync_checkpoints',
    local_dir_use_symlinks=False,
)
print('[entrypoint] snapshot_download complete')
"
  echo "[entrypoint] Downloaded — checkpoint size: $(du -sh /workspace/latentsync_checkpoints | cut -f1)"
else
  echo "[entrypoint] Weights cached on volume: $CKPT_FILE"
fi

# --- 6. Start FastAPI server on port 8383 ---
echo "[entrypoint] Starting LatentSync FastAPI server on port 8383"
cd /code
exec python /code/server.py
