# RunPod Serverless Rollout Plan (WAN Avatar) - Phase B First

This document is the step-by-step plan to deploy this repo as a RunPod **Queue-based Serverless endpoint** that:

- Downloads models on cold start (Phase **B**, low-risk, fastest path).
- Generates a 720p, 24fps avatar video by replacing the person in a driving video with a user image.
- Uploads the resulting MP4 to MinIO (configured via env vars), returning a `minio_key` (and optionally a presigned URL).

Once Phase B is stable, we can propose Phase **A** (Hugging Face bundle repo + RunPod cached models) for better UX/cost.

## Source of Truth (RunPod Docs)

Key RunPod constraints and behaviors we must design around:

- Payload limits:
  - `/run` (async): **10 MB** max payload.
  - `/runsync` (sync): **20 MB** max payload.
  - Implication: always pass **MinIO paths / URLs** (never base64 video blobs).
  - Ref: https://docs.runpod.io/serverless/endpoints/send-requests
- Worker init timeout:
  - Default worker init health limit is **~7 minutes**.
  - If our cold start (image pull + downloads) can exceed that, set `RUNPOD_INIT_TIMEOUT` (seconds).
  - Ref: https://docs.runpod.io/serverless/development/test-response-times
- Storage:
  - **Container disk** is local and fast but **ephemeral** (data is lost when worker stops).
  - Network volumes persist but add latency and restrict the endpoint to their datacenter(s).
  - Ref: https://docs.runpod.io/serverless/storage/overview
- Cached models:
  - If a model is hosted on Hugging Face, RunPod can schedule workers on hosts with that model preloaded.
  - Cached models are available under `/runpod-volume/huggingface-cache/hub/`.
  - Ref: https://docs.runpod.io/serverless/endpoints (cached models)
- Endpoint settings:
  - We can enable **FlashBoot**, configure **Execution Timeout**, **Job TTL**, **GPU priorities**, and optional **Network Volumes**.
  - Ref: https://docs.runpod.io/serverless/endpoints/endpoint-configurations

## Terminology

- **Phase B** (now): no cached model, no network volume. Download models during worker init onto container disk.
- **Phase A** (later): use a *slim* Hugging Face bundle repo + RunPod cached models (best cold-start).

## Phase B (Low Risk): Step-by-Step

### 0) Preconditions / Inputs

- MinIO has:
  - Input images (e.g. `avatar-templates/input-avatars/*.png`)
  - Driving videos (e.g. `avatar-templates/sitting-woman/*.mp4`)
- This repo already supports:
  - MinIO download + upload in `handler.py`
  - model download via `download_models.py`
  - ComfyUI startup via `entrypoint.sh`

### 1) Freeze the Worker Image (Deterministic)

Goal: build a reproducible worker image that always starts the same ComfyUI + custom nodes + workflow.

1. Base image: use `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404` as the Docker `FROM`.
2. Pin versions:
   - Pin ComfyUI to a commit SHA.
   - Pin each custom node repo to a commit SHA (avoid surprises).
   - Keep `requirements.txt` pinned.
3. Deterministic startup:
   - Start ComfyUI headless (no UI needed).
   - Do NOT hard-require `--use-sage-attention` (enable only via env flag), so missing deps do not kill the worker.
   - Increase readiness wait time (cold boots can exceed 2 minutes).
4. Build & push with an immutable tag:
   - `dexsynccom/twin-avatar:wan-worker-YYYYMMDD-<gitsha>`
   - Never use `:latest`.

Deliverable: a Docker Hub image tag we can select in the Serverless endpoint.

### 2) Serverless Endpoint Configuration (Queue-Based)

Create a **Queue-based** endpoint (not load-balancing).

Recommended initial settings:

- GPU types: select multiple (priority order) to improve availability.
  - Example priority: `H100 PRO` -> `A100` -> `L40S / 6000 Ada PRO` -> `A6000 / A40`.
