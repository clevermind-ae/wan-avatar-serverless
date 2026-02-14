# Serverless Integration (RunPod Queue Endpoint)

This repo runs as a RunPod **queue-based serverless** endpoint.

## Deploy

Use `deploy_serverless_endpoint.py` (REST API) to create:
- DockerHub registry auth (for private images)
- Serverless template
- Serverless endpoint

Example (Phase B: cold-start model downloads):

```bash
export RUNPOD_API_KEY=...
export DOCKERHUB_USERNAME=dexsynccom
export DOCKERHUB_PASSWORD=...

export RUNPOD_IMAGE_NAME=dexsynccom/twin-avatar:wan-worker-20260214-2d62a28

export MINIO_ENDPOINT=twin-storage.dexsync.com
export MINIO_ACCESS_KEY=...
export MINIO_SECRET_KEY=...
export MINIO_USE_SSL=true
export MINIO_BUCKET=avatar-templates

/Users/gonfreeks/clevermind/StreamingAvatar/venv/bin/python deploy_serverless_endpoint.py
```

The script prints the serverless invoke base:
- `https://api.runpod.ai/v2/<ENDPOINT_ID>`

## Request Contract

Submit:

- `POST https://api.runpod.ai/v2/<ENDPOINT_ID>/run`
- Header: `Authorization: Bearer <RUNPOD_API_KEY>`

Body:

```json
{
  "input": {
    "user_id": "user_123",
    "avatar_id": "avatar_456",
    "image_minio_path": "input-avatars/jobs.png",
    "driving_video_path": "sitting-woman/video-conference-woman.mp4",
    "output_video_key": "user-avatars/<user_id>/<avatar_id>/idle.mp4",
    "output_thumbnail_key": "user-avatars/<user_id>/<avatar_id>/thumb.jpg",
    "prompt": "optional positive prompt",
    "negative_prompt": "optional negative prompt"
  }
}
```

Notes:

- Exactly one of `image_minio_path`, `image_url`, `image_base64` is required.
- One of `driving_video_path`, `driving_video_url`, `driving_video_base64`, or `template_id` is required.
- For platform integrations, prefer `output_video_key` so downstream systems can use a stable MinIO key.
- `output_thumbnail_key` is optional; if provided, the worker will best-effort extract and upload a JPG thumbnail.

Poll:

- `GET https://api.runpod.ai/v2/<ENDPOINT_ID>/status/<JOB_ID>`

## Response

On success (`status=COMPLETED`), output contains:

- `minio_key`: uploaded MP4 key in `MINIO_BUCKET`
- `video_url`: presigned URL (from MinIO)
- `thumbnail_key`, `thumbnail_url` (optional): present if `output_thumbnail_key` was provided
- `fps`, `width`, `height`

Example:

```json
{
  "minio_key": "e2e/jobs_man1/idle_20260214_060045.mp4",
  "video_url": "https://twin-storage.dexsync.com/avatar-templates/....",
  "fps": 24,
  "width": 1280,
  "height": 720
}
```

## Notes

- Phase B uses cold-start model downloads; set:
  - `RUNPOD_INIT_TIMEOUT` (template env) to allow long initialization.
  - `executionTimeoutMs` (endpoint) to allow long jobs on first boot.
- For better UX/cost later, create a **slim HuggingFace bundle repo** and use RunPod **Cached Models**.
