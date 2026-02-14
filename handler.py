import runpod
import os
import websocket
import base64
import json
import uuid
import logging
import urllib.request
import time
import random
import shutil
from datetime import datetime

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

server_address = os.getenv("SERVER_ADDRESS", "127.0.0.1")
client_id = str(uuid.uuid4())

# MinIO config from environment
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "twin-storage.dexsync.com")
MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "")
MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "")
MINIO_BUCKET = os.getenv("MINIO_BUCKET", "avatars")
MINIO_USE_SSL = os.getenv("MINIO_USE_SSL", "false").lower() == "true"
DEFAULT_DRIVING_VIDEO_PATH = os.getenv("DEFAULT_DRIVING_VIDEO_PATH", "")

# Fixed generation parameters
FPS = 24
WIDTH = int(os.getenv("VIDEO_WIDTH", "1280"))
HEIGHT = int(os.getenv("VIDEO_HEIGHT", "720"))
STEPS = 4
CFG = 1.0
POSITIVE_PROMPT = (
    "a person standing naturally with subtle idle movements, "
    "gentle breathing motion, soft natural lighting, photorealistic, "
    "high quality, smooth motion"
)
NEGATIVE_PROMPT = (
    "blurry, distorted, deformed, low quality, artifacts, glitch, "
    "unnatural pose, static, overexposed, underexposed, text, watermark, "
    "extra limbs, bad anatomy, ugly"
)

_REPO_DIR = os.path.dirname(os.path.abspath(__file__))

# In the production Docker image we copy these to absolute paths at container root.
# In debug/template pods we typically run from a git checkout under /workspace.
TEMPLATES_DIR = os.getenv(
    "TEMPLATES_DIR",
    "/templates" if os.path.isdir("/templates") else os.path.join(_REPO_DIR, "templates"),
)
WORKFLOW_PATH = os.getenv(
    "WORKFLOW_PATH",
    "/workflow_replace.json"
    if os.path.exists("/workflow_replace.json")
    else os.path.join(_REPO_DIR, "workflow_replace.json"),
)
COMFY_INPUT_DIR = "/ComfyUI/input"
BASE64_FALLBACK_MAX_MB = int(os.getenv("BASE64_FALLBACK_MAX_MB", "80"))


def get_minio_client():
    from minio import Minio

    return Minio(
        MINIO_ENDPOINT,
        access_key=MINIO_ACCESS_KEY,
        secret_key=MINIO_SECRET_KEY,
        secure=MINIO_USE_SSL,
    )


def upload_to_minio(local_path, object_name):
    """Upload a file to MinIO and return a presigned URL."""
    client = get_minio_client()

    if not client.bucket_exists(MINIO_BUCKET):
        client.make_bucket(MINIO_BUCKET)

    client.fput_object(MINIO_BUCKET, object_name, local_path)
    logger.info(f"Uploaded to MinIO: {MINIO_BUCKET}/{object_name}")

    url = client.presigned_get_object(MINIO_BUCKET, object_name)
    return url


def download_file(url, output_path):
    """Download a file from a URL."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        with open(output_path, "wb") as f:
            shutil.copyfileobj(response, f)
    logger.info(f"Downloaded {url} -> {output_path}")
    return output_path


def save_base64(data, output_path):
    """Decode base64 data and save to file."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    decoded = base64.b64decode(data)
    with open(output_path, "wb") as f:
        f.write(decoded)
    logger.info(f"Saved base64 data to {output_path}")
    return output_path


