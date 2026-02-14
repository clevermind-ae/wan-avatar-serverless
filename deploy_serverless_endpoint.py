"""
RunPod Serverless Deploy Helper (REST API)

Creates (or reuses) a container registry auth, a serverless template, and a serverless endpoint.

Required env:
  RUNPOD_API_KEY

If the Docker image is private, provide:
  DOCKERHUB_USERNAME
  DOCKERHUB_PASSWORD
Optional:
  RUNPOD_CONTAINER_REGISTRY_AUTH_NAME (default: dockerhub-dexsynccom)
  RUNPOD_CONTAINER_REGISTRY_AUTH_ID   (skip creation/reuse by id)

Template/Endpoint config:
  RUNPOD_IMAGE_NAME (default: dexsynccom/twin-avatar:wan-worker-20260214-70cebb5)
  RUNPOD_TEMPLATE_NAME
  RUNPOD_ENDPOINT_NAME
  RUNPOD_GPU_TYPE_IDS (comma-separated; defaults to common 48GB+ GPUs + H100)

MinIO env (stored on the template in Phase B):
  MINIO_ENDPOINT
  MINIO_ACCESS_KEY
  MINIO_SECRET_KEY
  MINIO_BUCKET
  MINIO_USE_SSL
  DEFAULT_DRIVING_VIDEO_PATH (optional)
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Dict, List, Optional

import requests


REST_URL = os.getenv("RUNPOD_REST_URL", "https://rest.runpod.io/v1").rstrip("/")
API_KEY = os.environ.get("RUNPOD_API_KEY", "")


def _die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


def _req(method: str, path: str, *, json_body: Optional[dict] = None) -> Any:
    url = f"{REST_URL}{path}"
    headers = {"Authorization": f"Bearer {API_KEY}"}
    if json_body is not None:
        headers["Content-Type"] = "application/json"
    resp = requests.request(
        method,
        url,
        headers=headers,
        json=json_body,
        timeout=120,
    )
    if resp.status_code >= 400:
        snippet = resp.text[:2000]
        _die(f"{method} {path} failed: HTTP {resp.status_code}: {snippet}")
    if resp.text.strip() == "":
        return None
    return resp.json()


def _as_list(x: Any) -> List[dict]:
    if x is None:
        return []
    if isinstance(x, list):
        return x
    # Some endpoints wrap lists in an object; be tolerant.
    if isinstance(x, dict):
        for k in ("data", "items", "results"):
            if isinstance(x.get(k), list):
                return x[k]
    _die(f"Unexpected list response: {type(x).__name__}")
    return []


def ensure_container_registry_auth() -> Optional[str]:
    existing_id = os.getenv("RUNPOD_CONTAINER_REGISTRY_AUTH_ID")
    if existing_id:
        return existing_id

    name = os.getenv("RUNPOD_CONTAINER_REGISTRY_AUTH_NAME", "dockerhub-dexsynccom")
    auths = _as_list(_req("GET", "/containerregistryauth"))
    for auth in auths:
        if auth.get("name") == name:
            return auth.get("id")

    username = os.getenv("DOCKERHUB_USERNAME")
    password = os.getenv("DOCKERHUB_PASSWORD")
    if not username or not password:
        # If the image is public, we can proceed without auth.
        return None

    created = _req(
        "POST",
        "/containerregistryauth",
        json_body={"name": name, "username": username, "password": password},
    )
    if not isinstance(created, dict) or not created.get("id"):
        _die(f"Unexpected container registry auth create response: {created}")
    return created["id"]


def ensure_template(container_registry_auth_id: Optional[str]) -> str:
    image_name = os.getenv("RUNPOD_IMAGE_NAME", "dexsynccom/twin-avatar:wan-worker-20260214-70cebb5")
    # Keep template names ASCII/safe so they work across APIs/UIs.
    default_tag = image_name.split(":", 1)[1] if ":" in image_name else image_name
    default_tag = default_tag.replace("/", "_").replace(":", "_")
    template_name = os.getenv("RUNPOD_TEMPLATE_NAME") or f"wan-avatar-worker-{default_tag}"
    container_disk_gb = int(os.getenv("RUNPOD_CONTAINER_DISK_GB", "250"))

    # Stored on the template so endpoint updates do not need env patch support.
    env: Dict[str, str] = {
        # Phase B: cold starts may include 90GB+ model downloads.
        "RUNPOD_INIT_TIMEOUT": os.getenv("RUNPOD_INIT_TIMEOUT", "7200"),
        "DOWNLOAD_MODELS_ON_START": os.getenv("DOWNLOAD_MODELS_ON_START", "true"),
        "COMFYUI_READY_TIMEOUT": os.getenv("COMFYUI_READY_TIMEOUT", "600"),
        "COMFYUI_USE_SAGE_ATTENTION": os.getenv("COMFYUI_USE_SAGE_ATTENTION", "false"),
        "WAN_ATTENTION_MODE": os.getenv("WAN_ATTENTION_MODE", "sdpa"),
        "RUNPOD_START_SERVERLESS": os.getenv("RUNPOD_START_SERVERLESS", "true"),
        # MinIO
        "MINIO_ENDPOINT": os.getenv("MINIO_ENDPOINT", ""),
        "MINIO_ACCESS_KEY": os.getenv("MINIO_ACCESS_KEY", ""),
        "MINIO_SECRET_KEY": os.getenv("MINIO_SECRET_KEY", ""),
        "MINIO_BUCKET": os.getenv("MINIO_BUCKET", "avatar-templates"),
        "MINIO_USE_SSL": os.getenv("MINIO_USE_SSL", "true"),
    }
    default_driving = os.getenv("DEFAULT_DRIVING_VIDEO_PATH", "")
    if default_driving:
        env["DEFAULT_DRIVING_VIDEO_PATH"] = default_driving

    if not env["MINIO_ENDPOINT"] or not env["MINIO_ACCESS_KEY"] or not env["MINIO_SECRET_KEY"]:
        _die("MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY must be set for deployment.")

    templates = _as_list(_req("GET", "/templates"))
    for t in templates:
        if t.get("name") == template_name:
            template_id = t.get("id")
            if template_id:
                return template_id

    body: Dict[str, Any] = {
        "name": template_name,
        "imageName": image_name,
        "isServerless": True,
        "containerDiskInGb": container_disk_gb,
        # Use image CMD/ENTRYPOINT.
        "dockerStartCmd": [],
        "dockerEntrypoint": [],
        "env": env,
        "ports": [],
        "volumeInGb": int(os.getenv("RUNPOD_VOLUME_GB", "0")),
        "volumeMountPath": os.getenv("RUNPOD_VOLUME_MOUNT", "/workspace"),
    }
    if container_registry_auth_id:
        body["containerRegistryAuthId"] = container_registry_auth_id

    created = _req("POST", "/templates", json_body=body)
    if not isinstance(created, dict) or not created.get("id"):
        _die(f"Unexpected template create response: {created}")
    return created["id"]


def ensure_endpoint(template_id: str) -> Dict[str, str]:
    endpoint_name = os.getenv("RUNPOD_ENDPOINT_NAME", "wan-avatar-serverless")
    gpu_type_ids_csv = os.getenv(
        "RUNPOD_GPU_TYPE_IDS",
        ",".join(
            [
                "NVIDIA L40S",
                "NVIDIA RTX 6000 Ada Generation",
                "NVIDIA RTX A6000",
                "NVIDIA A40",
                "NVIDIA RTX PRO 6000 Blackwell Server Edition",
                "NVIDIA H100 80GB HBM3",
            ]
        ),
    )
    gpu_type_ids = [x.strip() for x in gpu_type_ids_csv.split(",") if x.strip()]

    # Phase B: allow enough time for model downloads + inference.
    execution_timeout_ms = int(os.getenv("RUNPOD_EXECUTION_TIMEOUT_MS", "7200000"))
    idle_timeout_s = int(os.getenv("RUNPOD_IDLE_TIMEOUT_S", "5"))
    workers_min = int(os.getenv("RUNPOD_WORKERS_MIN", "0"))
    workers_max = int(os.getenv("RUNPOD_WORKERS_MAX", "1"))
    scaler_type = os.getenv("RUNPOD_SCALER_TYPE", "QUEUE_DELAY")
    scaler_value = int(os.getenv("RUNPOD_SCALER_VALUE", "4"))
    flashboot = os.getenv("RUNPOD_FLASHBOOT", "true").lower() == "true"

    endpoints = _as_list(_req("GET", "/endpoints"))
    for ep in endpoints:
        name = ep.get("name") or ""
        if name == endpoint_name or name == f"{endpoint_name} -fb" or name.startswith(endpoint_name):
            ep_id = ep.get("id")
            # REST API uses a single `id` for both management and invocation (v2/<id>).
            endpoint_id = ep_id
            if not ep_id:
                _die(f"Endpoint exists but missing ids: {ep}")
            # Best-effort update to point to the latest template.
            _req(
                "PATCH",
                f"/endpoints/{ep_id}",
                json_body={
                    "templateId": template_id,
                    "gpuTypeIds": gpu_type_ids,
                    "gpuCount": 1,
                    "workersMin": workers_min,
                    "workersMax": workers_max,
                    "idleTimeout": idle_timeout_s,
                    "executionTimeoutMs": execution_timeout_ms,
                    "scalerType": scaler_type,
                    "scalerValue": scaler_value,
                    "flashboot": flashboot,
                    "allowedCudaVersions": ["12.8"],
                },
            )
            return {"id": ep_id, "endpointId": endpoint_id}

    created = _req(
        "POST",
        "/endpoints",
        json_body={
            "name": endpoint_name,
            "templateId": template_id,
            "gpuTypeIds": gpu_type_ids,
            "gpuCount": 1,
            "workersMin": workers_min,
            "workersMax": workers_max,
            "idleTimeout": idle_timeout_s,
            "executionTimeoutMs": execution_timeout_ms,
            "scalerType": scaler_type,
            "scalerValue": scaler_value,
            "flashboot": flashboot,
            "allowedCudaVersions": ["12.8"],
        },
    )
    # REST API returns only `id` (used for v2 invocation).
    if not isinstance(created, dict) or not created.get("id"):
        _die(f"Unexpected endpoint create response: {created}")
    return {"id": created["id"], "endpointId": created["id"]}


def main() -> int:
    if not API_KEY:
        _die("RUNPOD_API_KEY is required.")

    print(f"RunPod REST: {REST_URL}")

    auth_id = ensure_container_registry_auth()
    if auth_id:
        print(f"Container registry auth: {auth_id}")
    else:
        print("Container registry auth: (none)  (assuming image is public)")

    template_id = ensure_template(auth_id)
    print(f"Template id: {template_id}")

    endpoint = ensure_endpoint(template_id)
    print(json.dumps(endpoint, indent=2))
    print(f"Serverless invoke base: https://api.runpod.ai/v2/{endpoint['endpointId']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
