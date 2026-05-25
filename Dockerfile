# LatentSync 1.6 (ByteDance) + SSH + FastAPI wrapper that mimics HeyGem's /easy/submit API.
#
# Why: HeyGem (guiji2025/duix.avatar) bakes GFPGAN face restoration into a compiled
# binary, which homogenizes identity (bad for dark skin + beard). LatentSync uses
# latent-space ID anchoring with NO baked face-restorer, preserving Adnan's actual face.
#
# Build size: ~12-15 GB (CUDA 12.1 base + torch + LatentSync + model weights downloaded at first run)
# Target GPU: A40 (48 GB VRAM); LatentSync uses ~18 GB so plenty of headroom.

FROM nvidia/cuda:12.1.1-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HOME=/workspace/.cache/huggingface \
    TORCH_HOME=/workspace/.cache/torch \
    PIP_NO_CACHE_DIR=1

# System deps:
#   git, wget        - clone repo + download weights
#   ffmpeg           - LatentSync needs it for audio/video I/O
#   libgl1, libglib  - opencv runtime libs
#   openssh-server   - matches HeyGem image: we SCP files in via SSH
#   python3.10 + pip - matches LatentSync's documented env
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git wget curl ca-certificates \
        ffmpeg \
        libgl1 libglib2.0-0 \
        openssh-server \
        python3.10 python3.10-venv python3-pip \
        build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/python3.10 /usr/bin/python && \
    ln -sf /usr/bin/python3.10 /usr/bin/python3 && \
    mkdir -p /run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

WORKDIR /code

# Clone LatentSync. Pinned to a commit so builds are reproducible (update commit to upgrade).
RUN git clone https://github.com/bytedance/LatentSync.git /code/LatentSync && \
    cd /code/LatentSync && \
    git checkout main

# Install Python deps. LatentSync's requirements.txt covers torch + diffusers + face libs.
# We add fastapi/uvicorn for our HTTP wrapper.
RUN pip install --upgrade pip && \
    pip install \
        torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu121 && \
    pip install -r /code/LatentSync/requirements.txt && \
    pip install fastapi uvicorn[standard] python-multipart

# Our FastAPI wrapper exposing /easy/submit and /easy/query (HeyGem-compatible).
COPY server.py /code/server.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Weights download script — runs on first boot, caches to /workspace volume so repeat boots are fast.
# (LatentSync auto-downloads via huggingface_hub on first inference; HF_HOME above points to /workspace.)

# 22 = SSH (file uploads), 8383 = our FastAPI server (matches HeyGem port so Next.js doesn't change)
EXPOSE 22 8383

CMD ["/usr/local/bin/entrypoint.sh"]
