"""
FastAPI wrapper for LatentSync that mimics HeyGem's /easy/submit + /easy/query API.

Why this shape: our existing Next.js app talks to HeyGem at:
    POST /easy/submit  { audio_url, video_url, code, chaofen, watermark_switch, pn }
    GET  /easy/query?code=<uuid>

By matching that shape, lib/heygem-client.js stays UNCHANGED.

HeyGem response shapes we replicate:
    Submit OK:    {code: 10000, success: true, data: {...}, msg: "..."}
    Query OK:     {code: 10000, data: {status, progress, result, ...}, msg: "..."}
    Status codes derived from HeyGem session learnings:
        - status numeric: 0=queued, 1=running, 2=done, 3=failed
        - progress: 0-100
        - result: relative filename like "/<code>-r.mp4" (Next.js status route knows the quirk)

LatentSync inference call: we use scripts/inference.py from the cloned repo via subprocess
(simplest first cut — can swap to in-process import later for speed).
"""

import os
import sys
import json
import time
import uuid
import shutil
import logging
import threading
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(name)s — %(message)s",
)
log = logging.getLogger("latentsync-server")

# --- Paths (mirror HeyGem layout so the Next.js code's path assumptions still hold) ---
WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
JOBS_DIR = WORKSPACE / "jobs"
RESULTS_DIR = Path("/code/data/temp")  # HeyGem puts results here; status route looks here
LATENTSYNC_DIR = Path("/code/LatentSync")

JOBS_DIR.mkdir(parents=True, exist_ok=True)
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

# --- In-memory job table (process-local; survives only until pod stops) ---
# job_id (code) -> dict with: status (int), progress (int), result (str|None), msg (str), error (str|None)
JOBS: dict[str, dict] = {}
JOBS_LOCK = threading.Lock()

# Match HeyGem's quirk: only one job at a time (parallel submits failed silently for HeyGem).
INFERENCE_LOCK = threading.Lock()

app = FastAPI(title="LatentSync HeyGem-compat wrapper", version="1.0")


# ---------- Helpers ----------

def _set_status(code: str, **kwargs):
    with JOBS_LOCK:
        if code not in JOBS:
            JOBS[code] = {"status": 0, "progress": 0, "result": None, "msg": "", "error": None}
        JOBS[code].update(kwargs)


def _run_latentsync(code: str, video_path: str, audio_path: str):
    """Background worker: runs LatentSync inference and updates job status."""
    with INFERENCE_LOCK:  # serialize like HeyGem
        try:
            _set_status(code, status=1, progress=10, msg="starting inference")
            log.info(f"[{code}] running LatentSync on video={video_path} audio={audio_path}")

            out_path = RESULTS_DIR / f"{code}-r.mp4"

            # LatentSync 1.6 inference invocation. The exact script path/args follow the repo README:
            #   python -m scripts.inference \
            #       --unet_config_path "configs/unet/stage2.yaml" \
            #       --inference_ckpt_path "checkpoints/latentsync_unet.pt" \
            #       --video_path <input.mp4> --audio_path <input.wav> --video_out_path <out.mp4> \
            #       --inference_steps 20 --guidance_scale 1.5 --seed 1247
            #
            # First boot: weights auto-download from HuggingFace to HF_HOME (/workspace/.cache/huggingface).
            cmd = [
                "python", "-m", "scripts.inference",
                "--unet_config_path", "configs/unet/stage2.yaml",
                "--inference_ckpt_path", "checkpoints/latentsync_unet.pt",
                "--video_path", video_path,
                "--audio_path", audio_path,
                "--video_out_path", str(out_path),
                "--inference_steps", "20",
                "--guidance_scale", "1.5",
                "--seed", "1247",
            ]

            _set_status(code, progress=20, msg="feature extraction")

            proc = subprocess.run(
                cmd,
                cwd=str(LATENTSYNC_DIR),
                capture_output=True,
                text=True,
                timeout=1800,  # 30 min hard cap
            )

            if proc.returncode != 0:
                err = proc.stderr[-2000:] if proc.stderr else "unknown error"
                log.error(f"[{code}] inference failed:\n{err}")
                _set_status(code, status=3, progress=100, msg="failed", error=err)
                return

            if not out_path.exists():
                _set_status(code, status=3, progress=100, msg="failed", error="output file missing")
                return

            log.info(f"[{code}] done: {out_path}")
            # Match HeyGem result shape: "/<code>-r.mp4" (relative; Next.js status route handles the quirk)
            _set_status(code, status=2, progress=100, result=f"/{code}-r.mp4", msg="任务完成")

        except subprocess.TimeoutExpired:
            log.error(f"[{code}] timeout after 30 min")
            _set_status(code, status=3, progress=100, msg="timeout", error="30 min hard cap exceeded")
        except Exception as e:
            log.exception(f"[{code}] crash: {e}")
            _set_status(code, status=3, progress=100, msg="crash", error=str(e))


