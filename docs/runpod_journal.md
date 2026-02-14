# RunPod + ComfyUI + WAN Avatar: Journal / Issues

Goal for this repo:
- Zero-intervention startup on RunPod (serverless or on-demand pod).
- Generate avatar idle video by replacing the person in a driving video with a user-provided image.
- Output must be 720p @ 24 fps, upload to MinIO (env-configured).

This file tracks issues found while making the pipeline reproducible.

## Current Pod Findings (Template Pod)
Tested using RunPod template image `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`.
- Python: 3.12.x
- CUDA: 12.8.1
- Torch: 2.8.0 (template tag implies this)
- ComfyUI runtime (cloned by bootstrap): v0.13.0 (observed in logs on 2026-02-14)

## Serverless Findings (REST API, Custom Image)
Deployed a queue-based serverless endpoint using a custom image:
- Image: `dexsynccom/twin-avatar:wan-worker-20260214-2d62a28` (private Docker Hub)
- Template id: `c9h032022j`
- Endpoint id (invoke base): `b6bab5jxqhcydz` -> `https://api.runpod.ai/v2/b6bab5jxqhcydz`

Notes:
- Docker Hub private repo requires RunPod `containerRegistryAuthId` to pull.
- REST `/v1/endpoints` returns a single `id` (used for both management and v2 invocation); there is no separate `endpointId`.
- Cold starts can exceed defaults; set:
  - Template env: `RUNPOD_INIT_TIMEOUT=7200`
  - Endpoint: `executionTimeoutMs` high enough (example: `7200000`)

Measured E2E execution time (serverless, including cold-start model fetches on the worker):
- `jobs.png` + `video-conference-man-1.mp4`: `executionTime=611074ms` (10.2 min), output `e2e/jobs_man1/idle_20260214_060045.mp4`
- `exec-woman.png` + `video-conference-woman.mp4`: `executionTime=618927ms` (10.3 min), output `e2e/execwoman_woman1/idle_20260214_061954.mp4`

Validated outputs via `ffprobe`:
- H.264 MP4, `1280x720`, `24/1` fps.

## Issues / Challenges

### 1) HuggingFace "hf_transfer" extra is not reliable
Observed warning:
- `huggingface-hub ... does not provide the extra 'hf-transfer'`

Root cause:
- `huggingface_hub[hf_transfer]` is not a stable extra across versions.

Fix:
- Install `hf_transfer` explicitly and enable it via `HF_HUB_ENABLE_HF_TRANSFER=1`.
- Prefer a Python downloader (`download_models.py`) using `huggingface_hub` so downloads can resume and are consistent.

### 2) Large model downloads need resume + robust retries
Downloading 10-90GB of assets via plain `wget` is fragile:
- If a connection drops, `wget -O ...` can restart from 0.
- Redirected xet/cas URLs can expire mid-download.

Fix:
- Use `huggingface_hub` (with xet support) and hardlink into `/ComfyUI/models/...` to avoid double disk usage.
- If `wget/curl` is used, ensure resume (`--continue` / `--continue-at -`) and temp files.

### 3) Disk sizing can silently fail
Many RunPod templates default to ~80GB container disk.
Full WAN stacks can exceed that (user expectation: ~91GB).

Fix:
- In pod provisioning, set `containerDiskInGb` high enough (>= 120GB recommended if storing full model set locally).
- Long-term: network volume (per region) or MinIO-backed model cache.

### 4) ComfyUI-Manager config location changed
ComfyUI-Manager migrated config from:
- Old: `/ComfyUI/user/default/ComfyUI-Manager/config.ini`
- New: `/ComfyUI/user/__manager/config.ini`

Fix:
- Write config to the new location in bootstrap and Docker builds to avoid migration noise and surprises.

### 5) AdaptiveWindowSize node import warning
Observed:
- "Enhanced face crop nodes not available ..." from `ComfyUI-AdaptiveWindowSize`.

Impact:
- May be harmless if workflow doesn't use that node.
- Could break workflows expecting those nodes.

Fix:
- Verify required nodes in `workflow_replace.json`.
- Avoid rearranging that repo's folder layout unless necessary; pin to a known-good commit if possible.

### 6) ComfyUI readiness checks should be HTTP-based
Websocket may fail until HTTP server is ready.

Fix:
- Wait for `GET http://127.0.0.1:8188/` to return `200` before calling handler.

## Action Items
- Keep `bootstrap_comfyui.sh` idempotent and pin critical packages (`onnxruntime-gpu`, etc).
- Replace `wget` model fetches with `download_models.py` and make entrypoint use it by default.
- Add a single "smoke test" script that:
  - downloads 1 image + 1 driving video (MinIO)
  - runs workflow
  - validates output via `ffprobe` (24fps, 1280x720)
  - uploads to MinIO
