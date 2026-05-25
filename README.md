# LatentSync-SSHD Docker Image

Custom build of [ByteDance LatentSync 1.6](https://github.com/bytedance/LatentSync) with:
- **SSH** (so the Next.js app can SCP files in, same as the HeyGem image)
- **FastAPI wrapper** that exposes `/easy/submit` + `/easy/query` — **identical shape to HeyGem's API** so `lib/heygem-client.js` needs ZERO changes

Used by [Adnan Clone Studio](https://github.com/adnanpasha154-wq) to replace HeyGem after the 2026-05-25 A/B test showed HeyGem's baked-in GFPGAN was destroying face fidelity on darker skin + beards.

---

## Why LatentSync vs HeyGem

| | HeyGem (duix.avatar) | LatentSync 1.6 |
|---|---|---|
| Face restorer baked in? | **Yes (GFPGAN)** — homogenizes face | No — latent-space ID anchor |
| Beard/dark skin preservation | Bad (60% fidelity) | Strong (paper Section 4 explicitly shows beard preservation) |
| Reference input | Video | Video |
| License | Apache-2.0 | Apache-2.0 |
| VRAM (A40 has 48 GB) | ~16 GB | ~18 GB |
| API surface (we wrap to match) | `/easy/submit` + `/easy/query` | `/easy/submit` + `/easy/query` (our FastAPI mimics it) |

---

## Ports
- `22` — SSH (used by Next.js to SCP source video + audio)
- `8383` — FastAPI server (HeyGem-compatible endpoints)

---

## Deploy steps (one-time setup)

### 1. Create a NEW GitHub repo for this image

Don't reuse `heygem-sshd` — keep HeyGem as fallback.

```bash
cd C:\Users\User\OneDrive\Desktop\Adnan-Clone-Studio\docker-build-latentsync
git init
git add .
git commit -m "Initial LatentSync wrapper"
git branch -M main
gh repo create latentsync-sshd --public --source=. --push
```

### 2. Add Docker Hub secrets to the new repo

```bash
gh secret set DOCKERHUB_USERNAME --body "insightadnan" --repo adnanpasha154-wq/latentsync-sshd
gh secret set DOCKERHUB_TOKEN --body "<YOUR_DOCKER_HUB_TOKEN>" --repo adnanpasha154-wq/latentsync-sshd
```

### 3. Wait for GitHub Actions to build

Go to `https://github.com/adnanpasha154-wq/latentsync-sshd/actions` — should take ~15-20 min (CUDA base + torch is heavy).

Image lands at `insightadnan/latentsync-sshd:latest` on Docker Hub.

### 4. Create a new RunPod template

1. https://www.runpod.io/console/user/templates → **New Template**
2. Name: `latentsync-sshd`
3. Container image: `insightadnan/latentsync-sshd:latest`
4. Container disk: 20 GB
5. Volume disk: 50 GB (mount at `/workspace`)
6. Expose ports: `22/tcp`, `8383/http`
7. Environment variables:
   - `PUBLIC_KEY` = `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINpPK5lmyEEfHhtNdQiuUA500LjIJXodquZO6m651EJz adnan-clone-studio`

### 5. Deploy and test

- Pick A40 ($0.44/hr), pick `latentsync-sshd` template, deploy.
- **First boot:** ~8 min total (5 min image pull + 3 min weights download to volume).
- **Subsequent boots:** ~5 min (image already cached, weights persist on volume).

Open the Next.js app → Generate → submit a test reel. **The app code is unchanged** — the new pod's API responds identically to HeyGem's.

---

## What changes in the Next.js app

**Nothing.**

The FastAPI wrapper at `server.py` returns the same response shape as HeyGem:
- Submit: `{ code: 10000, success: true, data: { code }, msg: "submitted" }`
- Query: `{ code: 10000, data: { status, progress, result, msg } }`
- Status codes: 0=queued, 1=running, 2=done, 3=failed (same as HeyGem)
- Result path: `/<code>-r.mp4` (same quirk Next.js status route already handles)

The only thing that differs is **which template the pod boots from**. Pick `latentsync-sshd` instead of `heygem-sshd` in the RunPod deploy step.

---

## Quality validation — hard gate

After the first test reel:
- **If face fidelity is visibly > HeyGem's 60%** (Adnan's beard preserved, skin tone correct) → swap is a success, deprecate HeyGem image.
- **If face fidelity is the same or worse** → STOP. Switch to Sonic (#2 fallback from the research). Don't burn more pod hours tuning LatentSync params.

---

## Required GitHub secrets
- `DOCKERHUB_USERNAME` = `insightadnan`
- `DOCKERHUB_TOKEN` = (Docker Hub personal access token, same one used for heygem-sshd repo)