- Active workers: `0` (accept cold starts for now).
- Max workers: `1` initially (avoid concurrency surprises while stabilizing).
- Idle timeout: default `5s` is fine (we want scale-to-zero).
- Execution timeout: start at `1200s` (20 min) while stabilizing.
- Job TTL: `1h` (must cover queue delay + execution).
- FlashBoot: enable (helps when traffic is bursty but not totally idle).

Container / storage settings:

- Container disk: set to **>= 120 GB** (models + temp files; conservative).
  - (We can tune this based on actual disk usage observed.)

Environment variables (endpoint secrets):

- `MINIO_ENDPOINT`
- `MINIO_ACCESS_KEY`
- `MINIO_SECRET_KEY`
- `MINIO_BUCKET`
- `MINIO_USE_SSL`
- Optional: `DEFAULT_DRIVING_VIDEO_PATH`

Worker init timeout:

- Set `RUNPOD_INIT_TIMEOUT=1800` (30 minutes) so first-time downloads don’t mark the worker unhealthy.

### 3) Contract for Requests (Avoid Limits)

Client should always send `/run` (async) and poll `/status/{id}`.

Input schema (recommended):

- `input_image_url` OR `input_image_minio_path`
- `driving_video_path` (MinIO key under the bucket)
- Optional: `user_id`, `avatar_id` (used for output key prefixing)

Output schema (current behavior):

- `minio_key`: the uploaded MP4 location in the bucket
- Optional: `presigned_url`

Never send base64 videos (payload limit).

### 4) Validate End-to-End (Automated)

Use `smoke_test.py` as the acceptance gate:

1. Trigger a generation job.
2. Download output from MinIO.
3. Validate output:
   - MP4 exists
   - 1280x720
   - 24 fps
4. Confirm upload key naming and that videos play correctly.

Run it:

- Locally (where possible), then against the deployed endpoint.

### 5) Observe and Record Cold/Warm Metrics

Use RunPod endpoint metrics and client-side timestamps to record:

- `delayTime` (queue + cold start) percentiles
- `executionTime` percentiles
- Cold start count

Goal for Phase B:

- “Works reliably with zero manual intervention.”
- Accept that cold starts are expensive; record them so we can justify Phase A.

## Phase A (Later): Cached Models Using a Slim HF Bundle Repo

Why:

- Cached models reduce cold start time and reduce cost because workers are not billed while large model files are being downloaded (when the cache is missing on the host).

Cost note:

- Hosting a ~100GB bundle on Hugging Face may require a paid plan depending on whether the repo is private, organizational storage limits, and current HF policies. Treat this as a customer-facing decision and verify HF pricing/limits at proposal time.

Constraints:

- Cached models are designed around Hugging Face cache conventions under `/runpod-volume/huggingface-cache/hub/`.
- Practically, you should only use cached models if the model repository is a **tight bundle** of exactly what you need.

Plan:

1. Create a Hugging Face repo in our org, e.g. `clevermind-ae/wan-avatar-bundle-v1`.
2. Upload ONLY the required files (the subset in `download_models.py`).
3. Set the endpoint’s **Model** field to that HF repo.
4. Set env var: `HF_HOME=/runpod-volume/huggingface-cache` so `hf_hub_download()` resolves into the cached mount.
5. Update `download_models.py` to prefer local cached paths when present (and only download missing small artifacts).

Result:

- Much faster and cheaper cold starts.
- Better customer UX.

## Risks / Watchouts (Operational)

- Disk pressure: downloads can exceed container disk; keep disk size conservative in Phase B.
- Model download flakiness: rely on `huggingface_hub` + retries, avoid raw `wget` for huge files.
- Version drift: pin ComfyUI/custom node commits.
- Concurrency: keep `Max workers=1` until handler + ComfyUI are proven stable under parallel requests.
- Network volumes: avoid unless we explicitly accept reduced availability (datacenter constraint).