def download_minio_object(object_name, output_path):
    """Download an object from MinIO bucket to a local path."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    client = get_minio_client()
    client.fget_object(MINIO_BUCKET, object_name, output_path)
    logger.info(f"Downloaded MinIO object {MINIO_BUCKET}/{object_name} -> {output_path}")
    return output_path


def queue_prompt(prompt):
    url = f"http://{server_address}:8188/prompt"
    p = {"prompt": prompt, "client_id": client_id}
    data = json.dumps(p).encode("utf-8")
    req = urllib.request.Request(url, data=data)
    return json.loads(urllib.request.urlopen(req).read())


def get_history(prompt_id):
    url = f"http://{server_address}:8188/history/{prompt_id}"
    with urllib.request.urlopen(url) as response:
        return json.loads(response.read())


def wait_for_completion(ws, prompt):
    """Submit prompt to ComfyUI and wait for video output via WebSocket."""
    prompt_id = queue_prompt(prompt)["prompt_id"]
    logger.info(f"Queued prompt: {prompt_id}")

    while True:
        out = ws.recv()
        if isinstance(out, str):
            message = json.loads(out)
            if message["type"] == "executing":
                data = message["data"]
                if data["node"] is None and data["prompt_id"] == prompt_id:
                    break
        # Binary data (previews etc.) — skip
        continue

    history = get_history(prompt_id)[prompt_id]
    for node_id in history["outputs"]:
        node_output = history["outputs"][node_id]
        if "gifs" in node_output:
            for video in node_output["gifs"]:
                return video["fullpath"]

    return None


def connect_comfyui():
    """Wait for ComfyUI HTTP, then connect WebSocket."""
    http_url = f"http://{server_address}:8188/"
    logger.info(f"Checking ComfyUI at {http_url}")

    for attempt in range(180):
        try:
            urllib.request.urlopen(http_url, timeout=5)
            logger.info(f"ComfyUI HTTP ready (attempt {attempt + 1})")
            break
        except Exception:
            if attempt == 179:
                raise Exception("ComfyUI server not reachable after 3 minutes")
            time.sleep(1)

    ws_url = f"ws://{server_address}:8188/ws?clientId={client_id}"
    ws = websocket.WebSocket()
    for attempt in range(36):
        try:
            ws.connect(ws_url)
            ws.settimeout(3600)
            logger.info(f"WebSocket connected (attempt {attempt + 1})")
            return ws
        except Exception:
            if attempt == 35:
                raise Exception("WebSocket connection failed after 3 minutes")
            time.sleep(5)


def handler(job):
    job_input = job.get("input", {})
    logger.info(f"Received job: {json.dumps({k: v[:50] + '...' if isinstance(v, str) and len(v) > 50 else v for k, v in job_input.items()})}")

    task_id = f"task_{uuid.uuid4().hex[:12]}"
    comfy_input_files = []
    template_id = job_input.get("template_id")
    try:
        # --- Resolve image input ---
        image_path = None
        if "image_url" in job_input:
            image_path = download_file(
                job_input["image_url"],
                os.path.join(task_id, "input_image.jpg"),
            )
        elif "image_base64" in job_input:
            image_path = save_base64(
                job_input["image_base64"],
                os.path.join(task_id, "input_image.jpg"),
            )
        else:
            return {"error": "image_url or image_base64 is required"}

        # --- Resolve driving video ---
        video_path = None
        if "driving_video_url" in job_input:
            video_path = download_file(
                job_input["driving_video_url"],
                os.path.join(task_id, "driving_video.mp4"),
            )
        elif "driving_video_base64" in job_input:
            video_path = save_base64(
                job_input["driving_video_base64"],
                os.path.join(task_id, "driving_video.mp4"),
            )
        else:
            minio_video_path = job_input.get("driving_video_path") or DEFAULT_DRIVING_VIDEO_PATH
            if minio_video_path:
                # Accept either "object/key.mp4" or "bucket/object/key.mp4".
                # The MinIO client is already scoped to MINIO_BUCKET.
                prefix = f"{MINIO_BUCKET}/"
                if minio_video_path.startswith(prefix):
                    minio_video_path = minio_video_path[len(prefix):]
                minio_video_path = minio_video_path.lstrip("/")
                video_path = download_minio_object(
                    minio_video_path,
                    os.path.join(task_id, "driving_video.mp4"),
                )
            elif template_id:
                local_template_path = os.path.join(TEMPLATES_DIR, f"{template_id}.mp4")
                if os.path.exists(local_template_path):
                    video_path = local_template_path
                else:
                    available = [
                        f.replace(".mp4", "")
                        for f in os.listdir(TEMPLATES_DIR)
                        if f.endswith(".mp4")
                    ]
                    return {
                        "error": f"Template '{template_id}' not found. Available: {available}"
                    }

        if not video_path:
            return {
                "error": (
                    "Provide one of: driving_video_url, driving_video_base64, "
                    "driving_video_path, or template_id"
                )
            }

        # Comfy LoadImage/VHS_LoadVideo are most reliable when files are under /ComfyUI/input.
        os.makedirs(COMFY_INPUT_DIR, exist_ok=True)
        comfy_image_name = f"{task_id}_input_image.jpg"
        comfy_video_name = f"{task_id}_driving_video.mp4"
        comfy_image_path = os.path.join(COMFY_INPUT_DIR, comfy_image_name)
        comfy_video_path = os.path.join(COMFY_INPUT_DIR, comfy_video_name)
        shutil.copy2(image_path, comfy_image_path)
        shutil.copy2(video_path, comfy_video_path)
        comfy_input_files.extend([comfy_image_path, comfy_video_path])

        # --- Load and configure workflow ---
        with open(WORKFLOW_PATH, "r") as f:
            workflow = json.load(f)

        seed = random.randint(0, 2**32 - 1)

        workflow["57"]["inputs"]["image"] = comfy_image_name
        workflow["63"]["inputs"]["video"] = comfy_video_name
        workflow["63"]["inputs"]["force_rate"] = FPS
        workflow["30"]["inputs"]["frame_rate"] = FPS
        workflow["65"]["inputs"]["positive_prompt"] = job_input.get("prompt", POSITIVE_PROMPT)
        workflow["65"]["inputs"]["negative_prompt"] = job_input.get("negative_prompt", NEGATIVE_PROMPT)
        workflow["27"]["inputs"]["seed"] = seed
        workflow["27"]["inputs"]["cfg"] = CFG
        workflow["27"]["inputs"]["steps"] = STEPS
        workflow["150"]["inputs"]["value"] = WIDTH
        workflow["151"]["inputs"]["value"] = HEIGHT

        # --- Run through ComfyUI ---
        ws = connect_comfyui()
        try:
            output_path = wait_for_completion(ws, workflow)
        finally:
            ws.close()

        if not output_path:
            return {"error": "No video output from ComfyUI"}

        logger.info(f"Generated video: {output_path}")

        # --- Upload to MinIO ---
        user_id = job_input.get("user_id", "unknown")
        avatar_id = job_input.get("avatar_id", uuid.uuid4().hex[:8])
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        minio_key = f"{user_id}/{avatar_id}/idle_{timestamp}.mp4"

        try:
            presigned_url = upload_to_minio(output_path, minio_key)
            logger.info(f"Uploaded to MinIO: {minio_key}")
            return {
                "minio_key": minio_key,
                "video_url": presigned_url,
                "seed": seed,
                "template_id": template_id,
                "fps": FPS,
                "width": WIDTH,
                "height": HEIGHT,
            }
        except Exception as e:
            logger.error(f"MinIO upload failed: {e}")
            output_size_mb = os.path.getsize(output_path) / (1024 * 1024)
            if output_size_mb > BASE64_FALLBACK_MAX_MB:
                return {
                    "error": (
                        "MinIO upload failed and output is too large for base64 fallback "
                        f"({output_size_mb:.1f}MB > {BASE64_FALLBACK_MAX_MB}MB)"
                    ),
                    "seed": seed,
                    "template_id": template_id,
                    "minio_error": str(e),
                }

            with open(output_path, "rb") as f:
                video_b64 = base64.b64encode(f.read()).decode("utf-8")
            return {
                "video_base64": video_b64,
                "seed": seed,
                "template_id": template_id,
                "minio_error": str(e),
                "fps": FPS,
                "width": WIDTH,
                "height": HEIGHT,
            }
    finally:
        shutil.rmtree(task_id, ignore_errors=True)
        for comfy_input_file in comfy_input_files:
            try:
                os.remove(comfy_input_file)
            except OSError:
                pass


if os.getenv("RUNPOD_START_SERVERLESS", "true").lower() == "true":
    runpod.serverless.start({"handler": handler})
