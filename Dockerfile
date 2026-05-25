# LatentSync 1.6 (ByteDance) + SSH + FastAPI wrapper that mimics HeyGem's /easy/submit API.
#
# Why: HeyGem bakes GFPGAN face restoration in, which homogenizes identity (bad for dark
# skin + beard). LatentSync has no baked face-restorer, so it preserves Adnan's actual face.
#
# Build size: ~12-15 GB. Target GPU: A40 48 GB (LatentSync uses ~18 GB).
#
# Why this Dockerfile is the way it is (after iterating):
#   insightface (a LatentSync dep) ships a manylinux wheel for Python 3.10 on PyPI, so
#   we should NEVER have to compile it. The previous builds were trying to compile from
#   source because (a) python3.10-dev headers were missing and (b) pip was preferring sdist.
#   Fix: install python3.10-dev, install insightface explicitly from a binary-only wheel
#   BEFORE running requirements.txt, then strip insightface from requirements.txt so pip
#   doesn't try to "satisfy" it again.

FROM nvidia/cuda:12.1.1-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HOME=/workspace/.cache/huggingface \
    TORCH_HOME=/workspace/.cache/torch \
    PIP_NO_CACHE_DIR=1 \
    PIP_PREFER_BINARY=1

# System deps. Note python3.10-dev — required for any Python C-extension build fallback.
# cmake + pkg-config cover other build edge cases.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git wget curl ca-certificates \
        ffmpeg \
        libgl1 libglib2.0-0 \
        openssh-server \
        python3.10 python3.10-venv python3.10-dev python3-pip \
        build-essential cmake pkg-config && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/python3.10 /usr/bin/python && \
    ln -sf /usr/bin/python3.10 /usr/bin/python3 && \
    mkdir -p /run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

WORKDIR /code

# Clone LatentSync.
RUN git clone https://github.com/bytedance/LatentSync.git /code/LatentSync && \
    cd /code/LatentSync && \
    git checkout main

# Stage 1: build tooling. Cython + numpy + pybind11 cover almost every native build path.
RUN pip install --upgrade pip setuptools wheel && \
    pip install Cython numpy pybind11 scikit-build

# Stage 2: install insightface from BINARY WHEEL ONLY (--only-binary).
# Insightface 0.7.3 has a manylinux2014 wheel for Python 3.10 on PyPI — no compile needed.
# If --only-binary fails, fall back to source build (now possible because python3.10-dev is installed).
RUN pip install --only-binary=:all: insightface==0.7.3 || \
    pip install insightface==0.7.3

# Stage 3: strip insightface from LatentSync's requirements.txt (we already installed it
# in Stage 2) so pip doesn't try to "satisfy" it again with a possibly-different version.
RUN sed -i '/^insightface/d' /code/LatentSync/requirements.txt && \
    cat /code/LatentSync/requirements.txt

# Stage 4: install the rest of LatentSync's requirements. --prefer-binary tells pip to
# pick wheels over sdists whenever available — drastically reduces compile-from-source risk.
RUN pip install --prefer-binary -r /code/LatentSync/requirements.txt

# Stage 5: our FastAPI wrapper's deps.
RUN pip install fastapi "uvicorn[standard]" python-multipart huggingface_hub

# Our FastAPI wrapper + entrypoint.
COPY server.py /code/server.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 22 = SSH (file uploads), 8383 = our FastAPI server (matches HeyGem port so Next.js doesn't change)
EXPOSE 22 8383

CMD ["/usr/local/bin/entrypoint.sh"]