# ---------- Endpoints (HeyGem-compatible) ----------

@app.get("/")
def root():
    """Healthcheck — Next.js healthCheck() pings this with GET."""
    return {"ok": True, "service": "LatentSync HeyGem-compat", "active_jobs": len(JOBS)}


@app.post("/easy/submit")
async def submit(req: Request):
    """
    HeyGem-compatible submit endpoint.
    Body JSON: { audio_url, video_url, code, chaofen, watermark_switch, pn }
    - audio_url, video_url: ABSOLUTE paths on the pod (we SCP'd them earlier)
    - code: client-generated UUID, used to query status later
    - chaofen, watermark_switch, pn: HeyGem-specific, IGNORED by LatentSync (no equivalent)
    """
    body = await req.json()
    code = body.get("code") or str(uuid.uuid4())
    video_url = body.get("video_url")
    audio_url = body.get("audio_url")

    if not video_url or not audio_url:
        return JSONResponse(
            {"code": 10001, "success": False, "msg": "video_url and audio_url required"},
            status_code=400,
        )

    if not Path(video_url).exists():
        return JSONResponse(
            {"code": 10002, "success": False, "msg": f"video file not found: {video_url}"},
            status_code=400,
        )
    if not Path(audio_url).exists():
        return JSONResponse(
            {"code": 10003, "success": False, "msg": f"audio file not found: {audio_url}"},
            status_code=400,
        )

    _set_status(code, status=0, progress=0, msg="queued")

    # Kick off inference in background thread so submit returns immediately
    thread = threading.Thread(
        target=_run_latentsync,
        args=(code, video_url, audio_url),
        daemon=True,
    )
    thread.start()

    log.info(f"[{code}] submitted: video={video_url} audio={audio_url}")
    return {"code": 10000, "success": True, "data": {"code": code}, "msg": "submitted"}


@app.get("/easy/query")
async def query(code: str):
    """
    HeyGem-compatible status poll.
    Returns: { code: 10000, data: { status, progress, result, msg }, msg }
    Status values:
        0 = queued
        1 = running
        2 = done    (result field has "/<code>-r.mp4")
        3 = failed  (msg has error)
    """
    with JOBS_LOCK:
        job = JOBS.get(code)
    if not job:
        # HeyGem returns 10004 when task doesn't exist; replicate.
        return {"code": 10004, "success": False, "msg": "任务不存在"}

    return {
        "code": 10000,
        "success": True,
        "data": {
            "code": code,
            "status": job["status"],
            "progress": job["progress"],
            "result": job["result"],
            "msg": job["msg"],
            "error": job.get("error"),
        },
        "msg": job["msg"],
    }


if __name__ == "__main__":
    log.info("Starting LatentSync server on 0.0.0.0:8383 (HeyGem-compatible API)")
    uvicorn.run(app, host="0.0.0.0", port=8383, log_level="info")
