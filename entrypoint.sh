#!/bin/bash
# Adnan Clone Studio — LatentSync pod entrypoint
# 1) Inject SSH public key from PUBLIC_KEY env var (so Next.js can SCP files in)
# 2) Start sshd in background
# 3) Download LatentSync weights to /workspace cache if not present (first boot only)
# 4) Start FastAPI server on port 8383 (HeyGem-compatible API)
set -e

# --- 1. SSH key setup ---
if [ -n "$PUBLIC_KEY" ]; then
  echo "[entrypoint] Setting up SSH key from PUBLIC_KEY env"
  echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
else
  echo "[entrypoint] WARNING: PUBLIC_KEY env not set — SSH will not be accessible"
fi

# --- 2. Start sshd ---
echo "[entrypoint] Starting sshd"
/usr/sbin/sshd

# --- 3. Ensure LatentSync checkpoints exist (cached on /workspace volume across boots) ---
CKPT_DIR=/code/LatentSync/checkpoints
WORKSPACE_CKPT=/workspace/latentsync_checkpoints

mkdir -p "$WORKSPACE_CKPT"
ln -sfn "$WORKSPACE_CKPT" "$CKPT_DIR"

if [ ! -f "$CKPT_DIR/latentsync_unet.pt" ]; then
  echo "[entrypoint] First boot: downloading LatentSync weights (~5 GB, ~3-5 min)..."
  cd /code/LatentSync
  # LatentSync provides a download script that fetches from HuggingFace.
  # Falls back to direct hf-cli pull if the helper script changes.
  if [ -f "scripts/download_checkpoints.py" ]; then
    python scripts/download_checkpoints.py || \
      python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='ByteDance/LatentSync-1.6', local_dir='$CKPT_DIR')"
  else
    python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='ByteDance/LatentSync-1.6', local_dir='$CKPT_DIR')"
  fi
  echo "[entrypoint] Weights downloaded to $CKPT_DIR (persists on /workspace volume)"
else
  echo "[entrypoint] Weights already cached at $CKPT_DIR — skipping download"
fi

# --- 4. Start FastAPI server ---
echo "[entrypoint] Starting LatentSync FastAPI server on port 8383"
cd /code
exec python /code/server.py
